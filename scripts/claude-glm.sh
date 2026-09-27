#!/usr/bin/env bash
# Wrapper for Claude Code against the pool's running Pod: resolves the current Pod, waits until
# it actually answers, then execs `claude`. Replaces hand-editing GLM_URL/POD_ID before every
# session. It only reads (Pod list, Pod info, one /v1/models probe); it NEVER starts or creates a
# Pod (that stays scripts/start-any.sh, a deliberate, billed step).
#
# Usage: claude-glm.sh [ARGS FOR CLAUDE...]     (all arguments are passed through to `claude`)
#   Which Pod: the single ACTIVE pool Pod (needs RUNPOD_API_KEY), else RUNPOD_POD_ID, else GLM_URL;
#   the choice and the reason are printed, so a stale ID in .env cannot send a session to a
#   stopped Pod. Needs VLLM_API_KEY (the value of your RunPod Secret) and `claude` on PATH.
# Environment: READY_RETRIES / READY_DELAY: how often / how long apart the readiness probe is
#   retried while the endpoint is not yet answering (default 5 / 5s; the RunPod proxy can answer
#   502/524 for a short while after a start).
# Exit codes: 1 = no pool Pod running / endpoint never became ready / several pool Pods active,
#             2 = bad setup (VLLM_API_KEY not set), 127 = `claude` not found on PATH;
#             otherwise this execs into `claude`, so its exit code is claude's own.
set -uo pipefail
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

command -v claude >/dev/null 2>&1 || { echo "claude not found on PATH (see https://docs.claude.com/en/docs/claude-code)" >&2; exit 127; }
[ -n "${VLLM_API_KEY:-}" ] || { echo "Set VLLM_API_KEY (the value of your RunPod Secret)" >&2; exit 2; }

# Which Pod: the single ACTIVE pool Pod (needs RUNPOD_API_KEY), else RUNPOD_POD_ID, else GLM_URL.
resolve_rc=0; pool_resolve_pod "" || resolve_rc=$?
case "$resolve_rc" in
  0)
    POD_ID="$RESOLVED_POD_ID"
    case "$POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$POD_ID' (expected lower-case letters and digits)" >&2; exit 1 ;; esac
    URL="https://${POD_ID}-8000.proxy.runpod.net"
    echo "Pod: $POD_ID (source: $RESOLVED_SOURCE)" >&2
    ;;
  2)
    echo "Several pool Pods are active; set RUNPOD_POD_ID to the one you mean. Active pool Pods:" >&2
    printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r i n st; do [ -z "$i" ] || printf '  %s  %s  %s\n' "$n" "$i" "$st" >&2; done
    exit 1
    ;;
  *)
    if [ -n "${GLM_URL:-}" ]; then
      URL="${GLM_URL%/}"; URL="${URL%/v1}"
      echo "Pod: from GLM_URL ($URL)" >&2
    else
      echo "No pool Pod is running and neither RUNPOD_POD_ID nor GLM_URL is set. Start one first: scripts/start-any.sh (bills the GPU)." >&2
      exit 1
    fi
    ;;
esac

# Readiness probe: with your key, /v1/models must answer 200. Anything else (502/524 while the
# RunPod proxy or the container is still booting, connection errors, ...) is retried a few times.
tries="${READY_RETRIES:-5}"; delay="${READY_DELAY:-5}"; n=0
while true; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 -m 20 --config - "${URL}/v1/models" 2>/dev/null <<EOT
header = "Authorization: Bearer ${VLLM_API_KEY}"
EOT
  )"
  code="${code:-000}"
  [ "$code" = 200 ] && break
  n=$((n + 1))
  if [ "$n" -ge "$tries" ]; then
    echo "Endpoint not ready after $tries tries (last HTTP $code). Still booting? Try scripts/wait-for-ready.sh." >&2
    exit 1
  fi
  echo "Not ready yet (HTTP $code), retrying in ${delay}s ..." >&2
  sleep "$delay"
done
echo "Endpoint ready: $URL" >&2

export ANTHROPIC_BASE_URL="$URL"
export ANTHROPIC_AUTH_TOKEN="$VLLM_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
exec claude --model glm-5.3-flash "$@"
