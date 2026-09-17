#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability/common.sh
source "${SCRIPT_DIR}/common.sh"

PROFILE="${1:-}"
if [[ -z "$PROFILE" || "$#" -ne 1 ]]; then
  usage_observability_status
  exit 1
fi

init_observability_profile "$PROFILE"

helm status "${KUBE_PROMETHEUS_STACK_RELEASE}" \
  --kube-context "${CURRENT_PROFILE}" \
  --namespace "${MONITORING_NAMESPACE}" >/dev/null

echo "Profile: ${CURRENT_PROFILE}"
echo "Chart:   kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION}"
kctl -n "${MONITORING_NAMESPACE}" get deployment,statefulset,daemonset,pod,pvc

FAILURES=0
check_rollout() {
  local resource_type="$1"
  if ! rollout_all "${MONITORING_NAMESPACE}" "${resource_type}" 5s >/dev/null; then
    warn "Not all ${resource_type} workloads are Ready"
    FAILURES=$((FAILURES + 1))
  fi
}

check_rollout deployment
check_rollout statefulset
check_rollout daemonset

if ! kctl -n "${MONITORING_NAMESPACE}" get secret zilla-grafana-admin >/dev/null 2>&1; then
  warn "Grafana admin Secret is missing"
  FAILURES=$((FAILURES + 1))
fi

DATASOURCE_CONFIGMAPS="$(
  kctl -n "${MONITORING_NAMESPACE}" get configmap \
    -l grafana_datasource=1 \
    -o name
)"
if [[ -z "${DATASOURCE_CONFIGMAPS}" ]]; then
  warn "Grafana Prometheus datasource ConfigMap is missing"
  FAILURES=$((FAILURES + 1))
else
  ok "Grafana Prometheus datasource is provisioned"
fi

DASHBOARD_CONFIGMAPS="$(
  kctl -n "${MONITORING_NAMESPACE}" get configmap \
    -l grafana_dashboard=1 \
    -o name
)"
DASHBOARD_COUNT="$(printf '%s\n' "${DASHBOARD_CONFIGMAPS}" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "${DASHBOARD_COUNT}" -lt 3 ]]; then
  warn "Expected 3 Grafana dashboard ConfigMaps, found ${DASHBOARD_COUNT}"
  FAILURES=$((FAILURES + 1))
else
  ok "Grafana dashboards are provisioned (${DASHBOARD_COUNT} ConfigMaps)"
fi

if [[ "$FAILURES" -gt 0 ]]; then
  err "Observability status found ${FAILURES} problem(s)"
  exit 1
fi

ok "All monitoring workloads are Ready"
bash "${SCRIPT_DIR}/check-targets.sh" "${CURRENT_PROFILE}"
