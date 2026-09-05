## ISO model (per-tenant isolation)

- One namespace per tenant. Each has its own Frontend, Nginx BFF, Backend, Postgres, Redis.
- Single tenant-agnostic manifest applied with `-n <tenant>`.
- Per-tenant secrets include DB_USERNAME/DB_PASSWORD (admin) and DB_USER_TENANT/DB_PASS_TENANT (app). `tenant-config` ConfigMap carries a single-tenant entry.

Component flow (per tenant)
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

Kubernetes entity wiring
```mermaid
flowchart LR
  CMN[ConfigMap nginx-config] --> NGINX
  CMT[ConfigMap tenant-config] --> BE
  SEC1[Secret postgres-secret] --> BE & PG
  SEC2[Secret redis-secret] --> BE & R

  FE_SVC{{Service zilla-frontend}} --> FE
  BE_SVC{{Service zilla-backend}} --> BE
  N_SVC{{Service nginx-bff}} --> NGINX
  PG_SVC{{Service postgres}} --> PG
  R_SVC{{Service redis}} --> R

  FE --> FE_SVC
  BE --> BE_SVC
  NGINX --> N_SVC
  PG --> PG_SVC
  R --> R_SVC
```

Key commands
- Apply ISO tenants: `models/iso/start-iso.sh`
- Port-forward Nginx: `minikube -p iso kubectl -- port-forward -n <tenant> svc/nginx-bff 8080:80`
