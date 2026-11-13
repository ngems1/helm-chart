#!/usr/bin/env bash
# =============================================================================
# End-to-end test on a real (local) Kubernetes cluster.
#
#   1. installs the External Secrets Operator (ESO) + a "fake" ClusterSecretStore
#   2. installs the chart with examples/kind/values.yaml
#   3. proves: secrets synced -> pods got them, migration Job ran, HPA/PDB exist,
#      `helm test` passes, the NetworkPolicy blocks unlabelled pods,
#      and a config change rolls the pods (checksum annotation)
#
# Usage:   kind create cluster --name twelve-factor   # kind >= 0.24 enforces NetworkPolicy
#          ./scripts/e2e-kind.sh
# Cleanup: kind delete cluster --name twelve-factor
#
# Idempotent: every install is `helm upgrade --install` / `kubectl apply`,
# so you can re-run the script against the same cluster.
# =============================================================================
set -euo pipefail

NS="${NS:-shop}"
RELEASE="${RELEASE:-orders}"
CHART="charts/twelve-factor-app"
ESO_VERSION="${ESO_VERSION:-1.1.0}"   # external-secrets Helm chart version
FULLNAME="${RELEASE}-twelve-factor-app"

cd "$(dirname "$0")/.."

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

dump_debug() {
  # Runs on any failure: print what a human would look at first.
  echo "---- debug ----"
  kubectl get all,externalsecret,secret,networkpolicy,pdb,hpa -n "$NS" || true
  kubectl describe externalsecret -n "$NS" || true
  kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail -n 30 || true
}
trap 'rc=$?; [ $rc -ne 0 ] && dump_debug; exit $rc' EXIT

step "Install External Secrets Operator ${ESO_VERSION}"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$ESO_VERSION" -n external-secrets --create-namespace --wait --timeout 5m

step "Create the fake ClusterSecretStore (local only)"
# The webhook can take a few seconds to accept requests right after install.
for i in $(seq 1 20); do
  kubectl apply -f examples/kind/fake-secretstore.yaml && break
  echo "webhook not ready yet ($i/20)"; sleep 3
done
kubectl wait --for=condition=Ready clustersecretstore/fake-store --timeout=60s

step "Install the chart"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "$RELEASE" "$CHART" -n "$NS" \
  -f examples/kind/values.yaml --wait --timeout 5m

step "Check: ExternalSecret synced into a Kubernetes Secret"
kubectl -n "$NS" wait --for=condition=Ready "externalsecret/${FULLNAME}" --timeout=60s
db_url=$(kubectl -n "$NS" get secret "${FULLNAME}-secrets" -o jsonpath='{.data.DATABASE_URL}' | base64 -d)
[[ "$db_url" == postgres://* ]] && pass "Secret has DATABASE_URL" || fail "DATABASE_URL missing"
token=$(kubectl -n "$NS" get secret "${FULLNAME}-secrets" -o jsonpath='{.data.API_TOKEN}' | base64 -d)
[[ "$token" == "local-dev-token" ]] && pass "dataFrom expanded API_TOKEN" || fail "API_TOKEN missing"

step "Check: the pods received config + secrets as env vars"
env_out=$(kubectl -n "$NS" exec "deploy/${FULLNAME}" -- env)
grep -q '^DATABASE_URL=postgres://' <<<"$env_out" && pass "pod env has DATABASE_URL" || fail "pod env lacks DATABASE_URL"
grep -q '^LOG_LEVEL=info' <<<"$env_out"          && pass "pod env has LOG_LEVEL from ConfigMap" || fail "LOG_LEVEL missing"
grep -q '^PODINFO_PORT=9898' <<<"$env_out"       && pass "pod env has PODINFO_PORT (port binding)" || fail "PODINFO_PORT missing"

step "Check: HPA and PDB"
kubectl -n "$NS" get hpa "$FULLNAME" >/dev/null && pass "HPA exists"
ready=$(kubectl -n "$NS" get deploy "$FULLNAME" -o jsonpath='{.status.readyReplicas}')
[[ "$ready" -ge 2 ]] && pass "deployment has $ready ready replicas (HPA min 2)" || fail "only $ready ready replicas"
allowed=$(kubectl -n "$NS" get pdb "$FULLNAME" -o jsonpath='{.status.disruptionsAllowed}')
[[ "$allowed" == "1" ]] && pass "PDB allows exactly 1 disruption" || fail "PDB disruptionsAllowed=$allowed"

step "Check: helm test (a labelled client pod reaches /readyz)"
helm test "$RELEASE" -n "$NS" --logs --timeout 2m

step "Check: NetworkPolicy blocks pods WITHOUT the client label"
if kubectl -n "$NS" run np-denied --image=busybox:1.37 --restart=Never --rm -i --quiet \
     --command -- wget -q -O- -T 3 "http://${FULLNAME}/readyz" >/dev/null 2>&1; then
  fail "an unlabelled pod reached the app: NetworkPolicy is not enforced"
fi
pass "unlabelled pod was blocked"
kubectl -n "$NS" run np-allowed --image=busybox:1.37 --restart=Never --rm -i --quiet \
  --labels="${FULLNAME}-client=true" \
  --command -- wget -q -O- -T 5 "http://${FULLNAME}/readyz" >/dev/null \
  && pass "labelled pod was allowed" || fail "labelled pod was blocked"

step "Check: a config change rolls the pods (checksum/config)"
before=$(kubectl -n "$NS" get deploy "$FULLNAME" -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')
helm upgrade "$RELEASE" "$CHART" -n "$NS" -f examples/kind/values.yaml \
  --set config.env.LOG_LEVEL=debug --wait --timeout 5m
after=$(kubectl -n "$NS" get deploy "$FULLNAME" -o jsonpath='{.spec.template.metadata.annotations.checksum/config}')
[[ "$before" != "$after" ]] && pass "checksum changed -> rolling restart" || fail "checksum did not change"
kubectl -n "$NS" exec "deploy/${FULLNAME}" -- env | grep -q '^LOG_LEVEL=debug' \
  && pass "new pods see LOG_LEVEL=debug" || fail "new pods still on old config"

step "Check: idempotency (same values again = no changes to the pods)"
gen1=$(kubectl -n "$NS" get deploy "$FULLNAME" -o jsonpath='{.metadata.generation}')
helm upgrade "$RELEASE" "$CHART" -n "$NS" -f examples/kind/values.yaml \
  --set config.env.LOG_LEVEL=debug --wait --timeout 5m
gen2=$(kubectl -n "$NS" get deploy "$FULLNAME" -o jsonpath='{.metadata.generation}')
[[ "$gen1" == "$gen2" ]] && pass "re-applying identical values did not roll the pods" || fail "generation changed $gen1 -> $gen2"

printf '\n\033[1;32mAll end-to-end checks passed.\033[0m\n'
