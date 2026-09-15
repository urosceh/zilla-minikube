#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tenant-data.sh
source "${ROOT_DIR}/scripts/lib/tenant-data.sh"

MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
  usage_seed
  exit 1
fi

if [[ "$MODEL" == "all" ]]; then
  err "Profile 'all' is not supported. Run once per profile: iso, hybrid, shared, grouped"
  exit 1
fi

init_profile "$MODEL"
require_profile_running "$CURRENT_PROFILE"

if [[ -z "$(first_credentials_tenant_for_model "$MODEL")" ]]; then
  err "No tenants discovered for model: ${MODEL}"
  exit 1
fi

seeded_tenants=()
credentials_files=()
tenant=""

while IFS= read -r tenant; do
  [[ -z "$tenant" ]] && continue
  seed_tenant "$MODEL" "$tenant"
  seeded_tenants+=("$tenant")
  ctx="$(resolve_tenant_seed_context "$MODEL" "$tenant")"
  IFS='|' read -r cred_ns cred_deploy cred_variant <<<"$ctx"
  credentials_files+=(
    "$(export_tenant_credentials "$MODEL" "$tenant" "$cred_ns" "$cred_deploy" "$cred_variant")"
  )
done < <(discover_all_tenants_for_model "$MODEL")

ok "Seed complete for model: ${MODEL}"
log "Tenants seeded: ${seeded_tenants[*]}"
log "Credentials files: ${credentials_files[*]}"
