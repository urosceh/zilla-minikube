#!/usr/bin/env bash

set -euo pipefail
minikube profile sec > /dev/null 2>&1
kubectl config use-context sec

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TENANTS=(
  "amazon"
  "amd"
  "apple"
  "azure"
  "google"
  "meta"
  "netflix"
  "nvidia"
  "paypal"
  "reddit"
  "slack"
  "spotify"
  "tesla"
  "uber"
  "zoom"
)

# Parse arguments to get users count and tenants to omit
OMIT_TENANTS=()
USERS_COUNT=20

while [[ $# -gt 0 ]]; do
  case $1 in
    --count)
      USERS_COUNT=$2
      shift 2
      ;;
    --omit)
      if [[ $# -lt 2 ]]; then
        echo "[ERR] --omit requires a tenant name"
        exit 1
      fi
      OMIT_TENANTS+=("$2")
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--omit <tenant>] [--omit <tenant>] ..."
      echo "Available tenants: ${TENANTS[*]}"
      echo ""
      echo "Examples:"
      echo "  $0                                    # Seed all tenants"
      echo "  $0 --omit amazon --omit meta        # Seed all except amazon and meta"
      echo "  $0 --count 100 --omit tesla                    # Seed all except tesla with 100 users"
      exit 0
      ;;
    *)
      echo "[ERR] Unknown argument: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Filter out omitted tenants
TENANTS_TO_SEED=()
for tenant in "${TENANTS[@]}"; do
  if [[ ! " ${OMIT_TENANTS[*]:-} " =~ " ${tenant} " ]]; then
    TENANTS_TO_SEED+=("$tenant")
  else
    echo "[INFO] Omitting tenant: $tenant"
  fi
done

if [[ ${#TENANTS_TO_SEED[@]} -eq 0 ]]; then
  echo "[ERR] No tenants to seed (all tenants omitted)"
  exit 1
fi

echo "[INFO] Seeding tenants: ${TENANTS_TO_SEED[*]}"
echo ""

# Seed each tenant
for tenant in "${TENANTS_TO_SEED[@]}"; do
  echo "=========================================="
  echo "Seeding tenant: $tenant"
  echo "=========================================="
  
  if "$SCRIPT_DIR/seed_single.sh" "$tenant" "$USERS_COUNT"; then
    echo "[OK] Successfully seeded tenant: $tenant"
  else
    echo "[ERR] Failed to seed tenant: $tenant"
    echo "Continuing with remaining tenants..."
  fi
  echo ""
done

# Seed all tenants in parallel
# pids=()
# for tenant in "${TENANTS_TO_SEED[@]}"; do
#   (
#     echo "Seeding tenant: $tenant"
    
#     if "$SCRIPT_DIR/seed_single.sh" "$tenant" "$USERS_COUNT"; then
#       echo "[OK] Successfully seeded tenant: $tenant"
#     else
#       echo "[ERR] Failed to seed tenant: $tenant"
#     fi
#   ) &
#   pids+=($!)
# done

# # Wait for all seeding operations to complete
# for pid in "${pids[@]}"; do
#   wait "$pid"
# done


echo "=========================================="
echo "Seeding completed for all requested tenants"
echo "=========================================="
