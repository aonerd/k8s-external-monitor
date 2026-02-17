#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

echo "=== Kubeconfig Validation ==="
echo "Using: $KUBECONFIG_PATH"
echo ""

if [ ! -f "$KUBECONFIG_PATH" ]; then
    echo "FAIL: kubeconfig not found at $KUBECONFIG_PATH"
    exit 1
fi

PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" &>/dev/null 2>&1; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

echo "Cluster connectivity:"
check "kubectl cluster-info" kubectl cluster-info

echo ""
echo "Core resources (get/list):"
check "pods" kubectl get pods -A --no-headers
check "nodes" kubectl get nodes --no-headers
check "deployments" kubectl get deployments -A --no-headers
check "services" kubectl get services -A --no-headers
check "namespaces" kubectl get namespaces --no-headers

echo ""
echo "Metrics API:"
check "kubectl top nodes" kubectl top nodes --no-headers
check "kubectl top pods" kubectl top pods -A --no-headers

echo ""
echo "Autoscaling resources:"
check "HPA list" kubectl get hpa -A --no-headers

echo ""
echo "API server proxy (cAdvisor access):"
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$NODE" ]; then
    check "cAdvisor proxy ($NODE)" kubectl get --raw "/api/v1/nodes/$NODE/proxy/metrics/cadvisor"
else
    echo "  SKIP: No nodes found to test proxy access"
    ((FAIL++))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Some checks failed. The stack may still work partially."
    echo "Required for full functionality:"
    echo "  - Core resources: needed for kube-state-metrics"
    echo "  - Metrics API: needed for kubectl top equivalence"
    echo "  - API server proxy: needed for cAdvisor CPU/memory metrics"
    exit 1
fi
