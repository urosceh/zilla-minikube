#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

MODEL="${1:-}"
ALL_TENANTS=false
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-tenants) ALL_TENANTS=true ;;
    -h|--help) usage_smoke; exit 0 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$MODEL" ]]; then
  usage_smoke
  exit 1
fi

init_profile "$MODEL"
require_profile_running "$CURRENT_PROFILE"

FAILURES=0
record_fail() { err "$1"; FAILURES=$((FAILURES + 1)); }

check_pods_ready() {
  local ns="$1"
  local not_ready
  not_ready=$(kctl -n "$ns" get pods --no-headers 2>/dev/null | awk '$2 !~ /^[0-9]+\/[0-9]+$/ || $3 != "Running" {print}' | grep -v Completed || true)
  if [[ -n "$not_ready" ]]; then
    record_fail "Pods not ready in ${ns}: ${not_ready}"
    return 1
  fi
  local restarts
  restarts=$(kctl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}:{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | awk -F: '$2>0 {print}' || true)
  if [[ -n "$restarts" ]]; then
    record_fail "Restart loops detected in ${ns}: ${restarts}"
  fi
  ok "Pods ready in ${ns}"
}

check_jobs_complete() {
  local ns="$1"
  local job
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    local succeeded
    succeeded=$(kctl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo 0)
    if [[ "${succeeded:-0}" != "1" ]]; then
      record_fail "Job ${ns}/${job} not complete"
    fi
  done < <(kctl -n "$ns" get jobs -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

check_pg_redis() {
  local ns="$1"
  kctl -n "$ns" exec deploy/postgres -- pg_isready -U user -d zilla -p 5450 >/dev/null \
    || record_fail "PostgreSQL not ready in ${ns}"
  local redis_pass
  redis_pass=$(kctl -n "$ns" get secret redis-secret -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)
  kctl -n "$ns" exec deploy/redis -- sh -c "redis-cli -a '${redis_pass}' ping" | grep -q PONG \
    || record_fail "Redis not ready in ${ns}"
}

api_smoke_direct() {
  local ns="$1"
  local pf_port=18080
  kctl -n "$ns" port-forward svc/nginx-bff "${pf_port}:80" >/tmp/zilla-pf.log 2>&1 &
  local pf_pid=$!
  sleep 2
  local token
  token=$(curl -sf -X POST "http://127.0.0.1:${pf_port}/api/user/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${ZILLA_ADMIN_EMAIL}\",\"password\":\"${ZILLA_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bearerToken",""))' 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    record_fail "Login failed for direct route in ${ns}"
  else
    curl -sf "http://127.0.0.1:${pf_port}/api/project/all" -H "Authorization: Bearer ${token}" >/dev/null \
      || record_fail "Read API failed for direct route in ${ns}"
    ok "API smoke passed (direct) in ${ns}"
  fi
  kill "$pf_pid" 2>/dev/null || true
}

api_smoke_path_prefix() {
  local ns="$1"
  local tenant="$2"
  local pf_port=18081
  kctl -n "$ns" port-forward svc/nginx-bff "${pf_port}:80" >/tmp/zilla-pf.log 2>&1 &
  local pf_pid=$!
  sleep 2
  local token
  token=$(curl -sf -X POST "http://127.0.0.1:${pf_port}/api/${tenant}/user/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${ZILLA_ADMIN_EMAIL}\",\"password\":\"${ZILLA_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bearerToken",""))' 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    record_fail "Login failed for path-prefix tenant ${tenant} in ${ns}"
  else
    curl -sf "http://127.0.0.1:${pf_port}/api/${tenant}/project/all" -H "Authorization: Bearer ${token}" >/dev/null \
      || record_fail "Read API failed for path-prefix tenant ${tenant} in ${ns}"
    ok "API smoke passed (path-prefix) tenant ${tenant} in ${ns}"
  fi
  kill "$pf_pid" 2>/dev/null || true
}

api_smoke_header_tenant() {
  local ns="$1"
  local tenant="$2"
  local pf_port=18082
  kctl -n "$ns" port-forward svc/nginx-bff "${pf_port}:80" >/tmp/zilla-pf.log 2>&1 &
  local pf_pid=$!
  sleep 2
  local token
  token=$(curl -sf -X POST "http://127.0.0.1:${pf_port}/api/user/login" \
    -H 'Content-Type: application/json' \
    -H "tenant: ${tenant}" \
    -d "{\"email\":\"${ZILLA_ADMIN_EMAIL}\",\"password\":\"${ZILLA_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bearerToken",""))' 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    record_fail "Login failed for header-tenant ${tenant} in ${ns}"
  else
    curl -sf "http://127.0.0.1:${pf_port}/api/project/all" \
      -H "Authorization: Bearer ${token}" -H "tenant: ${tenant}" >/dev/null \
      || record_fail "Read API failed for header-tenant ${tenant} in ${ns}"
    ok "API smoke passed (header-tenant) ${tenant} in ${ns}"
  fi
  kill "$pf_pid" 2>/dev/null || true
}

smoke_namespace_iso() {
  local ns="$1"
  check_pods_ready "$ns"
  check_jobs_complete "$ns"
  check_pg_redis "$ns"
  api_smoke_direct "$ns"
}

smoke_namespace_hybrid() {
  local ns="$1"
  local tenants_dir="$2"
  check_pods_ready "$ns"
  check_jobs_complete "$ns"
  check_pg_redis "$ns"
  local tenant
  if $ALL_TENANTS; then
    while IFS= read -r tenant; do
      [[ -n "$tenant" ]] && api_smoke_path_prefix "$ns" "$tenant"
    done < <(discover_tenants_in_dir "$tenants_dir")
  else
    tenant=$(discover_tenants_in_dir "$tenants_dir" | head -n1)
    api_smoke_path_prefix "$ns" "$tenant"
  fi
}

smoke_namespace_shared() {
  local ns="$1"
  local tenants_dir="$2"
  check_pods_ready "$ns"
  check_jobs_complete "$ns"
  check_pg_redis "$ns"
  local tenant
  if $ALL_TENANTS; then
    while IFS= read -r tenant; do
      [[ -n "$tenant" ]] && api_smoke_header_tenant "$ns" "$tenant"
    done < <(discover_tenants_in_dir "$tenants_dir")
  else
    tenant=$(discover_tenants_in_dir "$tenants_dir" | head -n1)
    api_smoke_header_tenant "$ns" "$tenant"
  fi
}

main() {
  case "$MODEL" in
    iso)
      while IFS= read -r ns; do
        [[ -n "$ns" ]] && smoke_namespace_iso "$ns"
      done < <(discover_iso_tenants)
      ;;
    hybrid)
      smoke_namespace_hybrid hybrid "${ZILLA_MINIKUBE_ROOT}/models/hybrid/tenants"
      ;;
    shared)
      smoke_namespace_shared shared "${ZILLA_MINIKUBE_ROOT}/models/shared/tenants"
      ;;
    grouped)
      while IFS= read -r ns; do
        [[ -n "$ns" ]] && smoke_namespace_iso "$ns"
      done < <(discover_grouped_iso_tenants)
      smoke_namespace_hybrid hybrid-grouped "${ZILLA_MINIKUBE_ROOT}/models/grouped/hybrid.grouped/tenants"
      smoke_namespace_shared shared-grouped "${ZILLA_MINIKUBE_ROOT}/models/grouped/shared.grouped/tenants"
      ;;
    *)
      err "Unknown model: ${MODEL}"
      exit 1
      ;;
  esac

  if [[ "$FAILURES" -gt 0 ]]; then
    err "Smoke test failed with ${FAILURES} issue(s)"
    exit 1
  fi
  ok "Smoke test passed for model: ${MODEL}"
}

main "$@"
