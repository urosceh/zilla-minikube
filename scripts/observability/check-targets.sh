#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/observability/common.sh
source "${SCRIPT_DIR}/common.sh"

PROFILE="${1:-}"
if [[ -z "$PROFILE" || "$#" -ne 1 ]]; then
  echo "Usage: scripts/observability/check-targets.sh <iso|hybrid|shared|grouped>"
  exit 1
fi

init_observability_profile "$PROFILE"
require_command curl
require_command python3

EXPECTED_BACKENDS="$(expected_backend_target_count "$PROFILE")"
EXPECTED_EXPORTERS="$(expected_exporter_target_count "$PROFILE")"
LOCAL_PORT="$(
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
)"
PF_LOG="$(mktemp -t zilla-prometheus-port-forward.XXXXXX)"
TARGETS_JSON="$(mktemp -t zilla-prometheus-targets.XXXXXX)"

cleanup() {
  pkill -TERM -P "${PF_PID:-}" >/dev/null 2>&1 || true
  kill "${PF_PID:-}" >/dev/null 2>&1 || true
  wait "${PF_PID:-}" >/dev/null 2>&1 || true
  rm -f "$PF_LOG" "$TARGETS_JSON"
}
trap cleanup EXIT

kctl -n "${MONITORING_NAMESPACE}" port-forward \
  service/kube-prometheus-stack-prometheus "${LOCAL_PORT}:9090" \
  >"$PF_LOG" 2>&1 &
PF_PID=$!
PROMETHEUS_URL="http://127.0.0.1:${LOCAL_PORT}"

for _ in {1..30}; do
  if curl -sf "${PROMETHEUS_URL}/-/ready" >/dev/null; then
    break
  fi
  if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
    err "Prometheus port-forward failed: $(cat "$PF_LOG")"
    exit 1
  fi
  sleep 1
done
curl -sf "${PROMETHEUS_URL}/-/ready" >/dev/null ||
  { err "Prometheus API did not become ready"; exit 1; }

validate_targets() {
  python3 - "$PROFILE" "$EXPECTED_BACKENDS" "$EXPECTED_EXPORTERS" "$TARGETS_JSON" <<'PY'
import json
import sys

model = sys.argv[1]
expected = {
    "backend": int(sys.argv[2]),
    "postgres": int(sys.argv[3]),
    "redis": int(sys.argv[3]),
}
with open(sys.argv[4], encoding="utf-8") as targets_file:
    payload = json.load(targets_file)
targets = payload.get("data", {}).get("activeTargets", [])
failed = []

for target_type, expected_count in expected.items():
    matching = [
        target for target in targets
        if target.get("labels", {}).get("model") == model
        and target.get("labels", {}).get("zilla_target_type") == target_type
    ]
    up = [target for target in matching if target.get("health") == "up"]
    print(f"{target_type}: {len(up)}/{expected_count} UP ({len(matching)} discovered)")
    if len(matching) != expected_count or len(up) != expected_count:
        failed.append(target_type)
        for target in matching:
            labels = target.get("labels", {})
            print(
                "  "
                f"{labels.get('namespace', '?')}/{labels.get('service', '?')} "
                f"pod={labels.get('pod', '?')} health={target.get('health', '?')} "
                f"error={target.get('lastError') or '-'}"
            )
    for target in matching:
        labels = target.get("labels", {})
        missing = [
            label for label in ("model", "namespace", "service", "pod")
            if not labels.get(label)
        ]
        if model == "iso" and not labels.get("tenant"):
            missing.append("tenant")
        if model == "hybrid" and target_type == "backend" and not labels.get("tenant"):
            missing.append("tenant")
        if model == "grouped":
            if not labels.get("group"):
                missing.append("group")
            if (
                target_type == "backend"
                and labels.get("group") in {"iso", "hybrid"}
                and not labels.get("tenant")
            ):
                missing.append("tenant")
        if missing:
            failed.append(f"{target_type}-identity")
            print(
                f"  {labels.get('namespace', '?')}/{labels.get('service', '?')} "
                f"is missing labels: {', '.join(missing)}"
            )

if failed:
    raise SystemExit(f"target count/health mismatch: {', '.join(failed)}")
PY
}

TARGETS_OK=false
for attempt in {1..12}; do
  curl -sf "${PROMETHEUS_URL}/api/v1/targets?state=active" >"$TARGETS_JSON"
  if TARGET_OUTPUT="$(validate_targets 2>&1)"; then
    echo "$TARGET_OUTPUT"
    TARGETS_OK=true
    break
  fi
  [[ "$attempt" -lt 12 ]] && sleep 5
done
if [[ "$TARGETS_OK" != true ]]; then
  echo "$TARGET_OUTPUT" >&2
  err "Expected Zilla targets are not all UP"
  exit 1
fi

query_has_data() {
  local query="$1"
  curl -sfG "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode "query=${query}" |
    python3 -c 'import json,sys; p=json.load(sys.stdin); raise SystemExit(0 if p.get("data", {}).get("result") else 1)'
}

check_metric() {
  local metric="$1"
  local query="${metric}{model=\"${PROFILE}\"}"
  local attempt
  for attempt in {1..6}; do
    if query_has_data "$query"; then
      ok "${metric} returns data for model ${PROFILE}"
      return 0
    fi
    [[ "$attempt" -lt 6 ]] && sleep 5
  done
  err "${metric} has no data for model ${PROFILE}"
  return 1
}

FAILURES=0
check_metric zilla_http_requests_total || FAILURES=$((FAILURES + 1))
check_metric pg_up || FAILURES=$((FAILURES + 1))
check_metric redis_up || FAILURES=$((FAILURES + 1))

if [[ "$FAILURES" -gt 0 ]]; then
  err "Metric verification found ${FAILURES} problem(s)"
  exit 1
fi

ok "All expected ${PROFILE} targets and metric families are available"
