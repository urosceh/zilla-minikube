#!/bin/bash

# Shared tenant purge script for Zilla
# This script purges data from PostgreSQL for specific tenants in the sec cluster

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    echo "Usage: $0 <TENANT> [--leave-users] | --all [--leave-users]"
    echo ""
    echo "Arguments:"
    echo "  TENANT           The tenant name to purge"
    echo "  --all            Purge all tenants"
    echo "  --leave-users    Whether to leave users (default: false)"
    echo ""
    echo "Available tenants: ${DEFAULT_TENANTS[*]}"
    echo ""
    echo "Examples:"
    echo "  $0 amazon                    # Purge data for 'amazon' tenant"
    echo "  $0 meta --leave-users        # Purge 'meta' tenant and leave users"
    echo "  $0 --all                     # Purge all tenants"
    echo "  $0 --all --leave-users       # Purge all tenants and leave users"
}

# Function to check if cluster is accessible
check_cluster() {
    print_status "Checking sec cluster..."
    
    # Switch to sec cluster context
    minikube profile sec > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        print_error "Failed to switch to sec cluster"
        return 1
    fi
    
    kubectl config use-context sec > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        print_error "Failed to set kubectl context to sec"
        return 1
    fi
    
    print_success "Connected to sec cluster"
    return 0
}

# Function to get database credentials from secrets
get_db_credentials() {
    print_status "Reading database credentials from default namespace..."
    
    # Get postgres secret from default namespace
    local db_username_b64
    local db_password_b64
    
    db_username_b64=$(kubectl get secret postgres-secret -n default -o jsonpath='{.data.DB_USERNAME}' 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$db_username_b64" ]; then
        print_error "Failed to get DB_USERNAME from postgres-secret"
        return 1
    fi
    
    db_password_b64=$(kubectl get secret postgres-secret -n default -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null)
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
    print_status "Finding PostgreSQL pod in default namespace..."
    
    POSTGRES_POD=$(kubectl get pods -n default -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$POSTGRES_POD" ]; then
        print_error "No PostgreSQL pod found in default namespace"
        return 1
    fi
    
    # Check if pod is running
    local pod_status
    pod_status=$(kubectl get pod "$POSTGRES_POD" -n default -o jsonpath='{.status.phase}' 2>/dev/null)
    
    if [ "$pod_status" != "Running" ]; then
        print_error "PostgreSQL pod '$POSTGRES_POD' is not running (status: $pod_status)"
        return 1
    fi
    
    print_success "Found running PostgreSQL pod: $POSTGRES_POD"
    return 0
}

# Function to execute SQL query via kubectl exec
execute_sql() {
    local query=$1
    local description=$2
    
    print_status "$description"
    
    kubectl exec -n default "$POSTGRES_POD" -- psql -U "$DB_USERNAME" -d zilla -c "$query" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        print_success "$description - completed"
        return 0
    else
        print_error "$description - failed"
        return 1
    fi
}

# Function to create PostgreSQL functions for purging
create_purge_functions() {
    print_status "Creating PostgreSQL purge functions..."
    
    # Function to purge data (projects, sprints, issues, access)
    local create_purge_data_func=$(cat <<'EOF'
CREATE OR REPLACE FUNCTION purge_tenant_data(tenant_schema TEXT)
RETURNS void AS $$
BEGIN
    -- Use dynamic SQL with schema-qualified table names
    EXECUTE format('DELETE FROM %I.issue WHERE true', tenant_schema);
    EXECUTE format('DELETE FROM %I.sprint WHERE true', tenant_schema);
    EXECUTE format('DELETE FROM %I.user_project_access WHERE true', tenant_schema);
    EXECUTE format('DELETE FROM %I.project WHERE true', tenant_schema);
    
    -- Reset sequences
    EXECUTE format('ALTER SEQUENCE %I.project_project_id_seq RESTART WITH 1', tenant_schema);
    EXECUTE format('ALTER SEQUENCE %I.sprint_sprint_id_seq RESTART WITH 1', tenant_schema);
    EXECUTE format('ALTER SEQUENCE %I.user_project_access_id_seq RESTART WITH 1', tenant_schema);
END;
$$ LANGUAGE plpgsql;
EOF
)
    
    # Function to purge users
    local create_purge_users_func=$(cat <<'EOF'
CREATE OR REPLACE FUNCTION purge_tenant_users(tenant_schema TEXT)
RETURNS void AS $$
BEGIN
    -- Delete users and reset sequences
    EXECUTE format('DELETE FROM %I.admin_user WHERE true', tenant_schema);
    EXECUTE format('DELETE FROM %I.zilla_user WHERE true', tenant_schema);
    EXECUTE format('ALTER SEQUENCE %I.admin_user_id_seq RESTART WITH 1', tenant_schema);
END;
$$ LANGUAGE plpgsql;
EOF
)
    
    if ! execute_sql "$create_purge_data_func" "Creating purge_tenant_data function"; then
        return 1
    fi
    
    if ! execute_sql "$create_purge_users_func" "Creating purge_tenant_users function"; then
        return 1
    fi
    
    print_success "PostgreSQL purge functions created"
    return 0
}

# Function to purge tenant data using PostgreSQL functions (v2 - parallel safe)
purge_tenant_v2() {
    local tenant=$1
    local leave_users=$2

    print_status "Starting database purge for tenant '$tenant' (using PostgreSQL functions)..."
    
    # Call purge_tenant_data function
    if ! execute_sql "SELECT purge_tenant_data('$tenant');" "Purging data for tenant $tenant"; then
        print_error "Failed to purge data for tenant $tenant"
        return 1
    fi
    
    # Call purge_tenant_users function if not leaving users
    if [ "$leave_users" = false ]; then
        if ! execute_sql "SELECT purge_tenant_users('$tenant');" "Purging users for tenant $tenant"; then
            print_error "Failed to purge users for tenant $tenant"
            return 1
        fi
    fi
    
    print_success "Database purge completed successfully for tenant '$tenant'"
    return 0
}

# Main function
main() {
    local tenants_to_purge=()
    local leave_users=false
    local purge_all=false
    
    # Parse arguments
    if [ $# -eq 0 ]; then
        print_error "No arguments provided"
        show_usage
        exit 1
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                purge_all=true
                shift
                ;;
            --leave-users)
                leave_users=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                tenants_to_purge+=("$1")
                shift
                ;;
        esac
    done
    
    # Determine which tenants to purge
    if [ "$purge_all" = true ]; then
        tenants_to_purge=("${DEFAULT_TENANTS[@]}")
        print_status "Purging all tenants: ${tenants_to_purge[*]}"
    elif [ ${#tenants_to_purge[@]} -eq 0 ]; then
        print_error "No tenant specified"
        show_usage
        exit 1
    fi
    
    # Check if cluster is accessible
    if ! check_cluster; then
        exit 1
    fi
    
    # Get database credentials
    if ! get_db_credentials; then
        exit 1
    fi
    
    # Get postgres pod
    if ! get_postgres_pod; then
        exit 1
    fi
    
    # Create PostgreSQL purge functions
    if ! create_purge_functions; then
        exit 1
    fi
    
    # Confirm purge operation
    print_warning "This will permanently delete data for the following tenant(s): ${tenants_to_purge[*]}"
    if [ "$leave_users" = false ]; then
        print_warning "This includes ALL users, projects, sprints, issues, and admin accounts"
    else
        print_warning "This includes projects, sprints, issues (users will be preserved)"
    fi
    echo -n "Are you sure you want to continue? (y/N): "
    read -r confirmation
    
    if [ "$confirmation" != "y" ] && [ "$confirmation" != "Y" ]; then
        print_status "Purge operation cancelled"
        exit 0
    fi
    
    # Purge each tenant in parallel using v2 function
    local total_success=0
    local total_failed=0
    local pids=()
    local results_dir=$(mktemp -d)
    
    for tenant in "${tenants_to_purge[@]}"; do
        (
            echo ""
            echo "=========================================="
            echo "Purging tenant: $tenant"
            echo "=========================================="
            
            if purge_tenant_v2 "$tenant" "$leave_users"; then
                echo "success" > "$results_dir/$tenant"
            else
                echo "failed" > "$results_dir/$tenant"
            fi
        ) &
        pids+=($!)
    done
    
    # Wait for all purge operations to complete
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Count results
    for tenant in "${tenants_to_purge[@]}"; do
        if [ -f "$results_dir/$tenant" ]; then
            result=$(cat "$results_dir/$tenant")
            if [ "$result" = "success" ]; then
                ((total_success++))
            else
                ((total_failed++))
            fi
        else
            ((total_failed++))
        fi
    done
    
    # Cleanup temp directory
    rm -rf "$results_dir"
    
    # Final summary
    echo ""
    echo "=========================================="
    echo "Purge Summary"
    echo "=========================================="
    print_success "Successfully purged: $total_success tenant(s)"
    if [ $total_failed -gt 0 ]; then
        print_error "Failed to purge: $total_failed tenant(s)"
        exit 1
    else
        print_success "All purge operations completed successfully"
        exit 0
    fi
}

# Run main function with all arguments
main "$@"

