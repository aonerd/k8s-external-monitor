#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/source"

# Run setup if kubeconfig doesn't exist yet
if [ ! -f "$SOURCE_DIR/secrets/kubeconfig" ]; then
    echo "First run detected - running setup..."
    "$PROJECT_ROOT/scripts/setup.sh"
    echo ""
fi

echo "Starting K8s External Monitor stack..."
docker compose -f "$SOURCE_DIR/docker-compose.yml" up -d --build

echo ""
echo "Stack is starting. Services:"
echo "  Prometheus:         http://localhost:9090"
echo "  Prometheus Targets: http://localhost:9090/targets"
echo "  Grafana:            http://localhost:3000 (admin/admin)"
echo ""
echo "View logs: docker compose -f $SOURCE_DIR/docker-compose.yml logs -f"
