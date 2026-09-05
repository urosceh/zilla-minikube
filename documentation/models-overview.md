## Zilla models overview

This document summarizes all deployment models: how they are configured, what components they contain, and how they handle data and tenant isolation.

Global components (common across models)
- Frontend: `zilla-frontend`
- Nginx BFF: `nginx-bff` with `nginx-config` ConfigMap
- Backend: `zilla-backend`
- Postgres: one or more instances; DB name `zilla`
- Redis: cache/session store
- Secrets: Postgres and Redis
- Tenant config: `tenant-config` ConfigMap (JSON), where applicable

Key configuration locations
- ISO: `models/iso/manifest-iso.yaml` (tenant-agnostic), `models/iso/tenants/<tenant>/*.yaml`
- HYBRID: `models/hybrid/k8s.yaml`, `models/hybrid/migrations.yaml`, `models/hybrid/tenants/<tenant>/secrets.yaml`
- SHARED: `models/shared/k8s.yaml`, `models/shared/migrations.yaml`, `models/shared/tenants/<tenant>/secrets.yaml`, `models/shared/platform-secrets.yaml`
- GROUPED: `models/grouped/{iso.grouped|hybrid.grouped|shared.grouped}/...`
- Cluster bootstrap: `start_clusters.sh`

---

### ISO (isolated per tenant)
- Per-tenant namespace. Apply the same manifest with `-n <tenant>`.
- Components (per tenant): Frontend, Nginx, Backend, Postgres, Redis.
- Secrets per tenant: `postgres-secret` contains admin DB_USERNAME/DB_PASSWORD and app creds DB_USER_TENANT/DB_PASS_TENANT. `redis-secret` contains REDIS_PASSWORD.
- Tenant config per tenant: `tenant-config` (single-tenant JSON) mounted to Backend; Backend uses TENANT_CONFIG_PATH.
- Isolation
  - Compute/network: namespace and per-tenant Deployments/Services
  - Data: per-tenant Postgres instance and Redis instance
  - Secrets: per-tenant

ISO flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX -->|/| FE[zilla-frontend]
  NGINX -->|/api| BE[zilla-backend]
  BE --> PG[(Postgres)]
  BE --> R[(Redis)]
  CMT[(tenant-config)] --> BE
```

ISO k8s wiring
```mermaid
flowchart LR
  CMN[ConfigMap nginx-config] --> NGINX
  CMT[ConfigMap tenant-config] --> BE
  SEC1[Secret postgres-secret] --> BE & PG
  SEC2[Secret redis-secret] --> BE & R
  FE_S{{svc zilla-frontend}} --> FE
  N_S{{svc nginx-bff}} --> NGINX
  BE_S{{svc zilla-backend}} --> BE
  PG_S{{svc postgres}} --> PG
  R_S{{svc redis}} --> R
  FE --> FE_S
  NGINX --> N_S
  BE --> BE_S
  PG --> PG_S
  R --> R_S
```

---

### HYBRID (shared FE, per-tenant BEs)
- One namespace. Single Frontend and Nginx; one Postgres and Redis; one Backend per tenant.
- Secrets: per-tenant secrets under `tenants/<tenant>` supply DB user/password for that tenant’s backend.
- Nginx routes by path (e.g., `/api/<tenant>/...`) to the respective backend Service.
- Isolation
  - Compute: per-tenant backend Deployments
  - Data: single Postgres and Redis shared at instance level; backends use tenant-specific DB users/schemas
  - Secrets: per-tenant

HYBRID flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX --> FE[zilla-frontend]
  NGINX -->|/api/tenant-a| BE1[backend-tenant-a]
  NGINX -->|/api/tenant-b| BE2[backend-tenant-b]
  NGINX -->|/api/tenant-c| BE3[backend-tenant-c]
  BE1 --> PG[(Postgres shared)] & R[(Redis shared)]
  BE2 --> PG & R
  BE3 --> PG & R
```

HYBRID k8s wiring
```mermaid
flowchart LR
  CMN[ConfigMap nginx-config] --> NGINX
  SECs[Secrets per-tenant] --> BE1 & BE2 & BE3
  N_S{{svc nginx-bff}} --> NGINX
  FE_S{{svc zilla-frontend}} --> FE
  BE1_S{{svc be-tenant-a}} --> BE1
  BE2_S{{svc be-tenant-b}} --> BE2
  BE3_S{{svc be-tenant-c}} --> BE3
  PG_S{{svc postgres}} --> PG
  R_S{{svc redis}} --> R
  FE --> FE_S
  NGINX --> N_S
  BE1 --> BE1_S
  BE2 --> BE2_S
  BE3 --> BE3_S
  PG --> PG_S
  R --> R_S
```

---

### SHARED (fully shared FE/BE)
- One namespace. Single Frontend and Backend; one Postgres (multi-schema) and Redis (multiple DB indexes).
- Secrets: per-tenant secrets provide DB user/password (e.g., DB_USER_AMAZON) read by Backend as envs.
- Tenant config: `tenant-config` (all tenants JSON) mounted to Backend.
- Isolation
  - Compute: shared Deployments
  - Data: schema-level (Postgres) and DB-index-level (Redis)
  - Secrets: per-tenant

SHARED flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX --> FE[zilla-frontend]
  NGINX -->|/api| BE[zilla-backend]
  BE --> PG[(Postgres schemas: t1..tN)]
  BE --> R[(Redis dbs: 1..N)]
  CMT[(tenant-config)] --> BE
```

SHARED k8s wiring
```mermaid
flowchart LR
  CMN[ConfigMap nginx-config] --> NGINX
  CMT[ConfigMap tenant-config] --> BE
  SECs[Secrets per-tenant envs] --> BE
  FE_S{{svc zilla-frontend}} --> FE
  BE_S{{svc zilla-backend}} --> BE
  N_S{{svc nginx-bff}} --> NGINX
  PG_S{{svc postgres}} --> PG
  R_S{{svc redis}} --> R
  FE --> FE_S
  BE --> BE_S
  NGINX --> N_S
  PG --> PG_S
  R --> R_S
```

---

### GROUPED (mixed)
- Three namespaces, one per subgroup:
  - `iso.grouped`: isolated tenants (like ISO)
  - `hybrid.grouped`: shared FE + per-tenant BEs (like HYBRID)
  - `shared.grouped`: fully shared (like SHARED)
- Isolation follows the underlying subgroup’s rules.

GROUPED topology
```mermaid
flowchart LR
  subgraph ISO[iso.grouped]
    IFE[FE] --> IN[nginx]
    IN --> IBE[BE]
    IBE --> IPG[(pg)] & IR[(redis)]
  end
  subgraph HYB[hybrid.grouped]
    HFE[FE] <---> HN[nginx]
    HN --> HBE1[BE-1]
    HN --> HBE2[BE-2]
    HN --> HBE3[BE-3]
    HBE1 --> HPG[(pg)] & HR[(redis)]
    HBE2 --> HPG & HR
    HBE3 --> HPG & HR
  end
  subgraph SHR[shared.grouped]
    SFE[FE] --> SN[nginx]
    SN --> SBE[BE]
    SBE --> SPG[(pg multi-schema)] & SR[(redis multi-db)]
    SCM[(tenant-config)] --> SBE
  end
```

---

### Operational notes
- Resource requests/limits
  - ISO (per tenant default): FE 256Mi/512Mi, BE 128Mi/128Mi, PG 1Gi/1Gi (+3Gi PVC), Redis 64Mi/64Mi, Nginx 64Mi/64Mi
  - HYBRID: FE/BE 128Mi, PG 1Gi, Redis 64Mi
  - SHARED: FE/BE 256Mi/0.5 CPU
- Start clusters: `./start_clusters.sh [iso|hybrid|grouped|shared]`
- Deploy ISO tenants: `models/iso/start-iso.sh`
- Port-forward Nginx per ns: `minikube -p <profile> kubectl -- -n <ns> port-forward svc/nginx-bff 8080:80`
