# K8s External Monitor

Monitor a remote Kubernetes cluster entirely from your local machine using only kubeconfig credentials. No cluster-side installation required.

## What It Does

A docker-compose stack with four containers that gives you historical Kubernetes metrics and dashboards:

- **CPU & memory usage** per pod and node (same data as `kubectl top`, but with history)
- **HPA scaling** events, current vs desired replicas, scaling conditions
- **Resource requests vs limits** vs actual utilization
- **Pod & deployment state** - phases, replica counts, restarts
- **Kubernetes events** - tracking, event rates, warning alerts

All metrics are stored in Prometheus with configurable retention (default: 30 days).

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  LOCAL MACHINE (docker-compose)                              │
│                                                              │
│  ┌────────────────────┐  ┌──────────────────────┐           │
│  │ kube-state-metrics  │  │ k8s-metrics-exporter │           │
│  │ Pod/deploy/HPA state│  │ CPU/mem from          │           │
│  │ Requests & limits   │  │ metrics.k8s.io        │           │
│  └────────┬────────────┘  │ + K8s events          │           │
│           │               └──────────┬────────────┘           │
│           └──────────┬───────────────┘                       │
│                ┌─────┴──────┐                                │
│                │ Prometheus │                                │
│                └─────┬──────┘                                │
│                ┌─────┴──────┐                                │
│                │  Grafana   │                                │
│                │  Dashboards│                                │
│                └────────────┘                                │
│  All connected via ~/.kube/config                            │
└──────────────────────────────────────────────────────────────┘
                 │ K8s API calls only
                 ▼
        ┌─────────────────┐
        │  Remote K8s     │
        │  Cluster        │
        │  (nothing       │
        │   installed)    │
        └─────────────────┘
```

## Prerequisites

- Docker and docker-compose
- Valid kubeconfig at `~/.kube/config` with read access to the cluster
- `kubectl` installed (used by setup script)

## Quick Start

```bash
# 1. Run setup (creates Docker-compatible kubeconfig)
./scripts/setup.sh

# 2. Start the stack
cd source && docker-compose up -d --build

# 3. Open dashboards
open http://localhost:3000    # Grafana (admin/admin)
open http://localhost:9090    # Prometheus
```

## Setup Script

`setup.sh` creates a Docker-compatible copy of your kubeconfig:

- **Loopback addresses** (`127.0.0.1`, `localhost`) are rewritten to `host.docker.internal` for Docker container access
- **TLS verification** is skipped when server address is rewritten (cert SAN mismatch)

Re-run `setup.sh` if you switch kubeconfig contexts.

## Ports

| Service | Port | URL |
|---------|------|-----|
| Grafana | 3000 | http://localhost:3000 |
| Prometheus | 9090 | http://localhost:9090 |

kube-state-metrics and k8s-metrics-exporter are internal only (accessible via Docker network).

## Dashboards

Grafana comes pre-provisioned with:

- **Cluster Overview** - node and pod counts, overall resource usage
- **Node Resources** - per-node CPU and memory utilization
- **Pod Resources** - per-pod CPU and memory with requests/limits
- **HPA** - autoscaler status, replica counts, scaling conditions
- **Events** - recent events table, event rates by type, warning breakdown

## Useful Commands

```bash
# View container logs
cd source && docker-compose logs -f

# Restart after config changes
cd source && docker-compose down && docker-compose up -d --build

# Stop the stack
cd source && docker-compose down

# Validate your kubeconfig
./scripts/validate-kubeconfig.sh
```

## Limitations

This stack monitors via the Kubernetes API only. It **cannot** provide:

- Node OS-level metrics (requires node-exporter DaemonSet)
- Network traffic details (requires in-cluster agents)
- Log aggregation (requires in-cluster collectors)
- Custom application metrics (unless exposed via API)

## Project Structure

```
k8s-external-monitor/
├── scripts/                  # Setup and helper scripts
│   ├── setup.sh              # Kubeconfig setup for Docker
│   ├── start.sh              # Start the stack
│   ├── stop.sh               # Stop the stack
│   └── validate-kubeconfig.sh
├── source/                   # Docker-compose stack
│   ├── docker-compose.yml
│   ├── exporter/             # Custom Python metrics exporter
│   │   ├── exporter.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── grafana/
│       └── provisioning/
│           ├── datasources/
│           └── dashboards/
└── documentation/            # Additional docs
```

## License

[Apache License 2.0](LICENSE)
