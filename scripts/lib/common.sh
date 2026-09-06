#!/usr/bin/env bash
# Shared helpers for Zilla Minikube scripts.

set -euo pipefail

ZILLA_MINIKUBE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ZILLA_MINIKUBE_ROOT

# shellcheck source=scripts/lib/model-config.sh
source "${ZILLA_MINIKUBE_ROOT}/scripts/lib/model-config.sh"

CURRENT_PROFILE=""
KCTL=()

log() { echo "[INFO] $*"; }
ok() { echo "[OK] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERR] $*" >&2; }

usage_start_clusters() {
  cat <<'EOF'
Usage: start_clusters.sh <iso|hybrid|shared|grouped|all>

Starts one or all Minikube profiles with uniform capacity:
  3 CPU, 4096 MiB RAM, 20 GiB disk, docker driver.

Examples:
  ./start_clusters.sh iso
  ./start_clusters.sh all
EOF
}

usage_deploy() {
  cat <<'EOF'
Usage: scripts/deploy-model.sh <iso|hybrid|shared|grouped>

Deploys the selected infrastructure model into its Minikube profile.
All kubectl commands use: minikube -p <profile> kubectl --
EOF
}

usage_delete() {
  cat <<'EOF'
Usage: scripts/delete-model.sh <iso|hybrid|shared|grouped> [--purge-data]

Removes model workloads. With --purge-data, deletes namespaces and PVCs.
EOF
}

usage_smoke() {
  cat <<'EOF'
Usage: scripts/smoke-test.sh <iso|hybrid|shared|grouped> [--all-tenants]

Runs readiness, health, infrastructure, and API smoke checks.
EOF
}

require_model() {
  local model="$1"
  case " ${VALID_MODELS} " in
    *" ${model} "*) ;;
    *)
      err "Invalid model: ${model}. Expected one of: ${VALID_MODELS}"
      exit 1
      ;;
  esac
}

init_profile() {
  local model="$1"
  require_model "$model"
  CURRENT_PROFILE="$(model_profile "$model")"
  KCTL=(minikube -p "${CURRENT_PROFILE}" kubectl --)
}

require_profile_running() {
  local profile="$1"
  if ! minikube status -p "$profile" >/dev/null 2>&1; then
    err "Minikube profile '${profile}' is not running. Run: ./start_clusters.sh ${profile}"
    exit 1
  fi
}

kctl() {
  "${KCTL[@]}" "$@"
}

wait_deploy() {
  local ns="$1"
  local deploy="$2"
  local timeout="${3:-300s}"
  log "Waiting for deployment/${deploy} in namespace ${ns}"
  kctl -n "$ns" rollout status "deployment/${deploy}" --timeout="${timeout}"
}

wait_job() {
  local ns="$1"
  local job="$2"
  local timeout="${3:-300s}"
  log "Waiting for job/${job} in namespace ${ns}"
  kctl -n "$ns" wait --for=condition=complete "job/${job}" --timeout="${timeout}"
}

wait_data_layer() {
  local ns="$1"
  wait_deploy "$ns" postgres
  wait_deploy "$ns" redis
}

secret_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

tenant_secret_name() {
  local tenant="$1"
  echo "postgres-secret-${tenant}"
}

redis_secret_name() {
  local tenant="$1"
  echo "redis-secret-${tenant}"
}

upper_tenant() {
  echo "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_'
}

apply_file() {
  local ns="${1:-}"
  local file="$2"
  if [[ -n "$ns" ]]; then
    kctl -n "$ns" apply -f "$file"
  else
    kctl apply -f "$file"
  fi
}

apply_dir_secrets() {
  local ns="$1"
  local dir="$2"
  [[ -d "$dir" ]] || return 0
  local f
  for f in "$dir"/*/secrets.yaml; do
    [[ -f "$f" ]] || continue
    apply_file "$ns" "$f"
  done
}

discover_tenants_in_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}
