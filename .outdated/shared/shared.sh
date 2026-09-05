#!/usr/bin/env bash
# Deploy per-tenant secrets (and future manifests) to their own namespaces.
# First creates PostgreSQL roles for all predefined tenants using create_pg_role.sh
# Then iterates over each tenant and:
#  1. Ensures a namespace with the same name exists
#  2. Applies {tenant}/{tenant}.yaml into that namespace
#  3. Copies the secret named 'postgres-secret' from the tenant namespace
#     into the default namespace renaming it to postgres-secret-{tenant}
#
# Predefined tenants: meta, amazon, google, tesla, uber, slack, apple, azure, 
#                     netflix, spotify, zoom, nvidia, amd, paypal, reddit
#
# Usage:
#   ./shared.sh              # deploy all predefined tenants
#   ./shared.sh amazon meta  # deploy specific tenants (still creates PG roles for all)
#
# Requirements:
#   - kubectl installed and configured (current context points to your cluster)
#   - create_pg_role.sh script in the same directory
#   - Each tenant folder contains a YAML file named <tenant>.yaml
#   - Applying that file creates a secret named 'postgres-secret' in the tenant namespace
#
# Safe to re-run (idempotent). Missing tenant YAMLs are skipped with a warning.

set -euo pipefail
minikube profile sec > /dev/null 2>&1
kubectl config use-context sec

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_FILE="${SCRIPT_DIR}/migrations.yaml"

# Colors (fallback to no color if not a tty)
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  RED='\033[0;31m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN='' ; YELLOW='' ; RED='' ; CYAN='' ; BOLD='' ; NC=''
fi

log() { echo -e "${CYAN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
err() { echo -e "${RED}[ERR ]${NC} $*" >&2; }
ok() { echo -e "${GREEN}[ OK ]${NC} $*"; }

copy_secret_to_default() {
  local tenant=$1
  local source_secret_name="postgres-secret"                    # Fixed source name in tenant namespace
  local dest_secret_name="postgres-secret-${tenant}"           # Fixed destination naming pattern

  # Check existence in tenant namespace
  if ! kubectl get secret "$source_secret_name" -n "$tenant" >/dev/null 2>&1; then
    warn "Source secret $source_secret_name not found in namespace $tenant; skipping copy"
    return 0
  fi
  log "Copying $source_secret_name (ns:$tenant) to namespace default as $dest_secret_name"

  if command -v jq >/dev/null 2>&1; then
    if kubectl get secret "$source_secret_name" -n "$tenant" -o json \
      | jq --arg newname "$dest_secret_name" '.metadata.namespace="default" | .metadata.name=$newname | del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.metadata.ownerReferences,.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
      | kubectl apply -f - >/dev/null; then
        ok "Copied $source_secret_name to default as $dest_secret_name"
    else
      err "Failed to copy $source_secret_name to default via jq path"
    fi
  else
    if kubectl get secret "$source_secret_name" -n "$tenant" -o yaml \
      | sed '/^metadata:$/,/^type:/ { /namespace:/d; }' \
      | sed '/^metadata:$/a \\  namespace: default' \
      | sed "/^  name: ${source_secret_name}$/s//  name: ${dest_secret_name}/" \
      | sed '/creationTimestamp:/d;/resourceVersion:/d;/uid:/d' \
      | kubectl apply -f - >/dev/null; then
        ok "Copied $source_secret_name to default as $dest_secret_name (sed fallback)"
    else
      err "Failed to copy $source_secret_name to default (sed fallback)"
    fi
  fi
}

# Determine tenant list
TENANTS=()
if (( $# > 0 )); then
  for t in "$@"; do TENANTS+=("$t"); done
else
  # Fixed tenant list - no longer scanning directories
  TENANTS=(
    "amazon"
    "amd"
    "apple"
    "azure"
    "google"
    "meta"
    "netflix"
    "nvidia"
    "paypal"
    "reddit"
    "slack"
    "spotify"
    "tesla"
    "uber"
    "zoom"
  )
fi

log "Processing tenants: ${TENANTS[*]}"

# First, create PostgreSQL roles for all tenants
log "Creating PostgreSQL roles for tenants..."
CREATE_PG_ROLE_SCRIPT="$SCRIPT_DIR/create_pg_role.sh"

if [[ ! -f "$CREATE_PG_ROLE_SCRIPT" ]]; then
  err "create_pg_role.sh script not found at $CREATE_PG_ROLE_SCRIPT"
  exit 1
fi

if [[ ! -x "$CREATE_PG_ROLE_SCRIPT" ]]; then
  log "Making create_pg_role.sh executable"
  chmod +x "$CREATE_PG_ROLE_SCRIPT"
fi

for tenant in "${TENANTS[@]}"; do
  log "Creating PostgreSQL role for tenant: $tenant"
  if "$CREATE_PG_ROLE_SCRIPT" "$tenant" --force; then
    ok "PostgreSQL role created for tenant $tenant"
  else
    err "Failed to create PostgreSQL role for tenant $tenant"
    exit 1
  fi
done

log "All PostgreSQL roles created successfully"
echo

for tenant in "${TENANTS[@]}"; do
  TENANT_DIR="$SCRIPT_DIR/tenants/$tenant"
  YAML_FILE="$TENANT_DIR/secret.yaml"

  if [[ ! -d "$TENANT_DIR" ]]; then
    warn "Directory $TENANT_DIR does not exist; skipping tenant '$tenant'"
    continue
  fi
  if [[ ! -f "$YAML_FILE" ]]; then
    warn "Expected file $YAML_FILE for tenant '$tenant' not found; skipping"
    continue
  fi

  log "Ensuring namespace '$tenant' exists"
  if ! kubectl get namespace "$tenant" >/dev/null 2>&1; then
    kubectl create namespace "$tenant" >/dev/null
    ok "Created namespace $tenant"
  else
    ok "Namespace $tenant already exists"
  fi

  log "Applying $YAML_FILE to namespace $tenant"
  if kubectl apply -n "$tenant" -f "$YAML_FILE" >/dev/null; then
    ok "Applied $tenant manifest"
  else
    err "Failed to apply manifest for tenant $tenant"
    echo
    continue
  fi

  copy_secret_to_default "$tenant"
  
  log "Applying migrations for tenant: $tenant"
  kubectl delete job --all -n "$tenant" >/dev/null 2>&1;
  sleep 2
  if kubectl apply -n "$tenant" -f "$MIGRATIONS_FILE" >/dev/null; then
    ok "Applied migrations for tenant $tenant"
  else
    err "Failed to apply migrations for tenant $tenant"
    echo
    continue
  fi
  echo
done

log "Sleeping for 15 seconds to allow migrations to complete..."
sleep 15

for tenant in "${TENANTS[@]}"; do
  if [ "$(kubectl get job "zilla-migrations" -n "$tenant" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
    ok "\nMigrations completed successfully for tenant $tenant"
  else
    err "\nMigrations failed for tenant $tenant"
    echo
    continue
  fi
done

log "Done."