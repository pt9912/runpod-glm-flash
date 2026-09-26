#!/usr/bin/env bash
# Stops every RUNNING/STARTING/PROVISIONING Pod of the pool (name starts with POOL_PREFIX, default
# glm-5.3-flash-b300). Stopping ends the GPU billing. Use this instead of pod-stop.sh when the
# running Pod's ID changes (pool). Nothing to do if no pool Pod is running.
#
# Usage: stop-any.sh [--dry-run]
# Exit codes: 0 = done (or nothing to stop), 1 = at least one stop failed, 2 = bad arguments.
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

DRY=0
for a in "$@"; do
  case "$a" in --dry-run) DRY=1 ;; *) echo "unknown argument: $a" >&2; exit 2 ;; esac
done
pool_refresh || { printf '%s\n' "$POOL_ERR" >&2; echo "Could not list Pods; nothing was stopped." >&2; exit 1; }

fail=0; found=0
while IFS=$'\t' read -r id name status; do
  [ -n "$id" ] || continue
  case "$status" in RUNNING|STARTING|PROVISIONING) ;; *) continue ;; esac
  found=1
  if [ "$DRY" -eq 1 ]; then echo "DRY RUN: would stop '$name' ($id), status $status"; continue; fi
  RUNPOD_POD_ID="$id" "$HERE/pod-stop.sh" || fail=1
done <<<"$POOL_MEMBERS"
[ "$found" -eq 1 ] || echo "No running '$POOL_PREFIX*' Pod; nothing to stop."
exit "$fail"
