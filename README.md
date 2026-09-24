# runpod-glm-flash

IaC skeleton for the validated GLM-5.3-Flash deployment on one NVIDIA B300 in RunPod Secure Cloud.

All commands below are run from the repository root unless a block says otherwise.

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

**API key permissions:** read-only calls (`v2-smoke.sh`, `gpu-availability.sh`, `pre-check.sh --online`) work with a read-only key, but `pod-start.sh`, `pod-stop.sh` and `terraform apply` need write access to Pods. With a read-only or too narrowly restricted key they fail with `HTTP 403` ("Access to the requested resource was denied"). That is a permission problem, not a full GPU. Create a key with write access in the RunPod console (Settings > API Keys; RunPod recommends restricted keys with the minimum permissions). Note that `pre-check.sh --online` cannot detect missing write access, because it only performs a read.

Create these separately in the RunPod console:

- `VLLM_API_KEY`
- `HF_TOKEN` (only needed for a fresh setup with `offline_mode = false`)

Secret names are case-sensitive and must match `vllm_secret_name` / `hf_secret_name` exactly (defaults: `VLLM_API_KEY`, `HF_TOKEN`).

Terraform only sends the RunPod Secret placeholder strings. Never replace them with the actual token in HCL.

## 0. Pre-flight check

```bash
./scripts/pre-check.sh            # tools, environment, local files
./scripts/pre-check.sh --online   # additionally one read-only API call to verify the key
```

Checks that `curl`, `python3` and `terraform` (version from `terraform/versions.tf`) are installed, that `RUNPOD_API_KEY` is exported (a plain `. .env` does not export; use `set -a; source .env; set +a`) and that `terraform.tfvars` is complete. `ansible-playbook`, `RUNPOD_POD_ID`, `VLLM_API_KEY` and `ansible/inventory.yml` only produce warnings because they are needed later. Secret values are never printed. Exit code 1 means a blocking problem.

### Tools

Required: `curl`, `python3` and `terraform` (>= the version in `terraform/versions.tf`). Install them with your package manager; for Terraform use the official instructions at <https://developer.hashicorp.com/terraform/install>. Optional: `ansible-playbook` for the verification step (<https://docs.ansible.com/ansible/latest/installation_guide/>).

`runpodctl` is **not** needed by this repo. Install it only if you want it for other things, following <https://docs.runpod.io/runpodctl/overview>. One useful case is registering your SSH public key, which the Ansible verification needs (`ssh-keygen -t ed25519`, then either paste `~/.ssh/id_ed25519.pub` into the SSH Public Keys field of your RunPod account settings, or run `runpodctl ssh add-key --key-file ~/.ssh/id_ed25519.pub`).

## 1. Read-only REST v2 check

```bash
./scripts/v2-smoke.sh
```

This performs a GET against `/v2/pods`; it does not create a GPU. It prints only id, name and status per Pod, because the raw response contains every Pod's `env`.

## 2. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
```

Set the existing Network Volume ID. `machine_id` is optional (see above).

A Network Volume is bound to one datacenter, so a B300 must be free **in that datacenter**; a free B300 elsewhere does not help. Check stock first with `./scripts/gpu-availability.sh B300 <DATACENTER>` (without a datacenter it shows only the overall stock). `B300` matches the exact GPU name; `gpu_type_id` uses the full id `NVIDIA B300 SXM6 AC`, which you can pass as well. If no exact id/name matches, the script lists every GPU containing the text and says so. Exit codes: 0 in stock, 2 no stock, 4 unknown GPU type or datacenter (typo), 1 API error. If you do pin a `machine_id`, it must be in the volume's datacenter.

`offline_mode` (default `true`) assumes the checkpoint is already on the volume: `HF_HUB_OFFLINE=1` is set and no `HF_TOKEN` is sent. For a fresh setup or re-download set `offline_mode = false`; downloads are then allowed and the `HF_TOKEN` secret is injected.

## 3. Plan only

```bash
./scripts/plan.sh
```

`plan.sh` first runs `scripts/pre-check.sh` (tools, environment, `terraform/terraform.tfvars` without `REPLACE_WITH_` placeholders; comments are ignored, and variables from `TF_VAR_*` or `*.auto.tfvars` also count); the variables `network_volume_id` and `machine_id` also reject the placeholder values in Terraform itself.

The plan is saved to `terraform/tfplan`, so the reviewed plan is exactly what gets applied. Review the entire plan. Check Secure Cloud, B300, one GPU, 50 GB container disk, existing `/workspace` Network Volume, image, 1M/MTP5 args, port 8000 and that no literal secrets appear.

## 4. Apply intentionally

```bash
(cd terraform && terraform apply tfplan)
```

This is the first step that can start billable B300 compute. There is intentionally no automatic apply script.

## 5. Verify with Ansible

```bash
cd ansible
cp inventory.example.yml inventory.yml
$EDITOR inventory.yml
ansible-playbook playbook.yml
cd ..
```

Security note: the Pod exposes `22/tcp` with root login (`start_ssh = true`) because the Ansible role connects as `root`, and `ansible.cfg` sets `host_key_checking = False` because Pod host keys change on redeploy. Both are deliberate trade-offs; use SSH keys only, and remove `22/tcp` from `ports` in `terraform/main.tf` once you no longer need verification or shell access.

**Prerequisites for SSH (unverified for this setup):** your RunPod account needs registered SSH public keys (they are injected as `PUBLIC_KEY`), and the container must actually run an sshd. `docker_args` replaces the image's start command with `vllm serve`, and it is not known whether the vLLM image ships or starts openssh-server. If port 22 does not answer, the Ansible role cannot run. Fallback: check from outside through the HTTP proxy, `curl -i https://POD_ID-8000.proxy.runpod.net/v1/models` (expect 401 without a key, 200 with `Authorization: Bearer $VLLM_API_KEY`).

The role reads `VLLM_API_KEY` from the shell environment and falls back to `/proc/1/environ`, because RunPod injects container env vars into PID 1 and SSH login shells often do not see them.

The role checks the GPU, persistent caches, authenticated `/v1/models`, model ID and 1M max context. It also fails if `VLLM_API_KEY` is empty or still an unresolved `RUNPOD_SECRET_...` placeholder (e.g. after a mistyped secret name), because the API would otherwise run with a guessable key.

## 13/5 scheduling

`docs/schedule.example.yml` is deliberately **disabled** and kept outside `.github/workflows/`, so GitHub never runs it. It documents the intended GitHub Actions shape without risking accidental GPU spend. Move it to `.github/workflows/` and enable it only after pinning actions by SHA and deciding how to handle European DST.

`scripts/pod-start.sh` and `scripts/pod-stop.sh` call the REST v2 endpoint `POST /v2/pods/{id}/action` (`start`/`stop`); no `runpodctl` is needed, only `curl` and `python3`. Both first print the target (name, status, hourly cost) so a stale `RUNPOD_POD_ID` is visible, and do nothing if the Pod is already in the wanted state. Starting bills the GPU immediately. Stopping is risky for a scheduled setup: see "If the GPU is occupied". Do not automate destructive redeploy until the exact migration/redeploy behavior has been tested on the account.

## If the GPU is occupied

A stopped Pod keeps its machine assignment and resumes on the same host. If someone else rents the GPU meanwhile, `pod start` cannot succeed. Observed on 2026-09-24: `HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}`; nothing is started or billed in that case. RunPod's docs describe three options:

1. **Wait.** The GPU frees up once the other user stops their Pod. `./scripts/wait-for-gpu.sh B300 EU-NL-1` (use the datacenter of your volume) polls the stock read-only every 60 s and rings the terminal bell when the GPU is available; it never starts anything (a typo in the GPU or datacenter aborts with exit 4 instead of polling forever). Stock changes within minutes, so act right away and expect that a start can still fail.
2. **Redeploy (recommended with a Network Volume).** Terminate the Pod and create a new one that attaches the same volume; `/workspace` (model, HF and vLLM caches) is untouched. With `machine_id` unset, RunPod should choose any machine with a free B300 in the volume's datacenter (confirm this in the first plan/apply):

   ```bash
   (cd terraform && terraform state list)    # is runpod_pod.glm in the state?
   (cd terraform && terraform apply -replace=runpod_pod.glm)   # yes: replace it
   ./scripts/plan.sh && (cd terraform && terraform apply tfplan)   # no (e.g. the Pod was created outside Terraform): plain plan and apply
   ```

   Use `./scripts/gpu-availability.sh` beforehand; a create can still fail for capacity.
3. **Console migration (beta).** The RunPod console offers to migrate a stopped Pod to a machine with a free GPU. Their docs describe no API/CLI/Terraform equivalent.

After `pod-stop.sh` the Pod is `EXITED` while Terraform's state still says running; do not run `terraform apply` blindly after a stop/start, and read the plan first (whether a stop causes a proposed update or replacement is untested).

Redeploy and migration both produce a **new Pod ID, IP and proxy URL**. Afterwards update `RUNPOD_POD_ID` (local `.env`, GitHub secret) and `GLM_URL` (Claude Code), and re-run the Ansible verification. Terraform state follows a redeploy via `-replace`, but not a console migration; after a migration the old resource is stale.

For the 13/5 schedule this means: stop/start is cheap but can fail overnight; terminate/recreate is robust against machine binding but can fail on B300 capacity and changes the Pod ID daily. Decide deliberately.

## Stop billing

- `pod-stop.sh` stops the GPU billing. Per RunPod's pricing docs a stopped Pod is not charged for its container disk (only for a Pod-local volume disk, at a higher rate); the Network Volume bills separately (about $0.07/GB/month) whether or not a Pod runs.
- `terraform destroy` (from `terraform/`) terminates the Pod and removes it from state. It does **not** delete the Network Volume, which is not managed here, so the model and caches survive.
- `terraform apply -replace=runpod_pod.glm` destroys first and then creates: if B300 capacity is missing at that moment, you end up with no Pod.

## Optional: Runpod MCP servers

This repo does not need MCP. Runpod offers two [MCP servers](https://docs.runpod.io/get-started/mcp-servers) that let an AI coding agent such as Claude Code work with Runpod directly. The commands below are taken from Runpod's documentation and were not tested with this repo; the scripts here work without them.

**Docs server** (read-only documentation search, no login):

```bash
claude mcp add runpod-docs --scope user --transport http https://docs.runpod.io/mcp
```

**API server** (manages Pods, endpoints, templates, network volumes and registries through the REST API, v2 by default). It has **write access to your account and can start billable Pods**, so treat it like the API key itself. Recommended setup is the hosted server with "Sign in with Runpod" (OAuth): a browser opens on first use, and no key is stored on disk.

```bash
claude mcp add --transport http runpod -s user https://mcp.getrunpod.io/
```

Alternatives:

- Guided installer, detects your clients (Claude Code, Claude Desktop, Cursor, Windsurf, VS Code): `npx @runpod/mcp-server@latest add`; undo with `npx @runpod/mcp-server@latest remove`.
- Hosted server with an API key instead of OAuth: add `--header "Authorization: Bearer $RUNPOD_API_KEY"` to the command above.
- Local server: `claude mcp add runpod --scope user -e RUNPOD_API_KEY=... -- npx -y @runpod/mcp-server@latest`. The key is then stored in your Claude Code configuration, so prefer the OAuth variant.

Rules of thumb:

- Use `-s user` / `--scope user`. A project-scoped configuration is written to a `.mcp.json` in the repository and could end up in a commit; never put a key there.
- Use an API key with only the permissions you need (see "API key permissions"), and disable or delete it when you no longer need it.
- Check the connection with `/mcp` inside Claude Code; remove a server with `claude mcp remove runpod`.
- Starting or creating Pods through an agent bills the GPU exactly like the scripts do. Keep reviewing what the agent is about to do.

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

`--max-num-seqs 6` matches the previously validated Pod (its configuration was read via the API on 2026-09-24). It caps concurrent sequences, which bounds KV-cache use with the 1M context; do not raise it without measuring memory and latency on the Pod.

## vLLM memory note

Keep `--gpu-memory-utilization 0.96` with MTP5. Do not reuse a fixed KV-cache byte value measured without MTP.

`HF_HUB_OFFLINE=1` (default, `offline_mode = true`) assumes the complete checkpoint is already on the persistent Network Volume.
