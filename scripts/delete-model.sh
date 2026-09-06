#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

MODEL="${1:-}"
PURGE=false
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge-data) PURGE=true ;;
    -h|--help) usage_delete; exit 0 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$MODEL" ]]; then
  usage_delete
  exit 1
fi

init_profile "$MODEL"

delete_namespace() {
  local ns="$1"
  log "Deleting namespace ${ns}"
  kctl delete namespace "$ns" --ignore-not-found=true --wait=true
}

delete_workloads_in_ns() {
  local ns="$1"
  log "Deleting workloads in ${ns}"
  kctl -n "$ns" delete deploy,sts,job,svc,cm,secret,ingress --all --ignore-not-found=true || true
  if $PURGE; then
    kctl -n "$ns" delete pvc --all --ignore-not-found=true || true
  fi
}

delete_iso() {
  local tenant
  while IFS= read -r tenant; do
    [[ -z "$tenant" ]] && continue
    if $PURGE; then
      delete_namespace "$tenant"
    else
      delete_workloads_in_ns "$tenant"
    fi
  done < <(discover_iso_tenants)
}

delete_hybrid() {
  if $PURGE; then
    delete_namespace hybrid
  else
    delete_workloads_in_ns hybrid
  fi
}

delete_shared() {
  if $PURGE; then
    delete_namespace shared
  else
    delete_workloads_in_ns shared
  fi
}

delete_grouped() {
  local tenant
  while IFS= read -r tenant; do
    [[ -z "$tenant" ]] && continue
    if $PURGE; then
      delete_namespace "$tenant"
    else
      delete_workloads_in_ns "$tenant"
    fi
  done < <(discover_grouped_iso_tenants)
  if $PURGE; then
    delete_namespace hybrid-grouped
    delete_namespace shared-grouped
  else
    delete_workloads_in_ns hybrid-grouped
    delete_workloads_in_ns shared-grouped
  fi
}

main() {
  case "$MODEL" in
    iso) delete_iso ;;
    hybrid) delete_hybrid ;;
    shared) delete_shared ;;
    grouped) delete_grouped ;;
    *)
      err "Unknown model: ${MODEL}"
      usage_delete
      exit 1
      ;;
  esac
  ok "Delete complete for model: ${MODEL} (purge=${PURGE})"
}

main "$@"
