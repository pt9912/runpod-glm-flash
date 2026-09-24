#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_POD_ID:?Set RUNPOD_POD_ID}"
command -v runpodctl >/dev/null || { echo "runpodctl is required" >&2; exit 1; }
runpodctl pod start "$RUNPOD_POD_ID"
