#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tenant-data.sh
source "${ROOT_DIR}/scripts/lib/tenant-data.sh"
# shellcheck source=experiments/versions.env
source "${ROOT_DIR}/experiments/versions.env"

MODEL="${1:-}"
if [[ -z "$MODEL" || "$#" -ne 1 ]]; then
  echo "Usage: scripts/run-experiment.sh <iso|hybrid|shared|grouped>" >&2
  exit 1
fi

init_profile "$MODEL"
require_profile_running "$CURRENT_PROFILE"

WARMUP_SECONDS="${WARMUP_SECONDS:-30}"
STEADY_SECONDS="${STEADY_SECONDS:-120}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-30}"
VUS_PER_TENANT="${VUS_PER_TENANT:-2}"
THINK_TIME_SECONDS="${THINK_TIME_SECONDS:-0.25}"
TENANT_FILTER="${TENANTS:-}"
EXPERIMENT_PROTOCOL="${EXPERIMENT_PROTOCOL:-ad-hoc}"
EXPERIMENT_BATCH_ID="${EXPERIMENT_BATCH_ID:-}"
EXPERIMENT_REPETITION="${EXPERIMENT_REPETITION:-}"
EXPERIMENT_RESULT_FILE="${EXPERIMENT_RESULT_FILE:-}"

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    err "${name} must be a positive integer, got: ${value}"
    exit 1
  fi
}

require_positive_integer WARMUP_SECONDS "$WARMUP_SECONDS"
require_positive_integer STEADY_SECONDS "$STEADY_SECONDS"
require_positive_integer COOLDOWN_SECONDS "$COOLDOWN_SECONDS"
require_positive_integer VUS_PER_TENANT "$VUS_PER_TENANT"
if [[ -n "$EXPERIMENT_REPETITION" ]]; then
  require_positive_integer EXPERIMENT_REPETITION "$EXPERIMENT_REPETITION"
fi
if [[ ! "$THINK_TIME_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  err "THINK_TIME_SECONDS must be a non-negative number, got: ${THINK_TIME_SECONDS}"
  exit 1
fi

for command_name in minikube curl python3 jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    err "Required command not found: ${command_name}"
    exit 1
  fi
done

K6_MODE="local"
K6_VERSION=""
if command -v k6 >/dev/null 2>&1; then
  K6_VERSION="$(k6 version | head -n1)"
else
  K6_MODE="docker"
  if ! command -v docker >/dev/null 2>&1; then
    err "k6 is not installed and Docker is unavailable"
    exit 1
  fi
  K6_VERSION="${K6_DOCKER_IMAGE}"
  docker image inspect "${K6_DOCKER_IMAGE}" >/dev/null 2>&1 || docker pull "${K6_DOCKER_IMAGE}"
fi

tenants=()
if [[ -n "$TENANT_FILTER" ]]; then
  while IFS= read -r tenant; do
    [[ -n "$tenant" ]] && tenants+=("$tenant")
  done < <(printf '%s' "$TENANT_FILTER" | tr ',' '\n' | awk '{$1=$1}; NF')
else
  while IFS= read -r tenant; do
    [[ -n "$tenant" ]] && tenants+=("$tenant")
  done < <(discover_all_tenants_for_model "$MODEL")
fi

if [[ "${#tenants[@]}" -eq 0 ]]; then
  err "No tenants selected for model ${MODEL}"
  exit 1
fi

all_tenants="$(discover_all_tenants_for_model "$MODEL")"
configured_tenant_count="$(grep -c . <<<"$all_tenants")"
for tenant in "${tenants[@]}"; do
  if ! grep -qx "$tenant" <<<"$all_tenants"; then
    err "Tenant '${tenant}' does not belong to model '${MODEL}'"
    exit 1
  fi
done

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${ROOT_DIR}/results/${TIMESTAMP}-${MODEL}"
if [[ -e "$RESULT_DIR" ]]; then
  err "Result directory already exists: ${RESULT_DIR}"
  exit 1
fi
mkdir -p "$RESULT_DIR"

TMP_DIR="$(mktemp -d -t zilla-experiment.XXXXXX)"
ROUTES_TSV="${TMP_DIR}/routes.tsv"
ROUTES_JSON="${TMP_DIR}/routes.json"
CREDENTIALS_FILE="${TMP_DIR}/credentials.csv"
PROMETHEUS_LOG="${TMP_DIR}/prometheus-port-forward.log"
touch "$ROUTES_TSV"
echo "tenant,email,password" >"$CREDENTIALS_FILE"

background_pids=()
cleanup() {
  local pid
  for pid in "${background_pids[@]:-}"; do
    pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

resolve_route() {
  local tenant="$1"
  local namespace=""
  local route_type=""
  local group=""

  case "$MODEL" in
    iso)
      namespace="$tenant"
      route_type="direct"
      group="iso"
      ;;
    hybrid)
      namespace="hybrid"
      route_type="path-prefix"
      group="hybrid"
      ;;
    shared)
      namespace="shared"
      route_type="header-tenant"
      group="shared"
      ;;
    grouped)
      if discover_grouped_iso_tenants | grep -qx "$tenant"; then
        namespace="$tenant"
        route_type="direct"
        group="iso"
      elif discover_grouped_hybrid_tenants | grep -qx "$tenant"; then
        namespace="hybrid-grouped"
        route_type="path-prefix"
        group="hybrid"
      elif discover_grouped_shared_tenants | grep -qx "$tenant"; then
        namespace="shared-grouped"
        route_type="header-tenant"
        group="shared"
      else
        return 1
      fi
      ;;
  esac

  printf '%s|%s|%s' "$namespace" "$route_type" "$group"
}

append_credentials() {
  local tenant="$1"
  local existing="${ROOT_DIR}/credentials/${MODEL}-${tenant}-users.csv"
  local before after raw_file context ns deploy variant

  before="$(wc -l <"$CREDENTIALS_FILE" | tr -d ' ')"
  if [[ -f "$existing" ]]; then
    awk -F, -v tenant="$tenant" '
      NR > 1 && $2 == tenant && $3 != "" && $4 != "" {print $2 "," $3 "," $4}
    ' "$existing" >>"$CREDENTIALS_FILE"
  fi
  after="$(wc -l <"$CREDENTIALS_FILE" | tr -d ' ')"
  if [[ "$after" -gt "$before" ]]; then
    return 0
  fi

  context="$(resolve_tenant_seed_context "$MODEL" "$tenant")"
  IFS='|' read -r ns deploy variant <<<"$context"
  raw_file="${TMP_DIR}/raw-${tenant}.txt"
  read_tenant_passwords "$ns" "$deploy" "$variant" "$tenant" >"$raw_file"
  python3 - "$tenant" "$raw_file" "$CREDENTIALS_FILE" <<'PY'
import re
import sys

tenant, source, destination = sys.argv[1:]
rows = []
with open(source, encoding="utf-8") as handle:
    for raw in handle:
        line = raw.strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(",")]
        if len(parts) >= 3 and "@" in parts[-2]:
            rows.append((parts[-2], parts[-1]))
            continue
        match = re.search(r"(\S+@\S+)\s+(\S+)$", line)
        if match:
            rows.append(match.groups())
with open(destination, "a", encoding="utf-8") as handle:
    for email, password in rows:
        handle.write(f"{tenant},{email},{password}\n")
PY
  after="$(wc -l <"$CREDENTIALS_FILE" | tr -d ' ')"
  if [[ "$after" -eq "$before" ]]; then
    warn "No exported seed credentials found for '${tenant}'; using the local test admin"
    echo "${tenant},${ZILLA_ADMIN_EMAIL},${ZILLA_ADMIN_PASSWORD}" >>"$CREDENTIALS_FILE"
  fi
}

wait_namespace_ready() {
  local namespace="$1"
  local attempt
  for attempt in {1..90}; do
    if kctl -n "$namespace" get pods -o json |
      jq -e '
        [.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")] as $active
        | ($active | length) > 0
        and all($active[];
          any(.status.conditions[]?; .type == "Ready" and .status == "True")
        )
      ' >/dev/null; then
      return 0
    fi
    [[ "$attempt" -lt 90 ]] && sleep 2
  done
  err "Active pods did not become Ready in namespace ${namespace}"
  kctl -n "$namespace" get pods >&2
  return 1
}

log "Checking application workloads for ${MODEL}"
namespaces_file="${TMP_DIR}/namespaces.txt"
touch "$namespaces_file"
for tenant in "${tenants[@]}"; do
  IFS='|' read -r namespace route_type group <<<"$(resolve_route "$tenant")"
  echo "$namespace" >>"$namespaces_file"
done
sort -u "$namespaces_file" -o "$namespaces_file"
while IFS= read -r namespace; do
  wait_namespace_ready "$namespace"
done <"$namespaces_file"
ok "Application pods are Ready"

log "Checking monitoring stack and scrape targets"
monitoring_ready=false
for attempt in {1..6}; do
  if bash "${ROOT_DIR}/scripts/observability/status.sh" "$MODEL" >"${RESULT_DIR}/preflight.log" 2>&1; then
    monitoring_ready=true
    break
  fi
  [[ "$attempt" -lt 6 ]] && sleep 5
done
if [[ "$monitoring_ready" != true ]]; then
  cat "${RESULT_DIR}/preflight.log" >&2
  err "Monitoring stack did not become ready after 6 attempts"
  exit 1
fi
ok "Monitoring stack and expected targets are Ready"

PF_ADDRESS="127.0.0.1"
K6_HOST="127.0.0.1"
if [[ "$K6_MODE" == "docker" ]]; then
  PF_ADDRESS="0.0.0.0"
  K6_HOST="host.docker.internal"
fi

log "Preparing tenant routes and credentials"
for tenant in "${tenants[@]}"; do
  IFS='|' read -r namespace route_type group <<<"$(resolve_route "$tenant")"
  port="$(free_port)"
  pf_log="${TMP_DIR}/nginx-${tenant}.log"
  kctl -n "$namespace" port-forward --address="$PF_ADDRESS" \
    service/nginx-bff "${port}:80" >"$pf_log" 2>&1 &
  pf_pid=$!
  background_pids+=("$pf_pid")

  api_prefix="/api"
  tenant_header="false"
  if [[ "$route_type" == "path-prefix" ]]; then
    api_prefix="/api/${tenant}"
  elif [[ "$route_type" == "header-tenant" ]]; then
    tenant_header="true"
  fi

  health_url="http://127.0.0.1:${port}${api_prefix}/health"
  ready=false
  for _ in {1..30}; do
    if [[ "$tenant_header" == "true" ]]; then
      curl -sf -H "tenant: ${tenant}" "$health_url" >/dev/null && ready=true && break
    else
      curl -sf "$health_url" >/dev/null && ready=true && break
    fi
    if ! kill -0 "$pf_pid" >/dev/null 2>&1; then
      err "Nginx port-forward failed for ${tenant}: $(cat "$pf_log")"
      exit 1
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    err "Application health endpoint did not become ready for tenant ${tenant}"
    exit 1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$tenant" "http://${K6_HOST}:${port}" "$api_prefix" "$tenant_header" "$namespace" "$group" \
    >>"$ROUTES_TSV"
  append_credentials "$tenant"
done

python3 - "$ROUTES_TSV" "$ROUTES_JSON" <<'PY'
import csv
import json
import sys

source, destination = sys.argv[1:]
routes = []
with open(source, encoding="utf-8") as handle:
    for tenant, base_url, api_prefix, tenant_header, namespace, group in csv.reader(handle, delimiter="\t"):
        routes.append({
            "tenant": tenant,
            "baseUrl": base_url,
            "apiPrefix": api_prefix,
            "tenantHeader": tenant_header == "true",
            "namespace": namespace,
            "group": group,
        })
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(routes, handle, indent=2)
    handle.write("\n")
PY

PROMETHEUS_PORT="$(free_port)"
kctl -n monitoring port-forward service/kube-prometheus-stack-prometheus \
  "${PROMETHEUS_PORT}:9090" >"$PROMETHEUS_LOG" 2>&1 &
PROMETHEUS_PID=$!
background_pids+=("$PROMETHEUS_PID")
PROMETHEUS_URL="http://127.0.0.1:${PROMETHEUS_PORT}"
for _ in {1..30}; do
  curl -sf "${PROMETHEUS_URL}/-/ready" >/dev/null && break
  if ! kill -0 "$PROMETHEUS_PID" >/dev/null 2>&1; then
    err "Prometheus port-forward failed: $(cat "$PROMETHEUS_LOG")"
    exit 1
  fi
  sleep 1
done
curl -sf "${PROMETHEUS_URL}/-/ready" >/dev/null ||
  { err "Prometheus API did not become ready"; exit 1; }

tenant_csv="$(IFS=,; echo "${tenants[*]}")"
namespace_regex="$(paste -sd'|' "$namespaces_file")"
TEST_START_EPOCH="$(date +%s)"
STEADY_START_EPOCH=$((TEST_START_EPOCH + WARMUP_SECONDS))
STEADY_END_EPOCH=$((STEADY_START_EPOCH + STEADY_SECONDS))

image_lock_sha256="$(python3 - "${ROOT_DIR}/config/images.lock.env" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
current_profile_cpus="$(profile_cpus "$MODEL")"
current_profile_memory="$(profile_memory "$MODEL")"
current_profile_disk="$(profile_disk "$MODEL")"

python3 - "$RESULT_DIR/parameters.json" "$MODEL" "$tenant_csv" "$WARMUP_SECONDS" \
  "$STEADY_SECONDS" "$COOLDOWN_SECONDS" "$VUS_PER_TENANT" "$THINK_TIME_SECONDS" \
  "$K6_MODE" "$K6_VERSION" "$TEST_START_EPOCH" "$STEADY_START_EPOCH" "$STEADY_END_EPOCH" \
  "$EXPERIMENT_PROTOCOL" "$EXPERIMENT_BATCH_ID" "$EXPERIMENT_REPETITION" \
  "$configured_tenant_count" "$current_profile_cpus" "$current_profile_memory" "$current_profile_disk" \
  "$image_lock_sha256" <<'PY'
import json
import sys

(path, model, tenants, warmup, steady, cooldown, vus, think_time, k6_mode,
 k6_version, test_start, steady_start, steady_end, protocol, batch_id,
 repetition, configured_tenant_count, profile_cpus, profile_memory,
 profile_disk, image_lock_sha256) = sys.argv[1:]
selected_tenants = tenants.split(",")
payload = {
    "experiment_protocol": protocol,
    "experiment_batch_id": batch_id or None,
    "experiment_repetition": int(repetition) if repetition else None,
    "model": model,
    "tenants": selected_tenants,
    "tenant_selection": (
        "full" if len(selected_tenants) == int(configured_tenant_count) else "subset"
    ),
    "configured_tenant_count": int(configured_tenant_count),
    "warmup_seconds": int(warmup),
    "steady_seconds": int(steady),
    "cooldown_seconds": int(cooldown),
    "vus_per_tenant": int(vus),
    "think_time_seconds": float(think_time),
    "k6_mode": k6_mode,
    "k6_version": k6_version,
    "test_start_epoch": int(test_start),
    "steady_start_epoch": int(steady_start),
    "steady_end_epoch": int(steady_end),
    "profile_cpus": int(profile_cpus),
    "profile_memory_mib": int(profile_memory),
    "profile_disk": profile_disk,
    "images_lock_sha256": image_lock_sha256,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

kctl get pods --all-namespaces -o json |
  jq --arg namespaces "$namespace_regex" '
    [.items[]
      | select(.metadata.namespace | test("^(" + $namespaces + ")$"))
      | .metadata.namespace as $namespace
      | .metadata.name as $pod
      | .status.containerStatuses[]?
      | {
          namespace: $namespace,
          pod: $pod,
          container: .name,
          image: .image,
          image_id: .imageID
        }]
  ' >"${RESULT_DIR}/images.json"

log "Running k6 (${K6_MODE}) for ${#tenants[@]} tenant(s)"
set +e
if [[ "$K6_MODE" == "local" ]]; then
  MODEL="$MODEL" \
  ROUTES_FILE="$ROUTES_JSON" \
  CREDENTIALS_FILE="$CREDENTIALS_FILE" \
  K6_SUMMARY_PATH="${RESULT_DIR}/k6-summary.json" \
  WARMUP_SECONDS="$WARMUP_SECONDS" \
  STEADY_SECONDS="$STEADY_SECONDS" \
  COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
  VUS_PER_TENANT="$VUS_PER_TENANT" \
  THINK_TIME_SECONDS="$THINK_TIME_SECONDS" \
    k6 run "${ROOT_DIR}/experiments/k6/scenario.js" 2>&1 |
    tee "${RESULT_DIR}/k6.log"
  K6_EXIT_CODE="${PIPESTATUS[0]}"
else
  docker run --rm --add-host=host.docker.internal:host-gateway \
    -v "${ROOT_DIR}/experiments/k6:/scripts:ro" \
    -v "${TMP_DIR}:/work:ro" \
    -v "${RESULT_DIR}:/results" \
    -e MODEL="$MODEL" \
    -e ROUTES_FILE="/work/routes.json" \
    -e CREDENTIALS_FILE="/work/credentials.csv" \
    -e K6_SUMMARY_PATH="/results/k6-summary.json" \
    -e WARMUP_SECONDS="$WARMUP_SECONDS" \
    -e STEADY_SECONDS="$STEADY_SECONDS" \
    -e COOLDOWN_SECONDS="$COOLDOWN_SECONDS" \
    -e VUS_PER_TENANT="$VUS_PER_TENANT" \
    -e THINK_TIME_SECONDS="$THINK_TIME_SECONDS" \
    "${K6_DOCKER_IMAGE}" run /scripts/scenario.js 2>&1 |
    tee "${RESULT_DIR}/k6.log"
  K6_EXIT_CODE="${PIPESTATUS[0]}"
fi
set -e
echo "$K6_EXIT_CODE" >"${RESULT_DIR}/k6-exit-code.txt"

log "Exporting Prometheus aggregates and stable-phase time series"
python3 "${ROOT_DIR}/experiments/export_prometheus.py" \
  --url "$PROMETHEUS_URL" \
  --model "$MODEL" \
  --namespaces "$namespace_regex" \
  --start "$STEADY_START_EPOCH" \
  --end "$STEADY_END_EPOCH" \
  --window-seconds "$STEADY_SECONDS" \
  --tenant-count "${#tenants[@]}" \
  --output-dir "$RESULT_DIR"

if [[ -n "$EXPERIMENT_RESULT_FILE" ]]; then
  printf '%s\n' "$RESULT_DIR" >"$EXPERIMENT_RESULT_FILE"
fi

if [[ "$K6_EXIT_CODE" -ne 0 ]]; then
  err "k6 exited with code ${K6_EXIT_CODE}; diagnostic results were kept in ${RESULT_DIR}"
  exit "$K6_EXIT_CODE"
fi

ok "Experiment complete: ${RESULT_DIR}"
