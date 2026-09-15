#!/usr/bin/env bash
# Tenant seed/purge helpers for profile-based data operations.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CREDENTIALS_DIR="${ZILLA_MINIKUBE_ROOT}/credentials"
BACKEND_WORKDIR="/home/node/zilla-backend"

resolve_tenant_seed_context() {
  local model="$1"
  local tenant="$2"
  local ns="" deploy="" variant=""

  case "$model" in
    iso)
      ns="$tenant"
      deploy="zilla-backend"
      variant="master"
      ;;
    hybrid)
      ns="hybrid"
      deploy="zilla-backend-${tenant}"
      variant="master"
      ;;
    shared)
      ns="shared"
      deploy="zilla-backend"
      variant="master-shared"
      ;;
    grouped)
      if discover_grouped_iso_tenants | grep -qx "$tenant"; then
        ns="$tenant"
        deploy="zilla-backend"
        variant="master"
      elif discover_grouped_hybrid_tenants | grep -qx "$tenant"; then
        ns="hybrid-grouped"
        deploy="zilla-backend-${tenant}"
        variant="master"
      elif discover_grouped_shared_tenants | grep -qx "$tenant"; then
        ns="shared-grouped"
        deploy="zilla-backend"
        variant="master-shared"
      else
        err "Unknown tenant '${tenant}' for grouped model"
        return 1
      fi
      ;;
    *)
      err "Unknown model: ${model}"
      return 1
      ;;
  esac

  printf '%s|%s|%s' "$ns" "$deploy" "$variant"
}

wait_tenant_backend() {
  local ns="$1"
  local deploy="$2"
  wait_deploy "$ns" "$deploy"
}

clear_tenant_passwords() {
  local ns="$1"
  local deploy="$2"
  local variant="$3"
  local tenant="$4"

  case "$variant" in
    master)
      kctl -n "$ns" exec "deploy/${deploy}" -- sh -c ": > ${BACKEND_WORKDIR}/passwords.txt 2>/dev/null || true"
      ;;
    master-shared)
      kctl -n "$ns" exec "deploy/${deploy}" -- sh -c "mkdir -p ${BACKEND_WORKDIR}/passwords && : > ${BACKEND_WORKDIR}/passwords/${tenant}-passwords.txt"
      ;;
    *)
      err "Unknown backend variant: ${variant}"
      return 1
      ;;
  esac
}

run_tenant_seed() {
  local ns="$1"
  local deploy="$2"
  local variant="$3"
  local tenant="$4"

  if [[ "$variant" == "master-shared" ]]; then
    kctl -n "$ns" exec "deploy/${deploy}" -- \
      env NODE_ENV=test \
      ADMIN_EMAL="${ZILLA_ADMIN_EMAIL}" \
      ADMIN_PASSWORD="${ZILLA_ADMIN_PASSWORD}" \
      TENANT="${tenant}" \
      node build/scripts/seed.script.js
  else
    kctl -n "$ns" exec "deploy/${deploy}" -- \
      env NODE_ENV=test \
      ADMIN_EMAL="${ZILLA_ADMIN_EMAIL}" \
      ADMIN_PASSWORD="${ZILLA_ADMIN_PASSWORD}" \
      node build/scripts/seed.script.js
  fi
}

run_tenant_purge() {
  local ns="$1"
  local deploy="$2"
  local variant="$3"
  local tenant="$4"

  if [[ "$variant" == "master-shared" ]]; then
    kctl -n "$ns" exec "deploy/${deploy}" -- \
      env NODE_ENV=test \
      ADMIN_EMAL="${ZILLA_ADMIN_EMAIL}" \
      TENANT="${tenant}" \
      node build/scripts/purge.script.js
  else
    kctl -n "$ns" exec "deploy/${deploy}" -- \
      env NODE_ENV=test \
      ADMIN_EMAL="${ZILLA_ADMIN_EMAIL}" \
      node build/scripts/purge.script.js
  fi
}

read_tenant_passwords() {
  local ns="$1"
  local deploy="$2"
  local variant="$3"
  local tenant="$4"

  if [[ "$variant" == "master" ]]; then
    kctl -n "$ns" exec "deploy/${deploy}" -- cat "${BACKEND_WORKDIR}/passwords.txt" 2>/dev/null || true
  else
    kctl -n "$ns" exec "deploy/${deploy}" -- cat "${BACKEND_WORKDIR}/passwords/${tenant}-passwords.txt" 2>/dev/null || true
  fi
}

export_tenant_credentials() {
  local profile="$1"
  local tenant="$2"
  local ns="$3"
  local deploy="$4"
  local variant="$5"
  local out="${CREDENTIALS_DIR}/${profile}-${tenant}-users.csv"
  local raw line email password

  mkdir -p "$CREDENTIALS_DIR"

  raw="$(read_tenant_passwords "$ns" "$deploy" "$variant" "$tenant")"

  {
    echo "profile,tenant,email,password"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ([^[:space:]]+@[^[:space:]]+)[[:space:]](.+)$ ]]; then
        email="${BASH_REMATCH[1]}"
        password="${BASH_REMATCH[2]}"
        echo "${profile},${tenant},${email},${password}"
      fi
    done <<< "$raw"
  } > "$out"

  echo "$out"
}

seed_tenant() {
  local model="$1"
  local tenant="$2"
  local ctx ns deploy variant

  ctx="$(resolve_tenant_seed_context "$model" "$tenant")"
  IFS='|' read -r ns deploy variant <<< "$ctx"

  log "Seeding tenant '${tenant}' in ${ns}/${deploy} (${variant})"
  wait_tenant_backend "$ns" "$deploy"
  clear_tenant_passwords "$ns" "$deploy" "$variant" "$tenant"
  run_tenant_seed "$ns" "$deploy" "$variant" "$tenant"
}

purge_tenant() {
  local model="$1"
  local tenant="$2"
  local ctx ns deploy variant

  ctx="$(resolve_tenant_seed_context "$model" "$tenant")"
  IFS='|' read -r ns deploy variant <<< "$ctx"

  log "Purging tenant '${tenant}' in ${ns}/${deploy} (${variant})"
  wait_tenant_backend "$ns" "$deploy"
  run_tenant_purge "$ns" "$deploy" "$variant" "$tenant"
}

first_credentials_tenant_for_model() {
  discover_all_tenants_for_model "$1" | head -n1
}
