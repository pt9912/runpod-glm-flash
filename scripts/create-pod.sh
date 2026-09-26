#!/usr/bin/env bash
# Creates the GLM-5.3-Flash Pod through the documented REST v2 API (POST /v2/pods) and then
# verifies it with scripts/verify-pod.sh. Every field is explicit and checked afterwards. (Terraform
# was dropped: provider 1.0.8 did not send gpuTypeId, ports, dockerArgs or startSsh and produced a wrong
# Pod, see the README.)
#
# DEFAULT IS A DRY RUN: it prints the request and creates nothing. Add --yes to create.
# A created Pod BILLS the GPU at once (B300: about $7.89/h) until you stop or terminate it.
#
# Usage: create-pod.sh [--yes] [--online] [--ssh] [--force] [--terminate-on-fail]
#   --yes      really create the Pod
#   --force    create even if a Pod of the pool (name starts with POOL_PREFIX) is already running/active
#              (default: refuse, because two pool Pods must never run at once)
#   --terminate-on-fail   if the created Pod fails verification, terminate it (default: stop it and
#              rename it to failed-<name>-<id>, which takes it out of the pool and keeps it for inspection)
#   --online   allow model downloads: HF_HUB_OFFLINE is not set and the HF_TOKEN secret is injected
#   --ssh      also expose 22/tcp and start ssh (default: off, only 8000/http is exposed). Needs SSH public
#              keys registered in your RunPod account and an sshd in the image (not verified for this image).
#              The environment variable CREATE_POD_SSH=1 does the same (start-any.sh passes it on).
# Environment (all optional):
#   NETWORK_VOLUME_ID   REQUIRED: the ID of your Network Volume (put it in .env)
#   POD_NAME            default: glm-5.3-flash-b300
#   GPU_ID              default: NVIDIA B300 SXM6 AC
#   DATACENTER          default: the datacenter of the Network Volume (required to place the Pod there)
#   VLLM_SECRET_NAME / HF_SECRET_NAME   RunPod Secret names (defaults VLLM_API_KEY / HF_TOKEN)
#   CONTAINER_DISK_GB   default: 50
#
# Exit codes: 0 = dry run done, or Pod created and verified; 1 = failure, or the Pod was created
# but FAILED verification (it is then stopped and renamed, or terminated; see the messages);
# 2 = bad arguments/setup; 3 = a Pod with this name exists, or a pool Pod is active (nothing
# created); 4 = another start/create is in progress on this machine (nothing created);
# 5 = no capacity (nothing created).
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"
# shellcheck source=scripts/_pool.sh
source "$HERE/_pool.sh"

YES=0; ONLINE=0; SSH=0; FORCE=0; TERMINATE_ON_FAIL=0
[ "${CREATE_POD_SSH:-0}" != 1 ] || SSH=1
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;; --online) ONLINE=1 ;; --ssh) SSH=1 ;; --force) FORCE=1 ;; --terminate-on-fail) TERMINATE_ON_FAIL=1 ;;
    *) echo "unknown argument: $a (see the header of this script)" >&2; exit 2 ;;
  esac
done

VOLUME="${NETWORK_VOLUME_ID:-}"
[ -n "$VOLUME" ] || { echo "Set NETWORK_VOLUME_ID (the ID of your Network Volume) in .env" >&2; exit 2; }
POD_NAME="${POD_NAME:-glm-5.3-flash-b300}"
GPU_ID="${GPU_ID:-NVIDIA B300 SXM6 AC}"
DISK="${CONTAINER_DISK_GB:-50}"
case "$DISK" in ''|*[!0-9]*) echo "CONTAINER_DISK_GB must be a whole number" >&2; exit 2 ;; esac

# 1. The Pod must be placed in the volume's datacenter.
DC="${DATACENTER:-}"
if [ -z "$DC" ]; then
  vol="$(api_get "/network-volumes/$VOLUME" 2>&1)" || { printf '%s\n' "$vol" >&2; echo "Could not read Network Volume $VOLUME." >&2; exit 1; }
  DC="$(printf '%s' "$vol" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("dataCenter") or d.get("dataCenterId") or "")' 2>/dev/null)"
  [ -n "$DC" ] || { echo "Could not determine the datacenter of volume $VOLUME; set DATACENTER." >&2; exit 1; }
fi

# 2. Only one create at a time on this machine (start-any.sh holds the lock and sets POOL_LOCK_HELD).
if [ "$YES" -eq 1 ] && [ "${POOL_LOCK_HELD:-0}" != 1 ]; then
  trap pool_lock_release EXIT
  pool_lock_acquire || { echo "Another start/create is in progress on this machine (PID ${POOL_LOCK_HOLDER:-?}, lock $POOL_LOCKDIR). Nothing was created." >&2; exit 4; }
fi

# 3. Refuse to create a duplicate name, and (without --force) a second active Pod of the pool.
pool_refresh || { printf '%s\n' "$POOL_ERR" >&2; echo "Could not list Pods." >&2; exit 1; }
if printf '%s' "$POOL_ALL_NAMES" | grep -Fxq -- "$POD_NAME"; then
  echo "A Pod named '$POD_NAME' already exists." >&2
  echo "Nothing was created. Terminate it (scripts/pod-terminate.sh), or set POD_NAME." >&2
  exit 3
fi
if [ "$FORCE" -ne 1 ] && act="$(pool_active)"; then
  IFS=$'\t' read -r a_id a_name a_status <<<"$act"
  echo "A pool Pod is already active: '$a_name' ($a_id), status $a_status. Two pool Pods must not run at once." >&2
  echo "Nothing was created. Stop it (scripts/stop-any.sh), or use --force if you really want a second one." >&2
  exit 3
fi

# 3. Build the request body (no secret values: only RunPod Secret references).
body="$(POD_NAME="$POD_NAME" GPU_ID="$GPU_ID" VOLUME="$VOLUME" DC="$DC" DISK="$DISK" ONLINE="$ONLINE" SSH="$SSH" \
  VSEC="${VLLM_SECRET_NAME:-VLLM_API_KEY}" HSEC="${HF_SECRET_NAME:-HF_TOKEN}" python3 -c '
import json, os
e = os.environ
env = {
    "HF_HOME": "/workspace/huggingface",
    "HF_HUB_CACHE": "/workspace/huggingface/hub",
    "HF_XET_HIGH_PERFORMANCE": "1",
    "CUDA_VISIBLE_DEVICES": "0",
    "VLLM_ENGINE_READY_TIMEOUT_S": "3600",
    "VLLM_CACHE_ROOT": "/workspace/vllm-cache",
    "VLLM_API_KEY": "{{ RUNPOD_SECRET_%s }}" % e["VSEC"],
}
if e["ONLINE"] == "1":
    env["HF_TOKEN"] = "{{ RUNPOD_SECRET_%s }}" % e["HSEC"]
else:
    env["HF_HUB_OFFLINE"] = "1"
# The image supplies the `vllm serve` entrypoint; cmd (exec form) holds its arguments.
cmd = ["nota-ai/GLM-5.3-Flash-Nota-NVFP4", "--served-model-name", "glm-5.3-flash",
       "--host", "0.0.0.0", "--port", "8000", "--tensor-parallel-size", "1",
       "--max-model-len", "1048576", "--kv-cache-dtype", "fp8", "--enable-chunked-prefill",
       "--max-num-batched-tokens", "8192", "--max-num-seqs", "6",
       "--tool-call-parser", "glm47", "--reasoning-parser", "glm45", "--enable-auto-tool-choice",
       "--safetensors-load-strategy", "prefetch", "--gpu-memory-utilization", "0.96",
       "--speculative-config", "{\"method\":\"mtp\",\"num_speculative_tokens\":5}"]
body = {
    "name": e["POD_NAME"],
    "image": "vllm/vllm-openai:glm53-flash",
    "cmd": cmd,
    "env": env,
    "ports": ["8000/http"] + (["22/tcp"] if e["SSH"] == "1" else []),
    "disk": int(e["DISK"]),
    "cloud": "SECURE",
    "gpu": {"id": e["GPU_ID"], "count": 1},
    "mounts": {"network": [{"volumeId": e["VOLUME"], "path": "/workspace"}]},
    "dataCenterIds": [e["DC"]],
    "startSsh": e["SSH"] == "1",
}
print(json.dumps(body))
')"

echo "Pod to create: $POD_NAME | 1x $GPU_ID | datacenter $DC | volume $VOLUME on /workspace | disk ${DISK} GB | ssh $([ "$SSH" = 1 ] && echo on || echo off) | $([ "$ONLINE" = 1 ] && echo "downloads allowed (HF_TOKEN secret)" || echo "offline mode")"
printf '%s' "$body" | python3 -m json.tool | sed 's/^/  /'

if [ "$YES" -ne 1 ]; then
  echo
  echo "Stock of $GPU_ID in $DC (a hint, not a reservation):"
  "$HERE/gpu-availability.sh" "$GPU_ID" "$DC" 2>&1 | sed 's/^/  /'
  echo
  echo "DRY RUN: nothing was created. Add --yes to create the Pod (it bills the GPU immediately)."
  exit 0
fi

# 4. Create. Never retried automatically: a request that may have arrived must not be sent twice.
out="$(api_post /pods "$body" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  case "$(printf '%s' "$out" | head -n1)" in
    "HTTP 400"*)
      # Only the "no capacity" answer is retryable. (Observed: "There are no longer any instances
      # available with the requested specifications.") Any other 400 is a rule violation.
      if printf '%s' "$out" | grep -qiE "instances available|no capacity|out of capacity"; then
        echo "There is no capacity for $GPU_ID in $DC right now. Nothing was created (see the message above). Try again later: scripts/wait-for-gpu.sh B300 $DC" >&2; exit 5
      fi
      echo "The API rejected the request (see the message above). Nothing was created." >&2; exit 1 ;;
    "HTTP 402"*) echo "Insufficient balance. Nothing was created." >&2; exit 1 ;;
    "HTTP 422"*) echo "The request body failed validation (see above). Nothing was created." >&2; exit 1 ;;
    "HTTP 429"*|"HTTP 5"*) echo "The API answered with a server error or is throttling. Whether a Pod was created is NOT certain: check scripts/v2-smoke.sh before retrying." >&2; exit 1 ;;
    "HTTP "*)    echo "Pod creation failed (see above)." >&2; exit 1 ;;
    *) echo "The connection failed while the request may already have been sent: the outcome is UNKNOWN and a Pod may exist (and bill). Check before retrying: scripts/v2-smoke.sh" >&2; exit 1 ;;
  esac
fi

new_id="$(printf '%s' "$out" | python3 -c 'import json,sys
try:
    p = json.load(sys.stdin); print(p.get("id", "") if isinstance(p, dict) else "")
except Exception:
    print("")')"
if [ -z "$new_id" ]; then
  echo "The request was accepted but the response had no Pod id. A Pod may exist and bill: check scripts/v2-smoke.sh" >&2
  exit 1
fi
echo
echo "Created Pod $new_id. It is billing now."
echo "Add this to your .env:  RUNPOD_POD_ID=$new_id"
echo
echo "Verifying (read-only) ..."
if EXPECTED_VOLUME_ID="$VOLUME" "$HERE/verify-pod.sh" "$new_id"; then
  echo
  echo "Next: set RUNPOD_POD_ID in .env, then scripts/wait-for-ready.sh (needs VLLM_API_KEY)."
  exit 0
fi
echo >&2
echo "VERIFICATION FAILED: Pod $new_id is not what was intended, and it is billing." >&2
if [ "$TERMINATE_ON_FAIL" -eq 1 ]; then
  if term_out="$(api_post "/pods/$new_id/action" '{"action":"terminate"}' 2>&1)"; then
    echo "It was TERMINATED (--terminate-on-fail); the Network Volume is untouched." >&2
  else
    printf '%s\n' "$term_out" >&2
    echo "TERMINATING FAILED. The Pod is still billing: RUNPOD_POD_ID=$new_id scripts/pod-terminate.sh --yes" >&2
  fi
  exit 1
fi
# Default: stop it first (ends the GPU billing), then rename it so it leaves the pool. It is kept for inspection.
failed_name="failed-${POD_NAME}-${new_id}"
if ! api_post "/pods/$new_id/action" '{"action":"stop"}' >/dev/null 2>&1; then
  echo "STOPPING FAILED. The Pod is still billing: RUNPOD_POD_ID=$new_id scripts/pod-terminate.sh --yes" >&2
  exit 1
fi
echo "It was STOPPED (billing ended)." >&2
if api_patch "/pods/$new_id" "$(FAILED_NAME="$failed_name" python3 -c 'import json,os; print(json.dumps({"name": os.environ["FAILED_NAME"]}))')" >/dev/null 2>&1; then
  echo "It was renamed to '$failed_name', so it is no longer part of the pool. Inspect it, then remove it: RUNPOD_POD_ID=$new_id scripts/pod-terminate.sh --yes" >&2
else
  echo "Renaming failed: the stopped Pod still carries the pool name and could be restarted by start-any.sh. Remove it: RUNPOD_POD_ID=$new_id scripts/pod-terminate.sh --yes" >&2
fi
exit 1
