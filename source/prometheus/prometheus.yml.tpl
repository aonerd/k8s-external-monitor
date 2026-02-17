global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  # Scrape kube-state-metrics running locally in docker-compose
  - job_name: kube-state-metrics
    static_configs:
      - targets:
          - kube-state-metrics:8080

  # kube-state-metrics self-telemetry
  - job_name: kube-state-metrics-telemetry
    static_configs:
      - targets:
          - kube-state-metrics:8081

  # Scrape cAdvisor metrics via API server proxy
  # Provides actual CPU/memory utilization (same data as kubectl top)
  - job_name: kubernetes-cadvisor
    scheme: https
    authorization:
      credentials_file: /etc/prometheus/token
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: __TLS_SKIP_VERIFY__
    kubernetes_sd_configs:
      - role: node
        kubeconfig_file: /etc/prometheus/kubeconfig
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      # Route through API server proxy (node IPs are not reachable externally)
      - target_label: __address__
        replacement: __API_SERVER__
      # Build cAdvisor proxy path per node
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor
    metric_relabel_configs:
      # Drop high-cardinality container metrics we don't need
      - source_labels: [__name__]
        regex: container_(network_tcp_usage_total|tasks_state|memory_failures_total)
        action: drop

  # Scrape kubelet metrics via API server proxy
  - job_name: kubernetes-nodes
    scheme: https
    authorization:
      credentials_file: /etc/prometheus/token
    tls_config:
      ca_file: /etc/prometheus/ca.crt
      insecure_skip_verify: __TLS_SKIP_VERIFY__
    kubernetes_sd_configs:
      - role: node
        kubeconfig_file: /etc/prometheus/kubeconfig
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: __API_SERVER__
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics

  # Prometheus self-monitoring
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:9090
