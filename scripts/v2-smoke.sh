#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
BASE="${RUNPOD_BASE_URL:-https://api.runpod.io/v2}"

body="$(mktemp)"
trap 'rm -f "$body"' EXIT

# Read-only smoke test: proves credentials + v2 routing without creating compute.
# The auth header goes through stdin (--config -) so the key never appears in `ps`,
# and the HTTP status is checked manually so this works with curl < 7.76.
code="$(curl -sS -o "$body" -w '%{http_code}' --config - "${BASE%/}/pods" <<EOF
header = "Authorization: Bearer ${RUNPOD_API_KEY}"
EOF
)"

if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
  echo "HTTP $code from ${BASE%/}/pods" >&2
  cat "$body" >&2
  exit 1
fi

python3 -m json.tool < "$body"
