#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability/common.sh
source "${SCRIPT_DIR}/common.sh"

PROFILE="${1:-}"
if [[ -z "$PROFILE" || "$#" -ne 1 ]]; then
  usage_observability_install
  exit 1
fi

init_observability_profile "$PROFILE"

log "Creating namespace ${MONITORING_NAMESPACE} in profile ${CURRENT_PROFILE}"
kctl create namespace "${MONITORING_NAMESPACE}" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null

log "Applying local Grafana admin Secret"
kctl apply -f "${ROOT_DIR}/observability/grafana-admin-secret.yaml" >/dev/null

log "Installing ${KUBE_PROMETHEUS_STACK_RELEASE} chart ${KUBE_PROMETHEUS_STACK_VERSION}"
log "Pinned chart digest: ${KUBE_PROMETHEUS_STACK_DIGEST}"
install_stack() {
  helm upgrade --install "${KUBE_PROMETHEUS_STACK_RELEASE}" \
    "${KUBE_PROMETHEUS_STACK_CHART}" \
    --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
    --kube-context "${CURRENT_PROFILE}" \
    --namespace "${MONITORING_NAMESPACE}" \
    --values "${ROOT_DIR}/observability/values.yaml" \
    --wait \
    --timeout 15m
}

# A busy local Docker VM can briefly time out while the chart creates its CRDs.
# Re-running upgrade --install is safe and continues from already-created CRDs.
for attempt in 1 2 3; do
  if install_stack; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    err "Helm installation failed after ${attempt} attempts"
    exit 1
  fi
  warn "Helm attempt ${attempt} failed; retrying in 10 seconds"
  sleep 10
done

log "Applying Zilla backend and exporter ServiceMonitors"
kctl apply -f "${ROOT_DIR}/observability/service-monitors.yaml" >/dev/null

log "Provisioning Grafana dashboards"
kctl apply -k "${ROOT_DIR}/observability/grafana" >/dev/null

log "Waiting for monitoring workloads to become Ready"
rollout_all "${MONITORING_NAMESPACE}" deployment 5m
rollout_all "${MONITORING_NAMESPACE}" statefulset 5m
rollout_all "${MONITORING_NAMESPACE}" daemonset 5m

DATASOURCE_CONFIGMAPS="$(
  kctl -n "${MONITORING_NAMESPACE}" get configmap \
    -l grafana_datasource=1 \
    -o name
)"
if [[ -z "${DATASOURCE_CONFIGMAPS}" ]]; then
  err "Grafana Prometheus datasource ConfigMap was not created"
  exit 1
fi

DASHBOARD_CONFIGMAPS="$(
  kctl -n "${MONITORING_NAMESPACE}" get configmap \
    -l grafana_dashboard=1 \
    -o name
)"
DASHBOARD_COUNT="$(printf '%s\n' "${DASHBOARD_CONFIGMAPS}" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "${DASHBOARD_COUNT}" -lt 3 ]]; then
  err "Expected 3 Grafana dashboard ConfigMaps, found ${DASHBOARD_COUNT}"
  exit 1
fi

ok "Observability is ready in profile ${CURRENT_PROFILE}"
echo "Grafana:    scripts/observability/port-forward.sh ${CURRENT_PROFILE} grafana"
echo "Prometheus: scripts/observability/port-forward.sh ${CURRENT_PROFILE} prometheus"
