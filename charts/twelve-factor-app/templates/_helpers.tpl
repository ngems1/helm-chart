{{/*
Helper templates. `include "twelve-factor-app.xxx" .` returns their output as a
string. Kubernetes names are limited to 63 characters, hence the `trunc 63`.
*/}}

{{- define "twelve-factor-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Full name: "<release>-<chart>", or just "<release>" if it already contains the chart name. */}}
{{- define "twelve-factor-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "twelve-factor-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Labels put on every resource (recommended Kubernetes labels). */}}
{{- define "twelve-factor-app.labels" -}}
helm.sh/chart: {{ include "twelve-factor-app.chart" . }}
{{ include "twelve-factor-app.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Labels used to SELECT the pods. They must never change after the first install. */}}
{{- define "twelve-factor-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "twelve-factor-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector for the web (Deployment) pods only. The extra component label keeps
other pods of this release, such as the migration Job, out of the Service, PDB and HPA.
*/}}
{{- define "twelve-factor-app.webSelectorLabels" -}}
{{ include "twelve-factor-app.selectorLabels" . }}
app.kubernetes.io/component: web
{{- end }}

{{- define "twelve-factor-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "twelve-factor-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference: repository@digest when a digest is set, otherwise repository:tag. */}}
{{- define "twelve-factor-app.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}
{{- end }}

{{/* Name of the Secret created by the ExternalSecret. */}}
{{- define "twelve-factor-app.externalSecretTarget" -}}
{{- printf "%s-secrets" (include "twelve-factor-app.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Label that lets a client pod through the NetworkPolicy: "<fullname>-client: true". */}}
{{- define "twelve-factor-app.clientLabel" -}}
{{- printf "%s-client" (include "twelve-factor-app.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Effective minimum number of pods (used to sanity-check the PDB). */}}
{{- define "twelve-factor-app.minReplicas" -}}
{{- if .Values.autoscaling.enabled }}{{ .Values.autoscaling.minReplicas }}{{ else }}{{ .Values.replicaCount }}{{ end }}
{{- end }}

{{/*
Cross-field validation: rules JSON Schema cannot express. Called from deployment.yaml.
*/}}
{{- define "twelve-factor-app.validate" -}}
{{- if and .Values.externalSecrets.enabled (not .Values.externalSecrets.secretStoreRef.name) }}
{{- fail "externalSecrets.enabled=true requires externalSecrets.secretStoreRef.name" }}
{{- end }}
{{- if and .Values.externalSecrets.enabled (not (or .Values.externalSecrets.data .Values.externalSecrets.dataFrom)) }}
{{- fail "externalSecrets.enabled=true requires at least one entry in externalSecrets.data or externalSecrets.dataFrom" }}
{{- end }}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "autoscaling.minReplicas must be <= autoscaling.maxReplicas" }}
{{- end }}
{{- if and .Values.autoscaling.enabled (not (or .Values.autoscaling.targetCPUUtilizationPercentage .Values.autoscaling.targetMemoryUtilizationPercentage)) }}
{{- fail "autoscaling needs targetCPUUtilizationPercentage and/or targetMemoryUtilizationPercentage" }}
{{- end }}
{{- if .Values.podDisruptionBudget.enabled }}
{{- if and (not (kindIs "invalid" .Values.podDisruptionBudget.minAvailable)) (not (kindIs "invalid" .Values.podDisruptionBudget.maxUnavailable)) }}
{{- fail "podDisruptionBudget: set either minAvailable or maxUnavailable, not both" }}
{{- end }}
{{- if and (kindIs "invalid" .Values.podDisruptionBudget.minAvailable) (kindIs "invalid" .Values.podDisruptionBudget.maxUnavailable) }}
{{- fail "podDisruptionBudget: set minAvailable or maxUnavailable" }}
{{- end }}
{{- $min := int (include "twelve-factor-app.minReplicas" .) }}
{{- /* only numeric minAvailable can be compared; "50%" style values are left to Kubernetes */}}
{{- if and (not (kindIs "invalid" .Values.podDisruptionBudget.minAvailable)) (not (kindIs "string" .Values.podDisruptionBudget.minAvailable)) }}
{{- if ge (int .Values.podDisruptionBudget.minAvailable) $min }}
{{- fail (printf "podDisruptionBudget.minAvailable (%d) must be lower than the minimum replica count (%d), otherwise node drains block forever" (int .Values.podDisruptionBudget.minAvailable) $min) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.migration.enabled (not .Values.migration.command) }}
{{- fail "migration.enabled=true requires migration.command" }}
{{- end }}
{{- end }}
