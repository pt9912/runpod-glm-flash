#!/usr/bin/env bash
set -euo pipefail
: "${RUNPOD_API_KEY:?Set RUNPOD_API_KEY in your shell; never put it in terraform.tfvars}"
# Tools, environment and terraform.tfvars (existence, no REPLACE_WITH_ placeholders).
"$(dirname "$0")/pre-check.sh"
echo

cd "$(dirname "$0")/../terraform"
terraform init
# Lint only the .tf sources; a hand-edited terraform.tfvars must not abort the plan.
terraform fmt -check -diff -- *.tf
terraform validate
terraform plan -out=tfplan
