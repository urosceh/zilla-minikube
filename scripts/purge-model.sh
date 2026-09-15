#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tenant-data.sh
source "${ROOT_DIR}/scripts/lib/tenant-data.sh"

MODEL="${1:-}"
if [[ -z "$MODEL" ]]; then
  usage_purge
  exit 1
fi

if [[ "$MODEL" == "all" ]]; then
  err "Profile 'all' is not supported. Run once per profile: iso, hybrid, shared, grouped"
  exit 1
fi

init_profile "$MODEL"
require_profile_running "$CURRENT_PROFILE"

purged_tenants=()
tenant=""

while IFS= read -r tenant; do
  [[ -z "$tenant" ]] && continue
  purge_tenant "$MODEL" "$tenant"
  purged_tenants+=("$tenant")
done < <(discover_all_tenants_for_model "$MODEL")

ok "Purge complete for model: ${MODEL}"
log "Tenants purged: ${purged_tenants[*]}"
