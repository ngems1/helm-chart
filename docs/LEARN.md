# Learn: a 12-factor Helm chart, explained from zero

This guide is for someone who knows roughly what a container is but is new to Helm and Kubernetes production patterns. Read it with [`charts/twelve-factor-app/`](../charts/twelve-factor-app/) open beside it.

---

## 1. What is Helm?

Kubernetes is configured with YAML files (manifests). A real app needs 8–12 of them: a Deployment, Service, ConfigMap, HPA and so on. Writing them by hand for every app and environment is repetitive and error-prone.

**Helm** is a *template engine + package manager* for those files:

```
values.yaml  +  templates/*.yaml   ──helm template──►  plain Kubernetes YAML  ──►  cluster
(your settings)  (YAML with {{ }})
```

- A **chart** is a folder: `Chart.yaml` (name, version), `values.yaml` (defaults), `templates/`.
- A **release** is one installed copy of a chart (`helm install orders ...` creates release `orders`).
- `helm upgrade --install` creates the release or updates it. Running it twice with the same values changes nothing, which is what makes it **idempotent**.

### Reading template syntax

```yaml
name: {{ include "twelve-factor-app.fullname" . }}      # call a helper -> "orders-twelve-factor-app"
{{- if .Values.autoscaling.enabled }}                   # condition; "-" trims the whitespace before it
replicas: {{ .Values.replicaCount }}                    # read a value
labels:
  {{- include "twelve-factor-app.labels" . | nindent 4 }}  # pipe: add a newline + indent 4 spaces
```

Try it: `helm template demo charts/twelve-factor-app | less` prints exactly what would be sent to the cluster.

---

## 2. The 12 factors, and where each lives in this chart

[12factor.net](https://12factor.net) is a list of rules for apps that run well in the cloud. A chart can't make an app 12-factor, but it can make it **easy** to follow the rules and **hard** to break them.

| # | Factor | In plain words | In this chart |
|---|---|---|---|
| I | Codebase | one repo, many deploys | one chart, many values files (`examples/`) |
| II | Dependencies | declare them explicitly | baked into the image; the chart declares `kubeVersion` |
| III | **Config** | config in **env vars**, not in code | `config.env` → ConfigMap → `envFrom` |
| IV | Backing services | a DB is just a URL you're given | `DATABASE_URL` from ESO |
| V | Build, release, run | an immutable build + config = a release | `image.digest`, Helm revisions |
| VI | Processes | stateless; nothing kept on local disk | read-only root filesystem, only `/tmp` writable |
| VII | Port binding | the app opens its own port | `containerPort` + `portEnvName` |
| VIII | Concurrency | scale by running more copies | **HPA** |
| IX | Disposability | start fast, stop gracefully | probes, `preStop` sleep, grace period |
| X | Dev/prod parity | same thing everywhere | same chart on kind and in prod |
| XI | Logs | write to stdout | nothing to configure: the platform collects them |
| XII | Admin processes | one-off tasks use the same code and config | **migration Job** hook |

---

## 3. Config and secrets (factors III and IV)

### 3.1 Non-secret config → ConfigMap

```yaml
config:
  env:
    LOG_LEVEL: info
```

`configmap.yaml` turns this into a ConfigMap, and the Deployment loads all keys as env vars with `envFrom`.

**The catch:** pods read env vars only at **start**. If you change the ConfigMap, running pods keep the old values. The fix is in `deployment.yaml`:

```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

This is a hash of the rendered ConfigMap, put on the **pod template**. When config changes, the hash changes, the pod template changes, and Kubernetes does a rolling restart. When config doesn't change, nothing restarts (idempotent).

### 3.2 Secrets → External Secrets Operator (ESO)

Why not put the DB password in `values.yaml`? Because values files go to git, and git is forever. Even a Kubernetes `Secret` YAML in git is only base64, which is **not encryption**.

Instead, the password lives in a **secret manager** (AWS Secrets Manager, Azure Key Vault, …) and ESO copies it into the cluster:

```
 AWS Secrets Manager                 Kubernetes
 ┌──────────────────────┐   reads    ┌─────────────────────┐  writes  ┌─────────────────────────┐
 │ prod/orders/database │ ◄───────── │ ESO controller      │ ───────► │ Secret orders-...-secrets│
 │ {"url":"postgres://"}│  every 1h  │ (uses ExternalSecret│          │ DATABASE_URL=postgres://│
 └──────────────────────┘            │  + ClusterSecretStore)         └───────────┬─────────────┘
                                     └─────────────────────┘                      │ envFrom
                                                                                   ▼  pods
```

Three objects:

| Object | Who creates it | Says |
|---|---|---|
| `ClusterSecretStore` | platform team, once per cluster (`examples/secretstores/`) | "how to log in to AWS Secrets Manager" |
| `ExternalSecret` | **this chart** | "copy `prod/orders/database`.url into key `DATABASE_URL`" |
| `Secret` | **ESO** (not you!) | the actual values, refreshed every `refreshInterval` |

`data` maps one remote value to one env var. `dataFrom` takes a whole JSON secret and makes one env var per key.

**Rotation:** ESO updates the Secret, but (as with ConfigMaps) running pods keep old env vars. `reloadOnChange: true` adds an annotation for [Stakater Reloader](https://github.com/stakater/Reloader), which restarts the Deployment when the Secret changes.

---

## 4. HPA: Horizontal Pod Autoscaler (factor VIII)

```
CPU usage per pod (vs. its request)       replicas
   90% ┤      ╭──╮                           6 ┤      ╭───╮
   70% ┼------╯--╰------- target             4 ┤   ╭──╯   ╰──╮
   30% ┤──────╯   ╰─────                     2 ┼───╯         ╰─── (min)
```

The HPA checks the metrics every 15 seconds and computes:

```
desiredReplicas = ceil( currentReplicas × currentUtilisation / targetUtilisation )
                = ceil( 2 × 90% / 70% ) = ceil(2.57) = 3
```

Things juniors often get wrong:

1. **Utilisation is a percentage of the *request*.** With `requests.cpu: 100m` and usage of 70m, utilisation is 70%. No request means the HPA can't compute anything, which is why the chart always sets `resources.requests`.
2. **Don't set `replicas` in the Deployment when an HPA exists.** Every `helm upgrade` would reset the count to that number, and the HPA would fight back. The template drops `replicas` when `autoscaling.enabled=true`.
3. **metrics-server** must be installed, or the HPA shows `<unknown>`.
4. **Scale down slowly.** `stabilizationWindowSeconds: 300` means "only scale down if load stayed low for 5 minutes". This avoids flapping.

---

## 5. PDB: Pod Disruption Budget

A node drain (cluster upgrade, autoscaler removing a node) **evicts** pods. Without a PDB, Kubernetes can evict all your replicas at once if they're on the same node.

```yaml
podDisruptionBudget:
  maxUnavailable: 1     # at most 1 pod may be down because of a voluntary disruption
```

The drain then evicts one pod, waits until its replacement is Ready, evicts the next, and so on.

**The classic trap** the chart catches for you:

```yaml
replicas: 2
minAvailable: 2   # "always keep 2 of my 2 pods"  → NO pod may ever be evicted → drain hangs forever
```

`_helpers.tpl` refuses to render this (`minAvailable must be lower than the minimum replica count`). `unhealthyPodEvictionPolicy: AlwaysAllow` (Kubernetes 1.27+) lets already-broken pods be evicted, so a crash-looping pod can't block a drain either.

> A PDB protects only against **voluntary** disruptions (drains). A node that crashes is involuntary. For that, replicas are spread with `topologySpreadConstraints` across zones and nodes.

---

## 6. NetworkPolicy: a firewall for pods

By default, **every pod can talk to every pod** in the cluster. If one app is compromised, the attacker can reach everything.

A NetworkPolicy selects pods and lists what's allowed. Once a pod is selected for `Ingress`/`Egress`, **everything not listed is denied**.

```
                    ┌─────────────────────────── allowed ───────────────────────────┐
 pod with label  ──►│                                                               │
 orders-...-client  │   ingress (port http only)   ┌─────────┐   egress             │
 ingress-nginx ns ─►│ ───────────────────────────► │ app pod │ ───► kube-dns :53    │
 monitoring ns    ─►│                              └─────────┘ ───► 10.0.0.0/16:5432│
                    └───────────────────────────────────────────────────────────────┘
 any other pod ──X  (dropped)                         app pod ──X  169.254.169.254 (metadata)
```

How to read `networkpolicy.yaml`:

```yaml
ingress:
  - ports: [{port: http}]
    from:                 # items in `from` are OR-ed
      - podSelector: ...  #   pods with the client label (same namespace)
      - namespaceSelector: ...  # OR any pod in namespace ingress-nginx
egress:
  - to:
      - namespaceSelector: {kube-system}   # one item with BOTH selectors = AND:
        podSelector: {k8s-app: kube-dns}   # "kube-dns pods IN kube-system"
```

> ⚠️ **AND vs OR** is the #1 NetworkPolicy bug. `- namespaceSelector` and `- podSelector` as **two list items** means OR. Both keys in **one item** means AND.

**Why allow DNS?** With default-deny egress, the app can't even resolve `db.example.com`. Almost every app needs DNS.

**Your CNI must enforce it.** On a cluster without NetworkPolicy support the object is accepted and silently ignored. That's why the e2e test proves an unlabelled pod is **blocked**, rather than just checking that the object exists.

---

## 7. Graceful shutdown (factor IX)

When a pod is deleted, two things happen **in parallel**:

1. the kubelet sends SIGTERM to the app;
2. the endpoints controller removes the pod from the Service, and load balancers notice a few seconds later.

If (1) wins, requests still arrive at a dying app and users get errors. The fix is `preStop: sleep 5`: wait 5 seconds **before** SIGTERM, so traffic has moved away. The total time must fit in `terminationGracePeriodSeconds` (30).

The probes:

| Probe | Question | On failure |
|---|---|---|
| `startupProbe` | "Has it finished starting?" | the other probes wait; after 30×2s the container is restarted |
| `readinessProbe` | "Can it take traffic right now?" | removed from the Service (not restarted) |
| `livenessProbe` | "Is it stuck?" | **restarted** |

Never point liveness at something that checks the database. If the DB goes down, every pod restarts in a loop and makes things worse.

---

## 8. Validating input: the schema and `fail`

`values.schema.json` is a [JSON Schema](https://json-schema.org). Helm checks your merged values against it on `install`, `upgrade`, `lint` and `template`:

```json
"pullPolicy": { "enum": ["Always", "IfNotPresent", "Never"] },
"digest":     { "type": "string", "pattern": "^(sha256:[a-f0-9]{64})?$" }
```

`"additionalProperties": false` makes **unknown keys an error**. Without it, `--set securityContex.runAsNonRoot=false` (typo) is silently ignored, and you'd think a setting is applied when it isn't.

Some rules involve **two fields** (min ≤ max, PDB vs replicas), which a schema can't express. Those are in the `validate` helper with `fail "message"`, and the whole render stops with that message.

---

## 9. Testing a chart at three levels

| Level | Tool | Speed | Catches |
|---|---|---|---|
| Unit | [helm-unittest](https://github.com/helm-unittest/helm-unittest) (`tests/*_test.yaml`) | seconds | logic bugs: "with X set, field Y equals Z" |
| Schema | [kubeconform](https://github.com/yannh/kubeconform) | seconds | YAML Kubernetes would reject (typo'd field, wrong type) |
| E2E | kind + `scripts/e2e-kind.sh` | minutes | real behaviour: secrets sync, NetworkPolicy blocks traffic, pods roll |

A helm-unittest test:

```yaml
- it: leaves replicas to the HPA when autoscaling is on
  template: deployment.yaml
  asserts:
    - notExists:
        path: spec.replicas
```

Run everything locally:

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest
make lint unittest
kind create cluster --name twelve-factor
make e2e
kind delete cluster --name twelve-factor
```

---

## 10. Exercises

1. **Add a KEDA option.** Instead of CPU, scale on queue length. Add `autoscaling.keda.enabled` that renders a `ScaledObject` instead of the HPA, a schema entry, and a unit test.
2. **Break the NetworkPolicy on purpose.** Change the DNS rule into two list items (`- namespaceSelector`, `- podSelector`). What does it allow now? Write a unit test that would have caught it.
3. **Reproduce the drain trap.** On kind with 2 worker nodes, set `autoscaling.enabled=false, replicaCount=1, podDisruptionBudget.minAvailable=1, maxUnavailable=null`. Why does the chart refuse it? Remove the check, run `kubectl drain`, and watch it hang.
4. **Rotate a secret.** In `examples/kind/fake-secretstore.yaml`, change `API_TOKEN` and re-apply. How long until the Kubernetes Secret changes? Do the pods see the new value? What would make them see it?
5. **Add a `worker` process type.** 12-factor apps often run a web process and a background worker from the same image. Add `workers: [{name, command, replicas}]` that renders one extra Deployment per entry (hint: reuse the pod spec in a named template).
6. **Why is the migration Job `post-install` on the first install but `pre-upgrade` afterwards?** (Hint: what doesn't exist yet before the first install?)

---

## 11. Further reading

- [The Twelve-Factor App](https://12factor.net)
- [Helm: chart template guide](https://helm.sh/docs/chart_template_guide/) and [best practices](https://helm.sh/docs/chart_best_practices/)
- [Kubernetes: Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Kubernetes: Disruptions and PDBs](https://kubernetes.io/docs/concepts/workloads/pods/disruptions/)
- [Kubernetes: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) and the visual [editor.networkpolicy.io](https://editor.networkpolicy.io)
- [External Secrets Operator docs](https://external-secrets.io)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
