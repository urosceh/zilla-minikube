# Will create isolated deployment with random secrets for given name
# This script sets up a Kubernetes namespace with a PostgreSQL and Redis instance
# Usage:
#   ./isolated.sh <name>

#!/bin/bash

# Check if name parameter is provided
if [ $# -eq 0 ]; then
    echo "Error: Please provide a name parameter"
    echo "Usage: $0 <name>"
    exit 1
fi

NAME=$1

# Switch to minikube prim cluster
echo "Switching to minikube prim cluster..."
minikube profile prim > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: Failed to switch to prim cluster"
    echo "Make sure minikube prim cluster is running"
    exit 1
fi

echo "Using minikube prim cluster"

# Validate name (should be valid for Kubernetes namespace)
if [[ ! "$NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Error: Name must be a valid Kubernetes namespace name (lowercase letters, numbers, and hyphens only)"
    exit 1
fi

echo "Creating deployment for: $NAME"

# Check if namespace already exists
if kubectl get namespace "$NAME" &> /dev/null; then
    echo "Error: Namespace '$NAME' already exists!"
    exit 1
fi

# Create namespace
echo "Creating namespace: $NAME"
kubectl create namespace "$NAME"
if [ $? -ne 0 ]; then
    echo "Error: Failed to create namespace '$NAME'"
    exit 1
fi

echo "Namespace '$NAME' created successfully in prim cluster"

# Create folder for this deployment
DEPLOY_DIR="/Users/urosceh/Code/zilla-minikube/isolated/$NAME"
mkdir -p "$DEPLOY_DIR"

# Generate random values and base64 encode them
generate_random_string() {
    # Generate safe alphanumeric passwords (avoiding special characters that may cause SCRAM issues)
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 20
}

# Generate random credentials
DB_USERNAME_RAW=$(generate_random_string)
DB_PASSWORD_RAW=$(generate_random_string)
REDIS_PASSWORD_RAW=$(generate_random_string)

# Base64 encode the values
DB_USERNAME_B64=$(printf "%s" "$DB_USERNAME_RAW" | base64)
DB_PASSWORD_B64=$(printf "%s" "$DB_PASSWORD_RAW" | base64)
REDIS_PASSWORD_B64=$(printf "%s" "$REDIS_PASSWORD_RAW" | base64)

# Create secrets.yaml with random values
cat > "$DEPLOY_DIR/secrets.yaml" << EOF
# =====================
# Postgres Secret
# =====================
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
type: Opaque
data:
  DB_USERNAME: $DB_USERNAME_B64  # base64 encoded "$DB_USERNAME_RAW"
  DB_PASSWORD: $DB_PASSWORD_B64  # base64 encoded "$DB_PASSWORD_RAW"
---
# =====================
# Redis Secret
# =====================
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
type: Opaque
data:
  REDIS_PASSWORD: $REDIS_PASSWORD_B64  # base64 encoded "$REDIS_PASSWORD_RAW"
---
EOF

echo "Generated secrets.yaml with random credentials in: $DEPLOY_DIR/secrets.yaml"
echo "DB_USERNAME (decoded): $DB_USERNAME_RAW"
echo "DB_PASSWORD (decoded): $DB_PASSWORD_RAW"
echo "REDIS_PASSWORD (decoded): $REDIS_PASSWORD_RAW"

# Apply secrets to the namespace
echo "Applying secrets to namespace: $NAME"
kubectl apply -f "$DEPLOY_DIR/secrets.yaml" -n "$NAME"
if [ $? -ne 0 ]; then
    echo "Error: Failed to apply secrets"
    exit 1
fi

# Apply dsp.yaml to the namespace
echo "Applying dsp.yaml to namespace: $NAME"
kubectl apply -f "/Users/urosceh/Code/zilla-minikube/isolated/dsp.yaml" -n "$NAME"
if [ $? -ne 0 ]; then
    echo "Error: Failed to apply dsp.yaml"
    exit 1
fi

echo "Successfully deployed to namespace: $NAME"
echo "Deployment directory: $DEPLOY_DIR"
echo ""
echo "To check the deployment (make sure you're on prim cluster):"
echo "minikube profile prim"
echo "kubectl get all -n $NAME"
echo ""
echo "To delete the deployment:"
echo "minikube profile prim"
echo "kubectl delete namespace $NAME"
echo "rm -rf $DEPLOY_DIR"