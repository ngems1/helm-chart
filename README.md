# helm-twelve-factor-app

[![ci](https://github.com/ngems1/helm-twelve-factor-app/actions/workflows/ci.yml/badge.svg)](https://github.com/ngems1/helm-twelve-factor-app/actions/workflows/ci.yml)

A production-ready **Helm chart** for any [12-factor](https://12factor.net) web application, with:

- **HPA**: autoscaling on CPU and/or memory
- **PDB**: survives node drains and cluster upgrades
- **NetworkPolicy**: default-deny, allow only what's needed
- **External Secrets Operator**: secrets come from AWS Secrets Manager, Azure Key Vault, GCP Secret Manager or Vault, never from git
- a strict **`values.schema.json`**: typos and wrong types fail at `helm install`, not at 3 a.m.

> New to Helm, HPA or ESO? Read **[docs/LEARN.md](docs/LEARN.md)** first. It explains every concept from zero, with exercises.

---

## Problem

> *Write a Helm chart + values schema that deploys a 12-factor application with HPA, PDB, NetworkPolicy, and External Secrets Operator integration.*

Most teams copy-paste a chart per service, and each copy drifts: one has no PDB, another hard-codes a password in `values.yaml`, a third breaks node drains with `minAvailable: 100%`. This chart encodes the good defaults **once**, validates input, and is tested at three levels: unit, schema, and a real cluster.

## Architecture

```
                    ┌──────────────────── namespace: shop ──────────────────────────┐
 Secret manager     │                                                               │
 (AWS SM / AKV /    │  ExternalSecret ──ESO──► Secret "<app>-secrets" ─┐            │
  GCP SM / Vault)◄──┼── ClusterSecretStore                             │ envFrom    │
                    │                          ConfigMap "<app>" ──────┤            │
 Ingress ───────────┼─► Service :80 ──► Pods (Deployment) ◄───────────┘            │
 controller         │        ▲            ▲  ▲  non-root, read-only FS, probes     │
                    │        │            │  └─ HPA (2..10, CPU 70%)               │
                    │  ServiceMonitor     │  └─ PDB (maxUnavailable 1)             │
                    │                     └─ NetworkPolicy (default deny;          │
                    │                        in: client label / ingress ns /       │
                    │                        prometheus; out: DNS + listed CIDRs)  │
                    │  Job "<app>-migrate-N" (pre-upgrade hook, same image+config) │
                    └───────────────────────────────────────────────────────────────┘
```

| File | What it renders |
|---|---|
| `templates/deployment.yaml` | the app (calls the validation helper first) |
| `templates/configmap.yaml` | non-secret config `config.env` → env vars |
| `templates/externalsecret.yaml` | ESO `ExternalSecret` → Secret `<fullname>-secrets` |
| `templates/hpa.yaml` | `autoscaling/v2` HorizontalPodAutoscaler |
| `templates/pdb.yaml` | `policy/v1` PodDisruptionBudget |
| `templates/networkpolicy.yaml` | default-deny ingress + egress policy |
| `templates/migration-job.yaml` | factor XII admin process as a Helm hook |
| `templates/service.yaml`, `ingress.yaml`, `servicemonitor.yaml`, `serviceaccount.yaml` | the usual |
| `templates/tests/test-connection.yaml` | `helm test` smoke test |
| `values.schema.json` | JSON Schema (draft-07), `additionalProperties: false` everywhere |
| `templates/_helpers.tpl` → `validate` | cross-field rules the schema can't express |

## Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Kubernetes | >= 1.25 (1.30+ for native `preStop` sleep) | running it |
| Helm | >= 3.12 | install |
| External Secrets Operator | >= 0.17 (serves `external-secrets.io/v1`) | only if `externalSecrets.enabled` |
| metrics-server | any | the HPA needs CPU/memory metrics |
| A CNI that enforces NetworkPolicy | Calico, Cilium, AWS VPC CNI (network policy on), Azure NPM/Cilium, GKE Dataplane V2, kindnet >= kind 0.24 | NetworkPolicy to actually do anything |
| Prometheus Operator | any | only if `metrics.serviceMonitor.enabled` |
| kind, kubeconform, helm-unittest | latest | local testing |

## Usage

```bash
# 1. Defaults: podinfo demo app, HPA 2-10, PDB, NetworkPolicy, no secrets
helm upgrade --install orders charts/twelve-factor-app -n shop --create-namespace

# 2. Production-like (ESO + ingress + migrations + ServiceMonitor)
kubectl apply -f examples/secretstores/aws-secrets-manager.yaml   # once per cluster
helm upgrade --install orders charts/twelve-factor-app -n shop --create-namespace \
  -f examples/values-production.yaml

# 3. Your own app
helm upgrade --install billing charts/twelve-factor-app -n billing --create-namespace \
  --set image.repository=ghcr.io/acme/billing --set image.tag=2.4.1 \
  --set containerPort=8080 --set portEnvName=PORT \
  --set probes.liveness.path=/health --set probes.readiness.path=/ready --set probes.startup.path=/ready
```

Anything that needs to call the app must carry the client label, or come from an allowed namespace:

```yaml
metadata:
  labels:
    orders-twelve-factor-app-client: "true"   # "<fullname>-client"
```

## Examples

### Secrets from AWS Secrets Manager

```yaml
externalSecrets:
  enabled: true
  secretStoreRef: { name: aws-secrets-manager, kind: ClusterSecretStore }
  data:
    - secretKey: DATABASE_URL          # env var name in the pod
      remoteKey: prod/orders/database  # name in Secrets Manager
      property: url                    # field inside the JSON secret
  dataFrom:
    - remoteKey: prod/orders/env       # every JSON key becomes an env var
  reloadOnChange: true                 # restart pods on rotation (Stakater Reloader)
```

Store definitions for **AWS, Azure and GCP** are in [`examples/secretstores/`](examples/secretstores/).

### The schema at work

```console
$ helm install x charts/twelve-factor-app --set replicaCnt=3
Error: values don't meet the specifications of the schema(s) ... Additional property replicaCnt is not allowed

$ helm install x charts/twelve-factor-app --set podDisruptionBudget.maxUnavailable=null --set podDisruptionBudget.minAvailable=2
Error: ... podDisruptionBudget.minAvailable (2) must be lower than the minimum replica count (2), otherwise node drains block forever
```

## Configuration (most used values)

| Key | Default | Description |
|---|---|---|
| `image.repository` / `tag` / `digest` | podinfo / appVersion / "" | digest wins over tag |
| `containerPort`, `portEnvName` | `9898`, `PODINFO_PORT` | port binding (factor VII) |
| `config.env` | `{LOG_LEVEL: info, ...}` | non-secret env vars (ConfigMap) |
| `externalSecrets.enabled` | `false` | create an ExternalSecret |
| `existingSecret` | `""` | load a pre-existing Secret instead |
| `autoscaling.enabled` / `minReplicas` / `maxReplicas` | `true` / 2 / 10 | HPA |
| `autoscaling.targetCPUUtilizationPercentage` | `70` | null to disable |
| `podDisruptionBudget.maxUnavailable` | `1` | or `minAvailable` (one of them) |
| `networkPolicy.enabled` | `true` | default-deny + allow-list |
| `networkPolicy.ingress.fromNamespaces` | `[]` | e.g. `[ingress-nginx]` |
| `networkPolicy.egress.to` | `[]` | `{cidr, except, ports}` |
| `migration.enabled` / `command` | `false` / `[]` | pre-upgrade Job |
| `topologySpread.whenUnsatisfiable` | `ScheduleAnyway` | `DoNotSchedule` to enforce |

Every key is documented in [`values.yaml`](charts/twelve-factor-app/values.yaml) and typed in [`values.schema.json`](charts/twelve-factor-app/values.schema.json).

## Testing

| Level | Command | What it proves |
|---|---|---|
| Lint + schema | `make lint` | templates render; every values file matches the schema |
| Unit | `make unittest` | 40+ assertions on rendered YAML, including the 7 validation failures |
| Schema conformance | `make kubeconform` | output is valid Kubernetes and ESO/ServiceMonitor CRD YAML (CI: k8s 1.29/1.31/1.33) |
| End-to-end | `kind create cluster --name twelve-factor && make e2e` | ESO syncs secrets into pods, migration Job runs, HPA/PDB work, `helm test` passes, the NetworkPolicy **blocks** unlabelled pods, a config change rolls pods, a re-run changes nothing |

## CI checks

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every PR and push to `main`:

1. **lint**: `helm lint --strict` with every values file, plus negative tests (bad values **must** fail)
2. **unittest**: helm-unittest
3. **kubeconform**: matrix of 3 Kubernetes versions × 5 values files
4. **ct-lint**: chart-testing (yamllint, `Chart.yaml` version-bump check)
5. **e2e**: kind cluster + ESO + `scripts/e2e-kind.sh`

## Security considerations

- **No secrets in git.** Secrets come from the secret manager through ESO. The chart has no `secrets:` value on purpose, so nobody is tempted to put one in `values.yaml`.
- **Least privilege at runtime.** The pod runs non-root (UID 10001), `readOnlyRootFilesystem`, all capabilities dropped, `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`. It passes the Kubernetes **restricted** Pod Security Standard.
- **No Kubernetes API token** is mounted unless `serviceAccount.automountToken: true`.
- **Default-deny network.** Inbound only on the http port from allowed sources; outbound only DNS plus listed CIDRs. The production example blocks `169.254.169.254` (cloud metadata), a common SSRF target for credential theft.
- **Immutable images.** `image.digest` pins exact bytes; tags can be moved, digests can't.
- **Scoped secret access.** Use one store per trust boundary, or a namespaced `SecretStore`, and IAM policies scoped to path prefixes (`prod/orders/*`), so one app can't read another's secrets.
- **Schema `additionalProperties: false`.** This catches misspelled security settings, such as `securityContex`, that would otherwise be silently ignored.

## Idempotency notes

- `helm upgrade --install` is idempotent: the same values give the same manifests and the **same pod template**, so no restart. The e2e test verifies this through `metadata.generation`.
- The `checksum/config` annotation changes **only** when `config.env` changes, so pods roll exactly when config changes.
- With the HPA on, the Deployment has **no `replicas` field**, so an upgrade never resets the HPA's current scale.
- The migration Job is named `<fullname>-migrate-<revision>` with `before-hook-creation`, so re-runs never collide with an old Job. **Your migration command must itself be idempotent** (e.g. `migrate up` skips applied migrations), because it runs on every upgrade.
- ESO re-syncs every `refreshInterval`; re-applying the ExternalSecret doesn't duplicate anything (`creationPolicy: Owner`).
- `scripts/e2e-kind.sh` only uses `helm upgrade --install` and `kubectl apply`, so you can re-run it on the same cluster.

## Repository layout

```
charts/twelve-factor-app/   the chart (templates, values, schema, tests/, ci/ values)
examples/                   production values, SecretStores (AWS/Azure/GCP), kind setup
scripts/e2e-kind.sh         end-to-end test
docs/LEARN.md               junior-friendly guide + exercises
ct.yaml, lintconf.yaml      chart-testing config
```

## License

MIT
