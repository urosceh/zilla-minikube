#!/usr/bin/env python3
"""Export the agreed experiment metrics from the Prometheus HTTP API."""

from __future__ import annotations

import argparse
import csv
import json
import math
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request


def api_get(base_url: str, endpoint: str, params: dict[str, object]) -> dict:
    query = urllib.parse.urlencode(params)
    url = f"{base_url}{endpoint}?{query}"
    for attempt in range(1, 7):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                payload = json.load(response)
            break
        except urllib.error.HTTPError as error:
            if error.code not in {502, 503, 504} or attempt == 6:
                body = error.read().decode("utf-8", errors="replace")
                raise RuntimeError(
                    f"Prometheus HTTP {error.code} for {endpoint}: {body}"
                ) from error
        except (urllib.error.URLError, TimeoutError):
            if attempt == 6:
                raise
        time.sleep(attempt * 2)
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus request failed: {payload}")
    return payload


def selector(labels: dict[str, str]) -> str:
    return ",".join(f'{name}="{value}"' for name, value in labels.items())


def summarized_result(payload: dict) -> float | list[dict[str, object]] | None:
    result = payload.get("data", {}).get("result", [])
    if not result:
        return None
    if len(result) == 1 and not result[0].get("metric"):
        try:
            value = float(result[0]["value"][1])
            return value if math.isfinite(value) else None
        except (KeyError, TypeError, ValueError):
            return None
    values = []
    for series in result:
        try:
            value = float(series["value"][1])
        except (KeyError, TypeError, ValueError):
            continue
        values.append(
            {
                "labels": series.get("metric", {}),
                "value": value if math.isfinite(value) else None,
            }
        )
    return values or None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--namespaces", required=True, help="PromQL-compatible namespace regex")
    parser.add_argument("--start", required=True, type=float)
    parser.add_argument("--end", required=True, type=float)
    parser.add_argument("--window-seconds", required=True, type=int)
    parser.add_argument("--tenant-count", required=True, type=int)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    if args.tenant_count <= 0:
        parser.error("--tenant-count must be positive")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    window = f"{args.window_seconds}s"
    model_labels = selector({"model": args.model})
    workload = (
        f'namespace=~"{args.namespaces}",namespace!="monitoring",'
        'container!="",container!="POD"'
    )
    backend = f'{model_labels},zilla_target_type="backend",namespace!="monitoring"'
    postgres = f'{model_labels},zilla_target_type="postgres",namespace!="monitoring"'
    redis = f'{model_labels},zilla_target_type="redis",namespace!="monitoring"'
    labeled_tenant_cpu = (
        f'sum by (tenant) (label_replace(rate(container_cpu_usage_seconds_total{{{workload}}}[{window}]) '
        f'* on(namespace,pod) group_left(label_zilla_io_tenant) '
        f'max by (namespace,pod,label_zilla_io_tenant) '
        f'(kube_pod_labels{{namespace=~"{args.namespaces}",label_zilla_io_tenant!=""}}), '
        '"tenant", "$1", "label_zilla_io_tenant", "(.*)"))'
    )
    labeled_tenant_memory = (
        f'sum by (tenant) (label_replace(avg_over_time(container_memory_working_set_bytes{{{workload}}}[{window}]) '
        f'* on(namespace,pod) group_left(label_zilla_io_tenant) '
        f'max by (namespace,pod,label_zilla_io_tenant) '
        f'(kube_pod_labels{{namespace=~"{args.namespaces}",label_zilla_io_tenant!=""}}), '
        '"tenant", "$1", "label_zilla_io_tenant", "(.*)"))'
    )
    namespace_tenant_cpu = (
        f'sum by (tenant) (label_replace(rate(container_cpu_usage_seconds_total{{{workload}}}[{window}]), '
        '"tenant", "$1", "namespace", "(.*)"))'
    )
    namespace_tenant_memory = (
        f'sum by (tenant) (label_replace(avg_over_time(container_memory_working_set_bytes{{{workload}}}[{window}]), '
        '"tenant", "$1", "namespace", "(.*)"))'
    )
    if args.model == "iso":
        tenant_cpu = namespace_tenant_cpu
        tenant_memory = namespace_tenant_memory
    elif args.model == "grouped":
        grouped_iso_workload = workload + ',namespace!~"hybrid-grouped|shared-grouped"'
        grouped_iso_cpu = (
            "sum by (tenant) (label_replace(rate(container_cpu_usage_seconds_total"
            f"{{{grouped_iso_workload}}}[{window}]), "
            '"tenant", "$1", "namespace", "(.*)"))'
        )
        grouped_iso_memory = (
            "sum by (tenant) (label_replace(avg_over_time(container_memory_working_set_bytes"
            f"{{{grouped_iso_workload}}}[{window}]), "
            '"tenant", "$1", "namespace", "(.*)"))'
        )
        tenant_cpu = f"({labeled_tenant_cpu}) or ({grouped_iso_cpu})"
        tenant_memory = f"({labeled_tenant_memory}) or ({grouped_iso_memory})"
    else:
        tenant_cpu = labeled_tenant_cpu
        tenant_memory = labeled_tenant_memory

    running_workload_pods = (
        f'max by (namespace,pod) (kube_pod_status_phase{{namespace=~"{args.namespaces}",'
        'namespace!="monitoring",phase="Running"} == 1)'
    )
    instant_queries = {
        "rps": f"sum(increase(zilla_http_requests_total{{{backend}}}[{window}])) / {args.window_seconds}",
        "error_rate": (
            f'(sum(increase(zilla_http_requests_total{{{backend},status_code=~"5.."}}[{window}])) '
            "or vector(0)) "
            f"/ clamp_min(sum(increase(zilla_http_requests_total{{{backend}}}[{window}])), 1)"
        ),
        "latency_p50_seconds": (
            "histogram_quantile(0.50, sum by (le) "
            f"(increase(zilla_http_request_duration_seconds_bucket{{{backend}}}[{window}])))"
        ),
        "latency_p95_seconds": (
            "histogram_quantile(0.95, sum by (le) "
            f"(increase(zilla_http_request_duration_seconds_bucket{{{backend}}}[{window}])))"
        ),
        "latency_p99_seconds": (
            "histogram_quantile(0.99, sum by (le) "
            f"(increase(zilla_http_request_duration_seconds_bucket{{{backend}}}[{window}])))"
        ),
        "cpu_cores": (
            f"sum(rate(container_cpu_usage_seconds_total{{{workload}}}[{window}]))"
        ),
        "memory_working_set_bytes": (
            f"sum(avg_over_time(container_memory_working_set_bytes{{{workload}}}[{window}]))"
        ),
        "running_pods": (
            f'sum(kube_pod_status_phase{{namespace=~"{args.namespaces}",namespace!="monitoring",'
            'phase="Running"} == 1)'
        ),
        "restarts": (
            "sum(increase(kube_pod_container_status_restarts_total"
            f'{{namespace=~"{args.namespaces}",namespace!="monitoring"}}[{window}]))'
        ),
        "cpu_throttle_ratio": (
            f"sum(increase(container_cpu_cfs_throttled_periods_total{{{workload}}}[{window}])) "
            f"/ clamp_min(sum(increase(container_cpu_cfs_periods_total{{{workload}}}[{window}])), 1)"
        ),
        "postgres_connections": f"sum(pg_stat_database_numbackends{{{postgres}}})",
        "postgres_cache_hit_ratio": (
            f"sum(increase(pg_stat_database_blks_hit{{{postgres}}}[{window}])) "
            f"/ clamp_min(sum(increase(pg_stat_database_blks_hit{{{postgres}}}[{window}])) + "
            f"sum(increase(pg_stat_database_blks_read{{{postgres}}}[{window}])), 1)"
        ),
        "postgres_locks": f"sum(pg_locks_count{{{postgres}}})",
        "redis_memory_bytes": f"sum(redis_memory_used_bytes{{{redis}}})",
        "redis_ops_per_second": (
            f"sum(increase(redis_commands_processed_total{{{redis}}}[{window}])) / {args.window_seconds}"
        ),
        "redis_hit_ratio": (
            f"sum(increase(redis_keyspace_hits_total{{{redis}}}[{window}])) "
            f"/ clamp_min(sum(increase(redis_keyspace_hits_total{{{redis}}}[{window}])) + "
            f"sum(increase(redis_keyspace_misses_total{{{redis}}}[{window}])), 1)"
        ),
        "rps_by_tenant": (
            f"sum by (tenant) (increase(zilla_http_requests_total{{{backend}}}[{window}])) "
            f"/ {args.window_seconds}"
        ),
        "error_rate_by_tenant": (
            f'(sum by (tenant) (increase(zilla_http_requests_total{{{backend},status_code=~"5.."}}[{window}])) '
            f"or (sum by (tenant) (increase(zilla_http_requests_total{{{backend}}}[{window}])) * 0)) "
            f"/ clamp_min(sum by (tenant) "
            f"(increase(zilla_http_requests_total{{{backend}}}[{window}])), 1)"
        ),
        "cpu_cores_by_namespace": (
            f"sum by (namespace) (rate(container_cpu_usage_seconds_total{{{workload}}}[{window}]))"
        ),
        "memory_bytes_by_namespace": (
            f"sum by (namespace) (avg_over_time(container_memory_working_set_bytes{{{workload}}}[{window}]))"
        ),
        "cpu_cores_by_tenant": tenant_cpu,
        "memory_bytes_by_tenant": tenant_memory,
        "resource_requests": (
            "sum by (resource,unit) (kube_pod_container_resource_requests"
            f'{{namespace=~"{args.namespaces}",namespace!="monitoring",container!=""}} '
            f"* on(namespace,pod) group_left {running_workload_pods})"
        ),
        "resource_limits": (
            "sum by (resource,unit) (kube_pod_container_resource_limits"
            f'{{namespace=~"{args.namespaces}",namespace!="monitoring",container!=""}} '
            f"* on(namespace,pod) group_left {running_workload_pods})"
        ),
    }

    instant = {}
    summary = {}
    for name, query in instant_queries.items():
        payload = api_get(args.url, "/api/v1/query", {"query": query, "time": args.end})
        instant[name] = {"query": query, "response": payload}
        summary[name] = summarized_result(payload)

    summary["tenant_count"] = args.tenant_count
    rps = summary.get("rps")
    if isinstance(rps, (int, float)):
        summary["rps_per_tenant"] = rps / args.tenant_count
        summary["cpu_cores_per_rps"] = (
            summary["cpu_cores"] / rps
            if rps > 0 and isinstance(summary.get("cpu_cores"), (int, float))
            else None
        )
        summary["memory_bytes_per_rps"] = (
            summary["memory_working_set_bytes"] / rps
            if rps > 0
            and isinstance(summary.get("memory_working_set_bytes"), (int, float))
            else None
        )

    range_queries = {
        "rps": f"sum(rate(zilla_http_requests_total{{{backend}}}[1m]))",
        "error_rate": (
            f'(sum(rate(zilla_http_requests_total{{{backend},status_code=~"5.."}}[1m])) '
            "or vector(0)) "
            f"/ clamp_min(sum(rate(zilla_http_requests_total{{{backend}}}[1m])), 1e-9)"
        ),
        "cpu_cores": f"sum(rate(container_cpu_usage_seconds_total{{{workload}}}[1m]))",
        "memory_working_set_bytes": f"sum(container_memory_working_set_bytes{{{workload}}})",
    }
    ranges = {}
    for name, query in range_queries.items():
        ranges[name] = {
            "query": query,
            "response": api_get(
                args.url,
                "/api/v1/query_range",
                {"query": query, "start": args.start, "end": args.end, "step": 15},
            ),
        }

    with (args.output_dir / "prometheus-instant.json").open("w", encoding="utf-8") as handle:
        json.dump(instant, handle, indent=2, sort_keys=True)
        handle.write("\n")
    with (args.output_dir / "prometheus-range.json").open("w", encoding="utf-8") as handle:
        json.dump(ranges, handle, indent=2, sort_keys=True)
        handle.write("\n")
    with (args.output_dir / "metrics-summary.json").open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")

    with (args.output_dir / "metrics.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["metric", "timestamp", "value", "labels"])
        for name, item in instant.items():
            for series in item["response"].get("data", {}).get("result", []):
                timestamp, value = series["value"]
                writer.writerow([name, timestamp, value, json.dumps(series.get("metric", {}), sort_keys=True)])

    with (args.output_dir / "timeseries.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["metric", "timestamp", "value", "labels"])
        for name, item in ranges.items():
            for series in item["response"].get("data", {}).get("result", []):
                labels = json.dumps(series.get("metric", {}), sort_keys=True)
                for timestamp, value in series.get("values", []):
                    writer.writerow([name, timestamp, value, labels])


if __name__ == "__main__":
    main()
