# K8s External Monitor - Documentation

## Overview

This project provides a local observability stack for monitoring Kubernetes clusters when you only have read-only API access (via kubeconfig) and cannot install anything on the cluster itself.

## Architecture

The stack consists of three containers running via docker-compose:

1. **kube-state-metrics** - Exposes Kubernetes object state as Prometheus metrics
2. **Prometheus** - Scrapes and stores metrics with historical retention
3. **Grafana** - Visualizes metrics with pre-built Kubernetes dashboards

All components connect to the remote cluster using your existing kubeconfig credentials.

## Quick Start

See the main [CLAUDE.md](../CLAUDE.md) for setup instructions and development commands.

## Research & Background

The original research and architecture decisions are documented in [resources/inital-prompt.txt](../resources/inital-prompt.txt).

## Key Documents

- `architecture.md` - Detailed architecture and data flow (TODO)
- `setup-guide.md` - Step-by-step setup instructions (TODO)
- `troubleshooting.md` - Common issues and solutions (TODO)

