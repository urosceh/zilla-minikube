## GROUPED model (iso + hybrid + shared)

- Three namespaces in one cluster:
  - `iso.grouped`: one/more isolated tenants (like ISO model)
  - `hybrid.grouped`: shared FE, N BEs (like HYBRID)
  - `shared.grouped`: fully shared (like SHARED)
- Each subgroup keeps its own secrets and (where applicable) migrations.

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
    HN --> HBE1[be-tenant-1]
    HN --> HBE2[be-tenant-2]
    HN --> HBE3[be-tenant-3]
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

Kubernetes entity wiring (shared.grouped example)
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
- Apply grouped ISO: `kubectl apply -f models/grouped/iso.grouped/manifest-iso.yaml`
- Apply grouped HYBRID: `kubectl apply -f models/grouped/hybrid.grouped/k8s.yaml && kubectl apply -f models/grouped/hybrid.grouped/migrations.yaml`
- Apply grouped SHARED: `kubectl apply -f models/grouped/shared.grouped/k8s.yaml && kubectl apply -f models/grouped/shared.grouped/migrations.yaml`
- Port-forward Nginx: `minikube -p grouped kubectl -- port-forward -n <ns> svc/nginx-bff 8080:80`
