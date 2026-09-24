# runpod-glm

IaC skeleton for the validated GLM-5.3-Flash deployment on one NVIDIA B300 in RunPod Secure Cloud.

## Current architecture

- **Terraform:** official `runpod/runpod` provider, pinned to `1.0.2`
- **API base:** `https://api.runpod.io/v2`
- **Pod:** Secure Cloud, 1× NVIDIA B300 SXM6 AC
- **Image:** `vllm/vllm-openai:glm53-flash`
- **Persistent data:** existing Network Volume mounted at `/workspace`
- **Model:** `nota-ai/GLM-5.3-Flash-Nota-NVFP4`
- **Context:** 1,048,576
- **KV:** FP8
- **Spec decode:** MTP5
- **Auth:** RunPod Secret → `VLLM_API_KEY`

## Important provider caveat

The official provider is now published in the Terraform Registry and defaults to REST API v2, but its pod/v2 implementation is still moving quickly. Before spending money, run the read-only v2 smoke test and `terraform plan`, then compare the plan with the current provider schema/release notes. In particular verify `machine_id`, B300 selection, existing Network Volume attachment, `docker_args`, ports and secret placeholders.

The repo deliberately requires a `machine_id` because that is what the current official provider documentation exposes. Do not guess it.

## Secrets

No secret values belong in this repository or `terraform.tfvars`.

Set locally:

```bash
export RUNPOD_API_KEY='...'
```

Create these separately in the RunPod console:

- `HF_TOKEN`
- `VLLM_API_KEY`

Terraform only sends the RunPod Secret placeholder strings. Never replace them with the actual token in HCL.

## 1. Read-only REST v2 check

```bash
./scripts/v2-smoke.sh
```

This performs a GET against `/v2/pods`; it does not create a GPU.

## 2. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Set the existing Network Volume ID and a currently valid Secure Cloud B300 machine ID.

## 3. Plan only

```bash
../scripts/plan.sh
```

The plan is saved to `terraform/tfplan`, so the reviewed plan is exactly what gets applied. Review the entire plan. Check Secure Cloud, B300, one GPU, 50 GB container disk, existing `/workspace` Network Volume, image, 1M/MTP5 args, port 8000 and that no literal secrets appear.

## 4. Apply intentionally

```bash
terraform apply tfplan   # run from terraform/
```

This is the first step that can start billable B300 compute. There is intentionally no automatic apply script.

## 5. Verify with Ansible

```bash
cd ../ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml
ansible-playbook playbook.yml
```

The role checks the GPU, persistent caches, authenticated `/v1/models`, model ID and 1M max context.

## 13/5 scheduling

`docs/schedule.example.yml` is deliberately **disabled** and kept outside `.github/workflows/`, so GitHub never runs it. It documents the intended GitHub Actions shape without risking accidental GPU spend. Move it to `.github/workflows/` and enable it only after pinning a reviewed `runpodctl` version and deciding how to handle European DST.

RunPod currently exposes `pod start` and `pod stop` via `runpodctl`. If a stopped Pod's old GPU is occupied, a Network Volume lets you redeploy without losing `/workspace`. Do not automate destructive redeploy until the exact migration/redeploy behavior has been tested on the account.

## Claude Code

```bash
export GLM_URL='https://POD_ID-8000.proxy.runpod.net'
export ANTHROPIC_BASE_URL="${GLM_URL%/}"
export ANTHROPIC_AUTH_TOKEN="$VLLM_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
claude --model glm-5.3-flash
```

## vLLM memory note

Keep `--gpu-memory-utilization 0.96` with MTP5. Do not reuse a fixed KV-cache byte value measured without MTP.

`HF_HUB_OFFLINE=1` assumes the complete checkpoint is already on the persistent Network Volume.
