# Source Directory

This directory contains the main project source files:

```
source/
├── docker-compose.yml        # Main compose file for all services
├── prometheus/
│   └── prometheus.yml        # Prometheus configuration
└── grafana/
    └── provisioning/
        ├── datasources/      # Auto-provisioned data sources
        │   └── prometheus.yaml
        └── dashboards/       # Dashboard provisioning config + JSON files
            └── provider.yaml
```

## Services

| Service | Port | Purpose |
|---------|------|---------|
| kube-state-metrics | 8080 | K8s object state metrics |
| prometheus | 9090 | Metrics storage & querying |
| grafana | 3000 | Visualization dashboards |

