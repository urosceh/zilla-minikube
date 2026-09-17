#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
# shellcheck source=experiments/fair-comparison.env
source "${ROOT_DIR}/experiments/fair-comparison.env"

TARGET="${1:-}"
if [[ -z "$TARGET" || "$#" -ne 1 ]]; then
  cat <<'EOF' >&2
Usage: scripts/run-fair-comparison.sh <primary|iso|hybrid|shared|grouped>

  primary  Runs iso, hybrid, and shared three times in rotating order.
  grouped  Runs grouped separately; it is never included in primary results.
EOF
  exit 1
fi

case "$TARGET" in
  primary)
    read -r -a models <<<"$FAIR_COMPARISON_MODELS"
    ;;
  iso|hybrid|shared)
    models=("$TARGET")
    ;;
  grouped)
    models=("grouped")
    ;;
  *)
    err "Invalid comparison target: ${TARGET}"
    exit 1
    ;;
esac

for command_name in minikube python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    err "Required command not found: ${command_name}"
    exit 1
  fi
done

readonly BATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)"
readonly TMP_DIR="$(mktemp -d -t zilla-fair-comparison.XXXXXX)"
readonly IMAGE_LOCK="${ROOT_DIR}/config/images.lock.env"
MEASUREMENT_THRESHOLD_FAILURES=0

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

file_sha256() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

readonly INITIAL_IMAGE_LOCK_SHA="$(file_sha256 "$IMAGE_LOCK")"

activate_only_profile() {
  local selected="$1"
  local profile
  local namespace

  for profile in $VALID_MODELS; do
    if [[ "$profile" != "$selected" ]] &&
      minikube status -p "$profile" >/dev/null 2>&1; then
      log "Stopping profile '${profile}' to isolate host resources"
      minikube stop -p "$profile" >/dev/null
    fi
  done

  bash "${ROOT_DIR}/start_clusters.sh" "$selected"
  init_profile "$selected"
  log "Waiting for kube-system deployments"
  kctl -n kube-system wait \
    --for=condition=Available deployment --all --timeout=300s
  while IFS= read -r namespace; do
    [[ -z "$namespace" ]] && continue
    log "Waiting for deployments in namespace '${namespace}'"
    kctl -n "$namespace" wait \
      --for=condition=Available deployment --all --timeout=300s
  done < <(model_namespaces "$selected")
  sleep 10
}

purge_with_retry() {
  local model="$1"
  local attempt

  for attempt in {1..5}; do
    if bash "${ROOT_DIR}/scripts/purge-model.sh" "$model"; then
      return 0
    fi
    if [[ "$attempt" -eq 5 ]]; then
      err "Purge failed after ${attempt} attempts for model ${model}"
      return 1
    fi
    warn "Purge attempt ${attempt} failed for ${model}; retrying in 5 seconds"
    sleep 5
  done
}

run_repetition() {
  local model="$1"
  local repetition="$2"
  local result_pointer="${TMP_DIR}/${model}-${repetition}.result"
  local current_lock_sha
  local result_dir
  local run_status

  current_lock_sha="$(file_sha256 "$IMAGE_LOCK")"
  if [[ "$current_lock_sha" != "$INITIAL_IMAGE_LOCK_SHA" ]]; then
    err "config/images.lock.env changed during comparison batch ${BATCH_ID}"
    exit 1
  fi

  log "Batch ${BATCH_ID}: ${model} repetition ${repetition}/${FAIR_COMPARISON_REPETITIONS}"
  activate_only_profile "$model"

  purge_with_retry "$model"
  bash "${ROOT_DIR}/scripts/seed-model.sh" "$model"

  set +e
  (
    unset TENANTS
    EXPERIMENT_PROTOCOL="$FAIR_COMPARISON_PROTOCOL" \
    EXPERIMENT_BATCH_ID="$BATCH_ID" \
    EXPERIMENT_REPETITION="$repetition" \
    EXPERIMENT_RESULT_FILE="$result_pointer" \
    WARMUP_SECONDS="$FAIR_COMPARISON_WARMUP_SECONDS" \
    STEADY_SECONDS="$FAIR_COMPARISON_STEADY_SECONDS" \
    COOLDOWN_SECONDS="$FAIR_COMPARISON_COOLDOWN_SECONDS" \
    VUS_PER_TENANT="$FAIR_COMPARISON_VUS_PER_TENANT" \
    THINK_TIME_SECONDS="$FAIR_COMPARISON_THINK_TIME_SECONDS" \
      bash "${ROOT_DIR}/scripts/run-experiment.sh" "$model"
  )
  run_status=$?
  set -e

  if [[ ! -s "$result_pointer" ]]; then
    err "Experiment completed without reporting its result directory"
    if [[ "$run_status" -eq 0 ]]; then
      return 1
    fi
    return "$run_status"
  fi
  result_dir="$(<"$result_pointer")"
  printf '%s\n' "$result_dir" >>"${TMP_DIR}/${model}.runs"

  case "$run_status" in
    0) ;;
    99)
      MEASUREMENT_THRESHOLD_FAILURES=$((MEASUREMENT_THRESHOLD_FAILURES + 1))
      warn "${model} repetition ${repetition} completed with failed k6 thresholds"
      ;;
    *)
      err "${model} repetition ${repetition} failed with exit code ${run_status}"
      return "$run_status"
      ;;
  esac
}

for ((repetition = 1; repetition <= FAIR_COMPARISON_REPETITIONS; repetition++)); do
  model_count="${#models[@]}"
  offset=$(((repetition - 1) % model_count))
  for ((position = 0; position < model_count; position++)); do
    index=$(((position + offset) % model_count))
    run_repetition "${models[$index]}" "$repetition"
  done
done

for model in "${models[@]}"; do
  run_dirs=()
  while IFS= read -r run_dir; do
    [[ -n "$run_dir" ]] && run_dirs+=("$run_dir")
  done <"${TMP_DIR}/${model}.runs"
  output_prefix="${ROOT_DIR}/results/${BATCH_ID}-${model}-three-run-comparison"
  python3 "${ROOT_DIR}/experiments/compare_runs.py" \
    "${run_dirs[@]}" \
    --output-prefix "$output_prefix"
done

if [[ "$MEASUREMENT_THRESHOLD_FAILURES" -gt 0 ]]; then
  warn "Comparison completed with ${MEASUREMENT_THRESHOLD_FAILURES} run(s) that failed k6 thresholds"
  exit 99
fi

ok "Fair comparison batch complete: ${BATCH_ID} (${TARGET})"
