#!/usr/bin/env bash
# Starts the stopped Pod RUNPOD_POD_ID (this bills the GPU from the moment it runs).
# Exit codes: 0 = started or already running, 1 = failure (auth, unknown Pod, unknown
# outcome, ...), 5 = the GPU on the Pod's machine is occupied (nothing started, nothing
# billed; safe to retry, see scripts/start-when-free.sh), 6 = the Pod could not be read
# (timeout, 5xx, 429...): nothing was sent, safe to retry.
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

# 1. Show which Pod this acts on (a stale RUNPOD_POD_ID would start the wrong one).
set +e
info="$(api_pod_info "$RUNPOD_POD_ID" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$info" >&2
  echo >&2
  api_auth_hint "$info" && exit 1
  case "$(printf '%s' "$info" | head -n1)" in
    "HTTP 404"*)
      echo "Pod $RUNPOD_POD_ID does not exist. Check RUNPOD_POD_ID (a redeploy changes the Pod ID; list the Pods with scripts/v2-smoke.sh)." >&2
      exit 1
      ;;
    *)
      echo "Could not read Pod $RUNPOD_POD_ID (possibly a temporary problem); nothing was started." >&2
      exit 6
      ;;
  esac
fi
IFS=$'\t' read -r name status cost dc <<<"$info"
echo "Target: $name ($RUNPOD_POD_ID), status $status, \$$cost/h, datacenter $dc"
# The Pod's datacenter is the one that matters for stock (the volume is bound to it).
dc_hint="<DATACENTER OF YOUR VOLUME>"
[ "$dc" = "?" ] || dc_hint="$dc"
status_uc="$(printf '%s' "$status" | tr '[:lower:]' '[:upper:]')"
case "$status_uc" in
  RUNNING|STARTING|PROVISIONING)
    echo "Already $status; nothing to do."
    exit 0
    ;;
esac

# 2. Start. This bills the GPU from the moment it runs.
# A stopped Pod resumes on its original machine. If another user rented that GPU
# meanwhile, the API answers (observed 2026-09-24):
#   HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}
# Only that case gets the redeploy advice. 404 = unknown Pod, 409 = the current
# status does not allow "start", 401/403 = API key problems.
set +e
out="$(api_post "/pods/$RUNPOD_POD_ID/action" '{"action":"start"}' 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" >&2
  echo >&2
  api_auth_hint "$out" && exit 1
  first="$(printf '%s' "$out" | head -n1)"
  occupied=0
  case "$first" in
    "HTTP 400"*)
      if printf '%s' "$out" | grep -q "not enough free GPUs"; then
        occupied=1
        cat >&2 <<HINT
The GPU on this Pod's machine is occupied by someone else (nothing was started, nothing is billed).
Options: wait and retry, or redeploy with the same volume; see README "If the GPU is occupied":
  - be notified when a B300 is free there: scripts/wait-for-gpu.sh B300 $dc_hint
  - redeploy with the same volume: scripts/create-pod.sh (dry run first, then --yes)
A redeploy changes the Pod ID; update RUNPOD_POD_ID and GLM_URL afterwards.
HINT
      else
        echo "The API rejected the request (see the message above); nothing was started." >&2
      fi
      ;;
    "HTTP 404"*) echo "Pod $RUNPOD_POD_ID does not exist. Check RUNPOD_POD_ID." >&2 ;;
    "HTTP 409"*) echo "The Pod's current status ($status) does not allow 'start' (it may already be running)." >&2 ;;
    "HTTP "*) echo "pod start failed for Pod $RUNPOD_POD_ID (see the message above)." >&2 ;;
    *) echo "The connection failed while the start request may already have been sent: the outcome is UNKNOWN and the Pod may be starting (and billing). Check before retrying: scripts/v2-smoke.sh" >&2 ;;
  esac
  [ "$occupied" -eq 0 ] || exit 5
  exit 1
fi

printf '%s' "$out" | api_print_pod
