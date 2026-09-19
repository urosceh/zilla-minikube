# Local observability stack

The same `kube-prometheus-stack` configuration is installed independently in
each Minikube profile. It provides Prometheus, Grafana, Prometheus Operator,
kube-state-metrics, node-exporter, and kubelet/cAdvisor scraping.

The chart is pinned in `chart.lock.env`; every profile uses the single
`values.yaml` file. Alertmanager and the upstream default alert rules are
disabled to keep the stack small enough for local experiments.

## Lifecycle

Install into one running profile:

```bash
./scripts/observability/install.sh iso
./scripts/observability/status.sh iso
```

Replace `iso` with `hybrid`, `shared`, or `grouped`. Each command validates the
profile and explicitly uses its Kubernetes context.

Open Grafana:

```bash
./scripts/observability/port-forward.sh iso grafana
```

Visit <http://localhost:3000> and sign in with the local-only credentials
`admin` / `admin`. The **Zilla** folder contains Model Overview,
Backend and Tenants, and PostgreSQL and Redis. They are loaded from
`observability/grafana/dashboards/` and survive Grafana reinstalls because
`install.sh` reapplies the ConfigMaps. See
[`observability/grafana/README.md`](grafana/README.md) for panel interpretation.

Open Prometheus:

```bash
./scripts/observability/port-forward.sh iso prometheus
```

Visit <http://localhost:9090/targets>. The API server, DNS,
kube-state-metrics, node-exporter, kubelet, and cAdvisor targets should be
`UP`. Grafana is provisioned with Prometheus as its default datasource.

## Zilla application targets

`deploy-model.sh` deploys one PostgreSQL exporter and one Redis exporter beside
each real data-layer instance. ISO gets one pair per tenant namespace,
hybrid/shared get one pair for the shared instance, and grouped gets one pair
for each of its ISO, hybrid, and shared groups. Exporter credentials are read
from the existing `postgres-secret` and `redis-secret` Secrets.

Backend Services and exporter Services are discovered by the ServiceMonitors
in `service-monitors.yaml`. They scrape every 15 seconds and attach bounded
`model`, `tenant`, `group`, `namespace`, `service`, and `pod` labels. A shared
backend remains one scrape target; its application metrics retain the
validated per-request `tenant` label emitted by the backend.

Verify the exact expected target count and required metric families:

```bash
./scripts/observability/check-targets.sh iso
```

The same check runs at the end of `status.sh`. Replace `iso` with `hybrid`,
`shared`, or `grouped`. It fails when any expected backend/PostgreSQL/Redis
target is missing or down, or when `zilla_http_requests_total`, `pg_up`, or
`redis_up` has no data.

Delete the stack and its Prometheus PVC:

```bash
./scripts/observability/delete.sh iso
```

Prometheus Operator CRDs are intentionally retained because Helm does not own
the CRD lifecycle. They are reused by a subsequent installation and require no
manual changes.

## Experiment boundary

All monitoring workloads and Prometheus storage live in the `monitoring`
namespace. Queries that calculate Zilla application consumption **must exclude**
`namespace="monitoring"`; otherwise the measured result includes the cost of
the measurement system itself.

Prometheus retains up to three days of data in a 4 GiB PVC. These settings and
the Grafana credentials are for local Minikube only, not production.
