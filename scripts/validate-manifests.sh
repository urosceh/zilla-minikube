#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=observability/chart.lock.env
source "${ROOT_DIR}/observability/chart.lock.env"

FAILURES=0
record_fail() { err "$1"; FAILURES=$((FAILURES + 1)); }

log "Validating shell scripts (bash -n)"
while IFS= read -r script; do
  bash -n "$script" || record_fail "bash -n failed: $script"
done < <(
  find "${ROOT_DIR}/scripts" -name '*.sh' -type f
  find "${ROOT_DIR}" -maxdepth 1 -name '*.sh' -type f
)

log "Rendering pinned kube-prometheus-stack chart"
if command -v helm >/dev/null 2>&1; then
  helm template "${KUBE_PROMETHEUS_STACK_RELEASE}" \
    "${KUBE_PROMETHEUS_STACK_CHART}" \
    --version "${KUBE_PROMETHEUS_STACK_VERSION}" \
    --namespace "${MONITORING_NAMESPACE}" \
    --values "${ROOT_DIR}/observability/values.yaml" >/dev/null ||
    record_fail "Helm template validation failed"
else
  record_fail "Helm is required to validate observability/values.yaml"
fi

log "Checking for forbidden latest image tags in active manifests"
if rg -n 'image:.*:latest' \
  "${ROOT_DIR}/models" "${ROOT_DIR}/observability" \
  --glob '*.yaml' >/tmp/zilla-latest.txt 2>/dev/null; then
  record_fail "Found :latest image tags:\n$(cat /tmp/zilla-latest.txt)"
fi

log "Checking imagePullPolicy Always on local app images"
if rg -n 'imagePullPolicy: Always' \
  "${ROOT_DIR}/models" "${ROOT_DIR}/observability" \
  --glob '*.yaml' >/tmp/zilla-pull.txt 2>/dev/null; then
  record_fail "Found imagePullPolicy Always:\n$(cat /tmp/zilla-pull.txt)"
fi

EXPORTER_MANIFEST="${ROOT_DIR}/observability/exporters/base/exporters.yaml"
rg -F "image: ${POSTGRES_EXPORTER_IMAGE}" "$EXPORTER_MANIFEST" >/dev/null ||
  record_fail "PostgreSQL exporter manifest does not match config/images.lock.env"
rg -F "image: ${REDIS_EXPORTER_IMAGE}" "$EXPORTER_MANIFEST" >/dev/null ||
  record_fail "Redis exporter manifest does not match config/images.lock.env"

validate_model_dry_run() {
  local model="$1"
  init_profile "$model"
  if ! minikube status -p "$CURRENT_PROFILE" >/dev/null 2>&1; then
    warn "Profile ${CURRENT_PROFILE} not running; skipping kubectl dry-run for ${model}"
    return 0
  fi

  case "$model" in
    iso)
      local tenant
      while IFS= read -r tenant; do
        [[ -z "$tenant" ]] && continue
        kctl create namespace "$tenant" --dry-run=client -o yaml | kctl apply --dry-run=client -f - >/dev/null
        kctl -n "$tenant" apply --dry-run=client \
          -f "${ROOT_DIR}/models/iso/tenants/${tenant}/" \
          -f "${ROOT_DIR}/models/iso/data.yaml" \
          -f "${ROOT_DIR}/models/iso/migrations.yaml" \
          -f "${ROOT_DIR}/models/iso/apps.yaml" >/dev/null
        kctl -n "$tenant" apply --dry-run=client \
          -k "${ROOT_DIR}/observability/exporters/overlays/iso" >/dev/null
      done < <(discover_iso_tenants)
      ;;
    hybrid)
      kctl apply --dry-run=client \
        -f "${ROOT_DIR}/models/hybrid/platform-secrets.yaml" \
        -f "${ROOT_DIR}/models/hybrid/tenants/" \
        -f "${ROOT_DIR}/models/hybrid/data.yaml" \
        -f "${ROOT_DIR}/models/hybrid/tenant-init.yaml" \
        -f "${ROOT_DIR}/models/hybrid/migrations.yaml" \
        -f "${ROOT_DIR}/models/hybrid/apps.yaml" >/dev/null
      kctl -n hybrid apply --dry-run=client \
        -k "${ROOT_DIR}/observability/exporters/overlays/hybrid" >/dev/null
      ;;
    shared)
      kctl apply --dry-run=client \
        -f "${ROOT_DIR}/models/shared/platform-secrets.yaml" \
        -f "${ROOT_DIR}/models/shared/tenants/" \
        -f "${ROOT_DIR}/models/shared/data.yaml" \
        -f "${ROOT_DIR}/models/shared/tenant-init.yaml" \
        -f "${ROOT_DIR}/models/shared/migrations.yaml" \
        -f "${ROOT_DIR}/models/shared/apps.yaml" >/dev/null
      kctl -n shared apply --dry-run=client \
        -k "${ROOT_DIR}/observability/exporters/overlays/shared" >/dev/null
      ;;
    grouped)
      local tenant
      while IFS= read -r tenant; do
        [[ -z "$tenant" ]] && continue
        kctl create namespace "$tenant" --dry-run=client -o yaml | kctl apply --dry-run=client -f - >/dev/null
        kctl -n "$tenant" apply --dry-run=client \
          -f "${ROOT_DIR}/models/grouped/iso.grouped/tenants/${tenant}/" \
          -f "${ROOT_DIR}/models/grouped/iso.grouped/data.yaml" \
          -f "${ROOT_DIR}/models/grouped/iso.grouped/migrations.yaml" \
          -f "${ROOT_DIR}/models/grouped/iso.grouped/apps.yaml" >/dev/null
        kctl -n "$tenant" apply --dry-run=client \
          -k "${ROOT_DIR}/observability/exporters/overlays/grouped-iso" >/dev/null
      done < <(discover_grouped_iso_tenants)
      kctl apply --dry-run=client \
        -f "${ROOT_DIR}/models/grouped/hybrid.grouped/" \
        -f "${ROOT_DIR}/models/grouped/shared.grouped/" >/dev/null
      kctl -n hybrid-grouped apply --dry-run=client \
        -k "${ROOT_DIR}/observability/exporters/overlays/grouped-hybrid" >/dev/null
      kctl -n shared-grouped apply --dry-run=client \
        -k "${ROOT_DIR}/observability/exporters/overlays/grouped-shared" >/dev/null
      ;;
  esac

  if kctl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    kctl apply --dry-run=client \
      -f "${ROOT_DIR}/observability/service-monitors.yaml" >/dev/null
  fi
  ok "kubectl dry-run passed for model ${model}"
}

for m in iso hybrid shared grouped; do
  validate_model_dry_run "$m"
done

if [[ "$FAILURES" -gt 0 ]]; then
  err "Validation failed with ${FAILURES} issue(s)"
  exit 1
fi
ok "All static validations passed"
