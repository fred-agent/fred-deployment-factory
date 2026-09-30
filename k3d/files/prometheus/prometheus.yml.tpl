global:
  scrape_interval: {{ .Values.prometheus.scrapeInterval }}
  evaluation_interval: {{ .Values.prometheus.evaluationInterval }}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090

  # The applications deployed next to the stack (Fred, the evaluation app...):
  # every pod container port named `metrics`. Labels `app` and `pod` say which.
  - job_name: apps
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - {{ .Release.Namespace | quote }}
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: metrics
      - source_labels: [__meta_kubernetes_pod_phase]
        action: keep
        regex: Running
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component]
        target_label: component
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod

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
