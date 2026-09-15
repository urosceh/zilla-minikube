#!/usr/bin/env bash
# Shared helpers for the observability lifecycle scripts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=observability/chart.lock.env
source "${ROOT_DIR}/observability/chart.lock.env"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    err "Required command not found: ${command_name}"
    exit 1
  fi
}

init_observability_profile() {
  local profile="$1"
  require_command minikube
  require_command helm
  init_profile "$profile"
  require_profile_running "$CURRENT_PROFILE"
}

rollout_all() {
  local namespace="$1"
  local resource_type="$2"
  local timeout="$3"
  local resources resource

  resources="$(kctl -n "$namespace" get "$resource_type" -o name)"
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    kctl -n "$namespace" rollout status "$resource" --timeout="$timeout"
  done <<<"$resources"
}

usage_observability_install() {
  echo "Usage: scripts/observability/install.sh <iso|hybrid|shared|grouped>"
}

usage_observability_delete() {
  echo "Usage: scripts/observability/delete.sh <iso|hybrid|shared|grouped>"
}

usage_observability_status() {
  echo "Usage: scripts/observability/status.sh <iso|hybrid|shared|grouped>"
}

usage_observability_port_forward() {
  echo "Usage: scripts/observability/port-forward.sh <iso|hybrid|shared|grouped> <grafana|prometheus>"
}
