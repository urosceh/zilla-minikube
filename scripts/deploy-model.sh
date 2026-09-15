#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
  usage_deploy
  exit 1
fi

init_profile "$MODEL"
require_profile_running "$CURRENT_PROFILE"

delete_jobs() {
  local ns="$1"
  kctl -n "$ns" delete job --all --ignore-not-found=true >/dev/null 2>&1 || true
}

apply_tenant_secrets_dir() {
  local ns="$1"
  local dir="$2"
  local f
  for f in "$dir"/*/secrets.yaml; do
    [[ -f "$f" ]] && apply_file "$ns" "$f"
  done
}

wait_jobs_matching() {
  local ns="$1"
  local prefix="$2"
  local job
  while IFS= read -r job; do
    [[ -n "$job" ]] && wait_job "$ns" "$job"
  done < <(kctl -n "$ns" get jobs -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}{end}" | grep "^${prefix}" || true)
}

apply_observability_monitors_if_available() {
  if kctl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 &&
    kctl get namespace monitoring >/dev/null 2>&1; then
    apply_file "" "${ZILLA_MINIKUBE_ROOT}/observability/service-monitors.yaml"
  else
    warn "Prometheus Operator is not installed; ServiceMonitors will be applied by observability/install.sh"
  fi
}

deploy_exporters() {
  local ns="$1"
  local overlay="$2"
  log "Deploying PostgreSQL and Redis exporters in ${ns}"
  kctl -n "$ns" apply -k \
    "${ZILLA_MINIKUBE_ROOT}/observability/exporters/overlays/${overlay}"
  wait_deploy "$ns" postgres-exporter
  wait_deploy "$ns" redis-exporter
}

seed_admin_master() {
  local ns="$1"
  local deploy="${2:-zilla-backend}"
  log "Seeding admin in ${ns}/${deploy} (master)"
  kctl -n "$ns" exec "deploy/${deploy}" -- \
    node build/scripts/insert.admin.script.js "${ZILLA_ADMIN_EMAIL}" "${ZILLA_ADMIN_PASSWORD}" || true
}

seed_admin_shared() {
  local ns="$1"
  local tenant="$2"
  log "Seeding admin for tenant ${tenant} in ${ns}"
  kctl -n "$ns" exec deploy/zilla-backend -- \
    node build/scripts/insert.admin.script.js "${tenant}" "${ZILLA_ADMIN_EMAIL}" "${ZILLA_ADMIN_PASSWORD}" || true
}

deploy_iso_tenant() {
  local tenant="$1"
  local dir="${ZILLA_MINIKUBE_ROOT}/models/iso"
  log "Deploying ISO tenant: ${tenant}"
  kctl create namespace "$tenant" --dry-run=client -o yaml | kctl apply -f -
  apply_file "$tenant" "${dir}/tenants/${tenant}/secrets.yaml"
  [[ -f "${dir}/tenants/${tenant}/nginx-configmap.yaml" ]] && apply_file "$tenant" "${dir}/tenants/${tenant}/nginx-configmap.yaml"
  apply_file "$tenant" "${dir}/data.yaml"
  wait_data_layer "$tenant"
  deploy_exporters "$tenant" iso
  delete_jobs "$tenant"
  apply_file "$tenant" "${dir}/migrations.yaml"
  wait_job "$tenant" zilla-migrations
  apply_file "$tenant" "${dir}/apps.yaml"
  wait_deploy "$tenant" zilla-backend
  wait_deploy "$tenant" zilla-frontend
  wait_deploy "$tenant" nginx-bff
  seed_admin_master "$tenant"
}

deploy_iso() {
  local tenant
  while IFS= read -r tenant; do
    [[ -n "$tenant" ]] && deploy_iso_tenant "$tenant"
  done < <(discover_iso_tenants)
}

deploy_hybrid_like() {
  local base_dir="$1"
  local ns="$2"
  local exporter_overlay="$3"
  log "Deploying hybrid-like stack in namespace ${ns}"
  apply_file "" "${base_dir}/platform-secrets.yaml"
  apply_tenant_secrets_dir "$ns" "${base_dir}/tenants"
  apply_file "$ns" "${base_dir}/data.yaml"
  wait_data_layer "$ns"
  deploy_exporters "$ns" "$exporter_overlay"
  delete_jobs "$ns"
  apply_file "$ns" "${base_dir}/tenant-init.yaml"
  wait_jobs_matching "$ns" "tenant-init-"
  apply_file "$ns" "${base_dir}/migrations.yaml"
  wait_jobs_matching "$ns" "zilla-migrations-"
  apply_file "$ns" "${base_dir}/apps.yaml"
  # A stopped profile resumes existing application pods before Redis is ready.
  # Restart hybrid backends after the data layer to restore their Redis clients.
  local backend_deploy
  while IFS= read -r backend_deploy; do
    [[ -n "$backend_deploy" ]] &&
      kctl -n "$ns" rollout restart "deployment/${backend_deploy}"
  done < <(
    kctl -n "$ns" get deployment \
      -l app.kubernetes.io/component=backend \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )
  local deploy
  while IFS= read -r deploy; do
    [[ -n "$deploy" ]] && wait_deploy "$ns" "$deploy"
  done < <(kctl -n "$ns" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  local tenant
  while IFS= read -r tenant; do
    [[ -n "$tenant" ]] && seed_admin_master "$ns" "zilla-backend-${tenant}"
  done < <(discover_tenants_in_dir "${base_dir}/tenants")
}

deploy_shared_like() {
  local base_dir="$1"
  local ns="$2"
  local exporter_overlay="$3"
  log "Deploying shared-like stack in namespace ${ns}"
  if [[ -f "${base_dir}/platform-secrets.yaml" ]]; then
    apply_file "" "${base_dir}/platform-secrets.yaml"
  fi
  apply_tenant_secrets_dir "$ns" "${base_dir}/tenants"
  apply_file "$ns" "${base_dir}/data.yaml"
  wait_data_layer "$ns"
  deploy_exporters "$ns" "$exporter_overlay"
  delete_jobs "$ns"
  apply_file "$ns" "${base_dir}/tenant-init.yaml"
  wait_jobs_matching "$ns" "tenant-init-"
  apply_file "$ns" "${base_dir}/migrations.yaml"
  wait_jobs_matching "$ns" "zilla-migrations-"
  apply_file "$ns" "${base_dir}/apps.yaml"
  wait_deploy "$ns" zilla-backend
  wait_deploy "$ns" zilla-frontend
  wait_deploy "$ns" nginx-bff
  local tenant
  while IFS= read -r tenant; do
    [[ -n "$tenant" ]] && seed_admin_shared "$ns" "$tenant"
  done < <(discover_tenants_in_dir "${base_dir}/tenants")
}

deploy_hybrid() {
  deploy_hybrid_like "${ZILLA_MINIKUBE_ROOT}/models/hybrid" hybrid hybrid
}

deploy_shared() {
  apply_file "" "${ZILLA_MINIKUBE_ROOT}/models/shared/platform-secrets.yaml"
  deploy_shared_like "${ZILLA_MINIKUBE_ROOT}/models/shared" shared shared
}

deploy_grouped() {
  local tenant
  while IFS= read -r tenant; do
    [[ -n "$tenant" ]] && deploy_iso_tenant_grouped "$tenant"
  done < <(discover_grouped_iso_tenants)
  deploy_hybrid_like "${ZILLA_MINIKUBE_ROOT}/models/grouped/hybrid.grouped" hybrid-grouped grouped-hybrid
  deploy_shared_like "${ZILLA_MINIKUBE_ROOT}/models/grouped/shared.grouped" shared-grouped grouped-shared
}

deploy_iso_tenant_grouped() {
  local tenant="$1"
  local dir="${ZILLA_MINIKUBE_ROOT}/models/grouped/iso.grouped"
  log "Deploying grouped ISO tenant: ${tenant}"
  kctl create namespace "$tenant" --dry-run=client -o yaml | kctl apply -f -
  apply_file "$tenant" "${dir}/tenants/${tenant}/secrets.yaml"
  [[ -f "${dir}/tenants/${tenant}/nginx-configmap.yaml" ]] && apply_file "$tenant" "${dir}/tenants/${tenant}/nginx-configmap.yaml"
  apply_file "$tenant" "${dir}/data.yaml"
  wait_data_layer "$tenant"
  deploy_exporters "$tenant" grouped-iso
  delete_jobs "$tenant"
  apply_file "$tenant" "${dir}/migrations.yaml"
  wait_job "$tenant" zilla-migrations
  apply_file "$tenant" "${dir}/apps.yaml"
  wait_deploy "$tenant" zilla-backend
  wait_deploy "$tenant" zilla-frontend
  wait_deploy "$tenant" nginx-bff
  seed_admin_master "$tenant"
}

main() {
  apply_observability_monitors_if_available
  case "$MODEL" in
    iso) deploy_iso ;;
    hybrid) deploy_hybrid ;;
    shared) deploy_shared ;;
    grouped) deploy_grouped ;;
    *)
      err "Unknown model: ${MODEL}"
      usage_deploy
      exit 1
      ;;
  esac
  ok "Deploy complete for model: ${MODEL}"
}

main "$@"
