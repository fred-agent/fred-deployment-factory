{{- define "fred-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fred-stack.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "fred-stack.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "fred-stack.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "fred-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "fred-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fred-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "fred-stack.serviceType" -}}
{{- default "NodePort" .Values.service.type -}}
{{- end -}}

{{/*
Stack profile gating.
"extended" (default) → full stack; "base" → minimal stack.
Returns "true" when the extended profile is selected, "" otherwise.
*/}}
{{- define "fred-stack.stackExtended" -}}
{{- if eq (default "base" .Values.stack) "extended" -}}true{{- end -}}
{{- end -}}

{{/*
Effective enablement for the extended-only components. Each is deployed only
when the extended profile is selected AND its own `enabled` flag is true.
Returns "true" when enabled, "" otherwise.
*/}}
{{- define "fred-stack.clickhouseEnabled" -}}
{{- if and (eq (include "fred-stack.stackExtended" .) "true") .Values.clickhouse.enabled -}}true{{- end -}}
{{- end -}}

{{- /* Observability is part of the base k3d stack: a development instance
without metrics or logs cannot be used to find problems. */ -}}
{{- define "fred-stack.prometheusEnabled" -}}
{{- if .Values.prometheus.enabled -}}true{{- end -}}
{{- end -}}

{{- define "fred-stack.grafanaEnabled" -}}
{{- if .Values.grafana.enabled -}}true{{- end -}}
{{- end -}}

{{- define "fred-stack.logCollectionEnabled" -}}
{{- if .Values.logCollection.enabled -}}true{{- end -}}
{{- end -}}

{{- define "fred-stack.keycloakUrl" -}}
{{- printf "http://%s:%v" .Values.keycloak.hostname .Values.keycloak.publicPort -}}
{{- end -}}

{{- /* The namespace of a Fred release line. */ -}}
{{- define "fred-stack.lineNamespace" -}}
{{- printf "fred-%s" . -}}
{{- end -}}

{{/* The existing HTTP provisioning jobs share the server CA, never its private key. */}}
{{- define "fred-stack.opensearchCurlTls" -}}
{{- if .Values.opensearch.httpTls.existingSecret -}}
--cacert /etc/opensearch-ca/ca.crt
{{- else -}}
-k
{{- end -}}
{{- end -}}

{{- define "fred-stack.opensearchCaMount" -}}
{{- if .Values.opensearch.httpTls.existingSecret -}}
- name: opensearch-http-ca
  mountPath: /etc/opensearch-ca
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "fred-stack.opensearchCaVolume" -}}
{{- if .Values.opensearch.httpTls.existingSecret -}}
- name: opensearch-http-ca
  configMap:
    name: opensearch-http-ca
{{- end -}}
{{- end -}}
