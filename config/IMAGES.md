# Zilla container image provenance

All local deploys use images from [`config/images.lock.env`](./images.lock.env).

| Image | Branch | Commit SHA | Local tag |
| --- | --- | --- | --- |
| `zilla-backend` (ISO/hybrid/grouped ISO+hybrid) | `master` | `a64b6c444c7a35a79a319709de2d2e30cfa88e1b` | `zilla-backend:local-master-a64b6c44` |
| `zilla-backend` (shared/grouped-shared) | `master-shared` | `c50a1562c88cca323982de89e67f8cb73eb52018` | `zilla-backend:local-master-shared-c50a156` |
| `zilla-frontend` (ISO/grouped ISO) | `master` | `d481e950ca47b60534257b23636d68d4e1a73783` | `zilla-frontend:local-master-d481e950` |
| `zilla-frontend` (hybrid/shared/grouped) | `master-shared` | `3107d77a0ebc5a9f53107a2c7de37a819a372d45` | `zilla-frontend:local-master-shared-3107d77` |
| `zilla-migrations` | n/a (Docker Hub digest pin) | `sha256:1cf36e11…` | digest in manifests |
| `postgres` | n/a | `14-alpine` | `postgres:14-alpine` |
| `redis` | n/a | `6.2-alpine` | `redis:6.2-alpine` |
| `nginx` | n/a | `1.27-alpine` | `nginx:1.27-alpine` |
| `postgres-exporter` | n/a | `v0.20.1` | `quay.io/prometheuscommunity/postgres-exporter:v0.20.1@sha256:ac5ec343…` |
| `redis-exporter` | n/a | `v1.90.0` | `docker.io/oliver006/redis_exporter:v1.90.0@sha256:a129504e…` |

Build and load into a profile:

```bash
./scripts/build-images.sh iso
```

Repositories:

- Backend: `../zilla-backend`
- Frontend: `../zilla-frontend`
