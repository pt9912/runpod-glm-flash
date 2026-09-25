#!/usr/bin/env bash
# Measures how long a Pod takes from "started" to "vLLM answers": polls
# GET <GLM_URL>/v1/models with the vLLM API key until it returns 200, prints the
# elapsed time and appends it to .startup-times.log (git-ignored).
# It only reads; it never starts or stops anything. Run it right after pod-start.sh:
#   scripts/pod-start.sh && scripts/wait-for-ready.sh
#
# Usage: wait-for-ready.sh [TIMEOUT_SECONDS] [INTERVAL_SECONDS]      defaults: 3600, 15
# Env:   VLLM_API_KEY (required); GLM_URL, or RUNPOD_POD_ID (then
#        https://<id>-8000.proxy.runpod.net is used)
# Exit codes: 0 = ready, 3 = timeout, 4 = key rejected (HTTP 401/403), 2 = bad arguments/setup,
# 1 = VLLM_API_KEY not set.
#
# The elapsed time is measured from the start of this script, so start it together
# with the Pod. If the Pod already answers on the first poll, nothing is logged (it was
# already running); if it was already STARTING, the logged time is only partial.
# Every answer except 200 and 401/403 counts as "not ready yet" (e.g. 502/524 from the
# RunPod proxy while the container boots, 404, 500, connection errors).
set -euo pipefail
: "${VLLM_API_KEY:?Set VLLM_API_KEY (the value of your RunPod Secret)}"

TIMEOUT="${1:-3600}"
INTERVAL="${2:-15}"
case "$TIMEOUT$INTERVAL" in *[!0-9]*) echo "TIMEOUT and INTERVAL must be whole seconds" >&2; exit 2 ;; esac
[ "${#TIMEOUT}" -le 9 ] && [ "${#INTERVAL}" -le 9 ] || { echo "TIMEOUT and INTERVAL must have at most 9 digits" >&2; exit 2; }
TIMEOUT=$((10#$TIMEOUT)); INTERVAL=$((10#$INTERVAL))   # "08" is decimal, not invalid octal
[ "$INTERVAL" -ge "${READY_MIN_INTERVAL:-5}" ] || { echo "INTERVAL must be >= 5 s" >&2; exit 2; }

if [ -n "${GLM_URL:-}" ]; then
  URL="${GLM_URL%/}"
  URL="${URL%/v1}"   # the script appends /v1/models itself
  POD_LABEL="url"    # the URL, not RUNPOD_POD_ID, decides which Pod is measured
elif [ -n "${RUNPOD_POD_ID:-}" ]; then
  URL="https://${RUNPOD_POD_ID}-8000.proxy.runpod.net"
  POD_LABEL="$RUNPOD_POD_ID"
else
  echo "Set GLM_URL (https://POD_ID-8000.proxy.runpod.net) or RUNPOD_POD_ID" >&2
  exit 2
fi

LOG="$(cd "$(dirname "$0")/.." && pwd)/.startup-times.log"
start=$SECONDS
polls=0
echo "Waiting for ${URL}/v1/models (every ${INTERVAL}s, timeout ${TIMEOUT}s). Read-only, Ctrl-C to stop."

while true; do
  set +e
  # The key goes through stdin (--config -) so it never appears in `ps`.
  code="$(curl -sS -o /dev/null --connect-timeout 10 -m 20 -w '%{http_code}' --config - "${URL}/v1/models" 2>/dev/null <<EOT
header = "Authorization: Bearer ${VLLM_API_KEY}"
EOT
  )"
  set -e
  code="${code:-000}"
  elapsed=$((SECONDS - start))
  polls=$((polls + 1))

  case "$code" in
    200)
      printf '\a'
      if [ "$polls" -eq 1 ]; then
        # Answered on the very first poll: the Pod was already up, so this is not a startup time.
        echo "READY on the first poll: the Pod was already running. No startup time recorded."
        exit 0
      fi
      printf 'READY after %dm %02ds (%ds)\n' $((elapsed / 60)) $((elapsed % 60)) "$elapsed"
      printf '%s pod=%s seconds=%d\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$POD_LABEL" "$elapsed" >>"$LOG"
      echo "Logged to $LOG"
      exit 0
      ;;
    401|403)
      echo "HTTP $code: the server rejects VLLM_API_KEY. Check that it equals the RunPod Secret VLLM_API_KEY." >&2
      exit 4
      ;;
    *)
      printf '[%s] %dm %02ds: not ready (HTTP %s)\n' "$(date +%H:%M:%S)" $((elapsed / 60)) $((elapsed % 60)) "$code"
      ;;
  esac

  remaining=$((TIMEOUT - elapsed))
  if [ "$remaining" -le 0 ]; then
    echo "Timeout after ${TIMEOUT}s: vLLM did not answer 200." >&2
    exit 3
  fi
  nap="$INTERVAL"
  [ "$remaining" -ge "$nap" ] || nap="$remaining"
  sleep "$nap"
done
