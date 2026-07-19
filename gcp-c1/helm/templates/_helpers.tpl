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

{{- define "fredlab-infra.opensearchName" -}}
{{- default "opensearch" .Values.opensearch.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.temporalName" -}}
{{- default "temporal" .Values.temporal.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.temporalUiName" -}}
{{- default "temporal-ui" .Values.temporal.ui.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.gmpFrontendName" -}}
{{- default "gmp-frontend" .Values.gmpFrontend.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.grafanaName" -}}
{{- default "grafana" .Values.grafana.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.kubeStateMetricsName" -}}
{{- default "kube-state-metrics" .Values.kubeStateMetrics.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.controlPlaneBackendName" -}}
{{- default "control-plane-backend" .Values.controlPlane.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.controlPlaneConfigName" -}}
{{- default "control-plane-config" .Values.controlPlane.configMapName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.fredFrontendName" -}}
{{- default "fred-frontend" .Values.fredFrontend.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.knowledgeFlowName" -}}
{{- default "knowledge-flow-backend" .Values.knowledgeFlow.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.knowledgeFlowConfigName" -}}
{{- default "knowledge-flow-config" .Values.knowledgeFlow.configMapName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.knowledgeFlowWorkerName" -}}
{{- default "knowledge-flow-worker" .Values.knowledgeFlowWorker.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.fredEvaluationName" -}}
{{- default "fred-evaluation-backend" .Values.fredEvaluation.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.fredEvaluationConfigName" -}}
{{- default "fred-evaluation-config" .Values.fredEvaluation.configMapName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.fredEvaluationWorkerName" -}}
{{- default "fred-evaluation-worker" .Values.fredEvaluationWorker.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.agentsName" -}}
{{- default "fred-agents" .Values.fredAgents.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.agentsConfigName" -}}
{{- default "fred-agents-config" .Values.fredAgents.configMapName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fredlab-infra.secretName" -}}
{{- default "fredlab-infra-secrets" .Values.secret.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
