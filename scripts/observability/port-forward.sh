#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability/common.sh
source "${SCRIPT_DIR}/common.sh"

PROFILE="${1:-}"
TARGET="${2:-}"
if [[ -z "$PROFILE" || -z "$TARGET" || "$#" -ne 2 ]]; then
  usage_observability_port_forward
  exit 1
fi

init_observability_profile "$PROFILE"

case "$TARGET" in
  grafana)
    SERVICE="${KUBE_PROMETHEUS_STACK_RELEASE}-grafana"
    PORT_MAPPING="3000:80"
    URL="http://localhost:3000"
    echo "Grafana credentials: admin / zilla-local-only"
    ;;
  prometheus)
    SERVICE="${KUBE_PROMETHEUS_STACK_RELEASE}-prometheus"
    PORT_MAPPING="9090:9090"
    URL="http://localhost:9090"
    ;;
  *)
    err "Invalid target: ${TARGET}. Expected grafana or prometheus"
    usage_observability_port_forward
    exit 1
    ;;
esac

kctl -n "${MONITORING_NAMESPACE}" get "service/${SERVICE}" >/dev/null
log "Forwarding ${CURRENT_PROFILE}/${SERVICE} to ${URL}; press Ctrl-C to stop"
kctl -n "${MONITORING_NAMESPACE}" port-forward \
  "service/${SERVICE}" "${PORT_MAPPING}"
