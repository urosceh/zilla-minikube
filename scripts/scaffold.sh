#!/usr/bin/env bash
# Deprecated scaffold — manifests are maintained manually under models/.
# This script only ensures tenant directory placeholders exist.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[WARN] scripts/scaffold.sh is deprecated. Edit models/ manifests directly."
mkdir -p \
  "${ROOT}/models/iso/tenants" \
  "${ROOT}/models/hybrid/tenants" \
  "${ROOT}/models/shared/tenants" \
  "${ROOT}/models/grouped/iso.grouped/tenants" \
  "${ROOT}/models/grouped/hybrid.grouped/tenants" \
  "${ROOT}/models/grouped/shared.grouped/tenants"
echo "[OK] Tenant directories ensured."
