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
  not_ready=$(
    kctl -n "$ns" get pods -o json 2>/dev/null |
      python3 -c '
import json
import sys

for pod in json.load(sys.stdin).get("items", []):
    if any(owner.get("kind") == "Job" for owner in pod["metadata"].get("ownerReferences", [])):
        continue
    statuses = pod.get("status", {}).get("containerStatuses", [])
    ready = (
        pod.get("status", {}).get("phase") == "Running"
        and not pod["metadata"].get("deletionTimestamp")
        and statuses
        and all(status.get("ready") for status in statuses)
    )
    if not ready:
        ready_count = sum(bool(status.get("ready")) for status in statuses)
        print(
            pod["metadata"]["name"],
            pod.get("status", {}).get("phase", "Unknown"),
            f"{ready_count}/{len(statuses)}",
        )
'
  )
  if [[ -n "$not_ready" ]]; then
    record_fail "Pods not ready in ${ns}: ${not_ready}"
    return 1
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

API_PF_PID=""
API_PF_LOG=""
API_PF_PORT=""

cleanup_api_port_forward() {
  if [[ -n "$API_PF_PID" ]]; then
    pkill -TERM -P "$API_PF_PID" >/dev/null 2>&1 || true
    kill "$API_PF_PID" >/dev/null 2>&1 || true
    wait "$API_PF_PID" >/dev/null 2>&1 || true
  fi
  [[ -n "$API_PF_LOG" ]] && rm -f "$API_PF_LOG"
  API_PF_PID=""
  API_PF_LOG=""
  API_PF_PORT=""
}
trap cleanup_api_port_forward EXIT INT TERM

start_api_port_forward() {
  local ns="$1"
  API_PF_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  API_PF_LOG="$(mktemp -t zilla-smoke-port-forward.XXXXXX)"
  kctl -n "$ns" port-forward svc/nginx-bff "${API_PF_PORT}:80" >"$API_PF_LOG" 2>&1 &
  API_PF_PID=$!

  local attempt
  for attempt in {1..30}; do
    if curl -sf --connect-timeout 1 --max-time 2 "http://127.0.0.1:${API_PF_PORT}/" >/dev/null; then
      return 0
    fi
    if ! kill -0 "$API_PF_PID" >/dev/null 2>&1; then
      record_fail "Nginx port-forward failed in ${ns}: $(cat "$API_PF_LOG")"
      cleanup_api_port_forward
      return 1
    fi
    sleep 1
  done

  record_fail "Nginx port-forward timed out in ${ns}: $(cat "$API_PF_LOG")"
  cleanup_api_port_forward
  return 1
}

bearer_authorization() {
  local token="$1"
  if [[ "$token" == "Bearer "* ]]; then
    printf '%s' "$token"
  else
    printf 'Bearer %s' "$token"
  fi
}

api_smoke_direct() {
  local ns="$1"
  start_api_port_forward "$ns" || return
  local token
  token=$(curl -sf --connect-timeout 2 --max-time 15 -X POST "http://127.0.0.1:${API_PF_PORT}/api/user/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${ZILLA_ADMIN_EMAIL}\",\"password\":\"${ZILLA_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bearerToken",""))' 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    record_fail "Login failed for direct route in ${ns}"
  else
    local authorization
    authorization="$(bearer_authorization "$token")"
    if curl -sf --connect-timeout 2 --max-time 15 \
      "http://127.0.0.1:${API_PF_PORT}/api/project/all" \
      -H "Authorization: ${authorization}" >/dev/null; then
      ok "API smoke passed (direct) in ${ns}"
    else
      record_fail "Read API failed for direct route in ${ns}"
    fi
  fi
  cleanup_api_port_forward
}

api_smoke_path_prefix() {
  local ns="$1"
  local tenant="$2"
  start_api_port_forward "$ns" || return
  local token
  token=$(curl -sf --connect-timeout 2 --max-time 15 -X POST \
    "http://127.0.0.1:${API_PF_PORT}/api/${tenant}/user/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${ZILLA_ADMIN_EMAIL}\",\"password\":\"${ZILLA_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bearerToken",""))' 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    record_fail "Login failed for path-prefix tenant ${tenant} in ${ns}"
  else
    local authorization
    authorization="$(bearer_authorization "$token")"
    if curl -sf --connect-timeout 2 --max-time 15 \
      "http://127.0.0.1:${API_PF_PORT}/api/${tenant}/project/all" \
      -H "Authorization: ${authorization}" >/dev/null; then
      ok "API smoke passed (path-prefix) tenant ${tenant} in ${ns}"
    else
      record_fail "Read API failed for path-prefix tenant ${tenant} in ${ns}"
    fi
  fi
  cleanup_api_port_forward
}

api_smoke_header_tenant() {
  local ns="$1"
  local tenant="$2"
  start_api_port_forward "$ns" || return
  local token
  token=$(curl -sf --connect-timeout 2 --max-time 15 -X POST \
    "http://127.0.0.1:${API_PF_PORT}/api/user/login" \
    -H 'Content-Type: application/json' \
    -H "tenant: ${tenant}" \
    -d "{\"email\":\"${ZILLA_ADMIN_EMAIL}\",\"password\":\"${ZILLA_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("bearerToken",""))' 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    record_fail "Login failed for header-tenant ${tenant} in ${ns}"
  else
    local authorization
    authorization="$(bearer_authorization "$token")"
    if curl -sf --connect-timeout 2 --max-time 15 \
      "http://127.0.0.1:${API_PF_PORT}/api/project/all" \
      -H "Authorization: ${authorization}" -H "tenant: ${tenant}" >/dev/null; then
      ok "API smoke passed (header-tenant) ${tenant} in ${ns}"
    else
      record_fail "Read API failed for header-tenant ${tenant} in ${ns}"
    fi
  fi
  cleanup_api_port_forward
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
