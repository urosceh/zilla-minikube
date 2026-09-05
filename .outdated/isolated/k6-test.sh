#!/usr/bin/env bash

# k6 Test Runner for Zilla Backend
# Usage: ./k6-test.sh <tenant> [OPTIONS]
# Options:
#   --projects NUM          Number of projects (default: 20)
#   --type TYPE             Test type: load|stress|soak (default: load)
#   --seed-users            Seed users before running test (default: false)
#   --help                  Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
PROJECTS_COUNT=20
TYPE="load"
SEED_USERS=false

# Functions
show_help() {
  cat << EOF
k6 Test Runner for Zilla Backend

Usage: $0 <tenant> [OPTIONS]

Required:
  <tenant>                Tenant name (e.g., amazon, azure, google)

Options:
  --projects NUM         Number of projects to create (default: 20)
  --type TYPE            Test type: load|stress|soak (default: load)
  --seed-users           Seed users before running test (default: false)
  --help                 Show this help message

Examples:
  $0 amazon --projects 50 --type load
  $0 azure --type stress --seed-users
  $0 google --projects 100 --type soak

Available tenants:
$(kubectl get namespaces 2>/dev/null | grep -E "(amazon|amd|apple|azure|google|meta|netflix|nvidia|paypal|reddit|slack|spotify|tesla|uber|zoom|iso)" | awk '{print "  - " $1}' || echo "  (Unable to list tenants)")
EOF
}

# Check if tenant is provided
if [[ $# -eq 0 ]]; then
  echo "[ERR] Tenant is required"
  show_help
  exit 1
fi

TENANT=$1
shift  # Remove tenant from arguments

# Parse optional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --projects)
      PROJECTS_COUNT="$2"
      shift 2
      ;;
    --type)
      TYPE="$2"
      shift 2
      ;;
    --seed-users)
      SEED_USERS=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "[ERR] Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Validate type
if [[ $TYPE != "stress" && $TYPE != "load" && $TYPE != "soak" ]]; then
  echo "[ERR] Invalid type: $TYPE"
  echo "Valid types: load, stress, soak"
  exit 1
fi

USERS_COUNT=$((PROJECTS_COUNT * 10))

echo "========================================="
echo "K6 Test Configuration"
echo "========================================="
echo "Tenant:        $TENANT"
echo "Projects:      $PROJECTS_COUNT"
echo "Users:         $USERS_COUNT"
echo "Type:          $TYPE"
echo "Seed Users:    $SEED_USERS"
echo "========================================="
echo ""

# Switch to minikube context
minikube profile prim > /dev/null 2>&1
kubectl config use-context prim

if [[ $SEED_USERS == true ]]; then
  # Purging database and respond y to the prompt
  echo "Purging database and seeding users..."
  echo "y" | ./purge_iso.sh "$TENANT"

  # Seeding users if requested
  if [[ $SEED_USERS == true ]]; then
    echo "Seeding database..."
    ./seed_iso.sh "$TENANT" $USERS_COUNT
  fi
else 
  # Purging database and respond y to the prompt
  echo "Purging database and leaving users..."
  echo "y" | ./purge_iso.sh "$TENANT" --leave-users
fi

# Find the backend pod in the tenant namespace
BACKEND_POD=$(kubectl get pods -n "$TENANT" -l app=zilla-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$BACKEND_POD" ]; then
  echo "[ERR] No backend pod found in namespace: $TENANT"
  echo "Available namespaces:"
  kubectl get namespaces | grep -E "(amazon|amd|apple|azure|google|meta|netflix|nvidia|paypal|reddit|slack|spotify|tesla|uber|zoom|iso)"
  exit 1
fi

echo "Found backend pod: $BACKEND_POD in namespace: $TENANT"

# Check if port 3000 is already in use
if lsof -Pi :3000 -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "[WARN] Port 3000 is already in use. Killing existing process..."
  lsof -ti:3000 | xargs kill -9 2>/dev/null || true
  sleep 2
fi

# Start port forwarding in background
echo "Starting port forwarding: localhost:3000 -> $TENANT/$BACKEND_POD:3000"
kubectl port-forward -n "$TENANT" "$BACKEND_POD" 3000:3000 > /dev/null 2>&1 &
PORT_FORWARD_PID=$!

# Wait for port forwarding to be ready
echo "Waiting for port forwarding to be ready..."
for i in {1..30}; do
  if curl -s http://localhost:3000/api/health > /dev/null 2>&1; then
    echo "Port forwarding is ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "[ERR] Port forwarding failed to start"
    kill $PORT_FORWARD_PID 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

# Run k6 test
echo ""
echo "Running k6 $TYPE test for tenant: $TENANT"
echo ""

TEST_FILE="$SCRIPT_DIR/k6/k6-$TYPE-test.js"

if [[ $TYPE == "load" ]]; then
  TENANT="$TENANT" PROJECTS_COUNT="$PROJECTS_COUNT" USERS_COUNT="$USERS_COUNT" SCRIPT_DIR="$SCRIPT_DIR" k6 run "$TEST_FILE"
elif [[ $TYPE == "stress" ]]; then
  TENANT="$TENANT" PROJECTS_COUNT="$PROJECTS_COUNT" USERS_COUNT="$USERS_COUNT" SCRIPT_DIR="$SCRIPT_DIR" k6 run "$TEST_FILE"
elif [[ $TYPE == "soak" ]]; then
  TENANT="$TENANT" PROJECTS_COUNT="$PROJECTS_COUNT" USERS_COUNT="$USERS_COUNT" SCRIPT_DIR="$SCRIPT_DIR" k6 run "$TEST_FILE"
fi

# Cleanup
echo ""
echo "Cleaning up..."
kill $PORT_FORWARD_PID 2>/dev/null || true

echo "Test completed!"