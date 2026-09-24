#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# Stopping releases the GPU (billing stops) but keeps the Pod tied to its machine:
# another user may rent the GPU meanwhile, see README "If the GPU is occupied".
set +e
out="$(api_post "/pods/$RUNPOD_POD_ID/action" '{"action":"stop"}' 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo "pod stop failed for Pod $RUNPOD_POD_ID" >&2
  exit 1
fi

printf '%s' "$out" | python3 -c '
import json, sys
p = json.load(sys.stdin)
print("Pod %s: status=%s" % (p.get("id"), p.get("status")))
'
