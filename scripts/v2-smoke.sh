#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
BASE="${RUNPOD_BASE_URL:-https://api.runpod.io/v2}"
# Read-only smoke test: proves credentials + v2 routing without creating compute.
curl --fail-with-body -sS \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  "${BASE%/}/pods" | python3 -m json.tool
