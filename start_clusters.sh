#!/usr/bin/env bash
set -euo pipefail

# Ensure minikube profiles for the four models
# Sizes include headroom for kube-system/addons.

PROFILE_LIST="iso hybrid grouped shared"

# vCPU and memory (MiB) per profile
# - FE/BE: 128Mi, 0.25 CPU (shared model uses 256Mi, 0.5 CPU)
# - Postgres: 1Gi RAM, 0.5 CPU, 3Gi PVC
# - Redis/Nginx: small
# These cluster sizes provide buffer for system components.

ONLY_PROFILE=${1:-}

if [ -n "$ONLY_PROFILE" ]; then
  case " $PROFILE_LIST " in
    *" $ONLY_PROFILE "*) PROFILE_LIST="$ONLY_PROFILE" ;;
    *)
      echo "[ERR] Invalid profile: $ONLY_PROFILE"
      echo "Available profiles: $PROFILE_LIST"
      exit 1
      ;;
  esac
fi

get_cpus() {
  case "$1" in
    iso) echo 6 ;;
    hybrid) echo 3 ;;
    grouped) echo 6 ;;
    shared) echo 4 ;;
    *) echo 2 ;;
  esac
}

get_mem() {
  case "$1" in
    iso) echo 8192 ;;
    hybrid) echo 4096 ;;
    grouped) echo 8192 ;;
    shared) echo 6144 ;;
    *) echo 4096 ;;
  esac
}

get_disk() {
  case "$1" in
    iso) echo 20g ;;
    hybrid) echo 10g ;;
    grouped) echo 20g ;;
    shared) echo 10g ;;
    *) echo 10g ;;
  esac
}

DRIVER="${MINIKUBE_DRIVER:-docker}"

ensure_profile() {
  local profile="$1"
  local cpus mem disk
  cpus="$(get_cpus "$profile")"
  mem="$(get_mem "$profile")"
  disk="$(get_disk "$profile")"

  sleep 1

  if minikube status -p "$profile" >/dev/null 2>&1; then
    echo "[OK] Profile '$profile' exists. Starting/validating..."
    minikube start -p "$profile" \
      --driver="$DRIVER" \
      --cpus="$cpus" \
      --memory="$mem" \
      --disk-size="$disk" \
      --kubernetes-version=stable >/dev/null
  else
    echo "[INFO] Creating profile '$profile' (cpus=$cpus mem=${mem}Mi disk=$disk driver=$DRIVER)"
    minikube start -p "$profile" \
      --driver="$DRIVER" \
      --cpus="$cpus" \
      --memory="$mem" \
      --disk-size="$disk" \
      --kubernetes-version=stable
  fi
}

main() {
  echo "[START] Starting profiles: $PROFILE_LIST"
  for p in $PROFILE_LIST; do
    ensure_profile "$p"
  done
  echo "[DONE] Profiles ensured: $PROFILE_LIST"
}

main "$@"
