#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/source"

# Run setup if prometheus.yml doesn't exist yet
if [ ! -f "$SOURCE_DIR/prometheus/prometheus.yml" ]; then
    echo "First run detected - running setup..."
    "$PROJECT_ROOT/scripts/setup.sh"
    echo ""
fi

# Verify required files exist
for f in "$SOURCE_DIR/prometheus/prometheus.yml" "$SOURCE_DIR/secrets/token" "$SOURCE_DIR/secrets/ca.crt"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing required file: $f"
        echo "Run scripts/setup.sh first"
        exit 1
    fi
done

echo "Starting K8s External Monitor stack..."
docker compose -f "$SOURCE_DIR/docker-compose.yml" up -d

echo ""
echo "Stack is starting. Services:"
echo "  Prometheus:         http://localhost:9090"
echo "  Prometheus Targets: http://localhost:9090/targets"
echo "  Grafana:            http://localhost:3000 (admin/admin)"
echo "  kube-state-metrics: http://localhost:8080/metrics"
echo ""
echo "View logs: docker compose -f $SOURCE_DIR/docker-compose.yml logs -f"
