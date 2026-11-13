# Changelog

All notable changes to this chart. Format: [Keep a Changelog](https://keepachangelog.com), versions: [SemVer](https://semver.org).

## [1.0.0] - 2026-11-13

### Added
- Deployment for a 12-factor app: config via ConfigMap + `envFrom`, port binding via env, startup/liveness/readiness probes, graceful shutdown (preStop sleep on Kubernetes >= 1.30), non-root + read-only filesystem.
- HorizontalPodAutoscaler (`autoscaling/v2`, CPU and/or memory, scale-down stabilisation).
- PodDisruptionBudget (`policy/v1`) with `unhealthyPodEvictionPolicy: AlwaysAllow` on Kubernetes >= 1.27.
- Default-deny NetworkPolicy with label-based ingress, namespace allow-lists, DNS + CIDR egress.
- External Secrets Operator integration (`ExternalSecret`, `data` + `dataFrom`, optional Reloader annotation).
- Migration Job hook (factor XII), Ingress, ServiceMonitor, topology spread.
- `values.schema.json` (strict: unknown keys rejected) and cross-field validation in `_helpers.tpl`.
- helm-unittest suites, kubeconform, chart-testing and a kind end-to-end test in CI.
