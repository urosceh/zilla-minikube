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

# Check if tenant argument is provided
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <tenant>"
  echo "Available tenants: ${TENANTS[*]}"
  exit 1
fi

TENANT=$1
USERS_COUNT=${2:-20}

# Validate tenant exists in the list
if [[ ! " ${TENANTS[*]} " =~ " ${TENANT} " ]]; then
  echo "[ERR] Invalid tenant: $TENANT"
  echo "Available tenants: ${TENANTS[*]}"
  exit 1
fi

BACKEND_POD=$(kubectl get pods -l app=zilla-backend -o jsonpath='{.items[0].metadata.name}')

if [ -z "$BACKEND_POD" ]; then
  echo "[ERR] No backend pod found"
  exit 1
fi

echo "Seeding admin and users for tenant: kubectl exec -it "$BACKEND_POD" -- node /home/node/zilla-backend/build/scripts/insert.admin.script.js $TENANT admin@${TENANT}.dne.com admin123!"

if kubectl exec -it "$BACKEND_POD" -- node /home/node/zilla-backend/build/scripts/insert.admin.script.js $TENANT admin@${TENANT}.dne.com admin123! >/dev/null 2>&1; then
  echo "Admin seeded for tenant $TENANT"
  
  # Create passwords directory for tenant if it doesn't exist
  PASSWORDS_DIR="$SCRIPT_DIR/passwords/$TENANT"
  mkdir -p "$PASSWORDS_DIR"
  
  # Save user seeding output to CSV file (skip first line)
  echo "Seeding users for tenant $TENANT and saving to $PASSWORDS_DIR/$TENANT.csv"
  if kubectl exec -it "$BACKEND_POD" -c zilla-backend -- node /home/node/zilla-backend/build/scripts/seed.users.script.js $TENANT $USERS_COUNT $TENANT.dne.com 2>&1 | tail -n +2 > "$PASSWORDS_DIR/$TENANT.csv"; then
    echo "Users seeded for tenant $TENANT and saved to $PASSWORDS_DIR/$TENANT.csv"
  else
    echo "[ERR] Failed to seed users for tenant $TENANT"
    exit 1
  fi
else
  echo "[ERR] Failed to seed admin for tenant $TENANT"
  exit 1
fi