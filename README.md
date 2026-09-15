# Zilla Minikube — local infrastructure models

Reproducible local Kubernetes environments for comparing Zilla deployment topologies (ISO, hybrid, shared, grouped), with an identical local Prometheus and Grafana stack for every profile. ISO, hybrid, and shared use the same 3 CPU / 4 GiB profile; the standalone grouped stress profile uses 4 CPU / 6 GiB.

## macOS prerequisites

- Docker Desktop (or compatible Docker engine)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- `kubectl` (via Minikube)
- [Helm](https://helm.sh/docs/intro/install/) 3 or newer
- `bash`, `curl`, `python3`
- Git clones of this repo plus sibling repos:
  - `../zilla-backend`
  - `../zilla-frontend`

## Quick start (one model)

```bash
# 1. Start Minikube profile (ISO/hybrid/shared: 3 CPU, 4 GiB RAM, 20 GiB disk)
./start_clusters.sh iso

# 2. Build and load local images (see config/IMAGES.md for branch/SHA mapping)
./scripts/build-images.sh iso

# 3. Deploy model
./scripts/deploy-model.sh iso

# 4. Smoke test
./scripts/smoke-test.sh iso

# 5. Install the local monitoring stack
./scripts/observability/install.sh iso
./scripts/observability/status.sh iso

# 6. Tear down
./scripts/observability/delete.sh iso
# Add --purge-data to remove application namespaces/PVCs.
./scripts/delete-model.sh iso --purge-data
```

All `kubectl` commands use explicit profiles: `minikube -p <profile> kubectl -- ...`

## Commands for all four models

| Model | Profile | Deploy | Smoke | Port-forward (Nginx) |
| --- | --- | --- | --- | --- |
| ISO | `iso` | `./scripts/deploy-model.sh iso` | `./scripts/smoke-test.sh iso` | `minikube -p iso kubectl -- -n arm port-forward svc/nginx-bff 8080:80` |
| Hybrid | `hybrid` | `./scripts/deploy-model.sh hybrid` | `./scripts/smoke-test.sh hybrid` | `minikube -p hybrid kubectl -- -n hybrid port-forward svc/nginx-bff 8080:80` |
| Shared | `shared` | `./scripts/deploy-model.sh shared` | `./scripts/smoke-test.sh shared` | `minikube -p shared kubectl -- -n shared port-forward svc/nginx-bff 8080:80` |
| Grouped | `grouped` | `./scripts/deploy-model.sh grouped` | `./scripts/smoke-test.sh grouped` | `minikube -p grouped kubectl -- -n binance port-forward svc/nginx-bff 8080:80` |

Start all profiles:

```bash
./start_clusters.sh all
```

## Prometheus and Grafana

The pinned `prometheus-community/kube-prometheus-stack` chart is configured by
one shared `observability/values.yaml`, so monitoring resources are identical
in `iso`, `hybrid`, `shared`, and `grouped`.

```bash
./scripts/observability/install.sh <profile>
./scripts/observability/status.sh <profile>
./scripts/observability/port-forward.sh <profile> grafana
./scripts/observability/port-forward.sh <profile> prometheus
./scripts/observability/delete.sh <profile>
```

Grafana is available at <http://localhost:3000> after port-forwarding. Its
local-only login is `admin` / `zilla-local-only`. Three Zilla dashboards appear
in the **Zilla** folder after install; see
[`observability/grafana/README.md`](observability/grafana/README.md).
Prometheus is available at <http://localhost:9090>.

Monitoring runs only in the `monitoring` namespace. Always exclude
`namespace="monitoring"` from aggregate application CPU and memory results so
the observability stack is not counted as Zilla workload consumption. See
[`observability/README.md`](observability/README.md) for verification details.

## Reproducible experiments

Run the same authentication/read/write k6 scenario and export its matching
Prometheus measurement window with:

```bash
./scripts/run-experiment.sh <iso|hybrid|shared|grouped>
```

Results are written to a unique `results/<UTC timestamp>-<model>/` directory.
Durations, VUs, tenant selection, clean resets, three-run comparison, result
schemas, and Grafana screenshot steps are documented in
[`experiments/README.md`](experiments/README.md).

## Expected components (steady-state Deployments)

Pod counts are **intentionally different** across models; compare experiments using total and per-tenant resource consumption, not pod count parity.

| Model | Namespaces | Deployments | Tenants (on disk) | Notes |
| --- | --- | ---: | ---: | --- |
| ISO | 1 per tenant (`arm`, …) | 5 × tenants | 1 | Full stack per tenant |
| Hybrid | `hybrid` | 7 | 3 | Shared PG/Redis, BE per tenant |
| Shared | `shared` | 5 | 15 | Single BE, multi-schema PG |
| Grouped | `binance`, `hybrid-grouped`, `shared-grouped` | 5 + 7 + 5 | 1 + 3 + 8 | Combines ISO, hybrid, shared patterns |

Liquibase and tenant-init **Jobs** run during deploy and must complete before app rollouts.

## Manifest layout (phased apply)

Each model uses ordered manifests under `models/<model>/`:

1. `platform-secrets.yaml` — shared DB/Redis credentials (where applicable)
2. `tenants/*/secrets.yaml` — per-tenant credentials
3. `data.yaml` — PostgreSQL + Redis
4. `tenant-init.yaml` — schema/role setup (hybrid/shared)
5. `migrations.yaml` — Liquibase per tenant or shared DB
6. `apps.yaml` — backend, frontend, nginx

ISO applies `data.yaml`, `migrations.yaml`, `apps.yaml` per tenant namespace (discovered from `models/iso/tenants/`).

## Image provenance

See [`config/IMAGES.md`](config/IMAGES.md) and [`config/images.lock.env`](config/images.lock.env).

- ISO / hybrid backends: `zilla-backend` built from `master`
- Shared backends: `zilla-backend` built from `master-shared`
- Frontends: `master` for isolated stacks, `master-shared` for tenant-aware routing

## Validation

```bash
chmod +x start_clusters.sh scripts/*.sh scripts/observability/*.sh
./scripts/validate-manifests.sh
```

Requires running Minikube profiles for `kubectl apply --dry-run=client` checks.

## Local test credentials

- Admin: `admin@example.com` / `pass123!` (see `config/images.lock.env`)
- Database/Redis: `user`/`pass`, Redis password `password` (base64 in secrets)

Do not use these outside local Minikube.
