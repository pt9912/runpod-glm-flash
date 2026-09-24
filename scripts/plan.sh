#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in your shell; never put it in terraform.tfvars}"
cd "$(dirname "$0")/../terraform"

# terraform.tfvars must exist and must not still contain template placeholders
# (comment lines are ignored, e.g. the optional machine_id hint).
[ -f terraform.tfvars ] || {
  echo "terraform/terraform.tfvars is missing: cp terraform.tfvars.example terraform.tfvars and edit it" >&2
  exit 1
}
if grep -v '^[[:space:]]*#' terraform.tfvars | grep -n 'REPLACE_WITH'; then
  echo "terraform/terraform.tfvars still contains REPLACE_WITH_ placeholders (lines above)" >&2
  exit 1
fi

terraform init
# Lint only the .tf sources; a hand-edited terraform.tfvars must not abort the plan.
terraform fmt -check -diff -- *.tf
terraform validate
terraform plan -out=tfplan
