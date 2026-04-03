global:
  scrape_interval: {{ .Values.prometheus.scrapeInterval }}
  evaluation_interval: {{ .Values.prometheus.evaluationInterval }}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090

  {{- range $target := .Values.prometheus.extraMetricsTargets }}
  {{- if $target.enabled }}
  - job_name: {{ printf "%s-metrics" $target.jobName | quote }}
    metrics_path: {{ default "/metrics" $target.metricsPath | quote }}
    static_configs:
      - targets:
          - {{ $target.target | quote }}
  {{- end }}
  {{- end }}

  {{- range $path := .Values.prometheus.minioMetricsPaths }}
  {{- $jobSuffix := ($path | trimPrefix "/minio/metrics/v3/" | trimPrefix "/minio/metrics/v3" | default "root" | replace "/" "-") }}
  - job_name: minio-{{ $jobSuffix }}
    metrics_path: {{ $path | quote }}
    static_configs:
      - targets:
          - minio:9000
  {{- end }}

  - job_name: fred-stack-services
    kubernetes_sd_configs:
      - role: service
        namespaces:
          names:
            - {{ .Release.Namespace | quote }}
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_instance]
        action: keep
        regex: {{ .Release.Name | quote }}
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_port, __meta_kubernetes_service_port_number]
        action: keep
        regex: (\d+);$1
      - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_service_name]
        target_label: kubernetes_name

  - job_name: fred-stack-pods
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - {{ .Release.Namespace | quote }}
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_instance]
        action: keep
        regex: {{ .Release.Name | quote }}
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_container_port_number]
        action: keep
        regex: (\d+);$1
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: kubernetes_pod_name
