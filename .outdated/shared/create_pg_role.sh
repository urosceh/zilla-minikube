#!/usr/bin/env bash
# create_pg_role.sh
# Create / update a per-tenant PostgreSQL role + schema and generate a Kubernetes Secret YAML.
#
# Usage:
#   ./create_pg_role.sh <tenant> [--force]
#
# Behavior:
#   - Generates (or reuses) role name: <tenant>user
#   - Generates a random 20-char alphanumeric password (or reuses existing if secret file exists unless --force)
#   - Ensures schema <tenant> exists and is owned by the role
#   - Grants privileges needed for Liquibase + application
#   - Writes/updates secret file: ./<tenant>/<tenant>.yaml with base64 encoded DB_USER / DB_PASS / DB_SCHEMA
#   - Does NOT apply the secret; you can apply with: kubectl apply -n <tenant> -f ./<tenant>/<tenant>.yaml
#
# Requirements:
#   - kubectl access to cluster where Postgres runs (deployment labeled app=postgres in namespace default unless overridden)
#   - psql available inside the Postgres container
#
# Environment overrides:
#   POSTGRES_NAMESPACE           (default: default)
#   POSTGRES_APP_LABEL           (default: postgres)  # selector: app=<value>
#   POSTGRES_DB_NAME             (default: zilla)
#   PSQL_SUPERUSER               (default: postgres)  # admin role used to create tenant roles
#   PSQL_SUPERUSER_PASSWORD      (optional; if absent will try to read from secret POSTGRES_SUPER_SECRET)
#   POSTGRES_SUPER_SECRET        (default: postgres-secret)
#   POSTGRES_SUPER_SECRET_USER_KEY (default: DB_USERNAME)
#   POSTGRES_SUPER_SECRET_PASS_KEY (default: DB_PASSWORD)
#   DEBUG (default: false) set to true to print SQL and psql output
#
set -euo pipefail
DEBUG=${DEBUG:-false}

POSTGRES_NAMESPACE=${POSTGRES_NAMESPACE:-default}
POSTGRES_APP_LABEL=${POSTGRES_APP_LABEL:-postgres}
POSTGRES_DB_NAME=${POSTGRES_DB_NAME:-zilla}
PSQL_SUPERUSER=${PSQL_SUPERUSER:-postgres}
POSTGRES_SUPER_SECRET=${POSTGRES_SUPER_SECRET:-postgres-secret}
POSTGRES_SUPER_SECRET_USER_KEY=${POSTGRES_SUPER_SECRET_USER_KEY:-DB_USERNAME}
POSTGRES_SUPER_SECRET_PASS_KEY=${POSTGRES_SUPER_SECRET_PASS_KEY:-DB_PASSWORD}
FORCE=false

if [[ $# -lt 1 ]]; then
  echo "[ERR] Usage: $0 <tenant> [--force]" >&2
  exit 1
fi

TENANT=$1; shift || true
while (( $# )); do
  case "$1" in
    --force) FORCE=true ; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Basic tenant name validation (lowercase letters, digits, underscore allowed)
if [[ ! $TENANT =~ ^[a-z0-9_]+$ ]]; then
  echo "[ERR] Tenant name '$TENANT' invalid. Use lowercase alphanumerics + underscore only." >&2
  exit 1
fi

# Switch to minikube sec cluster
echo "[INFO] Switching to minikube profile: sec" >&2
if ! minikube profile sec >/dev/null 2>&1; then
  echo "[ERR] Failed to switch to minikube profile: sec" >&2
  echo "[ERR] Make sure the 'sec' minikube cluster is running" >&2
  exit 1
fi

# Set kubectl context to use sec cluster
echo "[INFO] Setting kubectl context to sec" >&2
if ! kubectl config use-context sec >/dev/null 2>&1; then
  echo "[ERR] Failed to set kubectl context to sec" >&2
  exit 1
fi

echo "[INFO] Using minikube cluster: sec" >&2

ROLE="${TENANT}user"
SCHEMA="${TENANT}"

# Store secret in ./<tenant>/<tenant>.yaml relative to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANT_DIR="${SCRIPT_DIR}/tenants/${TENANT}"
SECRET_FILE="${TENANT_DIR}/secret.yaml"
mkdir -p "$TENANT_DIR"

# Robust password generator (macOS safe). Prefers openssl; falls back to /dev/urandom with C locale.
_generate_password() {
  local len=${1:-20}
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 64 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$len" || true
  fi
  if [[ -z "${_PW:-}" ]]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" 2>/dev/null || true
  fi
}

if $FORCE || [[ ! -f "$SECRET_FILE" ]]; then
  PASS=$(_generate_password 20)
else
  PASS=$(grep -E 'DB_PASS:' "$SECRET_FILE" | awk '{print $2}' | sed 's/#.*//' | tr -d ' ' | base64 -d 2>/dev/null || true)
  if [[ -z "$PASS" ]]; then
    PASS=$(_generate_password 20)
  fi
fi

if [[ -z "$PASS" ]]; then
  echo "[ERR] Failed to generate password" >&2
  exit 1
fi

b64() { printf "%s" "$1" | base64 | tr -d '\n'; }
B64_USER=$(b64 "$ROLE")
B64_PASS=$(b64 "$PASS")
B64_SCHEMA=$(b64 "$SCHEMA")

# Discover postgres pod
PG_POD=$(kubectl get pods -n "$POSTGRES_NAMESPACE" -l app="$POSTGRES_APP_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$PG_POD" ]]; then
  echo "[ERR] Could not find Postgres pod with label app=$POSTGRES_APP_LABEL in ns=$POSTGRES_NAMESPACE" >&2
  exit 1
fi

echo "[INFO] Using Postgres pod: $PG_POD" >&2

# Read user and password for superuser from secret if not explicitly set
if [[ -z "${PSQL_SUPERUSER_PASSWORD:-}" ]] && kubectl get secret "$POSTGRES_SUPER_SECRET" -n "$POSTGRES_NAMESPACE" >/dev/null 2>&1; then
  PSQL_SUPERUSER=$(kubectl get secret "$POSTGRES_SUPER_SECRET" -n "$POSTGRES_NAMESPACE" -o jsonpath="{.data.${POSTGRES_SUPER_SECRET_USER_KEY}}" 2>/dev/null | base64 -d 2>/dev/null || echo "$PSQL_SUPERUSER")
  PSQL_SUPERUSER_PASSWORD=$(kubectl get secret "$POSTGRES_SUPER_SECRET" -n "$POSTGRES_NAMESPACE" -o jsonpath="{.data.${POSTGRES_SUPER_SECRET_PASS_KEY}}" 2>/dev/null | base64 -d 2>/dev/null || true)
fi

# Test superuser connection
if ! kubectl exec -n "$POSTGRES_NAMESPACE" "$PG_POD" -- sh -c "PGPASSWORD='${PSQL_SUPERUSER_PASSWORD:-}' psql -U $PSQL_SUPERUSER -d $POSTGRES_DB_NAME -c 'SELECT 1'" >/dev/null 2>&1; then
  echo "[ERR] Unable to connect to Postgres as '$PSQL_SUPERUSER'" >&2
  exit 1
fi

echo "[INFO] Applying role/schema changes for tenant '$TENANT' (role=$ROLE, schema=$SCHEMA, db=$POSTGRES_DB_NAME, superuser=$PSQL_SUPERUSER)" >&2
SQL=$(cat <<'EOSQL'
DO $$
DECLARE
  role_name text := '${ROLE}';
  role_pass text := '${PASS}';
  schema_name text := '${SCHEMA}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
    EXECUTE format('CREATE USER %I LOGIN PASSWORD %L', role_name, role_pass);
  ELSE
    EXECUTE format('ALTER USER %I PASSWORD %L', role_name, role_pass);
  END IF;

  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', '${POSTGRES_DB_NAME}', role_name);
  EXECUTE format('GRANT CREATE ON DATABASE %I TO %I', '${POSTGRES_DB_NAME}', role_name);

  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = schema_name) THEN
    EXECUTE format('CREATE SCHEMA %I AUTHORIZATION %I', schema_name, role_name);
  ELSE
    EXECUTE format('ALTER SCHEMA %I OWNER TO %I', schema_name, role_name);
  END IF;

  EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', schema_name, role_name);
  EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO %I', schema_name, role_name);
  EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO %I', schema_name, role_name);

  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON TABLES TO %I', schema_name, role_name);
  EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT ALL ON SEQUENCES TO %I', schema_name, role_name);
END
$$;
EOSQL
)

# Use a temp file to avoid shell quoting issues
SQL_TMP_FILE="$(mktemp)"
trap 'rm -f "$SQL_TMP_FILE"' EXIT
printf '%s\n' "$SQL" | ROLE="$ROLE" PASS="$PASS" SCHEMA="$SCHEMA" POSTGRES_DB_NAME="$POSTGRES_DB_NAME" envsubst '${ROLE} ${PASS} ${SCHEMA} ${POSTGRES_DB_NAME}' > "$SQL_TMP_FILE"

if OUTPUT=$(kubectl exec -i -n "$POSTGRES_NAMESPACE" "$PG_POD" -- sh -c "PGPASSWORD='${PSQL_SUPERUSER_PASSWORD:-}' psql -v ON_ERROR_STOP=1 -U $PSQL_SUPERUSER -d $POSTGRES_DB_NAME -f /dev/stdin" < "$SQL_TMP_FILE" 2>&1); then
  echo "[OK] psql execution successful" >&2
else
  echo "[ERR] psql execution failed with output: $OUTPUT" >&2
  exit 1
fi

echo "[OK] Role & schema ensured for tenant '$TENANT'" >&2

echo "[INFO] Writing secret file: $SECRET_FILE" >&2
cat > "$SECRET_FILE" <<YAML
# =====================
# Postgres Secret (Tenant: ${TENANT})
# Generated by create_pg_role.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# =====================
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  labels:
    tenant: ${TENANT}
type: Opaque
data:
  DB_USER: ${B64_USER}  # base64("${ROLE}")
  DB_PASS: ${B64_PASS}  # base64("${PASS}")
  DB_SCHEMA: ${B64_SCHEMA}  # base64("${SCHEMA}")
YAML

echo "[OK] Secret manifest created at $SECRET_FILE" >&2

echo "Next steps:" >&2
echo "  kubectl apply -n ${TENANT} -f ${SECRET_FILE}" >&2
echo "  (ensure namespace exists; use shared/k8s.sh if needed)" >&2
