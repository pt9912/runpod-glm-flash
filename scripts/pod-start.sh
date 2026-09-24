#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# Starting a Pod bills the GPU (B300: about $7.89/h) from the moment it runs.
# A stopped Pod resumes on its original machine. If another user rented that GPU
# meanwhile, the start fails. The exact error for that case has not been observed
# yet, so no pattern matching happens here: any failure is passed through with a
# pointer to the recovery options. HTTP 409 means the Pod's current status does
# not allow "start" (for example it is already running).
set +e
out="$(api_post "/pods/$RUNPOD_POD_ID/action" '{"action":"start"}' 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  cat >&2 <<HINT

pod start failed for Pod $RUNPOD_POD_ID.
If the GPU on the Pod's machine is occupied, see README "If the GPU is occupied":
  - check stock in the Network Volume's datacenter: scripts/gpu-availability.sh B300 <DATACENTER>
  - redeploy with the same volume: (cd terraform && terraform apply -replace=runpod_pod.glm)
A redeploy changes the Pod ID; update RUNPOD_POD_ID and GLM_URL afterwards.
HINT
  exit 1
fi

# Print only non-sensitive fields; the Pod object also contains env.
printf '%s' "$out" | python3 -c '
import json, sys
p = json.load(sys.stdin)
print("Pod %s: status=%s" % (p.get("id"), p.get("status")))
'
