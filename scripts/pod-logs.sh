#!/usr/bin/env bash
# Streams a Pod's container/system logs live: GET /v2/pods/{id}/logs (Server-Sent Events). Prints
# "<ts> [<source>] <line>" per event as it arrives; anything that is not a recognized SSE data
# frame (an HTTP error body, for example) is printed as-is so nothing is silently swallowed.
# Read-only: never starts, stops or changes anything on the Pod. Runs until the server closes the
# stream or you press Ctrl-C.
#
# Usage: pod-logs.sh [POD_ID] [--source container|system] [--tail N]
#   Which Pod: POD_ID if given; else the single ACTIVE pool Pod (needs RUNPOD_API_KEY); else
#   RUNPOD_POD_ID. If several pool Pods are active, give the POD_ID.
#   --source   container|system (default: both)
#   --tail     historical lines to backfill before the live stream starts (server default 100,
#              max 5000; 0 = no backfill, start live)
# Not through _api.sh: that helper buffers the whole response and has a 60s --max-time, both wrong
# for a long-lived stream; this uses its own curl -N (unbuffered, no timeout). The key goes through
# curl's stdin (--config -, a heredoc), same as _api.sh, so it never appears in `ps` or as an argv
# of any process (a process-substitution/printf intermediary would NOT have that property: its argv
# is visible in `ps` like any other command).
# Exit codes: 0 = the stream ended normally (server closed it); 130 = interrupted (Ctrl-C); other
#   nonzero = curl itself could not connect (its message goes to stderr). An HTTP-level error (e.g.
#   401) is NOT nonzero here -- GET /logs streams either way, so its (non-SSE) response body is
#   printed as-is instead; look at the printed text, not the exit code, for that case.
# Note: run through `make logs`, this is NOT one of the four lock-guarded targets (create/start/
#   pod-start/start-when-free), so a Ctrl-C during `make logs` can leave the underlying `docker run`
#   container behind (Make does not forward signals to a recipe's children -- see the Makefile
#   header). Harmless here (read-only, no billing): find and stop it with
#   `docker ps --filter ancestor=runpod-glm-tools` / `docker kill <id>` if that happens.
set -uo pipefail
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

SOURCE_FILTER=""; TAIL=""; POD_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE_FILTER="${2:-}"; shift 2 ;;
    --tail) TAIL="${2:-}"; shift 2 ;;
    -*) echo "unknown argument: $1 (see the header of this script)" >&2; exit 2 ;;
    *) POD_ARG="$1"; shift ;;
  esac
done
case "$SOURCE_FILTER" in ''|container|system) ;; *) echo "--source must be 'container' or 'system'" >&2; exit 2 ;; esac
if [ -n "$TAIL" ]; then
  case "$TAIL" in *[!0-9]*) echo "--tail must be a whole number" >&2; exit 2 ;; esac
  [ "$TAIL" -le 5000 ] || { echo "--tail must be <= 5000" >&2; exit 2; }
fi

pool_resolve_pod "$POD_ARG"; rc=$?
case "$rc" in
  0) POD_ID="$RESOLVED_POD_ID"; SOURCE="$RESOLVED_SOURCE" ;;
  2)
    echo "Several pool Pods are active; give the POD_ID:" >&2
    printf '%s' "$POOL_MEMBERS" | while IFS=$'\t' read -r i n st; do [ -z "$i" ] || printf '  %s  %s  %s\n' "$n" "$i" "$st" >&2; done
    exit 2
    ;;
  *) echo "Give a POD_ID, or start a pool Pod, or set RUNPOD_POD_ID" >&2; exit 2 ;;
esac
case "$POD_ID" in *[!a-z0-9]*) echo "Invalid Pod ID '$POD_ID' (expected lower-case letters and digits)" >&2; exit 2 ;; esac

qs=""
[ -z "$SOURCE_FILTER" ] || qs="source=${SOURCE_FILTER}"
if [ -n "$TAIL" ]; then [ -z "$qs" ] || qs="${qs}&"; qs="${qs}tail=${TAIL}"; fi
url="${BASE%/}/pods/${POD_ID}/logs"
[ -z "$qs" ] || url="${url}?${qs}"

echo "Streaming logs for Pod $POD_ID (source: $SOURCE). Ctrl-C to stop." >&2

# fd 8/9 closed: curl must never inherit a copy of the pool lock (see _pool.sh); harmless here
# since this script never holds it.
curl -sS -N --connect-timeout 10 --config - "$url" 8>&- 9>&- <<EOT |
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
header = "Accept: text/event-stream"
EOT
python3 -u -c '
import sys, json
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line or line.startswith(":"):
        continue
    if line.startswith("data:"):
        payload = line[len("data:"):].strip()
        if not payload:
            continue
        try:
            ev = json.loads(payload)
            print("%s [%s] %s" % (ev.get("ts", "?"), ev.get("source", "?"), ev.get("line", "")))
            continue
        except Exception:
            pass
    print(line)
'
