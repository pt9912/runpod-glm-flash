#!/usr/bin/env bash
# Gets ONE Pod of the pool running: first tries to start the stopped pool Pods one after the
# other (each on its own machine; a failed try costs nothing), and if none can start, creates
# a new Pod (any machine with a free B300) while the pool is smaller than POOL_MAX. It never
# lets two pool Pods run: if one is already RUNNING/STARTING/PROVISIONING it does nothing.
#
# Pool = every Pod whose name starts with POOL_PREFIX (default glm-5.3-flash-b300), not TERMINATED.
# New Pods get unique names (glm-5.3-flash-b300, glm-5.3-flash-b300-2, ...). Why restart before
# creating: the measured restart on the old machine (5:56 min) was faster than a new Pod (10:09 min).
#
# A SUCCESS BILLS THE GPU (B300: about $7.89/h) from that moment on. A failed try creates or starts
# nothing. Only "GPU occupied"/"no capacity" (exit 5) and a temporarily unreadable Pod (exit 6)
# are retried; anything else stops at once, so a possibly started or created Pod is never
# retried. If a created Pod FAILS verification, the script stops and tells you to terminate it.
#
# Usage: start-any.sh [--no-create] [--dry-run] [--wait] [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]
#   MAX_WAIT_SECONDS  attempts begin for at most this long (default 1200); a running attempt may finish
#                     about 2 minutes later.   INTERVAL_SECONDS  between rounds, >= 30 (default 30)
#   --no-create  only start existing Pods, never create one
#   --dry-run    show the pool and what would be tried; start and create nothing
#   --wait       afterwards run wait-for-ready.sh for the running Pod (measures the time to ready)
# Environment: POOL_PREFIX (default glm-5.3-flash-b300), POOL_MAX (default 6), NETWORK_VOLUME_ID etc. as
#   for create-pod.sh
#
# Exit codes: 0 = a pool Pod is running (started, created, or already running), 3 = gave up,
#   130 = interrupted, 2 = bad arguments, 1 = any other failure (message shown; a created Pod that
#   failed verification counts here).
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

CREATE=1; DRY=0; WAIT=0; NUMS=()
for a in "$@"; do
  case "$a" in
    --no-create) CREATE=0 ;; --dry-run) DRY=1 ;; --wait) WAIT=1 ;;
    -*) echo "unknown argument: $a (see the header of this script)" >&2; exit 2 ;;
    *) NUMS+=("$a") ;;
  esac
done
[ "${#NUMS[@]}" -le 2 ] || { echo "too many arguments" >&2; exit 2; }
MAX_WAIT="${NUMS[0]:-1200}"; INTERVAL="${NUMS[1]:-30}"; POOL_MAX="${POOL_MAX:-6}"
case "$MAX_WAIT$INTERVAL$POOL_MAX" in ''|*[!0-9]*) echo "MAX_WAIT_SECONDS, INTERVAL_SECONDS and POOL_MAX must be whole numbers" >&2; exit 2 ;; esac
[ "${#MAX_WAIT}" -le 9 ] && [ "${#INTERVAL}" -le 9 ] && [ "${#POOL_MAX}" -le 3 ] || { echo "numbers too long" >&2; exit 2; }
MAX_WAIT=$((10#$MAX_WAIT)); INTERVAL=$((10#$INTERVAL)); POOL_MAX=$((10#$POOL_MAX))
[ "$INTERVAL" -ge "${START_MIN_INTERVAL:-30}" ] || { echo "INTERVAL must be >= 30 s (API rate limit)" >&2; exit 2; }
[ "$POOL_MAX" -ge 1 ] || { echo "POOL_MAX must be >= 1" >&2; exit 2; }

tmp="$(mktemp)"; child=""
trap 'rm -f "$tmp"' EXIT
on_signal() {
  # Job cancelled: stop the running attempt (prevents a request that has not been sent yet), but say
  # clearly that one that was already sent cannot be undone.
  [ -z "$child" ] || kill -TERM -- "-$child" 2>/dev/null
  echo >&2
  echo "Interrupted. If a start or create request had already been sent, a Pod may be starting or exist (and bill): check with scripts/v2-smoke.sh." >&2
  exit 130
}
trap on_signal INT TERM

# run_child CMD...: run in its own process group; sets RC and OUT.
run_child() {
  set -m
  "$@" >"$tmp" 2>&1 </dev/null &   # stdin closed: a child must never eat the lines of the loop that calls us
  child=$!
  set +m
  wait "$child"; RC=$?; child=""
  OUT="$(cat "$tmp")"
}

finish() {   # finish ID NAME HOW
  echo
  echo "Running Pod: $2 ($1) $3"
  echo "  URL: https://$1-8000.proxy.runpod.net"
  echo "  Use: RUNPOD_POD_ID=$1   GLM_URL=https://$1-8000.proxy.runpod.net"
  if [ "$WAIT" -eq 1 ]; then
    RUNPOD_POD_ID="$1" "$HERE/wait-for-ready.sh" "${READY_TIMEOUT:-3600}" 10
    exit $?
  fi
  exit 0
}

# ---------------------------------------------------------------- dry run
if [ "$DRY" -eq 1 ]; then
  pool_refresh || { printf '%s\n' "$POOL_ERR" >&2; echo "Could not list Pods." >&2; exit 1; }
  echo "Pool '$POOL_PREFIX*': $(pool_count) of $POOL_MAX"
  printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r id name status; do [ -z "$id" ] || printf '  %-28s %-16s %s\n' "$name" "$id" "$status"; done
  if act="$(pool_active)"; then
    IFS=$'\t' read -r id name status <<<"$act"; echo "DRY RUN: '$name' ($id) is already $status; nothing would be done."; exit 0
  fi
  echo "DRY RUN: would try to start, in this order:"
  pool_candidates | while IFS=$'\t' read -r id name status; do printf '  %s (%s)\n' "$name" "$id"; done
  if [ "$CREATE" -eq 0 ]; then echo "  (--no-create: no new Pod)"
  elif [ "$(pool_count)" -ge "$POOL_MAX" ]; then echo "  no new Pod: the pool is full ($POOL_MAX)"
  else echo "  then create a new Pod named '$(pool_pick_name)'"; fi
  echo "DRY RUN: nothing was started or created."
  exit 0
fi

# ---------------------------------------------------------------- main loop
start=$SECONDS; attempt=0; read_failures=0; full_noted=0
echo "Getting a '$POOL_PREFIX*' Pod running (attempts begin for up to ${MAX_WAIT}s, every ${INTERVAL}s; pool max $POOL_MAX; create: $([ "$CREATE" -eq 1 ] && echo yes || echo no))."
while true; do
  if [ "$attempt" -gt 0 ] && [ $((SECONDS - start)) -ge "$MAX_WAIT" ]; then
    echo "Gave up after ${MAX_WAIT}s and $attempt round(s): no pool Pod could be started or created. Nothing is running." >&2
    exit 3
  fi
  attempt=$((attempt + 1))

  if ! pool_refresh; then
    read_failures=$((read_failures + 1))
    printf '%s\n' "$POOL_ERR" >&2
    if [ "$read_failures" -ge 10 ]; then echo "The Pod list could not be read 10 times in a row; giving up. Nothing was started." >&2; exit 1; fi
    echo "[$(date +%H:%M:%S)] round $attempt: could not read the Pod list (temporary?), nothing sent"
  else
    read_failures=0
    # Guard: never a second Pod.
    if act="$(pool_active)"; then IFS=$'\t' read -r id name status <<<"$act"; finish "$id" "$name" "(already $status, nothing started)"; fi

    # 1. Restart existing Pods, most recently used first.
    started=""
    while IFS=$'\t' read -r id name status; do
      [ -n "$id" ] || continue
      run_child env RUNPOD_POD_ID="$id" "$HERE/pod-start.sh"
      case "$RC" in
        0) finish "$id" "$name" "(restarted)" ;;
        5) echo "[$(date +%H:%M:%S)] round $attempt: '$name' ($id): its machine is occupied" ;;
        6) echo "[$(date +%H:%M:%S)] round $attempt: '$name' ($id): could not be read, skipped" ;;
        *) printf '%s\n' "$OUT" >&2; echo "Starting '$name' ($id) failed (exit $RC); stopping, nothing else is tried." >&2; exit "$RC" ;;
      esac
    done < <(pool_candidates)

    # 2. Create a new Pod (any machine with a free B300) while the pool has room.
    if [ "$CREATE" -eq 1 ]; then
      if pool_refresh && [ "$(pool_count)" -lt "$POOL_MAX" ]; then
        if act="$(pool_active)"; then IFS=$'\t' read -r id name status <<<"$act"; finish "$id" "$name" "(already $status, nothing created)"; fi
        newname="$(pool_pick_name)"
        run_child env POD_NAME="$newname" "$HERE/create-pod.sh" --yes
        case "$RC" in
          0)
            printf '%s\n' "$OUT"
            newid="$(printf '%s\n' "$OUT" | sed -n 's/^Created Pod \([^ ]*\)\. It is billing now\.$/\1/p' | head -n1)"
            if [ -z "$newid" ]; then   # fall back to a lookup by name
              pool_refresh && newid="$(printf '%s' "$POOL_MEMBERS" | awk -F'\t' -v n="$newname" '$2 == n { print $1; exit }')"
            fi
            finish "${newid:-?}" "$newname" "(newly created)"
            ;;
          5) echo "[$(date +%H:%M:%S)] round $attempt: no capacity for a new Pod ('$newname')" ;;
          3) echo "[$(date +%H:%M:%S)] round $attempt: the name '$newname' was taken meanwhile; picking another next round" ;;
          *)
            printf '%s\n' "$OUT" >&2
            if printf '%s' "$OUT" | grep -q "^Created Pod "; then
              echo "A Pod '$newname' WAS created but did not pass verification, and it is billing: terminate it (see above). Nothing else is tried." >&2
            else
              echo "Creating '$newname' failed (exit $RC); stopping." >&2
            fi
            exit 1
            ;;
        esac
      elif [ "$(pool_count)" -ge "$POOL_MAX" ] && [ "$full_noted" -eq 0 ]; then
        echo "The pool is full ($POOL_MAX Pods): no new Pod is created; only restarting is tried. Terminate an unused one (scripts/pod-terminate.sh) to make room."
        full_noted=1
      fi
    fi
  fi

  remaining=$((MAX_WAIT - (SECONDS - start)))
  [ "$remaining" -gt 0 ] || continue   # the loop head gives up
  nap="$INTERVAL"; [ "$remaining" -ge "$nap" ] || nap="$remaining"
  sleep "$nap"
done
