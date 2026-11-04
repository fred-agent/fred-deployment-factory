{{- define "fred-stack.fluentBitConfig" -}}
[SERVICE]
    Flush         2
    Log_Level     warn
    HTTP_Server   Off

# One record per line of a container's stdout/stderr (CRI format).
[INPUT]
    Name              tail
    Tag               kube.*
    Path              /var/log/containers/*_{{ .Release.Namespace }}_*.log
    Exclude_Path      /var/log/containers/fluent-bit-*
    multiline.parser  cri
    # A file it has never read is read from its start (what a pod logged
    # before Fluent Bit ran); the DB then remembers where each file stops.
    Read_from_Head    On
    DB                /var/lib/fluent-bit/tail.db
    Mem_Buf_Limit     32MB
    Skip_Long_Lines   On
    Refresh_Interval  5

# OOMKilled, BackOff, failed probes, image pulls...
[INPUT]
    Name   kubernetes_events
    Tag    k8s_events

# Pod, container and labels on every line; a line that is JSON (Fred's
# audit log, for one) is parsed under `log_json`, away from other fields.
[FILTER]
    Name             kubernetes
    Match            kube.*
    Kube_Tag_Prefix  kube.var.log.containers.
    Merge_Log        On
    Merge_Log_Key    log_json
    Keep_Log         On
    Labels           On
    Annotations      Off

[OUTPUT]
    Name                opensearch
    Match               kube.*
    Host                opensearch
    Port                9200
    tls                 On
    tls.verify          Off
    HTTP_User           ${OPENSEARCH_USER}
    HTTP_Passwd         ${OPENSEARCH_PASSWORD}
    Logstash_Format     On
    Logstash_Prefix     k3d-logs
    Suppress_Type_Name  On
    Replace_Dots        On
    Retry_Limit         5

[OUTPUT]
    Name                opensearch
    Match               k8s_events
    Host                opensearch
    Port                9200
    tls                 On
    tls.verify          Off
    HTTP_User           ${OPENSEARCH_USER}
    HTTP_Passwd         ${OPENSEARCH_PASSWORD}
    Logstash_Format     On
    Logstash_Prefix     k3d-events
    Suppress_Type_Name  On
    Replace_Dots        On
    Retry_Limit         5
{{- end }}
