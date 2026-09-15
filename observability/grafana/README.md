# Grafana dashboards

Three versioned dashboards are stored as JSON in `dashboards/` and loaded into
Grafana by the kube-prometheus-stack sidecar. `install.sh` applies one
ConfigMap per dashboard, labelled `grafana_dashboard=1` and annotated
`grafana_folder=Zilla`. Deleting and reinstalling Grafana recreates the
ConfigMaps, so the dashboards come back without a manual import.

Regenerate the JSON after editing `generate_dashboards.py`:

```bash
python3 observability/grafana/generate_dashboards.py
python3 observability/grafana/validate_dashboards.py
```

Open Grafana after `scripts/observability/port-forward.sh <profile> grafana`
and look in the **Zilla** folder.

Datasource UID is `prometheus`, matching `observability/values.yaml`.
Every panel uses PromQL that first aggregates across pods (`sum by (...)`
or `histogram_quantile` after `sum by (le, ...)`). The `monitoring`
namespace is excluded from application CPU and memory.

## Variables

All dashboards expose `model`, `namespace`, `tenant`, `group`, `service`, and
`pod`, each with an **All** option (`.*`).

| Variable | What it selects |
| --- | --- |
| `model` | `iso`, `hybrid`, `shared`, or `grouped` from scrape targets |
| `namespace` | Application namespaces. `monitoring` is never listed |
| `tenant` | Validated backend tenant label. On a shared backend this still splits HTTP series |
| `group` | Grouped-model group (`iso` / `hybrid` / `shared`). Empty on the other models |
| `service` | Kubernetes Service of the scrape target |
| `pod` | Pod name. On the PostgreSQL/Redis dashboard this is the exporter pod; instance identity on DB/cache panels is `namespace` plus `group` |

A shared backend is one Prometheus target. Tenant comparison on HTTP, DB, and
Redis **application** metrics uses the backend `tenant` label, not extra
scrape targets. Kubernetes CPU/memory cannot be split by tenant when those
tenants share a process; use the namespace panels and the HTTP tenant panels
together.

## Zilla Model Overview

Cluster-level cost and traffic of one infrastructure model.

| Panel | How to read it |
| --- | --- |
| CPU cores / Memory working set | Total application consumption. Monitoring is excluded so the measurement system is not part of the result |
| Running pods / Restarts / CPU throttle ratio / OOM events | Stability and saturation. Throttle is a ratio of CFS periods, not a summed percentage |
| CPU and memory by namespace | Closest Kubernetes view of tenant cost. In ISO a namespace is a tenant; in shared/hybrid it is the shared stack |
| CPU and memory by pod | Which replica is expensive. Memory is a per-pod gauge, not an average |
| Restarts, throttling, OOM, pods by phase | Reliability under load. Compare models on restarts and throttling, not only on RPS |
| Requests per second, error rate, p50/p95/p99 | Application traffic. Latency uses `histogram_quantile` on `zilla_http_request_duration_seconds_bucket` |
| Requests per second by tenant | Tenant split that still works on a shared backend |
| CPU by tenant label | Only pods that carry `zilla.io/tenant`. Shared Postgres/Redis/nginx without that label stay in the namespace panels |

## Zilla Backend and Tenants

Process and request behaviour of Zilla backends.

| Panel | How to read it |
| --- | --- |
| Requests per second by tenant / pod | Load distribution. Shared models should show many tenants on one pod |
| In-flight by pod vs total | Gauge of concurrent requests. Per-pod series are not averaged; the total panel sums them because each pod reports its own in-flight count |
| Error rate by tenant | 5xx share. Built from counters |
| Latency p50/p95/p99 and p95 by tenant/route | Histogram latency. Route labels are Express templates, never raw URLs |
| Top error routes / Slowest routes | Current hotspots during a run |
| Heap, RSS, process CPU | Node.js process gauges per pod. Do not sum heap or RSS to describe “typical” replica size |
| Event-loop lag | Delay gauges. The panel takes `max by (pod)`, never a sum of lag across pods |
| DB/Redis operations, p95, errors | Application-level Sequelize and Redis timing from the backend |
| Sequelize pool connections | Gauge by tenant and pool state (`size`, `available`, `using`, `waiting`). States are plotted separately |

## Zilla PostgreSQL and Redis

One series per **real** database or cache instance (ISO: per tenant namespace;
hybrid/shared: one shared instance; grouped: one instance per group).

| Panel | How to read it |
| --- | --- |
| PostgreSQL connections | `pg_stat_database_numbackends` summed across databases of that instance |
| Transactions per second | Commit and rollback rates |
| Cache hit ratio | `blks_hit / (blks_hit + blks_read)` from summed rates, not an average of per-database ratios |
| Locks by mode | `pg_locks_count` per instance and lock mode |
| PostgreSQL CPU / memory | `postgres-*` workload pods, excluding `postgres-exporter` |
| Redis memory / clients | Per-instance gauges. Summing across selected instances is a total, not an average |
| Commands per second | `redis_commands_processed_total` |
| Keyspace hit ratio | `hits / (hits + misses)` from summed rates |
| Evictions | Keys dropped when `maxmemory` is hit |
| Redis CPU / container memory | `redis-*` workload pods, excluding `redis-exporter` |

If a panel is empty, check that the profile has been scraped (`status.sh`) and
that the variable filters still match that model. Shared instances have an
empty `group` and often an empty `tenant`; **All** still matches them.
