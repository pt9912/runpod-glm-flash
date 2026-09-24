#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# Starting a Pod bills the GPU (B300: about $7.89/h) from the moment it runs.
# A stopped Pod resumes on its original machine. If another user rented that GPU
# meanwhile, the API answers (observed 2026-09-24):
#   HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}
# That case gets a targeted message below; every other failure is passed through
# with the generic hint. HTTP 409 means the Pod's current status does not allow
# "start" (for example it is already running); 401/403 are key problems.
set +e
out="$(api_post "/pods/$RUNPOD_POD_ID/action" '{"action":"start"}' 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  if printf '%s' "$out" | grep -q "not enough free GPUs"; then
    echo "The GPU on this Pod's machine is occupied by someone else (nothing was started, nothing is billed)." >&2
    echo "Options: wait and retry, or redeploy with the same volume; see README \"If the GPU is occupied\"." >&2
    echo >&2
  fi
  cat >&2 <<HINT

pod start failed for Pod $RUNPOD_POD_ID.
If the GPU on the Pod's machine is occupied, see README "If the GPU is occupied":
  - check stock in the Network Volume's datacenter: scripts/gpu-availability.sh B300 <DATACENTER>
  - redeploy with the same volume: see README (terraform apply -replace=runpod_pod.glm if the Pod is in the
    Terraform state, otherwise plan.sh and terraform apply tfplan)
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
