# Sourced helper (no shebang, not executable): RunPod REST v2 calls.
# Requires RUNPOD_API_KEY; BASE defaults to the v2 API.
BASE="${RUNPOD_BASE_URL:-https://api.runpod.io/v2}"

# _api_request METHOD PATH [JSON_BODY] -> prints the response body on 2xx;
# otherwise prints status and body to stderr and returns 1.
# The auth header goes through stdin (--config -) so the key never appears in
# `ps`; the status is checked manually so this works with curl < 7.76
# (no --fail-with-body).
_api_request() {
  local method="$1" path="$2" data="${3:-}" body code
  body="$(mktemp)"
  local -a args=(-sS -o "$body" -w '%{http_code}' -X "$method")
  if [ -n "$data" ]; then
    args+=(-H 'Content-Type: application/json' -d "$data")
  fi
  if ! code="$(curl "${args[@]}" --config - "${BASE%/}${path}" <<EOT
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
EOT
  )"; then
    rm -f "$body"
    return 1
  fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "HTTP $code from ${method} ${BASE%/}${path}" >&2
    cat "$body" >&2
    echo >&2
    rm -f "$body"
    return 1
  fi
  cat "$body"
  rm -f "$body"
}

# api_get PATH: read-only GET.
api_get() { _api_request GET "$1"; }

# api_post PATH JSON_BODY: state-changing POST (used by pod-start/stop).
api_post() { _api_request POST "$1" "$2"; }

# api_auth_hint OUTPUT: if OUTPUT (the captured stderr of a failed call) starts with
# "HTTP 401" or "HTTP 403" (our own message format), print an explanation and
# return 0; otherwise return 1 so the caller can show its own hint.
api_auth_hint() {
  case "$(printf '%s' "$1" | head -n1)" in
    "HTTP 401"*)
      echo "The API key was rejected (invalid or expired). Create a new key in the RunPod console (Settings > API Keys)." >&2
      ;;
    "HTTP 403"*)
      cat >&2 <<'MSG'
The API key is valid but not allowed to do this. Read calls (smoke test, pre-check --online) work
with a read-only key, but starting/stopping/creating Pods needs write access. Create a new API key
in the RunPod console (Settings > API Keys) with write access to Pods (or full access), and put
it in .env. This is a permission problem, not a full GPU.
MSG
      ;;
    *)
      return 1
      ;;
  esac
}
