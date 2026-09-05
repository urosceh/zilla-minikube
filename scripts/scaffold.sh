#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p models/iso/tenants models/hybrid/tenants models/shared/tenants \
         models/grouped/iso.grouped/tenants models/grouped/hybrid.grouped/tenants models/grouped/shared.grouped/tenants

# Tenants (33 unique)
iso_tenants=(adobe alibaba arm)
hybrid_tenants=(atlassian baidu blackrock)
shared_tenants=(amazon amd apple azure google meta netflix nvidia paypal reddit slack spotify tesla uber zoom)
grouped_iso_tenants=(binance)
grouped_hybrid_tenants=(datadog ibm intel)
grouped_shared_tenants=(mongo oracle qualcomm salesforce sap shopify stripe twilio)

create_secrets_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  # namespace applied at apply time
type: Opaque
data:
  DB_USERNAME: dXNlcg==        # base64("user")
  DB_PASSWORD: cGFzcw==        # base64("pass")
---
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
  # namespace applied at apply time
type: Opaque
data:
  REDIS_PASSWORD: cGFzc3dvcmQ=  # base64("password")
YAML
}

create_nginx_cm() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  default.conf: |
    server {
      listen 80;
      location /api/ {
        proxy_pass http://zilla-backend:3000/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
      location / {
        proxy_pass http://zilla-frontend:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      }
    }
YAML
}

# ISO model: single aggregate manifest; per-tenant secrets + nginx configmap
cat > models/iso/manifest-iso.yaml <<'YAML'
# ISO model aggregate manifest (namespaces, svc, deploy per tenant)
# FE/BE: 128Mi 0.25 CPU; Postgres: 1Gi 0.5 CPU (3Gi PVC); Redis minimal
# Migrations for iso are defined inline in this file (to be filled)
YAML
for t in "${iso_tenants[@]}"; do
  create_secrets_file "models/iso/tenants/$t/secrets.yaml"
  create_nginx_cm    "models/iso/tenants/$t/nginx-configmap.yaml"
done

# HYBRID model: single k8s + migrations at root; per-tenant secrets under tenants/
cat > models/hybrid/k8s.yaml <<'YAML'
# HYBRID manifest (1 FE, 3 BEs, 1 PG, 1 Redis, 1 Nginx) — to be filled
YAML
cat > models/hybrid/migrations.yaml <<'YAML'
# HYBRID Liquibase Job — to be filled
YAML
for t in "${hybrid_tenants[@]}"; do
  create_secrets_file "models/hybrid/tenants/$t/secrets.yaml"
done

# SHARED model: single k8s + migrations at root; per-tenant secrets under tenants/
cat > models/shared/k8s.yaml <<'YAML'
# SHARED manifest (shared FE/BE 256Mi 0.5 CPU, shared PG/Redis) — to be filled
YAML
cat > models/shared/migrations.yaml <<'YAML'
# SHARED Liquibase Job — to be filled
YAML
for t in "${shared_tenants[@]}"; do
  create_secrets_file "models/shared/tenants/$t/secrets.yaml"
done

# GROUPED model
# iso.grouped: single aggregate manifest; per-tenant secrets + nginx configmap; migrations inline
cat > models/grouped/iso.grouped/manifest-iso.yaml <<'YAML'
# GROUPED-ISO aggregate manifest — to be filled (migrations inline)
YAML
for t in "${grouped_iso_tenants[@]}"; do
  create_secrets_file "models/grouped/iso.grouped/tenants/$t/secrets.yaml"
  create_nginx_cm    "models/grouped/iso.grouped/tenants/$t/nginx-configmap.yaml"
done

# hybrid.grouped: single k8s + migrations; per-tenant secrets
cat > models/grouped/hybrid.grouped/k8s.yaml <<'YAML'
# GROUPED-HYBRID manifest — to be filled
YAML
cat > models/grouped/hybrid.grouped/migrations.yaml <<'YAML'
# GROUPED-HYBRID Liquibase Job — to be filled
YAML
for t in "${grouped_hybrid_tenants[@]}"; do
  create_secrets_file "models/grouped/hybrid.grouped/tenants/$t/secrets.yaml"
done

# shared.grouped: single k8s + migrations; per-tenant secrets
cat > models/grouped/shared.grouped/k8s.yaml <<'YAML'
# GROUPED-SHARED manifest — to be filled
YAML
cat > models/grouped/shared.grouped/migrations.yaml <<'YAML'
# GROUPED-SHARED Liquibase Job — to be filled
YAML
for t in "${grouped_shared_tenants[@]}"; do
  create_secrets_file "models/grouped/shared.grouped/tenants/$t/secrets.yaml"
done

echo "[OK] Scaffold complete."
