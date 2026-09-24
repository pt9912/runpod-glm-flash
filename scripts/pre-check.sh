#!/usr/bin/env bash
# Pre-flight check: are the required tools installed and the local setup complete?
# Read-only; never starts or changes anything. Secrets are never printed.
#
# Usage: pre-check.sh [--online]
#   --online  additionally do one read-only GET /pods to verify the API key
#
# Exit code: 0 = no blocking problem (warnings are allowed), 1 = at least one FAIL.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLINE=0
case "${1:-}" in
  "") ;;
  --online) ONLINE=1 ;;
  *) echo "usage: pre-check.sh [--online]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: pre-check.sh [--online]" >&2; exit 2; }

fails=0
warns=0
ok()   { printf '[ ok ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; fails=$((fails + 1)); }

# version_ge A B: true if A >= B (dotted versions)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

echo "== Tools =="
# curl and python3 are used by every script (API calls, JSON handling).
for t in curl python3; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t: $(command -v "$t")"
  else
    fail "$t is not installed (required by all scripts). Install it with your package manager (apt, dnf, brew, ...)"
  fi
done

# terraform: minimum version comes from terraform/versions.tf
min_tf="$(sed -n 's/.*required_version *= *"[>=~ ]*\([0-9][0-9.]*\)".*/\1/p' "$ROOT/terraform/versions.tf" 2>/dev/null | head -n1)"
min_tf="${min_tf:-1.5.0}"
if command -v terraform >/dev/null 2>&1; then
  tf_ver="$(terraform version 2>/dev/null | sed -n '1s/^Terraform v\([0-9][0-9.]*\).*/\1/p')"
  if [ -z "$tf_ver" ]; then
    warn "terraform found but its version could not be read"
  elif version_ge "$tf_ver" "$min_tf"; then
    ok "terraform $tf_ver (needs >= $min_tf)"
  else
    fail "terraform $tf_ver is older than the required >= $min_tf. Update: https://developer.hashicorp.com/terraform/install"
  fi
else
  fail "terraform is not installed (needs >= $min_tf). Install: https://developer.hashicorp.com/terraform/install"
fi

# ansible is only needed for the optional verification step (README step 5).
if command -v ansible-playbook >/dev/null 2>&1; then
  ok "ansible-playbook: $(ansible-playbook --version 2>/dev/null | head -n1)"
else
  warn "ansible-playbook is not installed (only needed for the Ansible verification). Install: https://docs.ansible.com/ansible/latest/installation_guide/"
fi

echo
echo "== Environment (values are never printed) =="
if [ -n "${RUNPOD_API_KEY:-}" ]; then
  ok "RUNPOD_API_KEY is set"
else
  fail "RUNPOD_API_KEY is empty or not exported (use: set -a; source .env; set +a)"
fi
if [ -n "${RUNPOD_POD_ID:-}" ]; then
  ok "RUNPOD_POD_ID is set"
else
  warn "RUNPOD_POD_ID is not set (needed by pod-start.sh / pod-stop.sh)"
fi
if [ -n "${VLLM_API_KEY:-}" ]; then
  ok "VLLM_API_KEY is set"
else
  warn "VLLM_API_KEY is not set (needed by clients such as Claude Code)"
fi

echo
echo "== Files =="
tfvars="$ROOT/terraform/terraform.tfvars"
# Terraform also accepts TF_VAR_* and *.auto.tfvars; only complain when nothing is set up.
alt_source=0
if [ -n "${TF_VAR_network_volume_id:-}" ] || compgen -G "$ROOT/terraform/*.auto.tfvars" >/dev/null; then
  alt_source=1
fi
if [ ! -f "$tfvars" ]; then
  if [ "$alt_source" -eq 1 ]; then
    ok "no terraform.tfvars, but variables come from TF_VAR_* / *.auto.tfvars"
  else
    fail "terraform/terraform.tfvars is missing (cp terraform.tfvars.example terraform.tfvars)"
  fi
else
  # Look at values only: drop full-line and trailing comments before checking.
  values="$(sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' "$tfvars")"
  if printf '%s\n' "$values" | grep -q 'REPLACE_WITH'; then
    fail "terraform/terraform.tfvars still contains REPLACE_WITH_ placeholders"
  elif ! printf '%s\n' "$values" | grep -q '^[[:space:]]*network_volume_id[[:space:]]*=' && [ "$alt_source" -eq 0 ]; then
    warn "terraform/terraform.tfvars does not set network_volume_id (Terraform will ask for it)"
  else
    ok "terraform/terraform.tfvars present, no placeholders"
  fi
fi

if [ -d "$ROOT/terraform/.terraform" ]; then
  ok "terraform is initialised (.terraform present)"
else
  warn "terraform is not initialised yet (scripts/plan.sh runs terraform init)"
fi
if [ -f "$ROOT/terraform/.terraform.lock.hcl" ]; then
  ok "terraform/.terraform.lock.hcl present"
else
  warn "terraform/.terraform.lock.hcl is missing (provider version not locked)"
fi
if [ -f "$ROOT/ansible/inventory.yml" ]; then
  if grep -q 'REPLACE_WITH' "$ROOT/ansible/inventory.yml"; then
    warn "ansible/inventory.yml still contains REPLACE_WITH_ placeholders"
  else
    ok "ansible/inventory.yml present"
  fi
else
  warn "ansible/inventory.yml is missing (only needed for the Ansible verification)"
fi

if [ "$ONLINE" -eq 1 ]; then
  echo
  echo "== API (read-only GET /pods) =="
  if [ -z "${RUNPOD_API_KEY:-}" ]; then
    fail "skipped: RUNPOD_API_KEY is not set"
  elif ! command -v curl >/dev/null 2>&1; then
    fail "skipped: curl is not installed"
  else
    # shellcheck source=scripts/_api.sh
    source "$ROOT/scripts/_api.sh"
    # api_get keeps no temp files; its error text goes to stderr and is captured here.
    if err="$(api_get /pods 2>&1 >/dev/null)"; then
      ok "API reachable and key accepted (${BASE})"
    else
      fail "API check failed: $(printf '%s' "$err" | head -n1)"
    fi
  fi
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "Result: $fails blocking problem(s), $warns warning(s)."
  exit 1
fi
echo "Result: ready ($warns warning(s))."
