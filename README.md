# Zilla Minikube — local infrastructure models

Reproducible local Kubernetes environments for comparing Zilla deployment topologies (ISO, hybrid, shared, grouped). This repo prepares manifests and lifecycle scripts only — no Prometheus/Grafana.

## macOS prerequisites

- Docker Desktop (or compatible Docker engine)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- `kubectl` (via Minikube)
- `bash`, `curl`, `python3`
- Git clones of this repo plus sibling repos:
  - `../zilla-backend`
  - `../zilla-frontend`

## Quick start (one model)

```bash
# 1. Start Minikube profile (uniform: 3 CPU, 4 GiB RAM, 20 GiB disk)
./start_clusters.sh iso

# 2. Build and load local images (see config/IMAGES.md for branch/SHA mapping)
./scripts/build-images.sh iso

# 3. Deploy model
./scripts/deploy-model.sh iso

# 4. Smoke test
./scripts/smoke-test.sh iso

# 5. Tear down (add --purge-data to remove namespaces/PVCs)
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
chmod +x start_clusters.sh scripts/*.sh
./scripts/validate-manifests.sh
```

Requires running Minikube profiles for `kubectl apply --dry-run=client` checks.

## Local test credentials

- Admin: `admin@example.com` / `pass123!` (see `config/images.lock.env`)
- Database/Redis: `user`/`pass`, Redis password `password` (base64 in secrets)

Do not use these outside local Minikube.
