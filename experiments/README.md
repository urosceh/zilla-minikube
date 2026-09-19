# Reproducible Zilla experiments

The active experiment uses one logical workload for every topology:

1. assign one seeded user to each VU and authenticate once per VU session;
2. list that user's projects;
3. perform a 60% issue-read, 20% issue-create, and 20% issue-update mix;
4. wait a uniformly random 2–4 seconds between iterations;
5. apply the same virtual-user schedule independently to every selected tenant.

An expired session is authenticated again only after a `401` response.

Only routing changes by topology:

- `iso`: direct `/api/...` route through each tenant's Nginx;
- `hybrid`: `/api/<tenant>/...`;
- `shared`: `/api/...` with the validated `tenant` header;
- `grouped`: the corresponding ISO, hybrid, or shared route for each group.

The old `.outdated/` scripts are not invoked. The active scenario keeps their
useful login/project/issue flow but uses current manifests, credentials, and
profile-explicit Minikube commands.

For thesis measurements, resource accounting, and the exact three-run
procedure, follow [`FAIR_COMPARISON.md`](FAIR_COMPARISON.md). The primary
fixed-cost comparison covers `iso` and `shared`; treat `hybrid` and `grouped`
as secondary experiments.

## macOS prerequisites

```bash
brew install minikube helm
```

Install k6 locally if desired:

```bash
brew install k6
```

If `k6` is absent, `scripts/run-experiment.sh` uses the immutable
`grafana/k6` image from `experiments/versions.env` through Docker Desktop.
Also ensure the chosen model is deployed, seeded, and monitored.

## Run

From the `zilla-minikube` root:

```bash
./scripts/run-experiment.sh iso
./scripts/run-experiment.sh hybrid
./scripts/run-experiment.sh shared
./scripts/run-experiment.sh grouped
```

The default schedule per tenant is 60 seconds warm-up, 180 seconds steady
measurement, and 30 seconds cool-down with 10 VUs. Warm-up ramps for 30
seconds and then holds all VUs for 30 seconds. Override it without editing
the scenario:

```bash
WARMUP_SECONDS=60 \
STEADY_SECONDS=180 \
COOLDOWN_SECONDS=30 \
VUS_PER_TENANT=10 \
THINK_TIME_MIN_SECONDS=2 \
THINK_TIME_MAX_SECONDS=4 \
./scripts/run-experiment.sh iso
```

Select a subset only for smoke/debug runs:

```bash
TENANTS=arm ./scripts/run-experiment.sh iso
TENANTS=amazon,amd ./scripts/run-experiment.sh shared
```

Published primary comparisons use `arm` for ISO and the 10 shared tenants
defined in `experiments/fair-comparison.env`.

## Clean reset and three repetitions

For the final fixed-cost comparison, use the controlled runner:

```bash
./scripts/run-fair-comparison.sh primary
```

It reads `experiments/fair-comparison.env`, runs `iso` and `shared` three
times in rotating order, stops the other profiles before each
measurement, resets and seeds all tenants, and generates one comparison
JSON/CSV pair per model. Before changing models, it pauses for a `y/n`
confirmation so the currently active Grafana can be inspected. Run secondary
models separately:

```bash
./scripts/run-fair-comparison.sh hybrid
./scripts/run-fair-comparison.sh grouped
```

Hybrid and grouped outputs are not part of the primary model ranking.

For ad-hoc repetitions, reset application data before every measured run.
Do not delete the monitoring namespace because its retained Prometheus data
is useful for cross-checking runs. The equivalent manual sequence is:

```bash
./scripts/purge-model.sh iso
./scripts/seed-model.sh iso
./scripts/run-experiment.sh iso
```

Repeat those three commands three times. Every invocation creates its own UTC
timestamped `results/<timestamp>-<model>/` directory, so no manual renaming is
needed. Then calculate the mean, sample standard deviation, minimum, and
maximum for scalar metrics:

```bash
python3 experiments/compare_runs.py \
  results/20260907T170000Z-iso \
  results/20260907T180000Z-iso \
  results/20260907T190000Z-iso \
  --output-prefix results/iso-three-run-comparison
```

Use the same durations, VUs, tenant set, image lock, Minikube capacity, and
reset procedure for every model. Record host load and avoid unrelated
workloads during the stable phase.

## Result format

Each run contains:

- `parameters.json`: model, tenants, phase timing, load, k6 runtime, and exact
  measurement timestamps;
- `images.json`: running application container images and resolved image IDs;
- `k6-summary.json`, `k6.log`, `k6-exit-code.txt`: load-generator results;
- `metrics-summary.json`: scalar Prometheus aggregates for comparison;
- `prometheus-instant.json`: queries plus full labeled instant responses;
- `prometheus-range.json`: stable-phase RPS, error, CPU, and memory series;
- `metrics.csv` and `timeseries.csv`: flattened data for spreadsheets,
  plotting, or statistical tools;
- `preflight.log`: readiness and scrape-target verification.

The exported values cover RPS, 5xx error rate, p50/p95/p99 latency, CPU,
memory, running pods, restarts, throttling, PostgreSQL connections/cache
hit/locks, Redis memory/operations/hit ratio, and Kubernetes
requests/limits. Resource requests/limits include only currently running
pods, so completed migration jobs do not inflate the steady-state budget.
The summary also exports tenant count, RPS per tenant, CPU cores per RPS, and
memory bytes per RPS.

CPU and memory are always exported by namespace. They are also exported by
`zilla.io/tenant` where workloads have a physical tenant label. Shared
processes cannot be truthfully split into per-tenant CPU or memory without
runtime attribution; for those processes use the shared total together with
per-tenant HTTP RPS/error metrics instead of fabricating an allocation.

Generated result directories are ignored by Git. A small schema example is
kept under `results/example/`.

## Grafana screenshots for the thesis

Start Grafana for the same profile:

```bash
./scripts/observability/port-forward.sh iso grafana
open http://localhost:3000
```

Log in with `admin` / `admin`, open a provisioned Zilla dashboard,
select the model and tenant filters, and set an absolute time range using
`steady_start_epoch` and `steady_end_epoch` from `parameters.json`. In a panel
menu choose **Share → Export → Download image** (or take a macOS screenshot
with `Shift-Command-4`). Include the run directory name, dashboard UID,
filters, and absolute time range in the figure caption. The dashboard and
export can differ slightly because Prometheus scrapes every 15 seconds.
