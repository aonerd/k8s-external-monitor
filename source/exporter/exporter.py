#!/usr/bin/env python3
"""
k8s-metrics-exporter: Exposes Kubernetes metrics.k8s.io data and cluster events
as Prometheus metrics. Designed for external (out-of-cluster) monitoring via kubeconfig.

Falls back to cAdvisor proxy when metrics.k8s.io has no pod data.
"""

import logging
import os
import re
import signal
import sys
import threading
import time

from kubernetes import client, config, watch
from prometheus_client import Counter, Gauge, start_http_server

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
KUBECONFIG = os.environ.get("KUBECONFIG", "/etc/kubeconfig/config")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9101"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("k8s-metrics-exporter")

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
# Pod-level resource usage (from metrics.k8s.io)
pod_cpu = Gauge(
    "kube_metrics_pod_cpu_usage_cores",
    "Current CPU usage in cores (from metrics.k8s.io)",
    ["namespace", "pod", "node"],
)
pod_mem = Gauge(
    "kube_metrics_pod_memory_usage_bytes",
    "Current memory usage in bytes (from metrics.k8s.io)",
    ["namespace", "pod", "node"],
)

# Node-level resource usage (from metrics.k8s.io)
node_cpu = Gauge(
    "kube_metrics_node_cpu_usage_cores",
    "Current CPU usage in cores (from metrics.k8s.io)",
    ["node"],
)
node_mem = Gauge(
    "kube_metrics_node_memory_usage_bytes",
    "Current memory usage in bytes (from metrics.k8s.io)",
    ["node"],
)

# Node capacity (from core API /api/v1/nodes)
node_cpu_cap = Gauge(
    "kube_metrics_node_cpu_capacity_cores",
    "Total CPU capacity in cores",
    ["node"],
)
node_mem_cap = Gauge(
    "kube_metrics_node_memory_capacity_bytes",
    "Total memory capacity in bytes",
    ["node"],
)

# Kubernetes events
event_count = Counter(
    "kube_event_count",
    "Kubernetes event count",
    ["namespace", "kind", "name", "reason", "type"],
)
event_last_seen = Gauge(
    "kube_event_last_seen_timestamp",
    "Timestamp of last seen event",
    ["namespace", "kind", "name", "reason", "type"],
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def parse_cpu(value: str) -> float:
    """Convert Kubernetes CPU quantity string to cores (float)."""
    if value.endswith("n"):
        return int(value[:-1]) / 1e9
    if value.endswith("u"):
        return int(value[:-1]) / 1e6
    if value.endswith("m"):
        return int(value[:-1]) / 1e3
    return float(value)


def parse_memory(value: str) -> int:
    """Convert Kubernetes memory quantity string to bytes (int)."""
    units = {
        "Ki": 1024,
        "Mi": 1024**2,
        "Gi": 1024**3,
        "Ti": 1024**4,
        "K": 1000,
        "M": 1000**2,
        "G": 1000**3,
        "T": 1000**4,
    }
    for suffix, multiplier in units.items():
        if value.endswith(suffix):
            return int(value[: -len(suffix)]) * multiplier
    return int(value)


def build_pod_node_map(core_v1: client.CoreV1Api) -> dict:
    """Build a mapping of (namespace, pod_name) -> node_name."""
    pod_map = {}
    pods = core_v1.list_pod_for_all_namespaces(
        field_selector="status.phase=Running",
    )
    for pod in pods.items:
        if pod.spec.node_name:
            pod_map[(pod.metadata.namespace, pod.metadata.name)] = pod.spec.node_name
    return pod_map


# ---------------------------------------------------------------------------
# cAdvisor fallback
# ---------------------------------------------------------------------------
# Regex for Prometheus exposition format lines
_METRIC_LINE_RE = re.compile(
    r'^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)'
    r'(?:\{(?P<labels>[^}]*)\})?\s+'
    r'(?P<value>\S+)'
)


def _parse_labels(label_str: str) -> dict:
    """Parse Prometheus label string like 'foo="bar",baz="qux"' into a dict."""
    labels = {}
    if not label_str:
        return labels
    for match in re.finditer(r'(\w+)="([^"]*)"', label_str):
        labels[match.group(1)] = match.group(2)
    return labels


def collect_pod_metrics_from_cadvisor(core_v1: client.CoreV1Api, node_names: list):
    """Fallback: scrape cAdvisor via kubelet proxy to get per-pod CPU/memory.

    Fetches /api/v1/nodes/<node>/proxy/metrics/cadvisor for each node and
    parses out container_cpu_usage_seconds_total and container_memory_working_set_bytes.
    Aggregates per pod, computes CPU rate from two consecutive samples.
    """
    pod_data = {}  # (ns, pod, node) -> {cpu_seconds: float, mem_bytes: int}

    api_client = core_v1.api_client
    for node_name in node_names:
        try:
            raw = core_v1.connect_get_node_proxy_with_path(
                name=node_name,
                path="metrics/cadvisor",
            )
        except Exception as exc:
            log.warning("Failed to scrape cAdvisor from node %s: %s", node_name, exc)
            continue

        for line in raw.split("\n"):
            if line.startswith("#") or not line.strip():
                continue

            m = _METRIC_LINE_RE.match(line)
            if not m:
                continue

            metric_name = m.group("name")
            labels = _parse_labels(m.group("labels") or "")
            value_str = m.group("value")

            # Skip pause containers; keep container="" (pod-level aggregate)
            container = labels.get("container", "")
            if container == "POD":
                continue

            ns = labels.get("namespace", "")
            pod = labels.get("pod", "")
            if not ns or not pod:
                continue

            key = (ns, pod, node_name)

            # Use pod-level aggregates (container="") OR per-container lines.
            # Some runtimes (OrbStack) only emit container="" with pod labels.
            # To avoid double-counting, prefer container="" when it has pod
            # labels; if per-container lines exist, they'll be summed.
            if metric_name == "container_cpu_usage_seconds_total":
                try:
                    val = float(value_str)
                except ValueError:
                    continue
                if key not in pod_data:
                    pod_data[key] = {"cpu_seconds": 0.0, "mem_bytes": 0, "has_container": False}
                # Track if we've seen container-level data
                if container:
                    pod_data[key]["has_container"] = True
                    pod_data[key]["cpu_seconds"] += val
                elif not pod_data[key]["has_container"]:
                    # Use pod-level aggregate only if no container-level data
                    pod_data[key]["cpu_seconds"] = val

            elif metric_name == "container_memory_working_set_bytes":
                try:
                    val = int(float(value_str))
                except ValueError:
                    continue
                if key not in pod_data:
                    pod_data[key] = {"cpu_seconds": 0.0, "mem_bytes": 0, "has_container": False}
                if container:
                    pod_data[key]["has_container"] = True
                    pod_data[key]["mem_bytes"] += val
                elif not pod_data[key].get("has_container_mem"):
                    pod_data[key]["mem_bytes"] = val

    return pod_data


# We store the previous cAdvisor CPU totals to compute a rate
_prev_cadvisor_cpu = {}  # (ns, pod, node) -> (timestamp, cpu_seconds)


def collect_pod_metrics_cadvisor_with_rate(
    core_v1: client.CoreV1Api, node_names: list
):
    """Collect pod metrics from cAdvisor and compute CPU rate (cores).

    Since cAdvisor gives cumulative cpu_seconds, we diff with the previous
    sample to get an instantaneous rate in cores.
    """
    global _prev_cadvisor_cpu
    now = time.time()
    pod_data = collect_pod_metrics_from_cadvisor(core_v1, node_names)

    new_prev = {}
    for key, data in pod_data.items():
        ns, pod_name, node_name = key
        cpu_total = data["cpu_seconds"]
        mem_bytes = data["mem_bytes"]

        # Memory is instantaneous — set directly
        pod_mem.labels(namespace=ns, pod=pod_name, node=node_name).set(mem_bytes)

        # CPU rate: diff with previous sample
        new_prev[key] = (now, cpu_total)
        if key in _prev_cadvisor_cpu:
            prev_time, prev_cpu = _prev_cadvisor_cpu[key]
            dt = now - prev_time
            if dt > 0:
                cpu_cores = (cpu_total - prev_cpu) / dt
                if cpu_cores >= 0:
                    pod_cpu.labels(namespace=ns, pod=pod_name, node=node_name).set(
                        cpu_cores
                    )
        # If no previous sample, skip CPU this cycle (will have data next cycle)

    _prev_cadvisor_cpu = new_prev
    return len(pod_data)


# ---------------------------------------------------------------------------
# Metrics collection
# ---------------------------------------------------------------------------
def collect_metrics(custom_api: client.CustomObjectsApi, core_v1: client.CoreV1Api):
    """Poll metrics.k8s.io and node capacity, update Prometheus gauges."""
    # Clear previous values so disappeared pods/nodes don't linger
    pod_cpu._metrics.clear()
    pod_mem._metrics.clear()
    node_cpu._metrics.clear()
    node_mem._metrics.clear()
    node_cpu_cap._metrics.clear()
    node_mem_cap._metrics.clear()

    # --- Node list (needed for capacity and cAdvisor fallback) ---
    node_names = []
    try:
        nodes = core_v1.list_node()
        for n in nodes.items:
            name = n.metadata.name
            node_names.append(name)
            cap = n.status.capacity
            node_cpu_cap.labels(node=name).set(parse_cpu(cap["cpu"]))
            node_mem_cap.labels(node=name).set(parse_memory(cap["memory"]))
        log.debug("Collected node capacity for %d nodes", len(nodes.items))
    except Exception:
        log.exception("Failed to collect node capacity")

    # --- Pod metrics (try metrics.k8s.io first, fallback to cAdvisor) ---
    pod_count = 0
    try:
        pod_metrics = custom_api.list_cluster_custom_object(
            group="metrics.k8s.io", version="v1beta1", plural="pods"
        )
        items = pod_metrics.get("items", [])
        pod_count = len(items)

        if pod_count > 0:
            try:
                pod_node_map = build_pod_node_map(core_v1)
            except Exception:
                log.exception("Failed to build pod-node map")
                pod_node_map = {}

            for item in items:
                ns = item["metadata"]["namespace"]
                name = item["metadata"]["name"]
                node = pod_node_map.get((ns, name), "unknown")
                total_cpu = 0.0
                total_mem = 0
                for container in item.get("containers", []):
                    total_cpu += parse_cpu(container["usage"]["cpu"])
                    total_mem += parse_memory(container["usage"]["memory"])
                pod_cpu.labels(namespace=ns, pod=name, node=node).set(total_cpu)
                pod_mem.labels(namespace=ns, pod=name, node=node).set(total_mem)
            log.debug("Collected pod metrics for %d pods via metrics.k8s.io", pod_count)
    except Exception:
        log.exception("Failed to query metrics.k8s.io for pod metrics")

    if pod_count == 0 and node_names:
        # Fallback: scrape cAdvisor via kubelet proxy
        try:
            cadvisor_count = collect_pod_metrics_cadvisor_with_rate(
                core_v1, node_names
            )
            log.debug("Collected pod metrics for %d pods via cAdvisor fallback", cadvisor_count)
        except Exception:
            log.exception("Failed cAdvisor fallback for pod metrics")

    # --- Node metrics ---
    try:
        node_metrics = custom_api.list_cluster_custom_object(
            group="metrics.k8s.io", version="v1beta1", plural="nodes"
        )
        for item in node_metrics.get("items", []):
            name = item["metadata"]["name"]
            usage = item["usage"]
            node_cpu.labels(node=name).set(parse_cpu(usage["cpu"]))
            node_mem.labels(node=name).set(parse_memory(usage["memory"]))
        log.debug("Collected node metrics for %d nodes", len(node_metrics.get("items", [])))
    except Exception:
        log.exception("Failed to collect node metrics")


# ---------------------------------------------------------------------------
# Event watcher (runs in a daemon thread)
# ---------------------------------------------------------------------------
def watch_events(core_v1: client.CoreV1Api, stop_event: threading.Event):
    """Watch Kubernetes events and increment counters."""
    w = watch.Watch()
    while not stop_event.is_set():
        try:
            log.info("Starting event watch stream")
            for ev in w.stream(core_v1.list_event_for_all_namespaces, timeout_seconds=300):
                if stop_event.is_set():
                    break
                obj = ev["object"]
                labels = {
                    "namespace": obj.metadata.namespace or "",
                    "kind": obj.involved_object.kind if obj.involved_object else "",
                    "name": obj.involved_object.name if obj.involved_object else "",
                    "reason": obj.reason or "",
                    "type": obj.type or "",
                }
                count = obj.count if obj.count else 1
                event_count.labels(**labels).inc(count)
                if obj.last_timestamp:
                    event_last_seen.labels(**labels).set(obj.last_timestamp.timestamp())
        except Exception:
            if stop_event.is_set():
                break
            log.exception("Event watch error, reconnecting in 10s")
            time.sleep(10)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    log.info(
        "Starting k8s-metrics-exporter (poll=%ds, port=%d)", POLL_INTERVAL, EXPORTER_PORT
    )

    # Load kubeconfig
    try:
        config.load_kube_config(config_file=KUBECONFIG)
        log.info("Loaded kubeconfig from %s", KUBECONFIG)
    except Exception:
        log.exception("Failed to load kubeconfig from %s", KUBECONFIG)
        sys.exit(1)

    custom_api = client.CustomObjectsApi()
    core_v1 = client.CoreV1Api()

    # Start Prometheus HTTP server
    start_http_server(EXPORTER_PORT)
    log.info("Prometheus metrics server listening on :%d", EXPORTER_PORT)

    # Start event watcher in background
    stop_event = threading.Event()
    event_thread = threading.Thread(
        target=watch_events, args=(core_v1, stop_event), daemon=True
    )
    event_thread.start()

    # Graceful shutdown
    def shutdown(signum, frame):
        log.info("Received signal %d, shutting down", signum)
        stop_event.set()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Poll loop
    while True:
        try:
            collect_metrics(custom_api, core_v1)
            log.info("Metrics collection complete")
        except Exception:
            log.exception("Unexpected error in poll loop")
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
