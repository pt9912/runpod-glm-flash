# runpod-glm

IaC skeleton for the validated GLM-5.3-Flash deployment on one NVIDIA B300 in RunPod Secure Cloud.

## Current architecture

- **Terraform:** official `runpod/runpod` provider, pinned to `1.0.8` (`network_volume_id` needs >= 1.0.6; 1.0.9 has a schema bug and fails to load with Terraform 1.14)
- **API base:** `https://api.runpod.io/v2` (repo default, **untested with the provider**, see "Important provider caveat")
- **Pod:** Secure Cloud, 1× NVIDIA B300 SXM6 AC
- **Image:** `vllm/vllm-openai:glm53-flash`
- **Persistent data:** existing Network Volume mounted at `/workspace`
- **Model:** `nota-ai/GLM-5.3-Flash-Nota-NVFP4`
- **Context:** 1,048,576
- **KV:** FP8
- **Spec decode:** MTP5
- **Auth:** RunPod Secret → `VLLM_API_KEY`

## Important provider caveat

The official provider (`runpod/runpod`, published in the Terraform Registry) is **shaped after REST API v1**: its schema documents the default `base_url` as `https://rest.runpod.io/v1`, and its pod fields (`image_name`, `docker_args`, `machine_id`, `network_volume_id`, `start_ssh`) are v1 names. RunPod's v2 API uses a different body (`image`, `args`, `gpu{id,count}`, `mounts.network[{volumeId,path}]`, `dataCenterIds`) and has no `machineId`/`startSsh`/`dockerArgs`.

This repo nevertheless sets `runpod_base_url` to the v2 URL by default. **Whether provider 1.0.8 works against `/v2` is untested.** Possible outcomes are a rejected request (422/400) or silently dropped fields such as `machine_id`/`start_ssh`. Before the first real apply:

1. Run the read-only smoke test and `terraform plan` (the plan alone does not call the API to create anything).
2. Decide the base URL deliberately: the provider's native `https://rest.runpod.io/v1` (set `runpod_base_url` in `terraform.tfvars`; note that RunPod announced the retirement of v1, so check the current date) or v2 verified with a throwaway CPU Pod.
3. In the plan and in the console after apply, verify B300 selection, the Network Volume attachment, `docker_args` (quoting of `--speculative-config`), ports and the secret placeholders.

`machine_id` is optional. Leave it unset so RunPod picks any machine with a free B300 (placement by GPU type and the Network Volume's datacenter; the REST v2 API itself has no machine field, and how the provider maps it depends on the API version, see above). Pin it only if you must, and never guess it. A pinned machine that is occupied makes the apply fail (see "If the GPU is occupied").

## Secrets

No secret values belong in this repository or `terraform.tfvars`.

Set locally, either directly:

```bash
export RUNPOD_API_KEY='...'
```

or via a git-ignored `.env` created from the template:

```bash
cp .env.example .env
$EDITOR .env
set -a; source .env; set +a
```

Create these separately in the RunPod console:

- `VLLM_API_KEY`
- `HF_TOKEN` (only needed for a fresh setup with `offline_mode = false`)

Secret names are case-sensitive and must match `vllm_secret_name` / `hf_secret_name` exactly (defaults: `VLLM_API_KEY`, `HF_TOKEN`).

Terraform only sends the RunPod Secret placeholder strings. Never replace them with the actual token in HCL.

## 1. Read-only REST v2 check

```bash
./scripts/v2-smoke.sh
```

This performs a GET against `/v2/pods`; it does not create a GPU. It prints only id, name and status per Pod, because the raw response contains every Pod's `env`.

## 2. Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Set the existing Network Volume ID. `machine_id` is optional (see above).

A Network Volume is bound to one datacenter, so a B300 must be free **in that datacenter**; a free B300 elsewhere does not help. Check stock first with `./scripts/gpu-availability.sh`. If you do pin a `machine_id`, it must be in the volume's datacenter.

`offline_mode` (default `true`) assumes the checkpoint is already on the volume: `HF_HUB_OFFLINE=1` is set and no `HF_TOKEN` is sent. For a fresh setup or re-download set `offline_mode = false`; downloads are then allowed and the `HF_TOKEN` secret is injected.

## 3. Plan only

```bash
../scripts/plan.sh
```

`plan.sh` first checks that `terraform/terraform.tfvars` exists and contains no `REPLACE_WITH_` placeholders (comment lines are ignored); the variables `network_volume_id` and `machine_id` also reject the placeholder values in Terraform itself.

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

Security note: the Pod exposes `22/tcp` with root login (`start_ssh = true`) because the Ansible role connects as `root`, and `ansible.cfg` sets `host_key_checking = False` because Pod host keys change on redeploy. Both are deliberate trade-offs; use SSH keys only, and remove `22/tcp` from `ports` in `terraform/main.tf` once you no longer need verification or shell access.

**Prerequisites for SSH (unverified for this setup):** your RunPod account needs registered SSH public keys (they are injected as `PUBLIC_KEY`), and the container must actually run an sshd. `docker_args` replaces the image's start command with `vllm serve`, and it is not known whether the vLLM image ships or starts openssh-server. If port 22 does not answer, the Ansible role cannot run. Fallback: check from outside through the HTTP proxy, `curl -i https://POD_ID-8000.proxy.runpod.net/v1/models` (expect 401 without a key, 200 with `Authorization: Bearer $VLLM_API_KEY`).

The role reads `VLLM_API_KEY` from the shell environment and falls back to `/proc/1/environ`, because RunPod injects container env vars into PID 1 and SSH login shells often do not see them.

The role checks the GPU, persistent caches, authenticated `/v1/models`, model ID and 1M max context. It also fails if `VLLM_API_KEY` is empty or still an unresolved `RUNPOD_SECRET_...` placeholder (e.g. after a mistyped secret name), because the API would otherwise run with a guessable key.

## 13/5 scheduling

`docs/schedule.example.yml` is deliberately **disabled** and kept outside `.github/workflows/`, so GitHub never runs it. It documents the intended GitHub Actions shape without risking accidental GPU spend. Move it to `.github/workflows/` and enable it only after pinning a reviewed `runpodctl` version and deciding how to handle European DST.

RunPod currently exposes `pod start` and `pod stop` via `runpodctl`. Stopping is risky for a scheduled setup: see "If the GPU is occupied". Do not automate destructive redeploy until the exact migration/redeploy behavior has been tested on the account.

## If the GPU is occupied

A stopped Pod keeps its machine assignment and resumes on the same host. If someone else rents the GPU meanwhile, `pod start` cannot succeed (the exact API/CLI error is not verified here). RunPod's docs describe three options:

1. **Wait.** The GPU frees up once the other user stops their Pod.
2. **Redeploy (recommended with a Network Volume).** Terminate the Pod and create a new one that attaches the same volume; `/workspace` (model, HF and vLLM caches) is untouched. With `machine_id` unset, RunPod should choose any machine with a free B300 in the volume's datacenter (confirm this in the first plan/apply):

   ```bash
   cd terraform
   terraform apply -replace=runpod_pod.glm
   ```

   Use `./scripts/gpu-availability.sh` beforehand; a create can still fail for capacity.
3. **Console migration (beta).** The RunPod console offers to migrate a stopped Pod to a machine with a free GPU. Their docs describe no API/CLI/Terraform equivalent.

After `pod-stop.sh` the Pod is `EXITED` while Terraform's state still says running; do not run `terraform apply` blindly after a stop/start, and read the plan first (whether a stop causes a proposed update or replacement is untested).

Redeploy and migration both produce a **new Pod ID, IP and proxy URL**. Afterwards update `RUNPOD_POD_ID` (local `.env`, GitHub secret) and `GLM_URL` (Claude Code), and re-run the Ansible verification. Terraform state follows a redeploy via `-replace`, but not a console migration; after a migration the old resource is stale.

For the 13/5 schedule this means: stop/start is cheap but can fail overnight; terminate/recreate is robust against machine binding but can fail on B300 capacity and changes the Pod ID daily. Decide deliberately.

## Stop billing

- `pod-stop.sh` stops the GPU, but a stopped Pod still bills its container disk, and the Network Volume bills separately.
- `terraform destroy` (from `terraform/`) terminates the Pod and removes it from state. It does **not** delete the Network Volume, which is not managed here, so the model and caches survive.
- `terraform apply -replace=runpod_pod.glm` destroys first and then creates: if B300 capacity is missing at that moment, you end up with no Pod.

## Claude Code

```bash
export GLM_URL='https://POD_ID-8000.proxy.runpod.net'
export ANTHROPIC_BASE_URL="${GLM_URL%/}"
export ANTHROPIC_AUTH_TOKEN="$VLLM_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
claude --model glm-5.3-flash
```

`VLLM_API_KEY` here is the client-side copy of the same value as the RunPod Secret (see `.env.example`). Whether this vLLM image serves the Anthropic-style `/v1/messages` API is not verified. The RunPod HTTP proxy closes connections after 100 seconds (HTTP 524), so use streaming clients; a slow first token with a very long context can otherwise hit that limit.

## vLLM concurrency note

`--max-num-seqs 4` keeps concurrency deliberately low so the KV cache can serve the 1M context; throughput under parallel load is limited accordingly. Raise it only after measuring memory and latency on the Pod.

## vLLM memory note

Keep `--gpu-memory-utilization 0.96` with MTP5. Do not reuse a fixed KV-cache byte value measured without MTP.

`HF_HUB_OFFLINE=1` (default, `offline_mode = true`) assumes the complete checkpoint is already on the persistent Network Volume.
