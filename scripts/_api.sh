# Sourced helper (no shebang, not executable): read-only RunPod REST v2 GET.
# Requires RUNPOD_API_KEY; BASE defaults to the v2 API.
BASE="${RUNPOD_BASE_URL:-https://api.runpod.io/v2}"

# api_get PATH -> prints the response body on 2xx; otherwise prints status and
# body to stderr and returns 1. The auth header goes through stdin (--config -)
# so the key never appears in `ps`; the status is checked manually so this
# works with curl < 7.76 (no --fail-with-body).
api_get() {
  local path="$1" body code
  body="$(mktemp)"
  if ! code="$(curl -sS -o "$body" -w '%{http_code}' --config - "${BASE%/}${path}" <<EOT
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
EOT
  )"; then
    rm -f "$body"
    return 1
  fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "HTTP $code from ${BASE%/}${path}" >&2
    cat "$body" >&2
    rm -f "$body"
    return 1
  fi
  cat "$body"
  rm -f "$body"
}
