#!/usr/bin/env bash

# k6 Test Runner for Zilla Backend (Shared Multi-tenant)
# Combines parallel multi-tenant testing with load/stress test types
# 
# Usage: 
#   ./k6-test.sh                           # All tenants, load test
#   ./k6-test.sh amazon amd apple          # Specific tenants, load test
#   ./k6-test.sh --type stress             # All tenants, stress test
#   ./k6-test.sh --type load amazon        # Specific tenant, load test
#   ./k6-test.sh --projects 20 amazon      # Specific tenant, 20 projects, load test
#   ./k6-test.sh --type stress amazon       # Specific tenant, stress test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
TEST_TYPE="load"
PROJECTS_COUNT=20
PURGE_USERS=false
TENANTS=()
USERS_COUNT=$((PROJECTS_COUNT * 10))

# Default tenant list
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

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --type)
      TEST_TYPE="$2"
      shift 2
      ;;
    --projects)
      PROJECTS_COUNT="$2"
      shift 2
      ;;
    --purge-users)
      PURGE_USERS="true"
      shift 1
      ;;
    --help)
      echo "Usage: ./k6-test.sh [OPTIONS] [TENANTS...]"
      echo ""
      echo "OPTIONS:"
      echo "  --type TYPE          Test type: load, stress, soak (default: load)"
      echo "  --projects COUNT     Number of projects per tenant (default: 20)"
      echo "  --help              Show this help message"
      echo ""
      echo "TENANTS:"
      echo "  Specific tenants (space-separated). If not provided, all tenants are tested."
      echo "  Available: ${DEFAULT_TENANTS[*]}"
      exit 0
      ;;
    *)
      TENANTS+=("$1")
      shift
      ;;
  esac
done

# Validate test type
if [[ ! "$TEST_TYPE" =~ ^(load|stress|soak)$ ]]; then
  echo "[ERR] Invalid test type: $TEST_TYPE"
  echo "Valid types: load, stress, soak"
  exit 1
fi

# Use default tenants if none specified
if [ ${#TENANTS[@]} -eq 0 ]; then
  TENANTS=("${DEFAULT_TENANTS[@]}")
fi

echo "════════════════════════════════════════════════════════"
echo "K6 Test Runner - Shared Multi-Tenant"
echo "════════════════════════════════════════════════════════"
echo "Test Type:        $TEST_TYPE"
echo "Projects/Tenant:  $PROJECTS_COUNT"
echo "Tenants:          ${#TENANTS[@]}"
echo "════════════════════════════════════════════════════════"
echo ""

# Set kubectl context
echo "Setting up Kubernetes context..."
kubectl config use-context minikube > /dev/null 2>&1 || true

# Base port for port-forwards
BASE_PORT=3001

# Kill any existing port-forwards in the range
echo "Cleaning up any existing port-forwards..."
for i in $(seq 0 $((${#TENANTS[@]} - 1))); do
  PORT=$((BASE_PORT + i))
  if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[WARN] Port $PORT is already in use. Killing..."
    lsof -ti:$PORT | xargs kill -9 2>/dev/null || true
  fi
done
sleep 2

echo ""
echo "=========================================="
echo "Phase 1: Database Setup (Purge + Seed)"
echo "=========================================="
echo ""

# if --purge-users
if [ "$PURGE_USERS" = "true" ]; then

  echo "PURGING DATABASES FOR TENANTS WITH USERS: ${TENANTS[@]}"

  sleep 5

  (
    cd "$SCRIPT_DIR"
    echo "y" | ./purge_tenant.sh "${TENANTS[@]}"
  )

  echo "Databases purged"

  # Setup databases for each tenant (purge + seed)
  for TENANT in "${TENANTS[@]}"; do
    echo "Setting up tenant: $TENANT (Users: $USERS_COUNT)"
    
    # Seed database
    (
      cd "$SCRIPT_DIR"
      ./seed_single.sh "$TENANT" $USERS_COUNT > /dev/null 2>&1 || true
    )

    echo "✓ Setup complete for $TENANT"
  done
else 
  # Purge database for list of tenants the script is running for with --leave-users
  (
    cd "$SCRIPT_DIR"
    echo "y" | ./purge_tenant.sh --leave-users "${TENANTS[@]}"
  )

  echo "Databases purged with users preserved"
fi

echo ""
echo "=========================================="
echo "Phase 2: Port Forwarding Setup"
echo "=========================================="
echo ""

# Find backend pods and start port-forwards for each tenant
port_forward_pids=()
VALID_TENANTS=()

BACKEND_POD=$(kubectl get pods -l app=zilla-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  
if [ -z "$BACKEND_POD" ]; then
  echo "[ERR] No backend pod found in default namespace"
  exit 1
fi

echo "Found backend pod: $BACKEND_POD in namespace: default"

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

echo ""
echo "=========================================="
echo "Phase 3: Running K6 Tests ($TEST_TYPE)"
echo "=========================================="
test_pids=()
OUTPUT_DIR="$SCRIPT_DIR/output/${TEST_TYPE}-${#TENANTS[@]}-$(date +%Y-%m-%d-%H-%M-%S)"
for i in "${!TENANTS[@]}"; do
  TENANT="${TENANTS[$i]}"
  PORT=$((BASE_PORT + i))
  
  # Check if passwords file exists
  if [[ ! -f "$SCRIPT_DIR/passwords/$TENANT/$TENANT.csv" ]]; then
    echo "[WARN] Passwords file not found for tenant $TENANT, skipping..."
    continue
  fi

  K6_TEST_SCRIPT="$SCRIPT_DIR/k6/k6-${TEST_TYPE}-test.js"
  

  if [ ${#TENANTS[@]} -gt 1 ]; then
    # Multiple tenants: run in parallel and output to file
    # make output directory - format output-tenantcount-date
    mkdir -p "$OUTPUT_DIR"
    (
      echo "Starting k6 test for tenant: $TENANT on port $PORT"
      TENANT="$TENANT" \
      BASE_URL="http://localhost:$PORT" \
      PROJECTS_COUNT="20" \
      USERS_COUNT="$USERS_COUNT" \
      SCRIPT_DIR="$SCRIPT_DIR" \
      k6 run "$K6_TEST_SCRIPT" > "$OUTPUT_DIR/k6-test-$TENANT.log" 2>&1
      
      echo "Completed k6 test for tenant: $TENANT"
    ) &
    test_pids+=($!)
  else
    # Single tenant: run synchronously and output to terminal
    echo "Starting k6 test for tenant: $TENANT on port $PORT"
    TENANT="$TENANT" \
    BASE_URL="http://localhost:$PORT" \
    PROJECTS_COUNT="20" \
    USERS_COUNT="$USERS_COUNT" \
    SCRIPT_DIR="$SCRIPT_DIR" \
    k6 run "$K6_TEST_SCRIPT"
    
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