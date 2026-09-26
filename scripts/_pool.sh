# Sourced helper (no shebang, not executable): the Pod pool.
# The pool = every Pod whose name STARTS WITH POOL_PREFIX (default: glm-5.3-flash-b300) and that
# is not TERMINATED. Requires _api.sh to be sourced first.
POOL_PREFIX="${POOL_PREFIX:-glm-5.3-flash-b300}"
POOL_MEMBERS=""     # lines "id<TAB>name<TAB>status", most recently started first
POOL_ALL_NAMES=""   # names of ALL Pods in the account (for unique naming), one per line
POOL_ERR=""

# pool_refresh: reload the Pod list. Returns 1 (message in POOL_ERR) if the API call fails.
pool_refresh() {
  local resp parsed kind id name status
  resp="$(api_get /pods 2>&1)" || { POOL_ERR="$resp"; return 1; }
  parsed="$(printf '%s' "$resp" | PREFIX="$POOL_PREFIX" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
pods = d.get("pods") if isinstance(d, dict) else d
if not isinstance(pods, list):
    sys.exit(1)
def clean(v): return " ".join(str(v if v is not None else "").split())
members = []
for p in pods:
    if not isinstance(p, dict):
        continue
    name = clean(p.get("name"))
    # An empty status becomes UNKNOWN (counted as active: fail-safe); case is normalised.
    status = clean(p.get("status")).upper() or "UNKNOWN"
    if status == "TERMINATED":
        continue
    print("N\t-\t%s\t-" % name)
    if name.startswith(os.environ["PREFIX"]):
        members.append((clean(p.get("startedAt")), clean(p.get("id")), name, status))
for started, pid, name, status in sorted(members, key=lambda m: m[0], reverse=True):
    print("M\t%s\t%s\t%s" % (pid, name, status))
')" || { POOL_ERR="unexpected response from GET /pods"; return 1; }
  POOL_MEMBERS=""; POOL_ALL_NAMES=""
  while IFS=$'\t' read -r kind id name status; do
    case "$kind" in
      M) POOL_MEMBERS+="$id"$'\t'"$name"$'\t'"$status"$'\n' ;;
      N) POOL_ALL_NAMES+="$name"$'\n' ;;
    esac
  done <<<"$parsed"
}

# pool_count: number of pool members.
pool_count() { if [ -z "$POOL_MEMBERS" ]; then echo 0; else printf '%s' "$POOL_MEMBERS" | grep -c .; fi; }

# pool_status_active STATUS: 0 if the status means "running or about to run". Fail-safe: EVERYTHING
# except EXITED, ERROR and TERMINATED counts (RUNNING, STARTING, PROVISIONING, and any unknown
# status), so an unexpected status can never lead to a second Pod.
pool_status_active() { case "$1" in EXITED|ERROR|TERMINATED) return 1 ;; *) return 0 ;; esac; }

# pool_active: print the first member whose status is active (see above); 1 if none.
pool_active() {
  local id name status
  while IFS=$'\t' read -r id name status; do
    [ -n "$id" ] || continue
    if pool_status_active "$status"; then printf '%s\t%s\t%s\n' "$id" "$name" "$status"; return 0; fi
  done <<<"$POOL_MEMBERS"
  return 1
}

# pool_candidates: print the members that can be started (EXITED or ERROR), most recent first.
pool_candidates() {
  local id name status
  while IFS=$'\t' read -r id name status; do
    case "$status" in EXITED|ERROR) printf '%s\t%s\t%s\n' "$id" "$name" "$status" ;; esac
  done <<<"$POOL_MEMBERS"
}

# pool_pick_name: an unused name: POOL_PREFIX, else POOL_PREFIX-2, -3, ...
pool_pick_name() {
  local n=1 cand="$POOL_PREFIX"
  while printf '%s' "$POOL_ALL_NAMES" | grep -Fxq -- "$cand"; do
    n=$((n + 1)); cand="${POOL_PREFIX}-${n}"
  done
  printf '%s\n' "$cand"
}

# ---- lock: at most one start/create at a time on this machine (a mkdir lock with the PID inside).
# It cannot protect against runs on other machines (GitHub Actions has its own concurrency group).
POOL_LOCKDIR="${POOL_LOCKDIR:-${TMPDIR:-/tmp}/runpod-glm-pool-$(id -u).lock}"
POOL_LOCK_OWNED=0

# pool_lock_acquire: 0 = lock taken, 1 = another live run holds it.
pool_lock_acquire() {
  local i holder
  for i in 1 2 3; do
    if mkdir "$POOL_LOCKDIR" 2>/dev/null; then
      echo "$$" >"$POOL_LOCKDIR/pid"; POOL_LOCK_OWNED=1; return 0
    fi
    holder="$(cat "$POOL_LOCKDIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then POOL_LOCK_HOLDER="$holder"; return 1; fi
    rm -rf "$POOL_LOCKDIR"   # stale: no PID or the process is gone
  done
  return 1
}
pool_lock_release() { if [ "$POOL_LOCK_OWNED" = 1 ]; then rm -rf "$POOL_LOCKDIR"; POOL_LOCK_OWNED=0; fi; }
