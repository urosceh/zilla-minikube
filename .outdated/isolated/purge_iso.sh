#!/bin/bash

# Isolated tenant purge script for Zilla
# This script purges data from a PostgreSQL instance in a specific namespace using iso cluster

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo "Usage: $0 <NAMESPACE> [--leave-users]"
    echo ""
    echo "Arguments:"
    echo "  NAMESPACE    The Kubernetes namespace containing the PostgreSQL instance"
    echo "  --leave-users    Whether to leave users (default: false)"
    echo ""
    echo "Examples:"
    echo "  $0 iso       # Purge PostgreSQL in 'iso' namespace"
    echo "  $0 tenant1 --leave-users  # Purge PostgreSQL in 'tenant1' namespace and leave users"
}

# Function to check if namespace exists
check_namespace() {
    local namespace=$1
    
    print_status "Checking if namespace '$namespace' exists in iso cluster..."
    
    # Switch to iso cluster context
    minikube profile iso > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        print_error "Failed to switch to iso cluster"
        return 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
        print_error "Namespace '$namespace' does not exist in iso cluster"
        return 1
    fi
    
    print_success "Namespace '$namespace' exists in iso cluster"
    return 0
}

# Function to get database credentials from secrets
get_db_credentials() {
    local namespace=$1
    
    print_status "Reading database credentials from secrets in namespace '$namespace'..."
    
    # Get postgres secret
    local db_username_b64
    local db_password_b64
    
    db_username_b64=$(kubectl get secret postgres-secret -n "$namespace" -o jsonpath='{.data.DB_USERNAME}' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$db_username_b64" ]; then
        print_error "Failed to get DB_USERNAME from postgres-secret"
        return 1
    fi
    
    db_password_b64=$(kubectl get secret postgres-secret -n "$namespace" -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$db_password_b64" ]; then
        print_error "Failed to get DB_PASSWORD from postgres-secret"
        return 1
    fi
    
    # Decode base64 credentials
    DB_USERNAME=$(echo "$db_username_b64" | base64 -d)
    DB_PASSWORD=$(echo "$db_password_b64" | base64 -d)
    
    if [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ]; then
        print_error "Failed to decode database credentials"
        return 1
    fi
    
    print_success "Successfully retrieved database credentials"
    return 0
}

# Function to get postgres pod name
get_postgres_pod() {
    local namespace=$1
    
    print_status "Finding PostgreSQL pod in namespace '$namespace'..."
    
    POSTGRES_POD=$(kubectl get pods -n "$namespace" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$POSTGRES_POD" ]; then
        print_error "No PostgreSQL pod found in namespace '$namespace'"
        return 1
    fi
    
    # Check if pod is running
    local pod_status
    pod_status=$(kubectl get pod "$POSTGRES_POD" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    
    if [ "$pod_status" != "Running" ]; then
        print_error "PostgreSQL pod '$POSTGRES_POD' is not running (status: $pod_status)"
        return 1
    fi
    
    print_success "Found running PostgreSQL pod: $POSTGRES_POD"
    return 0
}

# Function to execute SQL query via kubectl exec
execute_sql() {
    local namespace=$1
    local query=$2
    local description=$3
    
    print_status "$description"
    
    # Execute the SQL query
    kubectl exec -n "$namespace" "$POSTGRES_POD" -- psql -U "$DB_USERNAME" -d zilla -c "$query" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        print_success "$description - completed"
        return 0
    else
        print_error "$description - failed"
        return 1
    fi
}

# Function to purge database
purge_database() {
    local namespace=$1
    local leave_users=$2
    local failed_operations=0

    print_status "Starting database purge for namespace '$namespace'..."
    
    # Test database connection
    if ! execute_sql "$namespace" "SELECT 1;" "Testing database connection"; then
        print_error "Failed to connect to database"
        return 1
    fi
    
    # Delete issues
    if ! execute_sql "$namespace" "DELETE FROM issue WHERE true;" "Deleting all issues"; then
        ((failed_operations++))
    fi
    
    # Delete sprints
    if ! execute_sql "$namespace" "DELETE FROM sprint WHERE true;" "Deleting all sprints"; then
        ((failed_operations++))
    fi
    
    # Delete user project access
    if ! execute_sql "$namespace" "DELETE FROM user_project_access WHERE true;" "Deleting all user project access records"; then
        ((failed_operations++))
    fi
    
    # Delete projects
    if ! execute_sql "$namespace" "DELETE FROM project WHERE true;" "Deleting all projects"; then
        ((failed_operations++))
    fi
    
    if [ "$leave_users" = false ]; then
      # Delete all admin users (no exceptions)
      if ! execute_sql "$namespace" "DELETE FROM admin_user WHERE true;" "Deleting all admin users"; then
          ((failed_operations++))
      fi
      
      # Delete all users (no exceptions)
      if ! execute_sql "$namespace" "DELETE FROM zilla_user WHERE true;" "Deleting all zilla users"; then
          ((failed_operations++))
      fi
      
      # Reset sequences
      if ! execute_sql "$namespace" "ALTER SEQUENCE admin_user_id_seq RESTART WITH 1;" "Resetting admin_user sequence"; then
        ((failed_operations++))
      fi
    fi
    
    if ! execute_sql "$namespace" "ALTER SEQUENCE project_project_id_seq RESTART WITH 1;" "Resetting project sequence"; then
        ((failed_operations++))
    fi
    
    if ! execute_sql "$namespace" "ALTER SEQUENCE sprint_sprint_id_seq RESTART WITH 1;" "Resetting sprint sequence"; then
        ((failed_operations++))
    fi
    
    if ! execute_sql "$namespace" "ALTER SEQUENCE user_project_access_id_seq RESTART WITH 1;" "Resetting user_project_access sequence"; then
        ((failed_operations++))
    fi
    
    # Report results
    if [ $failed_operations -eq 0 ]; then
        print_success "Database purge completed successfully for namespace '$namespace'"
        return 0
    else
        print_warning "Database purge completed with $failed_operations failed operations for namespace '$namespace'"
        return 1
    fi
}

# Main function
main() {
    local namespace=$1
    local leave_users=false
    if [ "$2" == "--leave-users" ]; then
        print_status "Leaving users"
        leave_users=true
    fi
    
    # Check if namespace parameter is provided
    if [ -z "$namespace" ]; then
        print_error "Namespace parameter is required"
        show_usage
        exit 1
    fi
    
    print_status "Starting purge process for namespace: $namespace"
    
    # Check if namespace exists
    if ! check_namespace "$namespace"; then
        exit 1
    fi
    
    # Get database credentials
    if ! get_db_credentials "$namespace"; then
        exit 1
    fi
    
    # Get postgres pod
    if ! get_postgres_pod "$namespace"; then
        exit 1
    fi
    
    # Confirm purge operation
    print_warning "This will permanently delete ALL data in the database for namespace '$namespace'"
    print_warning "This includes ALL users, projects, sprints, issues, and admin accounts"
    echo -n "Are you sure you want to continue? (y/N): "
    read -r confirmation
    
    if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
        print_status "Purge operation cancelled"
        exit 0
    fi
    
    # Perform database purge
    if purge_database "$namespace" $leave_users; then
        print_success "Purge operation completed successfully"
        exit 0
    else
        print_error "Purge operation completed with errors"
        exit 1
    fi
}

# Run main function with all arguments
main "$@"