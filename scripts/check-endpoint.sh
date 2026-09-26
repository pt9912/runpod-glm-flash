#!/usr/bin/env bash
# Read-only check of a running Pod through the RunPod HTTPS proxy (no SSH needed):
#   1. WITHOUT a key the API must answer 401 (if it answers 200, the server is OPEN to everyone),
#   2. WITH your key it must answer 200 (a 401 means the server runs with a different key, for
#      example an unresolved RunPod Secret placeholder after a mistyped secret name),
#   3. the served model is glm-5.3-flash with the full 1,048,576 context.
# Prints only statuses, the model id and the context length, never a key.
#
# Usage: check-endpoint.sh [POD_ID]      POD_ID defaults to RUNPOD_POD_ID; GLM_URL is used only if there is no
#        Pod ID at all. Needs VLLM_API_KEY (the value of your RunPod Secret).
# Notes: /health, /metrics and /docs are not protected by vLLM, so they are not used for the negative test.
# Exit codes: 0 = all checks passed, 1 = at least one FAIL, 2 = bad arguments/setup,
#             3 = the endpoint does not answer yet (Pod still booting, 502/524/timeout).
set -uo pipefail
: "${VLLM_API_KEY:?Set VLLM_API_KEY (the value of your RunPod Secret)}"

POD_ID="${1:-${RUNPOD_POD_ID:-}}"
# A Pod ID (argument, else RUNPOD_POD_ID) wins over GLM_URL: an old GLM_URL left in .env must not
# redirect the check to another Pod.
if [ -n "$POD_ID" ]; then
  URL="https://${POD_ID}-8000.proxy.runpod.net"
elif [ -n "${GLM_URL:-}" ]; then
  URL="${GLM_URL%/}"; URL="${URL%/v1}"
else
  echo "Give a POD_ID, or set RUNPOD_POD_ID or GLM_URL" >&2; exit 2
fi

fails=0
ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; fails=$((fails + 1)); }

# get PATH [withkey]: sets CODE and BODY. The key goes through stdin (--config -), never onto the command line.
get() {
  local resp
  if [ "${2:-}" = withkey ]; then
    resp="$(curl -sS --connect-timeout 10 -m 20 -w $'\n%{http_code}' --config - "${URL}$1" 2>/dev/null <<EOT
header = "Authorization: Bearer ${VLLM_API_KEY}"
EOT
    )"
  else
    resp="$(curl -sS --connect-timeout 10 -m 20 -w $'\n%{http_code}' "${URL}$1" 2>/dev/null)"
  fi
  CODE="${resp##*$'\n'}"; CODE="${CODE:-000}"
  BODY="${resp%$'\n'*}"
}

echo "Endpoint: ${URL}/v1/models"

get /v1/models
case "$CODE" in
  401|403) ok "without a key: HTTP $CODE (the API is protected)" ;;
  200)     fail "WITHOUT a key the API answers 200: the server is OPEN to everyone. Stop it (scripts/stop-any.sh) and check the RunPod Secret VLLM_API_KEY" ;;
  000|404|502|503|504|524)
    echo "[....] the endpoint does not answer yet (HTTP $CODE): the Pod may still be booting. Try scripts/wait-for-ready.sh."
    exit 3 ;;
  *)       warn "without a key: unexpected HTTP $CODE" ;;
esac

get /v1/models withkey
case "$CODE" in
  200) ok "with your key: HTTP 200" ;;
  401|403) fail "with your key: HTTP $CODE. The server runs with a DIFFERENT key (an unresolved secret placeholder or a mistyped secret name?)" ;;
  *)   fail "with your key: unexpected HTTP $CODE" ;;
esac

if [ "$CODE" = 200 ]; then
  info="$(printf '%s' "$BODY" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)["data"][0]
    print("%s\t%s\t%s" % (m.get("id", "?"), m.get("max_model_len", "?"), m.get("root", "?")))
except Exception:
    print("?\t?\t?")')"
  IFS=$'\t' read -r mid mlen mroot <<<"$info"
  [ "$mid" = "glm-5.3-flash" ] && ok "served model: $mid" || fail "served model is '$mid', expected glm-5.3-flash"
  [ "$mlen" = "1048576" ] && ok "context length: $mlen (1M)" || fail "context length is '$mlen', expected 1048576"
  [ "$mroot" = "nota-ai/GLM-5.3-Flash-Nota-NVFP4" ] && ok "model root: $mroot" || warn "model root is '$mroot', expected nota-ai/GLM-5.3-Flash-Nota-NVFP4"
fi

echo "Result: $([ "$fails" -eq 0 ] && echo "all checks passed" || echo "FAIL ($fails)")"
[ "$fails" -eq 0 ]
