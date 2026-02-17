#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$PROJECT_ROOT/source"
SECRETS_DIR="$SOURCE_DIR/secrets"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== K8s External Monitor - Setup ==="
echo ""

# Check prerequisites
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
echo ""

# Extract API server address (use --minify to get current context only)
K8S_API_SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
if [ -z "$K8S_API_SERVER" ]; then
    echo "ERROR: Could not extract API server address from kubeconfig"
    exit 1
fi

# Strip protocol to get host:port for Prometheus __address__
API_HOST_PORT=$(echo "$K8S_API_SERVER" | sed -E 's|https?://||')
echo "API server: $K8S_API_SERVER"

# Create secrets directory
mkdir -p "$SECRETS_DIR"

# --- Create Docker-compatible kubeconfig ---
# Inside Docker containers, 127.0.0.1/localhost refers to the container itself.
# Always replace loopback addresses with host.docker.internal in the generated
# kubeconfig, since any cluster entry might use loopback (not just the current one).
echo ""
echo "Creating Docker-compatible kubeconfig..."
# Use --minify to only include the current context (cleaner, avoids affecting other clusters)
kubectl config view --minify --raw --flatten | sed \
    -e 's|https://127\.0\.0\.1|https://host.docker.internal|g' \
    -e 's|https://localhost|https://host.docker.internal|g' \
    > "$SECRETS_DIR/kubeconfig"
chmod 600 "$SECRETS_DIR/kubeconfig"

# If any server addresses were rewritten, the TLS certificate won't have
# host.docker.internal as a SAN → must skip TLS hostname verification.
# client-go forbids having both CA data and insecure-skip-tls-verify,
# so we must remove the CA data from the kubeconfig (it's still extracted
# separately for Prometheus).
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

# Also rewrite API_HOST_PORT for Prometheus relabel config
API_HOST_PORT=$(echo "$API_HOST_PORT" | sed \
    -e 's|127\.0\.0\.1|host.docker.internal|' \
    -e 's|localhost|host.docker.internal|')
echo "  Docker API host:port: $API_HOST_PORT"

# --- Extract CA certificate ---
echo ""
echo "Extracting CA certificate..."
CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)
TLS_SKIP_VERIFY="false"

# If host was rewritten to host.docker.internal, the server cert won't match
# that hostname, so Prometheus scraping must also skip TLS verification.
if grep -q 'host\.docker\.internal' "$SECRETS_DIR/kubeconfig"; then
    TLS_SKIP_VERIFY="true"
fi

if [ -n "$CA_DATA" ]; then
    echo "$CA_DATA" | base64 -d > "$SECRETS_DIR/ca.crt"
    echo "  CA certificate written to secrets/ca.crt"
else
    CA_FILE=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)
    if [ -n "$CA_FILE" ] && [ -f "$CA_FILE" ]; then
        cp "$CA_FILE" "$SECRETS_DIR/ca.crt"
        echo "  CA certificate copied from $CA_FILE"
    else
        echo "  WARNING: No CA certificate found, using insecure_skip_verify"
        TLS_SKIP_VERIFY="true"
        touch "$SECRETS_DIR/ca.crt"
    fi
fi

# --- Extract authentication credentials ---
echo ""
echo "Extracting authentication credentials..."
AUTH_METHOD="none"

# Check for bearer token first
TOKEN=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)

if [ -n "$TOKEN" ]; then
    AUTH_METHOD="bearer"
    echo "$TOKEN" > "$SECRETS_DIR/token"
    echo "  Bearer token extracted from kubeconfig"
else
    # Check for client certificate auth (OrbStack, minikube, kind, etc.)
    CLIENT_CERT_DATA=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null || true)
    CLIENT_KEY_DATA=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-key-data}' 2>/dev/null || true)

    if [ -n "$CLIENT_CERT_DATA" ] && [ -n "$CLIENT_KEY_DATA" ]; then
        AUTH_METHOD="client_cert"
        echo "$CLIENT_CERT_DATA" | base64 -d > "$SECRETS_DIR/client.crt"
        echo "$CLIENT_KEY_DATA" | base64 -d > "$SECRETS_DIR/client.key"
        chmod 600 "$SECRETS_DIR/client.key"
        echo "  Client certificate and key extracted"
    else
        # Check for file-based client certificate
        CLIENT_CERT_FILE=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate}' 2>/dev/null || true)
        CLIENT_KEY_FILE=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-key}' 2>/dev/null || true)

        if [ -n "$CLIENT_CERT_FILE" ] && [ -f "$CLIENT_CERT_FILE" ] && [ -n "$CLIENT_KEY_FILE" ] && [ -f "$CLIENT_KEY_FILE" ]; then
            AUTH_METHOD="client_cert"
            cp "$CLIENT_CERT_FILE" "$SECRETS_DIR/client.crt"
            cp "$CLIENT_KEY_FILE" "$SECRETS_DIR/client.key"
            chmod 600 "$SECRETS_DIR/client.key"
            echo "  Client certificate and key copied from files"
        else
            # Try exec-based credential plugin (EKS, GKE, AKS)
            EXEC_COMMAND=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.exec.command}' 2>/dev/null || true)
            if [ -n "$EXEC_COMMAND" ]; then
                echo "  Detected exec-based credential plugin: $EXEC_COMMAND"
                echo "  Generating token via kubectl..."
                EXEC_ARGS=$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.exec.args}' 2>/dev/null || true)
                TOKEN=$($EXEC_COMMAND $EXEC_ARGS 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('token',''))" 2>/dev/null || true)
                if [ -n "$TOKEN" ]; then
                    AUTH_METHOD="bearer"
                    echo "$TOKEN" > "$SECRETS_DIR/token"
                    echo "  Token generated successfully"
                    echo "  NOTE: Exec-based tokens expire. Re-run setup.sh to refresh."
                else
                    echo "  WARNING: Could not extract token from exec plugin"
                fi
            fi
        fi
    fi
fi

# Ensure all secret files exist (even if empty) to prevent Docker mount errors
touch "$SECRETS_DIR/token" "$SECRETS_DIR/client.crt" "$SECRETS_DIR/client.key"

echo "  Auth method: $AUTH_METHOD"

# --- Generate Prometheus configuration ---
echo ""
echo "Generating Prometheus configuration..."

# Step 1: Basic template substitution
sed \
    -e "s|__API_SERVER__|${API_HOST_PORT}|g" \
    -e "s|__TLS_SKIP_VERIFY__|${TLS_SKIP_VERIFY}|g" \
    "$SOURCE_DIR/prometheus/prometheus.yml.tpl" > "$SOURCE_DIR/prometheus/prometheus.yml"

# Step 2: Apply auth-method-specific configuration
if [ "$AUTH_METHOD" = "client_cert" ]; then
    # Remove bearer token authorization blocks
    sed -i '' '/^[[:space:]]*authorization:/{
N
/credentials_file/d
}' "$SOURCE_DIR/prometheus/prometheus.yml"
    # Add client cert and key to tls_config sections (after ca_file line)
    sed -i '' '/ca_file: \/etc\/prometheus\/ca.crt/a\
      cert_file: /etc/prometheus/client.crt\
      key_file: /etc/prometheus/client.key
' "$SOURCE_DIR/prometheus/prometheus.yml"
    echo "  Configured client certificate auth (mTLS)"
elif [ "$AUTH_METHOD" = "bearer" ]; then
    echo "  Configured bearer token auth"
else
    echo "  WARNING: No auth method configured. Kubernetes API calls may fail."
fi

echo "  Written to source/prometheus/prometheus.yml"

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

echo ""
echo "=== Setup complete ==="
echo ""
echo "Auth method:    $AUTH_METHOD"
echo "Secrets:        $SECRETS_DIR/"
echo "Prometheus cfg: $SOURCE_DIR/prometheus/prometheus.yml"
echo ""
echo "Next steps:"
echo "  cd source && docker-compose up -d"
echo "  Open Grafana:    http://localhost:3000 (admin/admin)"
echo "  Open Prometheus: http://localhost:9090/targets"
