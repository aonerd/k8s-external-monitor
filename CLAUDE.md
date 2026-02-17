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
    ├── prometheus/
    │   └── prometheus.yml
    └── grafana/
        └── provisioning/
            ├── datasources/
            └── dashboards/
```

## Architecture (3 containers)

```
┌─────────────────────────────────────────────────────────────────┐
│                      LOCAL MACHINE                               │
│                                                                  │
│  ┌──────────────────┐    ┌───────────────────────┐              │
│  │ kube-state-metrics│    │ Prometheus            │              │
│  │ --kubeconfig      │    │ kubernetes_sd_config   │              │
│  │                   │    │ + API proxy relabeling │              │
│  │ HPA status        │    │                       │              │
│  │ Pod/deploy state  │◄───┤ cAdvisor CPU/mem via  │              │
│  │ Requests/limits   │    │ /api/v1/nodes/*/proxy │              │
│  └────────┬──────────┘    └──────────┬────────────┘              │
│           │          ▲               │                           │
│           └──────────┼───────────────┘                           │
│                      │                                           │
│              ┌───────┴────────┐                                  │
│              │    Grafana     │                                  │
│              │  k8s-mixin +   │                                  │
│              │  HPA dashboards │                                  │
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
- Official K8s SIG project (v2.18+)
- Run out-of-cluster with `--kubeconfig` flag
- Covers: HPA status/replicas/conditions, pod phases, deployment replica counts, resource requests/limits
- Port: 8080 (metrics), 8081 (telemetry)

### Container 2: Prometheus
- Uses `kubernetes_sd_config` with `kubeconfig_file` for node discovery
- Relabels scrape targets to route through API server proxy: `/api/v1/nodes/<node>/proxy/metrics/cadvisor`
- Scrapes kube-state-metrics locally
- Provides historical storage of all metrics
- Port: 9090

### Container 3: Grafana
- Auto-provisioned with Prometheus datasource
- Pre-loaded kubernetes-mixin dashboards
- Pre-loaded kubernetes-autoscaling-mixin dashboards (HPA)
- Port: 3000

## Key Constraints
- User has read-only kubeconfig access only
- metrics-server is confirmed running on cluster (kubectl top works)
- Everything runs via docker-compose
- Mount ~/.kube/config as read-only volume
- No cluster-side installation permitted

## Tech Decisions
- No custom Python exporter needed — kube-state-metrics + cAdvisor proxy covers both object state and utilization
- Grafana provisioning via YAML (datasources + dashboard providers)
- Use kubernetes-mixin and kubernetes-autoscaling-mixin dashboards
- Use Sacreman gist pattern for Prometheus external scraping

## Coverage

### What This Stack Provides
- Historical kubectl top data (CPU/memory per pod and node over time)
- HPA scaling events, current vs desired replicas, scaling conditions
- Resource requests vs limits vs actual usage
- All stored in Prometheus with configurable retention

### What This Stack Cannot Cover
- Node OS-level metrics (needs node-exporter DaemonSet)
- Network traffic details (needs in-cluster agents)
- Logs (needs in-cluster collectors)
- Custom app metrics (unless accessible via API proxy)

## Prerequisites
1. metrics-server running on target cluster (verify with `kubectl top pods`)
2. ClusterRole with get/list/watch on core resources, metrics.k8s.io, and autoscaling groups
3. Valid kubeconfig with credentials at `~/.kube/config`
4. Docker and docker-compose installed locally

## Development Commands
```bash
# Start the stack
cd source && docker-compose up -d

# View logs
docker-compose logs -f

# Stop the stack
docker-compose down

# Check Prometheus targets
open http://localhost:9090/targets

# Open Grafana (default: admin/admin)
open http://localhost:3000
```

## Implementation Tasks
1. Create `source/docker-compose.yml` with all three services
2. Create `source/prometheus/prometheus.yml` with:
   - kubernetes_sd_config using kubeconfig_file
   - API-server proxy relabeling for cAdvisor metrics
   - Local scrape job for kube-state-metrics
3. Create Grafana provisioning:
   - `source/grafana/provisioning/datasources/prometheus.yaml`
   - `source/grafana/provisioning/dashboards/provider.yaml`
   - Dashboard JSON files from kubernetes-mixin
4. Create helper scripts in `scripts/`
5. Create README and setup documentation in `documentation/`

