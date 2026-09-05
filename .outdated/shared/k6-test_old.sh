#!/usr/bin/env bash

# k6 Test Runner for Zilla Backend (Shared Multi-tenant)
# Usage: ./k6-test.sh [tenant1 tenant2 ...] or ./k6-test.sh (for all tenants)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default tenant list from shared.sh
DEFAULT_TENANTS=(
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

# Determine tenant list
TENANTS=()
if (( $# > 0 )); then
  for t in "$@"; do TENANTS+=("$t"); done
else
  TENANTS=("${DEFAULT_TENANTS[@]}")
fi

echo "Starting k6 tests for tenants: ${TENANTS[*]}"

# Switch to minikube context
minikube profile sec > /dev/null 2>&1
kubectl config use-context sec

# Find the backend pod in default namespace
BACKEND_POD=$(kubectl get pods -l app=zilla-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$BACKEND_POD" ]; then
  echo "[ERR] No backend pod found in default namespace"
  exit 1
fi

echo "Found backend pod: $BACKEND_POD in namespace: default"

# Base port for port-forwards
BASE_PORT=3001

# Kill any existing port-forwards in the range
echo "Cleaning up any existing port-forwards..."
for i in "${!TENANTS[@]}"; do
  PORT=$((BASE_PORT + i))
  if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[WARN] Port $PORT is already in use. Killing existing process..."
    lsof -ti:$PORT | xargs kill -9 2>/dev/null || true
  fi
done
sleep 2

# Start port-forwards for each tenant on different ports
echo ""
echo "=========================================="
echo "Starting port-forwards for ${#TENANTS[@]} tenants..."
echo "=========================================="
port_forward_pids=()
for i in "${!TENANTS[@]}"; do
  TENANT="${TENANTS[$i]}"
  PORT=$((BASE_PORT + i))
  
  echo "Port-forward $((i+1))/${#TENANTS[@]}: localhost:$PORT -> $BACKEND_POD:3000 (tenant: $TENANT)"
  kubectl port-forward "$BACKEND_POD" "$PORT:3000" > /dev/null 2>&1 &
  port_forward_pids+=($!)
done

# Wait for all port-forwards to be ready
echo ""
echo "Waiting for port-forwards to be ready..."
sleep 3

for i in "${!TENANTS[@]}"; do
  PORT=$((BASE_PORT + i))
  TENANT="${TENANTS[$i]}"
  
  for attempt in {1..10}; do
    if curl -s http://localhost:$PORT/api/health > /dev/null 2>&1; then
      echo "✓ Port $PORT ready for tenant: $TENANT"
      break
    fi
    if [ $attempt -eq 10 ]; then
      echo "[ERR] Port-forward on port $PORT failed to start for tenant $TENANT"
      # Cleanup all port-forwards
      for pid in "${port_forward_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
      done
      exit 1
    fi
    sleep 1
  done
done

# Run k6 tests in parallel, each with its own port
echo ""
echo "=========================================="
echo "Running k6 tests in parallel..."
echo "=========================================="
test_pids=()
OUTPUT_DIR="$SCRIPT_DIR/output-${#TENANTS[@]}-$(date +%Y-%m-%d-%H-%M-%S)"
for i in "${!TENANTS[@]}"; do
  TENANT="${TENANTS[$i]}"
  PORT=$((BASE_PORT + i))
  
  # Check if passwords file exists
  if [[ ! -f "$SCRIPT_DIR/passwords/$TENANT/$TENANT.csv" ]]; then
    echo "[WARN] Passwords file not found for tenant $TENANT, skipping..."
    continue
  fi
  

  if [ ${#TENANTS[@]} -gt 1 ]; then
    # Multiple tenants: run in parallel and output to file
    # make output directory - format output-tenantcount-date
    mkdir -p "$OUTPUT_DIR"
    (
      echo "Starting k6 test for tenant: $TENANT on port $PORT"
      TENANT="$TENANT" \
      BASE_URL="http://localhost:$PORT" \
      PROJECTS_COUNT="20" \
      SCRIPT_DIR="$SCRIPT_DIR" \
      k6 run "$SCRIPT_DIR/k6-test.js" > "$OUTPUT_DIR/k6-test-$TENANT.log" 2>&1
      
      echo "Completed k6 test for tenant: $TENANT"
    ) &
    test_pids+=($!)
  else
    # Single tenant: run synchronously and output to terminal
    echo "Starting k6 test for tenant: $TENANT on port $PORT"
    TENANT="$TENANT" \
    BASE_URL="http://localhost:$PORT" \
    PROJECTS_COUNT="20" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    k6 run "$SCRIPT_DIR/k6-test.js"
    
    echo "Completed k6 test for tenant: $TENANT"
  fi
done

if [ ${#TENANTS[@]} -gt 1 ]; then
  # Wait for all tests to complete
  for pid in "${test_pids[@]}"; do
    wait "$pid"
  done
fi

# Cleanup all port-forwards
echo ""
echo "Cleaning up port-forwards..."
for pid in "${port_forward_pids[@]}"; do
  kill "$pid" 2>/dev/null || true
done

echo ""
echo "=========================================="
echo "All tests completed!"
echo "=========================================="

