#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability/common.sh
source "${SCRIPT_DIR}/common.sh"

PROFILE="${1:-}"
if [[ -z "$PROFILE" || "$#" -ne 1 ]]; then
  usage_observability_delete
  exit 1
fi

init_observability_profile "$PROFILE"

log "Uninstalling ${KUBE_PROMETHEUS_STACK_RELEASE} from profile ${CURRENT_PROFILE}"
helm uninstall "${KUBE_PROMETHEUS_STACK_RELEASE}" \
  --kube-context "${CURRENT_PROFILE}" \
  --namespace "${MONITORING_NAMESPACE}" \
  --ignore-not-found \
  --wait \
  --timeout 5m

log "Deleting namespace ${MONITORING_NAMESPACE} and its local Prometheus data"
kctl delete namespace "${MONITORING_NAMESPACE}" \
  --ignore-not-found=true \
  --wait=true \
  --timeout=5m

ok "Observability deleted from profile ${CURRENT_PROFILE}"
warn "Prometheus Operator CRDs are intentionally retained for clean reinstall"
