# K8s External Monitoring Stack

## Project Goal
Docker-compose stack that monitors a remote K8s cluster entirely from a local machine using only kubeconfig credentials. No cluster-side installation permitted.

## Directory Structure
```
k8s-external-monitor/
├── CLAUDE.md           # This file - project context for Claude Code
├── documentation/      # Architecture docs, research, guides
├── resources/          # Reference materials, initial prompts, artifacts
├── scripts/            # Helper scripts (setup, teardown, utilities)
└── source/             # Main project source
    ├── docker-compose.yml
    ├── exporter/       # Custom Python metrics exporter
    │   ├── exporter.py
    │   ├── requirements.txt
    │   └── Dockerfile
    ├── prometheus/
    │   └── prometheus.yml
    └── grafana/
        └── provisioning/
            ├── datasources/
            └── dashboards/
```

## Architecture (4 containers)

```
┌─────────────────────────────────────────────────────────────────┐
│                      LOCAL MACHINE                               │
│                                                                  │
│  ┌──────────────────┐    ┌───────────────────────┐              │
│  │ kube-state-metrics│    │ k8s-metrics-exporter  │              │
│  │ --kubeconfig      │    │ metrics.k8s.io API    │              │
│  │                   │    │ + K8s events watch    │              │
│  │ HPA status        │    │                       │              │
│  │ Pod/deploy state  │    │ CPU/mem per pod/node  │              │
│  │ Requests/limits   │    │ Node capacity         │              │
│  └────────┬──────────┘    └──────────┬────────────┘              │
│           │                          │                           │
│           └──────────┬───────────────┘                           │
│                      │                                           │
│              ┌───────┴────────┐                                  │
│              │   Prometheus   │                                  │
│              │ Static scrape  │                                  │
│              └───────┬────────┘                                  │
│              ┌───────┴────────┐                                  │
│              │    Grafana     │                                  │
│              │  5 dashboards  │                                  │
│              └────────────────┘                                  │
│                                                                  │
│  All connected via ~/.kube/config (read-only RBAC)              │
└─────────────────────────────────────────────────────────────────┘
              │
              │ K8s API calls only
              ▼
     ┌──────────────────┐
     │  Remote K8s      │
     │  Cluster         │
     │  (nothing        │
     │   installed)     │
     └──────────────────┘
```

### Container 1: kube-state-metrics
- Official K8s SIG project (v2.14.0)
- Run out-of-cluster with `--kubeconfig` flag
- Covers: HPA status/replicas/conditions, pod phases, deployment replica counts, resource requests/limits
- Port: 8080 (metrics), 8081 (telemetry) — internal only

### Container 2: k8s-metrics-exporter
- Custom Python exporter querying metrics.k8s.io API
- Provides CPU/memory usage per pod and node (same data as `kubectl top`)
- Provides node capacity (CPU cores, memory bytes)
- Watches Kubernetes events and exposes as counters
- Port: 9101 — internal only

### Container 3: Prometheus
- Static scrape config — 4 targets (kube-state-metrics, exporter, self)
- No kubernetes_sd_configs, no TLS/auth config needed
- Provides historical storage of all metrics
- Port: 9090 (bound to 127.0.0.1)

### Container 4: Grafana
- Auto-provisioned with Prometheus datasource
- Pre-loaded dashboards: Cluster Overview, Node Resources, Pod Resources, HPA, Events
- Port: 3000 (bound to 127.0.0.1)

## Key Constraints
- User has read-only kubeconfig access only
- metrics-server is confirmed running on cluster (kubectl top works)
- Everything runs via docker-compose
- Kubeconfig copied to source/secrets/ (not mounted from ~/.kube/config directly)
- No cluster-side installation permitted

## Tech Decisions
- Custom Python exporter queries metrics.k8s.io (replaces broken cAdvisor proxy approach)
- kube-state-metrics for object state (HPA, pods, deployments, resource requests/limits)
- Static Prometheus config (no template generation needed)
- setup.sh only creates Docker-compatible kubeconfig copy
- Grafana provisioning via YAML (datasources + dashboard providers)

## Coverage

### What This Stack Provides
- Historical kubectl top data (CPU/memory per pod and node over time)
- HPA scaling events, current vs desired replicas, scaling conditions
- Resource requests vs limits vs actual usage
- Kubernetes events tracking and alerting
- All stored in Prometheus with configurable retention

### What This Stack Cannot Cover
- Node OS-level metrics (needs node-exporter DaemonSet)
- Network traffic details (needs in-cluster agents)
- Logs (needs in-cluster collectors)
- Custom app metrics (unless exposed via API)

## Prerequisites
1. metrics-server running on target cluster (verify with `kubectl top pods`)
2. ClusterRole with get/list/watch on core resources, metrics.k8s.io, autoscaling, and events
3. Valid kubeconfig with credentials at `~/.kube/config`
4. Docker and docker-compose installed locally

## Development Commands
```bash
# Run setup (creates Docker-compatible kubeconfig)
./scripts/setup.sh

# Start the stack
cd source && docker-compose up -d --build

# View logs
docker-compose logs -f

# Stop the stack
docker-compose down

# Check Prometheus targets
open http://localhost:9090/targets

# Open Grafana (default: admin/admin)
open http://localhost:3000
```
