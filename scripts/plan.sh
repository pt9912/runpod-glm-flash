#!/usr/bin/env bash
# NOTE: the Pod is created with scripts/create-pod.sh. The Terraform Pod resource is locked
# (allow_unsafe_apply = false) because provider 1.0.8 drops gpu_type_id, ports, docker_args and
# start_ssh, so the plan fails with an explanation (see the README, "Important provider caveat").
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
