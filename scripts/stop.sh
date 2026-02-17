#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/source"

echo "Stopping K8s External Monitor stack..."
docker compose -f "$SOURCE_DIR/docker-compose.yml" down

echo "Stack stopped."
