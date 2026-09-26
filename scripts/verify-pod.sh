#!/usr/bin/env bash
# Read-only check that a Pod matches what this repo intends. Run it right after
# `create-pod.sh` (or after a redeploy): a request can succeed while a field is silently
# dropped (for example the Network Volume), and then the Pod bills without the model on it.
# It prints only non-sensitive facts: env variable NAMES (never values), and for
# VLLM_API_KEY only whether it is a RunPod Secret reference.
#
# Usage: verify-pod.sh [POD_ID]
#   POD_ID              default: RUNPOD_POD_ID
#   EXPECTED_VOLUME_ID  default: NETWORK_VOLUME_ID (optional: without it the volume is not compared)
# Exit codes: 0 = no FAIL (warnings allowed), 1 = at least one FAIL or the Pod could not be read,
#             2 = bad arguments.
set -uo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY}"
HERE="$(dirname "$0")"
# shellcheck source=scripts/_api.sh
source "$HERE/_api.sh"

POD_ID="${1:-${RUNPOD_POD_ID:-}}"
[ -n "$POD_ID" ] || { echo "Give a POD_ID or set RUNPOD_POD_ID" >&2; exit 2; }

VOLUME="${EXPECTED_VOLUME_ID:-${NETWORK_VOLUME_ID:-}}"

resp="$(api_get "/pods/$POD_ID" 2>&1)" || { printf '%s\n' "$resp" >&2; echo "Could not read Pod $POD_ID." >&2; exit 1; }

printf '%s' "$resp" | python3 -c '
import json, sys
pod_id, volume = sys.argv[1], sys.argv[2]
try:
    p = json.load(sys.stdin)
except Exception:
    p = None
if not isinstance(p, dict):
    print("[FAIL] the API returned no Pod object")
    sys.exit(1)
fails = 0
def ok(m):   print("[ ok ] " + m)
def warn(m): print("[WARN] " + m)
def fail(m):
    global fails
    fails += 1
    print("[FAIL] " + m)

print("Pod %s: %s, status %s, datacenter %s, $%s/h" % (pod_id, p.get("name", "?"), p.get("status", "?"), p.get("dataCenterId", "?"), p.get("cost", "?")))

# GPU
g = p.get("gpu") or {}
if g.get("count") == 1 and "B300" in str(g.get("id", "")):
    ok("GPU: 1x %s" % g.get("id"))
else:
    fail("GPU is %r x %r, expected 1x B300" % (g.get("count"), g.get("id")))

# Network Volume (the important one: a silently dropped volume means no model on the Pod)
nets = ((p.get("mounts") or {}).get("network")) or []
if not nets:
    fail("no Network Volume is mounted (mounts=%s): the model would be missing" % json.dumps(p.get("mounts")))
else:
    n = nets[0]
    if n.get("path") != "/workspace":
        fail("Network Volume is mounted at %r, expected /workspace" % n.get("path"))
    elif volume and n.get("volumeId") != volume:
        fail("Network Volume is %r, expected %r" % (n.get("volumeId"), volume))
    else:
        ok("Network Volume %s mounted at /workspace%s" % (n.get("volumeId"), "" if volume else " (expected id unknown, not compared)"))

# Ports
ports = p.get("ports") or []
(ok if "8000/http" in ports else fail)("ports: %s%s" % (", ".join(ports) or "none", "" if "8000/http" in ports else " (8000/http missing)"))

# Env: names only. VLLM_API_KEY must be a Secret reference, never empty or a literal value.
env = p.get("env") or {}
print("       env variable names: %s" % ", ".join(sorted(env)))
v = env.get("VLLM_API_KEY")
if v is None or v == "":
    fail("VLLM_API_KEY is not set: the API would be unprotected")
elif "RUNPOD_SECRET_" in v:
    ok("VLLM_API_KEY is a RunPod Secret reference")
else:
    fail("VLLM_API_KEY holds a literal value, not a RunPod Secret reference (the key would be stored in the Pod definition)")
if env.get("HF_HUB_OFFLINE") == "1" and "HF_TOKEN" in env:
    warn("HF_TOKEN is set although HF_HUB_OFFLINE=1 (not needed offline)")
if env.get("HF_HOME") != "/workspace/huggingface" or env.get("VLLM_CACHE_ROOT") != "/workspace/vllm-cache":
    warn("HF_HOME / VLLM_CACHE_ROOT do not point to /workspace (caches would not persist)")

# vLLM arguments
cmd = p.get("cmd")
argstr = " ".join(cmd) if isinstance(cmd, list) and cmd else str(p.get("args") or "")
for needle, level, what in (("--max-model-len 1048576", fail, "1M context"),
                            ("--served-model-name glm-5.3-flash", fail, "served model name"),
                            ("--kv-cache-dtype fp8", warn, "FP8 KV cache"),
                            ("--max-num-seqs 6", warn, "max-num-seqs 6"),
                            ("mtp", warn, "MTP speculative decoding")):
    if needle in argstr:
        ok("args: %s" % what)
    else:
        level("args: %s not found" % what)

print("Result: %s" % ("FAIL (%d)" % fails if fails else "no blocking problem"))
sys.exit(1 if fails else 0)
' "$POD_ID" "$VOLUME"
