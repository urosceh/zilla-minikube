#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

FAILURES=0
record_fail() { err "$1"; FAILURES=$((FAILURES + 1)); }

log "Validating shell scripts (bash -n)"
while IFS= read -r script; do
  bash -n "$script" || record_fail "bash -n failed: $script"
done < <(find "${ROOT_DIR}/scripts" "${ROOT_DIR}" -maxdepth 1 -name '*.sh' -type f)

log "Checking for forbidden latest image tags in active manifests"
if rg -n 'image:.*:latest' "${ROOT_DIR}/models" --glob '*.yaml' >/tmp/zilla-latest.txt 2>/dev/null; then
  record_fail "Found :latest image tags:\n$(cat /tmp/zilla-latest.txt)"
fi

log "Checking imagePullPolicy Always on local app images"
if rg -n 'imagePullPolicy: Always' "${ROOT_DIR}/models" --glob '*.yaml' >/tmp/zilla-pull.txt 2>/dev/null; then
  record_fail "Found imagePullPolicy Always:\n$(cat /tmp/zilla-pull.txt)"
fi

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
      ;;
    shared)
      kctl apply --dry-run=client \
        -f "${ROOT_DIR}/models/shared/platform-secrets.yaml" \
        -f "${ROOT_DIR}/models/shared/tenants/" \
        -f "${ROOT_DIR}/models/shared/data.yaml" \
        -f "${ROOT_DIR}/models/shared/tenant-init.yaml" \
        -f "${ROOT_DIR}/models/shared/migrations.yaml" \
        -f "${ROOT_DIR}/models/shared/apps.yaml" >/dev/null
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
      done < <(discover_grouped_iso_tenants)
      kctl apply --dry-run=client \
        -f "${ROOT_DIR}/models/grouped/hybrid.grouped/" \
        -f "${ROOT_DIR}/models/grouped/shared.grouped/" >/dev/null
      ;;
  esac
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
