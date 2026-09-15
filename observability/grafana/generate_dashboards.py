#!/usr/bin/env python3
"""Generate versioned Grafana dashboards for the local Zilla observability stack."""

from __future__ import annotations

import json
from pathlib import Path

DATASOURCE = {"type": "prometheus", "uid": "prometheus"}
DASHBOARD_DIR = Path(__file__).resolve().parent / "dashboards"

APP = (
    'model=~"$model", namespace=~"$namespace", namespace!="monitoring", '
    'tenant=~"$tenant", group=~"$group", service=~"$service", pod=~"$pod"'
)
PROCESS = (
    'model=~"$model", namespace=~"$namespace", namespace!="monitoring", '
    'group=~"$group", service=~"$service", pod=~"$pod"'
)
BACKEND = f'zilla_target_type="backend", {APP}'
BACKEND_PROCESS = f'zilla_target_type="backend", {PROCESS}'
POSTGRES = f'zilla_target_type="postgres", {APP}'
REDIS = f'zilla_target_type="redis", {APP}'
K8S = 'namespace=~"$namespace", namespace!="monitoring", pod=~"$pod"'
K8S_CONTAINER = f'{K8S}, container!="", container!="POD"'
K8S_NS = 'namespace=~"$namespace", namespace!="monitoring"'
POSTGRES_POD = f'{K8S_NS}, container!="", container!="POD", pod=~"postgres-.*", pod!~".*exporter.*"'
REDIS_POD = f'{K8S_NS}, container!="", container!="POD", pod=~"redis-.*", pod!~".*exporter.*"'


class Layout:
    def __init__(self) -> None:
        self.x = 0
        self.y = 0
        self.row_h = 0
        self.next_id = 1

    def allocate(self, width: int, height: int) -> dict:
        if self.x + width > 24:
            self.x = 0
            self.y += self.row_h
            self.row_h = 0
        pos = {"x": self.x, "y": self.y, "w": width, "h": height}
        self.x += width
        self.row_h = max(self.row_h, height)
        return pos

    def row(self, title: str) -> dict:
        if self.x > 0 or self.row_h > 0:
            self.y += self.row_h
        self.x = 0
        self.row_h = 0
        panel = {
            "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y},
            "id": self.panel_id(),
            "panels": [],
            "title": title,
            "type": "row",
        }
        self.y += 1
        return panel

    def panel_id(self) -> int:
        panel_id = self.next_id
        self.next_id += 1
        return panel_id


def query(expr: str, legend: str, ref_id: str, instant: bool = False) -> dict:
    target = {
        "datasource": DATASOURCE,
        "editorMode": "code",
        "expr": expr,
        "legendFormat": legend,
        "refId": ref_id,
    }
    if instant:
        target["instant"] = True
        target["range"] = False
    else:
        target["range"] = True
    return target


def timeseries(layout: Layout, title: str, description: str, unit: str, targets: list[dict], width: int = 12, height: int = 8) -> dict:
    return {
        "datasource": DATASOURCE,
        "description": description,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "axisBorderShow": False,
                    "axisCenteredZero": False,
                    "axisColorMode": "text",
                    "axisLabel": "",
                    "axisPlacement": "auto",
                    "barAlignment": 0,
                    "drawStyle": "line",
                    "fillOpacity": 15,
                    "gradientMode": "none",
                    "hideFrom": {"legend": False, "tooltip": False, "viz": False},
                    "insertNulls": False,
                    "lineInterpolation": "smooth",
                    "lineWidth": 1,
                    "pointSize": 5,
                    "scaleDistribution": {"type": "linear"},
                    "showPoints": "never",
                    "spanNulls": False,
                    "stacking": {"group": "A", "mode": "none"},
                    "thresholdsStyle": {"mode": "off"},
                },
                "mappings": [],
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
                "unit": unit,
            },
            "overrides": [],
        },
        "gridPos": layout.allocate(width, height),
        "id": layout.panel_id(),
        "options": {
            "legend": {
                "calcs": ["mean", "lastNotNull"],
                "displayMode": "table",
                "placement": "bottom",
                "showLegend": True,
            },
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "targets": targets,
        "title": title,
        "type": "timeseries",
    }


def stat(layout: Layout, title: str, description: str, unit: str, expr: str, width: int = 4, height: int = 4) -> dict:
    return {
        "datasource": DATASOURCE,
        "description": description,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "mappings": [],
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "green", "value": None},
                        {"color": "yellow", "value": None},
                    ],
                },
                "unit": unit,
            },
            "overrides": [],
        },
        "gridPos": layout.allocate(width, height),
        "id": layout.panel_id(),
        "options": {
            "colorMode": "value",
            "graphMode": "area",
            "justifyMode": "auto",
            "orientation": "auto",
            "percentChangeColorMode": "standard",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "showPercentChange": False,
            "textMode": "auto",
            "wideLayout": True,
        },
        "targets": [query(expr, title, "A", instant=True)],
        "title": title,
        "type": "stat",
    }


def table(layout: Layout, title: str, description: str, unit: str, targets: list[dict], width: int = 12, height: int = 8) -> dict:
    return {
        "datasource": DATASOURCE,
        "description": description,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "inspect": False},
                "mappings": [],
                "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
                "unit": unit,
            },
            "overrides": [],
        },
        "gridPos": layout.allocate(width, height),
        "id": layout.panel_id(),
        "options": {
            "cellHeight": "sm",
            "footer": {"countRows": False, "fields": "", "reducer": ["sum"], "show": False},
            "showHeader": True,
        },
        "targets": [
            {**target, "format": "table", "instant": True, "range": False}
            for target in targets
        ],
        "title": title,
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": True, "__name__": True}}},
        ],
        "type": "table",
    }


def variable(name: str, label: str, expr: str, description: str) -> dict:
    return {
        "allValue": ".*",
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
        "datasource": DATASOURCE,
        "definition": expr,
        "description": description,
        "includeAll": True,
        "label": label,
        "multi": True,
        "name": name,
        "options": [],
        "query": {"qryType": 1, "query": expr, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
        "refresh": 2,
        "regex": "",
        "skipUrlSync": False,
        "sort": 1,
        "type": "query",
    }


def dashboard(title: str, uid: str, description: str, variables: list[dict], panels: list[dict]) -> dict:
    return {
        "annotations": {"list": []},
        "description": description,
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 1,
        "id": None,
        "links": [],
        "liveNow": False,
        "panels": panels,
        "refresh": "15s",
        "schemaVersion": 39,
        "tags": ["zilla"],
        "templating": {"list": variables},
        "time": {"from": "now-1h", "to": "now"},
        "timepicker": {},
        "timezone": "browser",
        "title": title,
        "uid": uid,
        "version": 1,
        "weekStart": "",
    }


def common_variables(*extra: dict) -> list[dict]:
    variables = [
        variable("model", "Model", 'label_values(up{zilla_target_type=~"backend|postgres|redis"}, model)', "Infrastructure model label from ServiceMonitor targets."),
        variable("namespace", "Namespace", 'label_values(kube_namespace_created{namespace!="monitoring"}, namespace)', "Application namespaces. The monitoring namespace is never listed."),
        variable("tenant", "Tenant", "label_values(zilla_http_requests_total, tenant)", "Validated application tenant label. Shared backends still split HTTP series here."),
        variable("group", "Group", 'label_values(up{zilla_target_type=~"backend|postgres|redis"}, group)', "Grouped-model group label. Empty for ISO/hybrid/shared."),
        variable("service", "Service", 'label_values(up{zilla_target_type=~"backend|postgres|redis", namespace=~"$namespace"}, service)', "Kubernetes Service name of the scrape target."),
        variable("pod", "Pod", 'label_values(kube_pod_info{namespace=~"$namespace", namespace!="monitoring"}, pod)', "Application pods in the selected namespaces."),
    ]
    variables.extend(extra)
    return variables


def model_overview() -> dict:
    layout = Layout()
    panels = [
        layout.row("Model capacity"),
        stat(
            layout,
            "CPU cores",
            "Sum of container CPU usage across the selected application namespaces. Monitoring is excluded so the stack is not counted as model cost.",
            "cores",
            f"sum(rate(container_cpu_usage_seconds_total{{{K8S_CONTAINER}}}[5m]))",
        ),
        stat(
            layout,
            "Memory working set",
            "Sum of container memory working set. This is additive across pods and excludes the monitoring namespace.",
            "bytes",
            f"sum(container_memory_working_set_bytes{{{K8S_CONTAINER}}})",
        ),
        stat(
            layout,
            "Running pods",
            "Count of pods currently in the Running phase. Monitoring pods are excluded.",
            "short",
            f'sum(kube_pod_status_phase{{{K8S}, phase="Running"}} == 1)',
        ),
        stat(
            layout,
            "Restarts (1h)",
            "Total container restarts in the last hour. Use this to compare stability across models, not as a per-pod gauge average.",
            "short",
            f"sum(increase(kube_pod_container_status_restarts_total{{{K8S}}}[1h]))",
        ),
        stat(
            layout,
            "CPU throttle ratio",
            "Share of CFS periods that were throttled. This is a ratio of rates, not a sum of gauge percentages.",
            "percentunit",
            f"sum(rate(container_cpu_cfs_throttled_periods_total{{{K8S_CONTAINER}}}[5m])) / clamp_min(sum(rate(container_cpu_cfs_periods_total{{{K8S_CONTAINER}}}[5m])), 1e-9)",
        ),
        stat(
            layout,
            "OOM events (1h)",
            "cAdvisor OOM events in the last hour. Complements kube_pod_container_status_last_terminated_reason for killed containers.",
            "short",
            f"sum(increase(container_oom_events_total{{{K8S_CONTAINER}}}[1h]))",
        ),
        layout.row("CPU, memory and reliability"),
        timeseries(
            layout,
            "CPU by namespace",
            "Application CPU by namespace. In ISO this maps to a tenant; in shared/hybrid it is the shared stack. Monitoring is excluded.",
            "cores",
            [query(f"sum by (namespace) (rate(container_cpu_usage_seconds_total{{{K8S_CONTAINER}}}[5m]))", "{{namespace}}", "A")],
        ),
        timeseries(
            layout,
            "Memory by namespace",
            "Working-set memory by namespace. Gauges are summed across pods in a namespace because memory is additive.",
            "bytes",
            [query(f"sum by (namespace) (container_memory_working_set_bytes{{{K8S_CONTAINER}}})", "{{namespace}}", "A")],
        ),
        timeseries(
            layout,
            "CPU by pod",
            "Per-pod CPU. Each series is one pod; do not treat this as a tenant split on shared backends.",
            "cores",
            [query(f"sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{K8S_CONTAINER}}}[5m]))", "{{namespace}}/{{pod}}", "A")],
        ),
        timeseries(
            layout,
            "Memory by pod",
            "Per-pod working set. Shown per pod rather than averaged, so a single large process is visible.",
            "bytes",
            [query(f"sum by (namespace, pod) (container_memory_working_set_bytes{{{K8S_CONTAINER}}})", "{{namespace}}/{{pod}}", "A")],
        ),
        timeseries(
            layout,
            "Restarts by pod",
            "Hourly restart increase per pod. Useful when comparing isolated tenants against a shared process.",
            "short",
            [query(f"sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{{{K8S}}}[1h]))", "{{namespace}}/{{pod}}", "A")],
        ),
        timeseries(
            layout,
            "CPU throttling by pod",
            "Per-pod throttle ratio from CFS periods. Ratio of rates, never a summed percentage.",
            "percentunit",
            [
                query(
                    f"sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{{{K8S_CONTAINER}}}[5m])) / clamp_min(sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{{{K8S_CONTAINER}}}[5m])), 1e-9)",
                    "{{namespace}}/{{pod}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "OOM-killed containers",
            "Pods whose last termination reason is OOMKilled. This is a 0/1 gauge per container, shown as a sum of currently marked containers.",
            "short",
            [
                query(
                    f'sum by (namespace, pod) (kube_pod_container_status_last_terminated_reason{{{K8S}, reason="OOMKilled"}})',
                    "{{namespace}}/{{pod}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Pods by phase",
            "Pod count by Kubernetes phase. Each phase is counted, not averaged, across the selected namespaces.",
            "short",
            [query(f"sum by (phase) (kube_pod_status_phase{{{K8S}}} == 1)", "{{phase}}", "A")],
        ),
        layout.row("HTTP traffic"),
        timeseries(
            layout,
            "Requests per second",
            "Application request rate from zilla_http_requests_total. Multiple backend pods are summed after rate().",
            "reqps",
            [query(f"sum(rate(zilla_http_requests_total{{{BACKEND}}}[5m]))", "all", "A")],
            width=8,
        ),
        timeseries(
            layout,
            "Error rate",
            "5xx share of HTTP requests. Built from two counters so a missing error series becomes 0 rather than inflating the ratio.",
            "percentunit",
            [
                query(
                    f'sum(rate(zilla_http_requests_total{{{BACKEND}, status_code=~"5.."}}[5m])) / clamp_min(sum(rate(zilla_http_requests_total{{{BACKEND}}}[5m])), 1e-9)',
                    "5xx",
                    "A",
                )
            ],
            width=8,
        ),
        timeseries(
            layout,
            "Latency p50 / p95 / p99",
            "Request latency from histogram buckets. histogram_quantile is applied after summing buckets across pods by le.",
            "s",
            [
                query(
                    f"histogram_quantile(0.50, sum by (le) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "p50",
                    "A",
                ),
                query(
                    f"histogram_quantile(0.95, sum by (le) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "p95",
                    "B",
                ),
                query(
                    f"histogram_quantile(0.99, sum by (le) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "p99",
                    "C",
                ),
            ],
            width=8,
        ),
        timeseries(
            layout,
            "Requests per second by tenant",
            "HTTP rate split by the backend tenant label. This is the correct tenant view for shared backends, which are a single scrape target.",
            "reqps",
            [query(f"sum by (tenant) (rate(zilla_http_requests_total{{{BACKEND}}}[5m]))", "{{tenant}}", "A")],
        ),
        timeseries(
            layout,
            "CPU by tenant label",
            "CPU of pods that carry zilla.io/tenant. Shared data-layer pods without that label are omitted here and remain in the namespace panels.",
            "cores",
            [
                query(
                    "sum by (label_zilla_io_tenant) ("
                    f"rate(container_cpu_usage_seconds_total{{{K8S_CONTAINER}}}[5m])"
                    " * on(namespace, pod) group_left(label_zilla_io_tenant) "
                    f'kube_pod_labels{{{K8S}, label_zilla_io_tenant=~"$tenant", label_zilla_io_tenant!=""}}'
                    ")",
                    "{{label_zilla_io_tenant}}",
                    "A",
                )
            ],
        ),
    ]
    return dashboard(
        "Zilla Model Overview",
        "zilla-model-overview",
        "Cluster-level comparison of a Zilla infrastructure model, excluding the monitoring namespace.",
        common_variables(),
        panels,
    )


def backend_tenants() -> dict:
    layout = Layout()
    panels = [
        layout.row("HTTP by pod and tenant"),
        timeseries(
            layout,
            "Requests per second by tenant",
            "HTTP rate by validated tenant label. Shared backends keep one target and still split here.",
            "reqps",
            [query(f"sum by (tenant) (rate(zilla_http_requests_total{{{BACKEND}}}[5m]))", "{{tenant}}", "A")],
        ),
        timeseries(
            layout,
            "Requests per second by pod",
            "HTTP rate by backend pod. Rate is taken per series, then summed by pod across methods and routes.",
            "reqps",
            [query(f"sum by (namespace, pod) (rate(zilla_http_requests_total{{{BACKEND}}}[5m]))", "{{namespace}}/{{pod}}", "A")],
        ),
        timeseries(
            layout,
            "In-flight requests by pod",
            "Gauge of requests currently handled by each backend pod. Shown per pod; do not average this value across pods.",
            "short",
            [query(f"sum by (namespace, pod, method) (zilla_http_requests_in_flight{{{BACKEND_PROCESS}}})", "{{pod}} {{method}}", "A")],
        ),
        timeseries(
            layout,
            "In-flight requests total",
            "Sum of in-flight gauges across selected backend pods. Summing is valid because each pod reports its own concurrent requests.",
            "short",
            [query(f"sum(zilla_http_requests_in_flight{{{BACKEND_PROCESS}}})", "in flight", "A")],
        ),
        timeseries(
            layout,
            "Error rate by tenant",
            "5xx ratio by tenant. Built from counters, not from averaged gauges.",
            "percentunit",
            [
                query(
                    f'sum by (tenant) (rate(zilla_http_requests_total{{{BACKEND}, status_code=~"5.."}}[5m])) / clamp_min(sum by (tenant) (rate(zilla_http_requests_total{{{BACKEND}}}[5m])), 1e-9)',
                    "{{tenant}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Latency p50 / p95 / p99",
            "Overall HTTP latency. histogram_quantile after summing buckets across pods by le.",
            "s",
            [
                query(
                    f"histogram_quantile(0.50, sum by (le) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "p50",
                    "A",
                ),
                query(
                    f"histogram_quantile(0.95, sum by (le) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "p95",
                    "B",
                ),
                query(
                    f"histogram_quantile(0.99, sum by (le) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "p99",
                    "C",
                ),
            ],
        ),
        layout.row("Slow routes and errors"),
        timeseries(
            layout,
            "p95 latency by tenant",
            "Per-tenant p95 from histogram buckets. Buckets are summed by le and tenant before quantile.",
            "s",
            [
                query(
                    f"histogram_quantile(0.95, sum by (le, tenant) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "{{tenant}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "p95 latency by route",
            "Slowest normalized Express routes. Route labels are templates such as /api/project/:projectKey, never raw URLs.",
            "s",
            [
                query(
                    f"histogram_quantile(0.95, sum by (le, route) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "{{route}}",
                    "A",
                )
            ],
        ),
        table(
            layout,
            "Top error routes",
            "Highest 4xx/5xx rates by normalized route and status. Instant table so current hotspots are readable during a load run.",
            "reqps",
            [
                query(
                    f'topk(10, sum by (route, status_code, tenant) (rate(zilla_http_requests_total{{{BACKEND}, status_code=~"[45].."}}[5m])))',
                    "",
                    "A",
                )
            ],
        ),
        table(
            layout,
            "Slowest routes (p95)",
            "Highest p95 routes after aggregating histogram buckets across pods.",
            "s",
            [
                query(
                    f"topk(10, histogram_quantile(0.95, sum by (le, route) (rate(zilla_http_request_duration_seconds_bucket{{{BACKEND}}}[5m]))))",
                    "",
                    "A",
                )
            ],
        ),
        layout.row("Node.js runtime"),
        timeseries(
            layout,
            "Heap used and total by pod",
            "Node.js heap gauges per backend pod. Series are not summed across pods because each process has its own heap.",
            "bytes",
            [
                query(f"zilla_nodejs_heap_size_used_bytes{{{BACKEND_PROCESS}}}", "{{pod}} used", "A"),
                query(f"zilla_nodejs_heap_size_total_bytes{{{BACKEND_PROCESS}}}", "{{pod}} total", "B"),
            ],
        ),
        timeseries(
            layout,
            "Resident memory by pod",
            "process RSS per backend pod. Shown per pod; summing would hide which replica is growing.",
            "bytes",
            [query(f"zilla_process_resident_memory_bytes{{{BACKEND_PROCESS}}}", "{{pod}}", "A")],
        ),
        timeseries(
            layout,
            "Process CPU by pod",
            "User plus system CPU seconds from prom-client. Rate is per pod, not an average of gauges.",
            "cores",
            [
                query(
                    f"sum by (pod) (rate(zilla_process_cpu_user_seconds_total{{{BACKEND_PROCESS}}}[5m]) + rate(zilla_process_cpu_system_seconds_total{{{BACKEND_PROCESS}}}[5m]))",
                    "{{pod}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Event-loop lag by pod",
            "prom-client event-loop lag. Mean and p99 are gauges of a delay, so the panel uses the per-pod value rather than summing lag across pods.",
            "s",
            [
                query(f"max by (pod) (zilla_nodejs_eventloop_lag_mean_seconds{{{BACKEND_PROCESS}}})", "{{pod}} mean", "A"),
                query(f"max by (pod) (zilla_nodejs_eventloop_lag_p99_seconds{{{BACKEND_PROCESS}}})", "{{pod}} p99", "B"),
            ],
        ),
        layout.row("Application DB and Redis"),
        timeseries(
            layout,
            "DB operations per second",
            "Sequelize operations recorded by the backend. Split by operation, status, and tenant.",
            "ops",
            [query(f"sum by (operation, status, tenant) (rate(zilla_db_operations_total{{{BACKEND}}}[5m]))", "{{tenant}} {{operation}} {{status}}", "A")],
        ),
        timeseries(
            layout,
            "DB operation p95",
            "p95 DB duration from histogram buckets, aggregated across pods by le, operation, and tenant.",
            "s",
            [
                query(
                    f"histogram_quantile(0.95, sum by (le, operation, tenant) (rate(zilla_db_operation_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "{{tenant}} {{operation}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Sequelize pool connections",
            "Gauge of pool state per tenant. Each state is plotted separately so size/using/waiting are not summed into a meaningless total.",
            "short",
            [query(f"sum by (tenant, state) (zilla_db_pool_connections{{{BACKEND}}})", "{{tenant}} {{state}}", "A")],
        ),
        timeseries(
            layout,
            "Redis operations per second",
            "Application Redis calls recorded by the backend, including errors.",
            "ops",
            [query(f"sum by (operation, status, tenant) (rate(zilla_redis_operations_total{{{BACKEND}}}[5m]))", "{{tenant}} {{operation}} {{status}}", "A")],
        ),
        timeseries(
            layout,
            "Redis operation p95",
            "p95 Redis duration from histogram buckets after summing across pods by le.",
            "s",
            [
                query(
                    f"histogram_quantile(0.95, sum by (le, operation, tenant) (rate(zilla_redis_operation_duration_seconds_bucket{{{BACKEND}}}[5m])))",
                    "{{tenant}} {{operation}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Failed DB and Redis operations",
            "Error-status counters for application DB and Redis calls.",
            "ops",
            [
                query(
                    f'sum by (tenant) (rate(zilla_db_operations_total{{{BACKEND}, status="error"}}[5m]))',
                    "db {{tenant}}",
                    "A",
                ),
                query(
                    f'sum by (tenant) (rate(zilla_redis_operations_total{{{BACKEND}, status="error"}}[5m]))',
                    "redis {{tenant}}",
                    "B",
                ),
            ],
        ),
    ]
    return dashboard(
        "Zilla Backend and Tenants",
        "zilla-backend-tenants",
        "HTTP, Node.js, and application DB/Redis metrics for Zilla backends, including shared-model tenant splits.",
        common_variables(),
        panels,
    )


def postgres_redis() -> dict:
    layout = Layout()
    pg_vars = [
        variable("model", "Model", 'label_values(up{zilla_target_type=~"postgres|redis"}, model)', "Infrastructure model of the exporter target."),
        variable("namespace", "Namespace", 'label_values(up{zilla_target_type=~"postgres|redis", namespace!="monitoring"}, namespace)', "Namespace of each real PostgreSQL/Redis instance."),
        variable("tenant", "Tenant", 'label_values(up{zilla_target_type=~"postgres|redis"}, tenant)', "Tenant label when the instance is dedicated; empty on shared instances."),
        variable("group", "Group", 'label_values(up{zilla_target_type=~"postgres|redis"}, group)', "Grouped-model group. Empty outside grouped."),
        variable("service", "Service", 'label_values(up{zilla_target_type=~"postgres|redis", namespace=~"$namespace"}, service)', "Exporter Service name."),
        variable("pod", "Pod", 'label_values(up{zilla_target_type=~"postgres|redis", namespace=~"$namespace"}, pod)', "Exporter pod. Database/cache resource panels also match postgres-* and redis-* workload pods."),
    ]
    instance = "{{namespace}} {{group}}"
    panels = [
        layout.row("PostgreSQL"),
        timeseries(
            layout,
            "PostgreSQL connections by instance",
            "Backend connections (numbackends) per real PostgreSQL instance. Gauge is summed across databases of that instance, not averaged.",
            "short",
            [query(f"sum by (namespace, group, service) (pg_stat_database_numbackends{{{POSTGRES}}})", instance, "A")],
        ),
        timeseries(
            layout,
            "PostgreSQL transactions per second",
            "Commit and rollback rates per instance. Counters are rated then summed across databases of the same instance.",
            "ops",
            [
                query(f"sum by (namespace, group, service) (rate(pg_stat_database_xact_commit{{{POSTGRES}}}[5m]))", f"{instance} commit", "A"),
                query(f"sum by (namespace, group, service) (rate(pg_stat_database_xact_rollback{{{POSTGRES}}}[5m]))", f"{instance} rollback", "B"),
            ],
        ),
        timeseries(
            layout,
            "PostgreSQL cache hit ratio",
            "blks_hit / (blks_hit + blks_read) per instance. The ratio is computed from summed rates, never by averaging per-database ratios.",
            "percentunit",
            [
                query(
                    f"sum by (namespace, group, service) (rate(pg_stat_database_blks_hit{{{POSTGRES}}}[5m])) / clamp_min(sum by (namespace, group, service) (rate(pg_stat_database_blks_hit{{{POSTGRES}}}[5m])) + sum by (namespace, group, service) (rate(pg_stat_database_blks_read{{{POSTGRES}}}[5m])), 1e-9)",
                    instance,
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "PostgreSQL locks by mode",
            "Lock counts per instance and mode. Gauges are summed across databases of one instance; modes stay separate.",
            "short",
            [query(f"sum by (namespace, group, service, mode) (pg_locks_count{{{POSTGRES}}})", f"{instance} {{{{mode}}}}", "A")],
        ),
        timeseries(
            layout,
            "PostgreSQL CPU",
            "CPU of postgres workload pods (not the exporter). Identified by pod name postgres-*.",
            "cores",
            [
                query(
                    f"sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{POSTGRES_POD}}}[5m]))",
                    "{{namespace}}/{{pod}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "PostgreSQL memory",
            "Working-set memory of postgres workload pods, excluding exporter pods.",
            "bytes",
            [
                query(
                    f"sum by (namespace, pod) (container_memory_working_set_bytes{{{POSTGRES_POD}}})",
                    "{{namespace}}/{{pod}}",
                    "A",
                )
            ],
        ),
        layout.row("Redis"),
        timeseries(
            layout,
            "Redis memory used",
            "redis_memory_used_bytes per real Redis instance. One gauge per instance; summing across instances is the selected-set total.",
            "bytes",
            [query(f"sum by (namespace, group, service) (redis_memory_used_bytes{{{REDIS}}})", instance, "A")],
        ),
        timeseries(
            layout,
            "Redis connected clients",
            "Client count per Redis instance. This is a gauge of connections to that instance, not an average across instances.",
            "short",
            [query(f"sum by (namespace, group, service) (redis_connected_clients{{{REDIS}}})", instance, "A")],
        ),
        timeseries(
            layout,
            "Redis commands per second",
            "Rate of processed Redis commands per instance.",
            "ops",
            [query(f"sum by (namespace, group, service) (rate(redis_commands_processed_total{{{REDIS}}}[5m]))", instance, "A")],
        ),
        timeseries(
            layout,
            "Redis keyspace hit ratio",
            "hits / (hits + misses) per instance, computed from summed rates rather than averaged ratios.",
            "percentunit",
            [
                query(
                    f"sum by (namespace, group, service) (rate(redis_keyspace_hits_total{{{REDIS}}}[5m])) / clamp_min(sum by (namespace, group, service) (rate(redis_keyspace_hits_total{{{REDIS}}}[5m])) + sum by (namespace, group, service) (rate(redis_keyspace_misses_total{{{REDIS}}}[5m])), 1e-9)",
                    instance,
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Redis evictions",
            "Evicted keys per second when an instance hits maxmemory.",
            "ops",
            [query(f"sum by (namespace, group, service) (rate(redis_evicted_keys_total{{{REDIS}}}[5m]))", instance, "A")],
        ),
        timeseries(
            layout,
            "Redis CPU",
            "CPU of redis workload pods (not the exporter).",
            "cores",
            [
                query(
                    f"sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{REDIS_POD}}}[5m]))",
                    "{{namespace}}/{{pod}}",
                    "A",
                )
            ],
        ),
        timeseries(
            layout,
            "Redis container memory",
            "Working-set memory of redis workload pods, excluding exporter pods.",
            "bytes",
            [
                query(
                    f"sum by (namespace, pod) (container_memory_working_set_bytes{{{REDIS_POD}}})",
                    "{{namespace}}/{{pod}}",
                    "A",
                )
            ],
        ),
    ]
    return dashboard(
        "Zilla PostgreSQL and Redis",
        "zilla-postgres-redis",
        "Per-instance PostgreSQL and Redis health. One series per real database or cache, not per tenant when the instance is shared.",
        pg_vars,
        panels,
    )


def write_dashboard(name: str, payload: dict) -> Path:
    DASHBOARD_DIR.mkdir(parents=True, exist_ok=True)
    path = DASHBOARD_DIR / name
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> None:
    written = [
        write_dashboard("zilla-model-overview.json", model_overview()),
        write_dashboard("zilla-backend-tenants.json", backend_tenants()),
        write_dashboard("zilla-postgres-redis.json", postgres_redis()),
    ]
    for path in written:
        print(path)


if __name__ == "__main__":
    main()
