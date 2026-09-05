## SHARED model (fully shared FE/BE)

- One namespace. Single Frontend and Backend shared by all tenants; one Postgres (multi-schema), one Redis (multiple DBs).
- Per-tenant secrets under `models/shared/tenants/<tenant>/secrets.yaml` supply DB creds; Backend reads them via env and a tenant-config ConfigMap.
- Manifests in `models/shared/k8s.yaml` and `models/shared/migrations.yaml`.

Component flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX --> FE[zilla-frontend]
  NGINX -->|/api| BE[zilla-backend]
  BE --> PG[(Postgres multi-schema)]
  BE --> R[(Redis multi-db)]
  CM[(tenant-config)] --> BE
```

Kubernetes entity wiring
```mermaid
flowchart LR
  CMN[ConfigMap nginx-config] --> NGINX
  CMT[ConfigMap tenant-config] --> BE
  SECs[Secrets per tenant] --> BE

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
- Apply Shared: `kubectl apply -f models/shared/k8s.yaml && kubectl apply -f models/shared/migrations.yaml`
- Port-forward Nginx: `minikube -p shared kubectl -- port-forward -n shared svc/nginx-bff 8080:80`
