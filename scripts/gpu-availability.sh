#!/usr/bin/env bash
# Read-only: shows per-datacenter stock for a GPU type, so you can see whether
# a B300 is free in the datacenter of your Network Volume before (re)deploying.
# Availability is an ordering hint, not a reservation.
#
# Usage: gpu-availability.sh [GPU_MATCH] [DATACENTER_ID]
#   GPU_MATCH      case-insensitive substring of the GPU id/name (default: B300)
#   DATACENTER_ID  only show this datacenter (e.g. the one your volume lives in)
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
# shellcheck source=scripts/_api.sh
source "$(dirname "$0")/_api.sh"

MATCH="${1:-B300}"
DC="${2:-}"

api_get "/catalog/datacenters?include=GPU_AVAILABILITY" | python3 -c '
import json, sys
match, dc = sys.argv[1].lower(), sys.argv[2]
rows = []
for d in json.load(sys.stdin)["dataCenters"]:
    if dc and d["id"] != dc:
        continue
    for g in d.get("gpuAvailability", []):
        if match in g["id"].lower() or match in g["name"].lower():
            rows.append((d["id"], d["region"], g["name"], g["availability"]))
if not rows:
    print("no datacenter offers a GPU matching %r" % match, file=sys.stderr)
    sys.exit(2)
for r in sorted(rows, key=lambda r: (r[3] == "NONE", r[0])):
    print("%-12s %-14s %-28s %s" % r)
' "$MATCH" "$DC"
