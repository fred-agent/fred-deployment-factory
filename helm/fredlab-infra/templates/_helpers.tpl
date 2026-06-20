{{- define "fredlab-infra.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "fredlab-infra.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "fredlab-infra.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "fredlab-infra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "fredlab-infra.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fredlab-infra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "fredlab-infra.postgresName" -}}
{{- printf "%s-postgres" (include "fredlab-infra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.keycloakName" -}}
{{- printf "%s-keycloak" (include "fredlab-infra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.secretName" -}}
{{- printf "%s-secrets" (include "fredlab-infra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
