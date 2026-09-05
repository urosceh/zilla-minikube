## Zilla multi-tenant models

This document outlines the 4 deployment models and their topology. Each model includes two Mermaid diagrams: a component flow and a cluster/topology view.

Resource targets (per pod unless noted):
- Frontend, Backend: iso/hybrid/grouped.shared: 128Mi, 0.25 CPU; shared: 256Mi, 0.5 CPU
- Postgres (per instance): 1Gi RAM, 0.5 CPU, 3Gi PVC
- Redis, Nginx: 64Mi, 0.1 CPU

---

### ISO model (isolated per-tenant)
- One namespace per tenant. Each tenant has its own Frontend, Nginx BFF, Backend, Postgres, and Redis.
- Single manifest is tenant-agnostic; apply with `-n <tenant>`.
- Per-tenant secrets contain admin keys and DB_USER_TENANT/DB_PASS_TENANT; per-tenant backend configmap `tenant-config` holds the single-tenant entry.

Component flow per tenant
```mermaid
flowchart TB
  user((User))
  subgraph NS[Namespace: <tenant>]
    FE[zilla-frontend]
    NGINX[nginx-bff]
    BE[zilla-backend]
    PG[(Postgres)]
    R[(Redis)]
  end

  user -->|HTTP 80| NGINX
  NGINX -->|/| FE
  NGINX -->|/api| BE
  BE --> PG
  BE --> R
```

3-tenant topology (example)
```mermaid
flowchart LR
  subgraph adobe[adobe]
    FE1[frontend] --> N1[nginx]
    N1 --> BE1[backend]
    BE1 --> PG1[(pg)]
    BE1 --> R1[(redis)]
  end
  subgraph alibaba[alibaba]
    FE2[frontend] --> N2[nginx]
    N2 --> BE2[backend]
    BE2 --> PG2[(pg)]
    BE2 --> R2[(redis)]
  end
  subgraph arm[arm]
    FE3[frontend] --> N3[nginx]
    N3 --> BE3[backend]
    BE3 --> PG3[(pg)]
    BE3 --> R3[(redis)]
  end
```

---

### HYBRID model (shared FE, N backends)
- One namespace. Single Frontend + N Backends (one per tenant), one Postgres, one Redis, and an Nginx BFF that routes by path.
- Per-tenant secrets live under `tenants/<tenant>/secrets.yaml`.

Component flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX --> FE[zilla-frontend]
  NGINX -->|/api/atlassian| BE1[backend-atlassian]
  NGINX -->|/api/baidu| BE2[backend-baidu]
  NGINX -->|/api/blackrock| BE3[backend-blackrock]
  BE1 --> PG[(Postgres)]
  BE2 --> PG
  BE3 --> PG
  BE1 --> R[(Redis)]
  BE2 --> R
  BE3 --> R
```

Topology
```mermaid
flowchart LR
  FE[frontend]
  N[nginx-bff]
  FE <---> N
  N --> BE1[be-atlassian]
  N --> BE2[be-baidu]
  N --> BE3[be-blackrock]
  BE1 --> PG[(pg)] & R[(redis)]
  BE2 --> PG & R
  BE3 --> PG & R
```

---

### SHARED model (fully shared)
- One namespace. Single Frontend, single Backend, one Postgres, one Redis, and tenant-config ConfigMap with all tenants.
- Per-tenant secrets under `tenants/<tenant>/secrets.yaml` provide per-tenant DB creds for the shared Backend.

Component flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX --> FE[zilla-frontend]
  NGINX -->|/api| BE[zilla-backend]
  BE --> PG[(Postgres: multiple schemas)]
  BE --> R[(Redis: multiple DBs)]
  CM[(tenant-config)] --> BE
```

Topology
```mermaid
flowchart LR
  FE[frontend] --> N[nginx]
  N --> BE[backend]
  BE --> PG[(pg with schemas: amazon..zoom)]
  BE --> R[(redis db 1..15)]
  CM[(tenant-config)] --> BE
```

---

### GROUPED model (mixed: isolated + hybrid + shared)
- Three namespaces:
  - iso.grouped: one or more fully isolated tenants
  - hybrid.grouped: shared FE, N backends
  - shared.grouped: fully shared
- Each subgroup follows the rules of its respective model.

High-level topology
```mermaid
flowchart TB
  subgraph ISO[iso.grouped]
    IFE[frontend] --> IN[nginx]
    IN --> IBE[backend]
    IBE --> IPG[(pg)] & IR[(redis)]
  end
  subgraph HYB[hybrid.grouped]
    HFE[frontend]
    HN[nginx]
    HFE <---> HN
    HN --> HBE1[be-1]
    HN --> HBE2[be-2]
    HN --> HBE3[be-3]
    HBE1 --> HPG[(pg)] & HR[(redis)]
    HBE2 --> HPG & HR
    HBE3 --> HPG & HR
  end
  subgraph SHR[shared.grouped]
    SFE[frontend] --> SN[nginx]
    SN --> SBE[backend]
    SBE --> SPG[(pg multi-schema)] & SR[(redis multi-db)]
    SCM[(tenant-config)] --> SBE
  end
```

Hybrid.grouped routing focus
```mermaid
sequenceDiagram
  participant U as User
  participant N as nginx-bff
  participant BE1 as backend-tenant-1
  participant BE2 as backend-tenant-2
  participant BE3 as backend-tenant-3

  U->>N: GET /api/tenant-1/*
  N->>BE1: proxy
  U->>N: GET /api/tenant-2/*
  N->>BE2: proxy
  U->>N: GET /api/tenant-3/*
  N->>BE3: proxy
```

---

### Capacity quick reference (requests)
- ISO (per tenant): ~1.5 Gi, hybrid (whole ns with 3 tenants): ~1.6–2.0 Gi, shared: ~1.6 Gi
- For 3 ISO tenants: ~4.5 Gi
- Add 20–30% headroom for kube-system and bursts.

### Common commands
- Start clusters (all or single):
  - `./start_clusters.sh`
  - `./start_clusters.sh iso`
- Deploy ISO tenants: `models/iso/start-iso.sh`
- Diagnose ISO: `scripts/diagnose_iso.sh --fix`
