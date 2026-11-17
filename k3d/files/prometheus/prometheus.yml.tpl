global:
  scrape_interval: {{ .Values.prometheus.scrapeInterval }}
  evaluation_interval: {{ .Values.prometheus.evaluationInterval }}

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090

  # The applications deployed next to the stack (Fred, the evaluation app...):
  # every pod container port named `metrics`. Labels `namespace`, `app` and `pod`
  # say which: the same service name exists in several application namespaces.
  - job_name: apps
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - {{ .Release.Namespace | quote }}
            {{- range $line, $_ := .Values.lines }}
            - {{ include "fred-stack.lineNamespace" $line | quote }}
            {{- end }}
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
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

  # CPU and memory of each container, read from every node's kubelet (cAdvisor):
  # also the Rust Control Plane, PostgreSQL and the mock, which expose no KPI.
  # Only two metrics and the namespaces above plus prometheus.containerNamespaces
  # are kept; cAdvisor's labels `namespace`, `pod` and `container` say which.
  {{- $namespaces := list .Release.Namespace }}
  {{- range $line, $_ := .Values.lines }}
  {{- $namespaces = append $namespaces (include "fred-stack.lineNamespace" $line) }}
  {{- end }}
  - job_name: containers
    scheme: https
    metrics_path: /metrics/cadvisor
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    authorization:
      credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    kubernetes_sd_configs:
      - role: node
    metric_relabel_configs:
      - source_labels: [__name__]
        action: keep
        regex: container_cpu_usage_seconds_total|container_memory_working_set_bytes
      - source_labels: [namespace]
        action: keep
        regex: {{ concat $namespaces .Values.prometheus.containerNamespaces | join "|" | quote }}
      # The pod's own cgroup (no container name) and its pause container.
      - source_labels: [container]
        action: drop
        regex: "|POD"

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
