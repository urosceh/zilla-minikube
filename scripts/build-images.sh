#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ZILLA_MINIKUBE_ROOT="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  err "Usage: $0 <iso|hybrid|shared|grouped|all>"
  exit 1
fi

REPO_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
BACKEND_REPO="${REPO_ROOT}/zilla-backend"
FRONTEND_REPO="${REPO_ROOT}/zilla-frontend"
WORKTREE_ROOT="${ROOT_DIR}/.build/worktrees"

worktree_head_sha() {
  local wt="$1"
  local git_file="${wt}/.git"
  local gitdir_line gitdir head

  [[ -f "$git_file" ]] || return 1
  IFS= read -r gitdir_line < "$git_file"
  [[ "$gitdir_line" == "gitdir: "* ]] || return 1
  gitdir="${gitdir_line#gitdir: }"
  if [[ "$gitdir" != /* ]]; then
    gitdir="${wt}/${gitdir}"
  fi

  [[ -f "${gitdir}/HEAD" ]] || return 1
  IFS= read -r head < "${gitdir}/HEAD"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$head"
}

build_backend() {
  local branch="$1"
  local sha="$2"
  local tag="$3"
  local wt="${WORKTREE_ROOT}/zilla-backend-${branch}"
  local actual_sha

  log "Building backend ${tag} from ${branch}@${sha}"

  mkdir -p "$WORKTREE_ROOT"
  if [[ ! -d "$wt" ]]; then
    git -C "$BACKEND_REPO" worktree add -f "$wt" "$sha"
  fi

  if ! actual_sha="$(worktree_head_sha "$wt")"; then
    err "Cannot verify detached HEAD metadata for backend worktree ${wt}."
    exit 1
  fi
  if [[ "$actual_sha" != "$sha" ]]; then
    err "Backend worktree ${wt} is at ${actual_sha}, expected pinned SHA ${sha}. Refusing to modify it or build the wrong source."
    exit 1
  fi

  docker build --network=host -t "$tag" "$wt"
}

build_frontend() {
  local branch="$1"
  local sha="$2"
  local tag="$3"
  local wt="${WORKTREE_ROOT}/zilla-frontend-${branch}"

  log "Building frontend ${tag} from ${branch}@${sha}"
  mkdir -p "$WORKTREE_ROOT"
  if [[ ! -d "${wt}" ]]; then
    git -C "$FRONTEND_REPO" worktree add -f "$wt" "$sha"
  else
    git -C "$wt" checkout -f "$sha"
  fi

  docker build --network=host -t "$tag" "$wt"
}

load_images() {
  local profile="$1"
  log "Loading images into Minikube profile: ${profile}"
  minikube -p "$profile" image load \
    "${ZILLA_BACKEND_MASTER_IMAGE}" \
    "${ZILLA_BACKEND_MASTER_SHARED_IMAGE}" \
    "${ZILLA_FRONTEND_MASTER_IMAGE}" \
    "${ZILLA_FRONTEND_MASTER_SHARED_IMAGE}" \
    "${POSTGRES_IMAGE}" \
    "${REDIS_IMAGE}" \
    "${NGINX_IMAGE}"
  # Migrations image pulled on first use (digest-pinned in manifests)
}

build_all_images() {
  build_backend "$ZILLA_BACKEND_MASTER_BRANCH" "$ZILLA_BACKEND_MASTER_SHA" "$ZILLA_BACKEND_MASTER_IMAGE"
  build_backend "$ZILLA_BACKEND_MASTER_SHARED_BRANCH" "$ZILLA_BACKEND_MASTER_SHARED_SHA" "$ZILLA_BACKEND_MASTER_SHARED_IMAGE"
  build_frontend "$ZILLA_FRONTEND_MASTER_BRANCH" "$ZILLA_FRONTEND_MASTER_SHA" "$ZILLA_FRONTEND_MASTER_IMAGE"
  build_frontend "$ZILLA_FRONTEND_MASTER_SHARED_BRANCH" "$ZILLA_FRONTEND_MASTER_SHARED_SHA" "$ZILLA_FRONTEND_MASTER_SHARED_IMAGE"
}

profiles_to_load() {
  case "$PROFILE" in
    all) echo iso hybrid shared grouped ;;
    iso|hybrid|shared|grouped) echo "$PROFILE" ;;
    *)
      err "Invalid profile: ${PROFILE}"
      exit 1
      ;;
  esac
}

main() {
  if [[ ! -d "$BACKEND_REPO/.git" ]] || [[ ! -d "$FRONTEND_REPO/.git" ]]; then
    err "Expected git repos at ${BACKEND_REPO} and ${FRONTEND_REPO}"
    exit 1
  fi

  build_all_images

  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && load_images "$p"
  done < <(profiles_to_load)

  ok "Images built and loaded. See config/images.lock.env for branch/SHA mapping."
}

main "$@"
