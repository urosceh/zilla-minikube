#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$MODEL_DIR/manifest-iso.yaml"
TENANTS=(arm)

for t in "${TENANTS[@]}"; do
  echo "[NS] ensuring namespace $t"
  kubectl get ns "$t" >/dev/null 2>&1 || kubectl create namespace "$t"

  if [[ -f "$MODEL_DIR/tenants/$t/secrets.yaml" ]]; then
    echo "[APPLY] secrets for $t"
    kubectl apply -n "$t" -f "$MODEL_DIR/tenants/$t/secrets.yaml"
  fi
  if [[ -f "$MODEL_DIR/tenants/$t/nginx-configmap.yaml" ]]; then
    echo "[APPLY] nginx config for $t"
    kubectl apply -n "$t" -f "$MODEL_DIR/tenants/$t/nginx-configmap.yaml"
  fi
  if [[ -f "$MODEL_DIR/tenants/$t/backend-configmap.yaml" ]]; then
    echo "[APPLY] backend config for $t"
    kubectl apply -n "$t" -f "$MODEL_DIR/tenants/$t/backend-configmap.yaml"
  fi

  echo "[APPLY] iso manifest for $t"
  kubectl apply -n "$t" -f "$MANIFEST"

done

echo "[DONE] ISO applied for tenants: ${TENANTS[*]}"
