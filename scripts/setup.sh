#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/source"
SECRETS_DIR="$SOURCE_DIR/secrets"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== K8s External Monitor - Setup ==="
echo ""

# --- Check prerequisites ---
if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl is not installed"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed"
    exit 1
fi

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "ERROR: kubeconfig not found at $KUBECONFIG_PATH"
    echo "Set KUBECONFIG env var if it's in a different location"
    exit 1
fi

echo "Using kubeconfig: $KUBECONFIG_PATH"

# --- Create Docker-compatible kubeconfig ---
mkdir -p "$SECRETS_DIR"

echo ""
echo "Creating Docker-compatible kubeconfig..."

# Use --minify to only include the current context
kubectl config view --minify --raw --flatten | sed \
    -e 's|https://127\.0\.0\.1|https://host.docker.internal|g' \
    -e 's|https://localhost|https://host.docker.internal|g' \
    > "$SECRETS_DIR/kubeconfig"
chmod 600 "$SECRETS_DIR/kubeconfig"

# If server addresses were rewritten, the TLS cert won't have
# host.docker.internal as a SAN → must skip TLS hostname verification.
# client-go forbids having both CA data and insecure-skip-tls-verify,
# so we must remove the CA data from the kubeconfig.
if grep -q 'host\.docker\.internal' "$SECRETS_DIR/kubeconfig"; then
    sed -i '' \
        -e '/certificate-authority-data:/d' \
        -e '/certificate-authority:/d' \
        "$SECRETS_DIR/kubeconfig"
    sed -i '' '/server: https:\/\/host\.docker\.internal/a\
    insecure-skip-tls-verify: true
' "$SECRETS_DIR/kubeconfig"
    echo "  Configured TLS skip for host.docker.internal (cert SAN mismatch)"
fi

# --- Validate connectivity ---
echo ""
echo "Validating cluster connectivity..."

if kubectl cluster-info &>/dev/null; then
    echo "  Cluster is reachable"
else
    echo "  WARNING: Cannot reach cluster. Check your kubeconfig and network."
fi

if kubectl top pods -A &>/dev/null 2>&1; then
    echo "  metrics-server is available (kubectl top works)"
else
    echo "  WARNING: kubectl top failed. metrics-server may not be running."
fi

if kubectl get events -A --no-headers &>/dev/null 2>&1; then
    echo "  Events API is accessible"
else
    echo "  WARNING: Cannot list events. Event tracking may not work."
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Secrets: $SECRETS_DIR/"
echo ""
echo "Next steps:"
echo "  cd source && docker-compose up -d --build"
echo "  Open Grafana:    http://localhost:3000 (admin/admin)"
echo "  Open Prometheus: http://localhost:9090/targets"
