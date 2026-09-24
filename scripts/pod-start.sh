#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
command -v runpodctl >/dev/null || { echo "runpodctl is required" >&2; exit 1; }

# A stopped Pod resumes on its original machine. If another user rented that GPU
# meanwhile, the start fails. The exact error text/exit code for that case has not
# been observed yet, so no pattern matching happens here: any failure is passed
# through with the original exit code plus a pointer to the recovery options.
# Once the real "GPU occupied" output is known, branch on it below.
set +e
out="$(runpodctl pod start "$RUNPOD_POD_ID" 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  cat >&2 <<EOF

pod start failed (exit $rc) for Pod $RUNPOD_POD_ID.
If the GPU on the Pod's machine is occupied, see README "If the GPU is occupied":
  - check stock in the Network Volume's datacenter: scripts/gpu-availability.sh
  - redeploy with the same volume: (cd terraform && terraform apply -replace=runpod_pod.glm)
A redeploy changes the Pod ID; update RUNPOD_POD_ID and GLM_URL afterwards.
EOF
  exit "$rc"
fi

printf '%s\n' "$out"
