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
{{- default "postgres" .Values.postgresql.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.keycloakName" -}}
{{- default "keycloak" .Values.keycloak.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.openfgaName" -}}
{{- default "openfga" .Values.openfga.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.temporalName" -}}
{{- default "temporal" .Values.temporal.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.temporalUiName" -}}
{{- default "temporal-ui" .Values.temporal.ui.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.controlPlaneBackendName" -}}
{{- default "control-plane-backend" .Values.controlPlane.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.secretName" -}}
{{- default "fredlab-infra-secrets" .Values.secret.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
