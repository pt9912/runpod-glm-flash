#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# Read-only smoke test: proves credentials + v2 routing without creating compute.
# Capture first so an HTTP error is not followed by a json.tool parse error.
response="$(api_get /pods)"
printf '%s\n' "$response" | python3 -m json.tool
