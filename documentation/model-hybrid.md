## HYBRID model (shared FE, per-tenant BEs)

- One namespace. Single Frontend, N Backends (one per tenant), one Postgres, one Redis, and one Nginx BFF routing by path.
- Per-tenant secrets under `models/hybrid/tenants/<tenant>/secrets.yaml`.
- Manifests in `models/hybrid/k8s.yaml` and `models/hybrid/migrations.yaml`.

Routing and component flow
```mermaid
flowchart TB
  user((User)) --> NGINX[nginx-bff]
  NGINX --> FE[zilla-frontend]
  NGINX -->|/api/atlassian| BE1[backend-atlassian]
  NGINX -->|/api/baidu| BE2[backend-baidu]
  NGINX -->|/api/blackrock| BE3[backend-blackrock]
  BE1 --> PG[(Postgres)] & R[(Redis)]
  BE2 --> PG & R
  BE3 --> PG & R
```

Kubernetes entity wiring
```mermaid
flowchart LR
  CMN[ConfigMap nginx-config] --> NGINX
  SECs[Secrets per tenant] --> BE1 & BE2 & BE3

  FE_SVC{{Service zilla-frontend}} --> FE
  N_SVC{{Service nginx-bff}} --> NGINX
  BE1_SVC{{Service be-atlassian}} --> BE1
  BE2_SVC{{Service be-baidu}} --> BE2
  BE3_SVC{{Service be-blackrock}} --> BE3
  PG_SVC{{Service postgres}} --> PG
  R_SVC{{Service redis}} --> R

  FE --> FE_SVC
  NGINX --> N_SVC
  BE1 --> BE1_SVC
  BE2 --> BE2_SVC
  BE3 --> BE3_SVC
  PG --> PG_SVC
  R --> R_SVC
```

Key commands
- Apply Hybrid: `kubectl apply -f models/hybrid/k8s.yaml && kubectl apply -f models/hybrid/migrations.yaml`
- Port-forward Nginx: `minikube -p hybrid kubectl -- port-forward -n hybrid svc/nginx-bff 8080:80`
