#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ZILLA_MINIKUBE_ROOT="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

ONLY_PROFILE="${1:-}"

if [[ -z "$ONLY_PROFILE" ]]; then
  usage_start_clusters
  exit 1
fi

PROFILE_LIST=""
case "$ONLY_PROFILE" in
  all) PROFILE_LIST="iso hybrid grouped shared" ;;
  iso|hybrid|grouped|shared) PROFILE_LIST="$ONLY_PROFILE" ;;
  -h|--help)
    usage_start_clusters
    exit 0
    ;;
  *)
    err "Invalid profile: ${ONLY_PROFILE}"
    usage_start_clusters
    exit 1
    ;;
esac

ensure_profile() {
  local profile="$1"
  local cpus memory disk
  cpus="$(profile_cpus "$profile")"
  memory="$(profile_memory "$profile")"
  disk="$(profile_disk "$profile")"
  sleep 1
  if minikube status -p "$profile" >/dev/null 2>&1; then
    log "Profile '${profile}' exists. Starting/validating..."
    minikube start -p "$profile" \
      --driver="$MINIKUBE_DRIVER" \
      --cpus="$cpus" \
      --memory="$memory" \
      --disk-size="$disk" \
      --kubernetes-version=stable >/dev/null
  else
    log "Creating profile '${profile}' (cpus=${cpus} mem=${memory}Mi disk=${disk} driver=${MINIKUBE_DRIVER})"
    minikube start -p "$profile" \
      --driver="$MINIKUBE_DRIVER" \
      --cpus="$cpus" \
      --memory="$memory" \
      --disk-size="$disk" \
      --kubernetes-version=stable
  fi
}

main() {
  log "Starting profiles: ${PROFILE_LIST}"
  for p in $PROFILE_LIST; do
    ensure_profile "$p"
  done
  ok "Profiles ensured: ${PROFILE_LIST}"
}

main "$@"
