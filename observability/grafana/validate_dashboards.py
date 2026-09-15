#!/usr/bin/env python3
"""Structural checks for provisioned Zilla Grafana dashboards."""

from __future__ import annotations

import json
import sys
from pathlib import Path

DASHBOARD_DIR = Path(__file__).resolve().parent / "dashboards"
EXPECTED = {
    "zilla-model-overview.json": {
        "uid": "zilla-model-overview",
        "title": "Zilla Model Overview",
        "variables": {"model", "namespace", "tenant", "group", "service", "pod"},
    },
    "zilla-backend-tenants.json": {
        "uid": "zilla-backend-tenants",
        "title": "Zilla Backend and Tenants",
        "variables": {"model", "namespace", "tenant", "group", "service", "pod"},
    },
    "zilla-postgres-redis.json": {
        "uid": "zilla-postgres-redis",
        "title": "Zilla PostgreSQL and Redis",
        "variables": {"model", "namespace", "tenant", "group", "service", "pod"},
    },
}


def fail(message: str) -> None:
    raise AssertionError(message)


def walk_panels(panels: list[dict]):
    for panel in panels:
        yield panel
        yield from walk_panels(panel.get("panels") or [])


def exprs(panel: dict) -> list[str]:
    return [str(target.get("expr", "")) for target in panel.get("targets") or [] if target.get("expr")]


def main() -> int:
    found_histogram = False
    monitoring_cpu_memory = 0
    errors: list[str] = []

    for filename, expected in EXPECTED.items():
        path = DASHBOARD_DIR / filename
        if not path.exists():
            errors.append(f"missing {filename}")
            continue
        dashboard = json.loads(path.read_text(encoding="utf-8"))
        if dashboard.get("uid") != expected["uid"]:
            errors.append(f"{filename} uid is {dashboard.get('uid')!r}")
        if dashboard.get("title") != expected["title"]:
            errors.append(f"{filename} title is {dashboard.get('title')!r}")
        variable_names = {item["name"] for item in dashboard.get("templating", {}).get("list", [])}
        missing = expected["variables"] - variable_names
        if missing:
            errors.append(f"{filename} missing variables {sorted(missing)}")
        for variable in dashboard.get("templating", {}).get("list", []):
            if not variable.get("includeAll"):
                errors.append(f"{filename} variable {variable['name']} is missing All")
            if variable.get("allValue") != ".*":
                errors.append(f"{filename} variable {variable['name']} allValue must be .*")

        query_panels = 0
        for panel in walk_panels(dashboard.get("panels") or []):
            if panel.get("type") == "row":
                continue
            query_panels += 1
            if not panel.get("title"):
                errors.append(f"{filename} panel {panel.get('id')} has no title")
            if not panel.get("description"):
                errors.append(f"{filename} panel {panel.get('title')} has no description")
            unit = (panel.get("fieldConfig") or {}).get("defaults", {}).get("unit")
            if not unit:
                errors.append(f"{filename} panel {panel.get('title')} has no unit")
            for expr in exprs(panel):
                if "histogram_quantile" in expr:
                    found_histogram = True
                    if "sum by (le" not in expr:
                        errors.append(f"{filename} quantile query does not aggregate buckets by le: {expr}")
                if "zilla_nodejs_eventloop_lag" in expr and expr.strip().startswith("sum("):
                    errors.append(f"{filename} event-loop lag must not be summed: {expr}")
                if "container_cpu_usage_seconds_total" in expr or "container_memory_working_set_bytes" in expr:
                    if 'namespace!="monitoring"' not in expr:
                        errors.append(f"{filename} resource query does not exclude monitoring: {expr}")
                    else:
                        monitoring_cpu_memory += 1
        if query_panels < 8:
            errors.append(f"{filename} has too few query panels: {query_panels}")

    if not found_histogram:
        errors.append("no histogram_quantile latency queries found")
    if monitoring_cpu_memory < 3:
        errors.append("expected CPU/memory queries to exclude the monitoring namespace")

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("OK: Grafana dashboards passed structural checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
