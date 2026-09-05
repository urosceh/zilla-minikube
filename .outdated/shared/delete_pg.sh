# for each tenant, delete the postgres role and schema and namespace

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

POSTGRES_POD=$(kubectl get pods -n default -l app=postgres -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POSTGRES_POD" ]; then
  echo "Postgres pod not found"
  exit 1
fi

echo "Postgres pod: $POSTGRES_POD"

DB_USERNAME=$(kubectl get secret postgres-secret -n default -o jsonpath='{.data.DB_USERNAME}' | base64 -d)

# Delete tenants in parallel
pids=()
for tenant in "${TENANTS[@]}"; do
  (
    kubectl delete namespace "$tenant" >/dev/null 2>&1;

    if ! kubectl exec "$POSTGRES_POD" -- psql -U "$DB_USERNAME" -d zilla -c "DROP SCHEMA IF EXISTS $tenant CASCADE;" >/dev/null 2>&1; then
      echo "Failed to delete schema $tenant"
      continue
    fi
    if ! kubectl exec "$POSTGRES_POD" -- psql -U "$DB_USERNAME" -d zilla -c "DROP ROLE IF EXISTS $tenant;" >/dev/null 2>&1; then
      echo "Failed to delete role $tenant"
      continue
    fi
    rm -rf "$SCRIPT_DIR/tenants/$tenant"
    echo "Namespace, folder, postgres role and schema $tenant deleted"
  ) &
  pids+=($!)
done

# Wait for all tenant deletions to complete
for pid in "${pids[@]}"; do
  wait "$pid"
done