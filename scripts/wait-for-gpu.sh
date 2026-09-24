#!/usr/bin/env bash
# Polls GPU stock (read-only) until the GPU is available, then reports and exits 0.
# It NEVER starts or creates anything: starting bills the GPU, that stays your call.
# Stock is an ordering hint, not a reservation; act quickly and expect a start/apply
# can still fail.
#
# Usage: wait-for-gpu.sh [GPU_MATCH] [DATACENTER_ID] [INTERVAL_SECONDS] [TIMEOUT_SECONDS]
#   defaults: B300, any datacenter, 60 s, 0 (= wait until Ctrl-C)
# Example (your volume lives in EU-NL-1): wait-for-gpu.sh B300 EU-NL-1
#
# Exit codes: 0 = in stock, 3 = timeout, 1 = the API failed 5 times in a row.
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"

MATCH="${1:-B300}"
DC="${2:-}"
INTERVAL="${3:-60}"
TIMEOUT="${4:-0}"
case "$INTERVAL$TIMEOUT" in *[!0-9]*) echo "INTERVAL and TIMEOUT must be whole seconds" >&2; exit 2 ;; esac
[ "$INTERVAL" -ge 10 ] || { echo "INTERVAL must be >= 10 s (API rate limit)" >&2; exit 2; }

HERE="$(dirname "$0")"
start=$SECONDS
errors=0
echo "Waiting for ${MATCH}${DC:+ in $DC} (every ${INTERVAL}s, timeout: $([ "$TIMEOUT" -gt 0 ] && echo "${TIMEOUT}s" || echo none)). Read-only, Ctrl-C to stop."

while true; do
  set +e
  out="$("$HERE/gpu-availability.sh" "$MATCH" ${DC:+"$DC"} 2>&1)"
  rc=$?
  set -e
  now="$(date +%H:%M:%S)"

  case "$rc" in
    0)
      printf '\a'
      echo "[$now] IN STOCK:"
      printf '%s\n' "$out"
      echo "Next: scripts/pod-start.sh (restart the stopped Pod) or scripts/plan.sh + terraform apply tfplan."
      exit 0
      ;;
    2)
      errors=0
      echo "[$now] no stock"
      ;;
    *)
      errors=$((errors + 1))
      echo "[$now] API error ($errors/5): $(printf '%s' "$out" | head -n1)" >&2
      [ "$errors" -lt 5 ] || exit 1
      ;;
  esac

  if [ "$TIMEOUT" -gt 0 ] && [ $((SECONDS - start)) -ge "$TIMEOUT" ]; then
    echo "Timeout after ${TIMEOUT}s without stock." >&2
    exit 3
  fi
  sleep "$INTERVAL"
done
