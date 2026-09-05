#!/usr/bin/env bash
set -euo pipefail

# Diagnose ISO tenants (default: all from models/iso/tenants)
# Usage:
#   scripts/diagnose_iso.sh            # diagnose all iso tenants
#   scripts/diagnose_iso.sh adobe      # diagnose single tenant
#   scripts/diagnose_iso.sh --fix      # try restarts if broken
#   scripts/diagnose_iso.sh adobe --fix

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/models/iso"
KCTL=(minikube -p iso kubectl --)
FIX=false

TENANTS=()
for arg in "$@"; do
  case "$arg" in
    --fix) FIX=true ;;
    -h|--help)
      sed -n '1,20p' "$0"; exit 0 ;;
    *) TENANTS+=("$arg") ;;
  esac
done

if [ ${#TENANTS[@]} -eq 0 ]; then
  if [ -d "$MODEL_DIR/tenants" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && TENANTS+=("$d")
    done < <(ls -1 "$MODEL_DIR/tenants" | sed '/^$/d')
  else
    echo "[ERR] No tenants directory at $MODEL_DIR/tenants" >&2; exit 1
  fi
fi

section() { echo; echo "==== $* ===="; }
ns() { echo "[$1] $2"; }

has_endpoints() {
  local ns="$1" name="$2"
  "${KCTL[@]}" -n "$ns" get endpoints "$name" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -qE '\S'
}

restart_if_needed() {
  local ns="$1" deploy="$2"
  if ! "${KCTL[@]}" -n "$ns" get deploy "$deploy" >/dev/null 2>&1; then return 0; fi
  local status
  status=$("${KCTL[@]}" -n "$ns" get deploy "$deploy" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)
  if [ "$status" != "True" ]; then
    ns "$ns" "[FIX] rollout restart deploy/$deploy"
    "${KCTL[@]}" -n "$ns" rollout restart deploy/"$deploy"
    "${KCTL[@]}" -n "$ns" rollout status deploy/"$deploy" --timeout=180s || true
  fi
}

for t in "${TENANTS[@]}"; do
  section "Tenant: $t"

  ns "$t" "Pods and Services"
  "${KCTL[@]}" -n "$t" get pods -o wide || true
  "${KCTL[@]}" -n "$t" get svc || true

  ns "$t" "Endpoints"
  for s in zilla-backend zilla-frontend nginx-bff postgres redis; do
    echo "- $s:" $({ "${KCTL[@]}" -n "$t" get endpoints "$s" -o wide 2>/dev/null || echo "(no endpoints)"; })
  done

  ns "$t" "ConfigMaps and Secrets presence"
  "${KCTL[@]}" -n "$t" get cm tenant-config nginx-config -o name || true
  "${KCTL[@]}" -n "$t" get secret postgres-secret redis-secret -o name || true

  ns "$t" "Recent pod events"
  for d in zilla-backend zilla-frontend nginx-bff postgres redis; do
    if "${KCTL[@]}" -n "$t" get deploy "$d" >/dev/null 2>&1; then
      pod=$("${KCTL[@]}" -n "$t" get pods -l app="$d" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      if [ -n "${pod:-}" ]; then
        echo "- $d -> $pod"
        "${KCTL[@]}" -n "$t" describe pod "$pod" | tail -n 60 || true
      fi
    fi
  done

  ns "$t" "Tail logs (backend/frontend/nginx)"
  for d in zilla-backend zilla-frontend nginx-bff; do
    if "${KCTL[@]}" -n "$t" get deploy "$d" >/dev/null 2>&1; then
      echo "--- logs $d ---"
      "${KCTL[@]}" -n "$t" logs deploy/"$d" --tail=100 --all-containers=true || true
    fi
  done

  # Common auto-fixes
  if $FIX; then
    ns "$t" "Auto-fix: ensure secrets/configmaps applied"
    if [ -f "$MODEL_DIR/tenants/$t/secrets.yaml" ]; then
      "${KCTL[@]}" -n "$t" apply -f "$MODEL_DIR/tenants/$t/secrets.yaml" || true
    fi
    if [ -f "$MODEL_DIR/tenants/$t/backend-configmap.yaml" ]; then
      "${KCTL[@]}" -n "$t" apply -f "$MODEL_DIR/tenants/$t/backend-configmap.yaml" || true
    fi
    if [ -f "$MODEL_DIR/tenants/$t/nginx-configmap.yaml" ]; then
      "${KCTL[@]}" -n "$t" apply -f "$MODEL_DIR/tenants/$t/nginx-configmap.yaml" || true
    fi

    ns "$t" "Auto-fix: restart non-available deployments"
    for d in postgres redis zilla-backend zilla-frontend nginx-bff; do
      restart_if_needed "$t" "$d"
    done

    ns "$t" "Auto-fix: verify endpoints after restart"
    for s in zilla-backend zilla-frontend; do
      if ! has_endpoints "$t" "$s"; then
        ns "$t" "[WARN] Service $s still has no endpoints"
      fi
    done
  fi

done

echo "[DONE] Diagnosis complete. Use --fix to try automatic restarts."
