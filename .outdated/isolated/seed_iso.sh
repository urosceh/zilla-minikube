#!/bin/bash

# Isolated tenant seeding script for Zilla
# This script seeds data into a PostgreSQL instance in a specific namespace using iso cluster

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ADMIN_PASSWORD="admin123!"
ADMIN_FIRST_NAME="Admin"
ADMIN_LAST_NAME="User"
BACKEND_PORT=3000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <NAMESPACE> [COUNT]"
    echo ""
    echo "Arguments:"
    echo "  NAMESPACE    The Kubernetes namespace containing the PostgreSQL instance"
    echo "  COUNT        Number of users to create (default: 20)"
    echo ""
    echo "Examples:"
    echo "  $0 iso       # Seed PostgreSQL in 'iso' namespace with 20 users"
    echo "  $0 iso 50    # Seed PostgreSQL in 'iso' namespace with 50 users"
    echo "  $0 tenant1   # Seed PostgreSQL in 'tenant1' namespace with 20 users"
}

# Function to check if namespace exists
check_namespace() {
    local namespace=$1
    
    print_status "Checking if namespace '$namespace' exists in prim cluster..."
    
    # Switch to prim cluster context
    minikube profile prim > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        print_error "Failed to switch to prim cluster"
        return 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
        print_error "Namespace '$namespace' does not exist in prim cluster"
        return 1
    fi
    
    print_success "Namespace '$namespace' exists in prim cluster"
    return 0
}

create_admin_user() {
    local namespace=$1
    local tenant=$2
    
    # Generate tenant-specific admin email
    local admin_email="admin@${tenant}.dne.com"
    
    print_status "Creating admin user for namespace '$namespace' with email: $admin_email"
    
    # Find the backend pod
    local backend_pod
    backend_pod=$(kubectl get pods -n "$namespace" -l app=zilla-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$backend_pod" ]; then
        print_error "No backend pod found in namespace '$namespace'"
        return 1
    fi
    
    # Execute the admin insert script in the backend pod
    kubectl exec -n "$namespace" -it "$backend_pod" -- node /home/node/zilla-backend/build/scripts/insert.admin.script.js "$admin_email" "$ADMIN_PASSWORD"
    
    if [ $? -eq 0 ]; then
        print_success "Admin user created successfully with email: $admin_email"
        return 0
    else
        print_error "Failed to create admin user"
        return 1
    fi
}

# Function to create batch of users
create_users_batch() {
    local tenant=$1
    local count=$2
    local namespace=$3
    
    print_status "Creating batch of users..."
    
    # Find the backend pod
    local backend_pod
    backend_pod=$(kubectl get pods -n "$namespace" -l app=zilla-backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$backend_pod" ]; then
        print_error "No backend pod found in namespace '$namespace'"
        return 1
    fi
    
    # Execute the user seeding script in the backend pod
    local users_output
    users_output=$(kubectl exec -n "$namespace" -it "$backend_pod" -- node /home/node/zilla-backend/build/scripts/seed.users.script.js "$count" "${tenant}.dne.com" 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$users_output" ]; then
        print_error "Failed to create users batch"
        return 1
    fi
    
    # Create passwords directory if it doesn't exist
    mkdir -p "$SCRIPT_DIR/passwords"

    # Save users output to CSV file (without header)
    echo "$users_output" > "$SCRIPT_DIR/passwords/${tenant}-users.csv"

    print_success "Created $count users and saved credentials to $SCRIPT_DIR/passwords/${tenant}-users.csv"
    echo "$users_output"
    return 0
}

# Function to seed database
seed_database() {
    local namespace=$1
    local tenant=$2
    local count=${3:-20}  # Default to 20 users if not specified
    
    print_status "Starting database seeding for namespace '$namespace'..."
    
    # Create admin user directly in database
    if ! create_admin_user "$namespace" "$tenant"; then
        print_error "Failed to create admin user"
        return 1
    fi

    # Create batch of users
    if ! create_users_batch "$tenant" "$count" "$namespace"; then
        print_error "Failed to create users batch"
        return 1
    fi
    
    print_success "Database seeding completed successfully for namespace '$namespace'"
    print_status "User credentials saved to ./passwords/${tenant}-users.csv"
    return 0
}

main() {
    local namespace=$1
    local count=${2:-20}  # Default to 20 users if not specified
    
    # Check if namespace parameter is provided
    if [ -z "$namespace" ]; then
        print_error "Namespace parameter is required"
        show_usage
        exit 1
    fi
    
    print_status "Starting seeding process for namespace: $namespace with $count users"
    
    # Extract tenant name from namespace (assuming namespace = tenant)
    local tenant="$namespace"
    
    # Check if namespace exists
    if ! check_namespace "$namespace"; then
        exit 1
    fi
    
    # Perform database seeding
    if seed_database "$namespace" "$tenant" "$count"; then
        print_success "Seeding operation completed successfully"
        exit 0
    else
        print_error "Seeding operation failed"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"