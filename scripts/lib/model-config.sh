#!/usr/bin/env bash
# Central model topology, namespaces, tenants, and resource constants.

set -euo pipefail

: "${ZILLA_MINIKUBE_ROOT:?ZILLA_MINIKUBE_ROOT must be set}"

# shellcheck source=scripts/lib/images.sh
source "${ZILLA_MINIKUBE_ROOT}/scripts/lib/images.sh"

readonly PROFILE_CPUS=3
readonly PROFILE_MEMORY=4096
readonly PROFILE_DISK=20g
readonly GROUPED_PROFILE_CPUS=4
readonly GROUPED_PROFILE_MEMORY=6144
readonly MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"

readonly VALID_MODELS="iso hybrid shared grouped"

# Uniform resource table (all models, same component type)
readonly RES_BACKEND_CPU_REQ="250m"
readonly RES_BACKEND_CPU_LIM="500m"
readonly RES_BACKEND_MEM_REQ="256Mi"
readonly RES_BACKEND_MEM_LIM="512Mi"
readonly RES_BACKEND_NODE_OPTIONS="--max-old-space-size=384"

readonly RES_FRONTEND_CPU_REQ="200m"
readonly RES_FRONTEND_CPU_LIM="500m"
readonly RES_FRONTEND_MEM_REQ="512Mi"
readonly RES_FRONTEND_MEM_LIM="1536Mi"

readonly RES_NGINX_CPU_REQ="50m"
readonly RES_NGINX_CPU_LIM="100m"
readonly RES_NGINX_MEM_REQ="64Mi"
readonly RES_NGINX_MEM_LIM="128Mi"

readonly RES_REDIS_CPU_REQ="100m"
readonly RES_REDIS_CPU_LIM="250m"
readonly RES_REDIS_MEM_REQ="128Mi"
readonly RES_REDIS_MEM_LIM="256Mi"

readonly RES_POSTGRES_CPU_REQ="250m"
readonly RES_POSTGRES_CPU_LIM="500m"
readonly RES_POSTGRES_MEM_REQ="512Mi"
readonly RES_POSTGRES_MEM_LIM="1Gi"

readonly RES_LIQUIBASE_CPU_REQ="100m"
readonly RES_LIQUIBASE_CPU_LIM="500m"
readonly RES_LIQUIBASE_MEM_REQ="128Mi"
readonly RES_LIQUIBASE_MEM_LIM="512Mi"

readonly POSTGRES_PORT=5450
readonly REDIS_PORT=6379
readonly BACKEND_PORT=3000
readonly FRONTEND_PORT=8080
readonly NGINX_PORT=80

model_profile() {
  case "$1" in
    iso|hybrid|shared|grouped) echo "$1" ;;
    *) return 1 ;;
  esac
}

profile_cpus() {
  case "$1" in
    grouped) echo "$GROUPED_PROFILE_CPUS" ;;
    iso|hybrid|shared) echo "$PROFILE_CPUS" ;;
    *) return 1 ;;
  esac
}

profile_memory() {
  case "$1" in
    grouped) echo "$GROUPED_PROFILE_MEMORY" ;;
    iso|hybrid|shared) echo "$PROFILE_MEMORY" ;;
    *) return 1 ;;
  esac
}

profile_disk() {
  case "$1" in
    iso|hybrid|shared|grouped) echo "$PROFILE_DISK" ;;
    *) return 1 ;;
  esac
}

model_dir() {
  echo "${ZILLA_MINIKUBE_ROOT}/models/$1"
}

# --- Tenant discovery ---

discover_iso_tenants() {
  local dir="${ZILLA_MINIKUBE_ROOT}/models/iso/tenants"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

discover_hybrid_tenants() {
  local dir="${ZILLA_MINIKUBE_ROOT}/models/hybrid/tenants"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

discover_shared_tenants() {
  local dir="${ZILLA_MINIKUBE_ROOT}/models/shared/tenants"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

discover_grouped_iso_tenants() {
  local dir="${ZILLA_MINIKUBE_ROOT}/models/grouped/iso.grouped/tenants"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

discover_grouped_hybrid_tenants() {
  local dir="${ZILLA_MINIKUBE_ROOT}/models/grouped/hybrid.grouped/tenants"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

discover_grouped_shared_tenants() {
  local dir="${ZILLA_MINIKUBE_ROOT}/models/grouped/shared.grouped/tenants"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# Redis DB assignment per tenant (1-based, unique within shared Redis instance)
tenant_redis_db() {
  local model="$1"
  local tenant="$2"
  local idx=1
  local t
  case "$model" in
    hybrid)
      while IFS= read -r t; do
        [[ "$t" == "$tenant" ]] && { echo "$idx"; return 0; }
        idx=$((idx + 1))
      done < <(discover_hybrid_tenants)
      ;;
    shared)
      while IFS= read -r t; do
        [[ "$t" == "$tenant" ]] && { echo "$idx"; return 0; }
        idx=$((idx + 1))
      done < <(discover_shared_tenants)
      ;;
    grouped-hybrid)
      while IFS= read -r t; do
        [[ "$t" == "$tenant" ]] && { echo "$idx"; return 0; }
        idx=$((idx + 1))
      done < <(discover_grouped_hybrid_tenants)
      ;;
    grouped-shared)
      while IFS= read -r t; do
        [[ "$t" == "$tenant" ]] && { echo "$idx"; return 0; }
        idx=$((idx + 1))
      done < <(discover_grouped_shared_tenants)
      ;;
    iso|grouped-iso)
      echo "1"
      return 0
      ;;
  esac
  return 1
}

# Expected steady-state Deployment count per model (for smoke tests)
expected_deployment_count() {
  case "$1" in
    iso)
      local n
      n=$(discover_iso_tenants | wc -l | tr -d ' ')
      echo $((7 * n))
      ;;
    hybrid) echo 9 ;;
    shared) echo 7 ;;
    grouped)
      local iso_n hybrid_n
      iso_n=$(discover_grouped_iso_tenants | wc -l | tr -d ' ')
      hybrid_n=$(discover_grouped_hybrid_tenants | wc -l | tr -d ' ')
      echo $((7 * iso_n + hybrid_n + 13))
      ;;
  esac
}

# Expected Prometheus application target counts per model.
expected_backend_target_count() {
  case "$1" in
    iso) discover_iso_tenants | wc -l | tr -d ' ' ;;
    hybrid) discover_hybrid_tenants | wc -l | tr -d ' ' ;;
    shared) echo 1 ;;
    grouped)
      local iso_n hybrid_n
      iso_n=$(discover_grouped_iso_tenants | wc -l | tr -d ' ')
      hybrid_n=$(discover_grouped_hybrid_tenants | wc -l | tr -d ' ')
      echo $((iso_n + hybrid_n + 1))
      ;;
  esac
}

expected_exporter_target_count() {
  case "$1" in
    iso) discover_iso_tenants | wc -l | tr -d ' ' ;;
    hybrid|shared) echo 1 ;;
    grouped)
      local iso_n
      iso_n=$(discover_grouped_iso_tenants | wc -l | tr -d ' ')
      echo $((iso_n + 2))
      ;;
  esac
}

# Namespaces for a model
model_namespaces() {
  case "$1" in
    iso)
      discover_iso_tenants
      ;;
    hybrid)
      echo hybrid
      ;;
    shared)
      echo shared
      ;;
    grouped)
      discover_grouped_iso_tenants
      echo hybrid-grouped
      echo shared-grouped
      ;;
  esac
}

# Smoke route type: direct | path-prefix | header-tenant
tenant_route_type() {
  case "$1" in
    iso|grouped-iso) echo direct ;;
    hybrid|grouped-hybrid) echo path-prefix ;;
    shared|grouped-shared) echo header-tenant ;;
    *) return 1 ;;
  esac
}

# Representative tenant for smoke (first in list)
smoke_tenant_for() {
  case "$1" in
    iso) discover_iso_tenants | head -n1 ;;
    hybrid) discover_hybrid_tenants | head -n1 ;;
    shared) discover_shared_tenants | head -n1 ;;
    grouped-iso) discover_grouped_iso_tenants | head -n1 ;;
    grouped-hybrid) discover_grouped_hybrid_tenants | head -n1 ;;
    grouped-shared) discover_grouped_shared_tenants | head -n1 ;;
  esac
}

# All tenants for a model profile (sorted, unique)
discover_all_tenants_for_model() {
  case "$1" in
    iso)
      discover_iso_tenants
      ;;
    hybrid)
      discover_hybrid_tenants
      ;;
    shared)
      discover_shared_tenants
      ;;
    grouped)
      {
        discover_grouped_iso_tenants
        discover_grouped_hybrid_tenants
        discover_grouped_shared_tenants
      } | awk 'NF' | sort -u
      ;;
    *)
      return 1
      ;;
  esac
}
