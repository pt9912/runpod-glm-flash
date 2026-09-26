# runpod-glm-flash

[Deutsch](README.de.md) | English

Bash tooling to run the validated GLM-5.3-Flash deployment on an NVIDIA B300 in RunPod Secure Cloud.

All commands below are run from the repository root unless a block says otherwise.

## Current architecture

- **Pod creation:** `scripts/create-pod.sh` (REST v2, verified right after creation). The pool of Pods is managed with `start-any.sh` / `stop-any.sh`. There is no Terraform (see "Why there is no Terraform")
- **API base:** `https://api.runpod.io/v2` (used by all scripts)
- **Pod:** Secure Cloud, 1× NVIDIA B300 SXM6 AC
- **Image:** `vllm/vllm-openai:glm53-flash`
- **Persistent data:** existing Network Volume mounted at `/workspace`
- **Model:** `nota-ai/GLM-5.3-Flash-Nota-NVFP4`
- **Context:** 1,048,576
- **KV:** FP8
- **Spec decode:** MTP5
- **Auth:** RunPod Secret → `VLLM_API_KEY`

## Scripts at a glance

| Script | What it does | Changes state | GPU billing |
|---|---|---|---|
| `pre-check.sh` | Checks tools, environment and `NETWORK_VOLUME_ID` (`--online`: also one read-only API call) | no | no |
| `v2-smoke.sh` | Lists your Pods (id, name, status) | no | no |
| `gpu-availability.sh` | Shows the stock of a GPU type, overall or per datacenter | no | no |
| `wait-for-gpu.sh` | Polls the stock until the GPU is available; never starts anything | no | no |
| `create-pod.sh` | Creates the Pod (dry run by default, `--yes` to create) and verifies it | creates a Pod | starts |
| `verify-pod.sh` | Checks that a Pod matches the intended configuration | no | no |
| `check-endpoint.sh` | Checks the API through the proxy: 401 without a key, 200 with it, model and context | no | no |
| `wait-for-ready.sh` | Polls until vLLM answers and measures the start time (writes a local log) | no | no |
| `pod-start.sh` | Starts one stopped Pod | yes | starts |
| `start-when-free.sh` | Retries `pod-start.sh` for one Pod while its GPU is occupied | yes | starts |
| `start-any.sh` | Pool: gets one Pod running, restarting stopped ones first, creating a new one if none can start | yes | starts |
| `pod-stop.sh` | Stops one Pod | yes | ends |
| `stop-any.sh` | Stops every active Pod of the pool | yes | ends |
| `pod-terminate.sh` | Deletes a Pod permanently (needs `--yes`; the volume stays) | yes | ends |

`_api.sh` and `_pool.sh` are helpers that the other scripts source; you do not run them. `docs/schedule.example.yml` is a disabled example workflow. `pod-start.sh`, `pod-stop.sh` and `pod-terminate.sh` print the target (name, status, hourly cost) before they act, `create-pod.sh` prints the request, and `start-any.sh --dry-run` shows the pool and the order without sending anything. The scripts marked "starts" begin the GPU billing.

Typical flows:

```bash
# first time
./scripts/pre-check.sh --online
./scripts/create-pod.sh              # dry run: shows the request and the stock
./scripts/create-pod.sh --yes        # creates the Pod and verifies it (bills the GPU)
./scripts/wait-for-ready.sh && ./scripts/check-endpoint.sh

# every day
./scripts/start-any.sh --wait        # gets one pool Pod running and waits until vLLM answers
./scripts/check-endpoint.sh
./scripts/stop-any.sh                # when you are done (ends the GPU billing)
```

## Why there is no Terraform

Earlier versions of this repository described the Pod with Terraform (provider `runpod/runpod` 1.0.8). It was removed: **on 2026-09-26 `terraform apply` created a wrong Pod** (an H100 at $3.49/h instead of the B300, port `8888/http` instead of `8000/http`, no vLLM arguments). Capturing the provider's request against a local mock showed why: it sent only `name`, `cloudType`, `imageName`, `containerDiskInGb`, `gpuCount`, `env`, `networkVolumeId` and `volumeMountPath`, and **silently dropped `gpuTypeId`, `ports`, `dockerArgs` and `startSsh`**, with the v1 as well as the v2 base URL. `terraform plan` cannot reveal this, because it shows what Terraform intends, not what the provider sends.

The Pod is created with `scripts/create-pod.sh`, which calls the documented REST v2 endpoint with every field explicit and verifies the result with `scripts/verify-pod.sh` right afterwards. The Terraform files are still in the Git history (before the commit that removed them) should the provider be fixed and you want to revisit it; then check with a request capture, not with `plan`.

## Secrets

No secret values belong in this repository.

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

**API key permissions:** read-only calls (`v2-smoke.sh`, `gpu-availability.sh`, `pre-check.sh --online`) work with a read-only key, but `create-pod.sh`, `pod-start.sh`, `pod-stop.sh` and `pod-terminate.sh` need write access to Pods. With a read-only or too narrowly restricted key they fail with `HTTP 403` ("Access to the requested resource was denied"). That is a permission problem, not a full GPU. Create a key with write access in the RunPod console (Settings > API Keys; RunPod recommends restricted keys with the minimum permissions). Note that `pre-check.sh --online` cannot detect missing write access, because it only performs a read.

Create these separately in the RunPod console:

- `VLLM_API_KEY`
- `HF_TOKEN` (only needed for a fresh setup with `offline_mode = false`)

Secret names are case-sensitive and must match `vllm_secret_name` / `hf_secret_name` exactly (defaults: `VLLM_API_KEY`, `HF_TOKEN`).

The Pod definition contains only RunPod Secret references (`{{ RUNPOD_SECRET_<name> }}`), never the values.

## 0. Pre-flight check

```bash
./scripts/pre-check.sh            # tools, environment, local files
./scripts/pre-check.sh --online   # additionally one read-only API call to verify the key
```

Checks that `curl` and `python3` are installed, that `RUNPOD_API_KEY` is exported (a plain `. .env` does not export; use `set -a; source .env; set +a`) and that `NETWORK_VOLUME_ID` is set. `RUNPOD_POD_ID` and `VLLM_API_KEY` only produce warnings because they are needed later. Secret values are never printed. Exit code 1 means a blocking problem.

### Tools

Required: `curl` and `python3`. Install them with your package manager.

`runpodctl` is **not** needed by this repo. Install it only if you want it for other things, following <https://docs.runpod.io/runpodctl/overview>. One useful case is registering your SSH public key, which you need for a Pod created with `--ssh` (`ssh-keygen -t ed25519`, then either paste `~/.ssh/id_ed25519.pub` into the SSH Public Keys field of your RunPod account settings, or run `runpodctl ssh add-key --key-file ~/.ssh/id_ed25519.pub`).

## 1. Read-only REST v2 check

```bash
./scripts/v2-smoke.sh
```

This performs a GET against `/v2/pods`; it does not create a GPU. It prints only id, name and status per Pod, because the raw response contains every Pod's `env`.

## 2. Configure

Put the ID of your existing Network Volume into `.env` (template: `.env.example`):

```bash
echo 'NETWORK_VOLUME_ID=<your Network Volume ID>' >> .env
```

A Network Volume is bound to one datacenter, so a B300 must be free **in that datacenter**; a free B300 elsewhere does not help. `create-pod.sh` places the Pod in the volume's datacenter automatically. Check stock first with `./scripts/gpu-availability.sh B300 <DATACENTER>` (without a datacenter it uses the datacenter of the Pod `RUNPOD_POD_ID` if that is set, otherwise the overall stock; pass `any` for the overall stock). `B300` matches the exact GPU name; the full GPU id is `NVIDIA B300 SXM6 AC`, which you can pass as well. If no exact id/name matches, the script lists every GPU containing the text and says so. Exit codes: 0 in stock, 2 no stock, 4 unknown GPU type or datacenter (typo), 1 API error.

By default the Pod runs in offline mode: the checkpoint is expected on the volume, `HF_HUB_OFFLINE=1` is set and no `HF_TOKEN` is sent. For a fresh setup or re-download use `create-pod.sh --online`; downloads are then allowed and the `HF_TOKEN` secret is injected.

## 3. Dry run

```bash
./scripts/create-pod.sh
```

The default is a **dry run**: it reads the datacenter of the volume, refuses if a Pod with the same name already exists, prints the complete request (only RunPod Secret references, no secret values) plus the current stock, and creates nothing. Options: `--online` (downloads allowed), `--ssh` (also `22/tcp` and `startSsh`; off by default). Environment overrides: `POD_NAME`, `GPU_ID`, `DATACENTER`, `CONTAINER_DISK_GB`, `VLLM_SECRET_NAME`, `HF_SECRET_NAME`.

Review the request: 1× B300, `mounts.network` with your volume on `/workspace`, port 8000, the image, the vLLM arguments (1M context, MTP, `--max-num-seqs 6`) and that `VLLM_API_KEY` is a `{{ RUNPOD_SECRET_... }}` reference.

## 4. Create the Pod

```bash
./scripts/create-pod.sh --yes
```

This is the step that starts billable B300 compute (about $7.89/h). The script never retries a request that may have been sent. It then runs `scripts/verify-pod.sh` (read-only): 1× B300, the volume on `/workspace`, port 8000, `VLLM_API_KEY` as a Secret reference (never empty, never a literal value), the caches on `/workspace` and the key vLLM arguments; it prints env variable names only, never values. On success, put the printed Pod ID into `.env` as `RUNPOD_POD_ID`. If the verification fails, the Pod is wrong and billing, so the script **stops it right away and renames it to `failed-<name>-<id>`**: billing ends, and the Pod leaves the pool (see below) so it is never restarted by accident, but it stays for you to inspect. With `--terminate-on-fail` it is deleted instead. If stopping fails, the message says the Pod is still billing and names the command to end it:

```bash
RUNPOD_POD_ID=<the new ID> ./scripts/pod-terminate.sh --yes
```

`pod-terminate.sh` deletes a Pod permanently (without `--yes` it only shows the target); the Network Volume is a separate resource and stays, so model and caches survive. `create-pod.sh` refuses to create a second Pod while another Pod of the pool is active (`--force` overrides that) and takes a lock so that two runs on the same machine cannot create at the same time. Exit codes of `create-pod.sh`: 0 done, 1 failure or failed verification, 2 bad arguments, 3 a Pod with this name exists or a pool Pod is active, 4 another start/create is in progress, 5 no capacity (nothing created; only the "no instances available" answer counts as capacity, any other HTTP 400 is a rejected request). You can verify any Pod later with `./scripts/verify-pod.sh [POD_ID]`.

## 5. Check the endpoint

```bash
./scripts/check-endpoint.sh
```

Once the Pod answers (`wait-for-ready.sh`), this read-only check goes through the RunPod HTTPS proxy and needs no SSH. It prints only statuses, the model id and the context length, never a key. It checks that:

- **without a key** the API answers `401` (a `200` means the server is open to everyone: stop the Pod and check the Secret `VLLM_API_KEY`),
- **with your `VLLM_API_KEY`** it answers `200` (a `401` means the server runs with a different key, for example an unresolved Secret placeholder after a mistyped secret name),
- the served model is `glm-5.3-flash` with `max_model_len` 1048576 (a different model root only warns).

It uses the Pod from `RUNPOD_POD_ID` or the ID you pass (`./scripts/check-endpoint.sh <POD_ID>`), never a stale `GLM_URL`. Exit codes: 0 all checks passed, 1 a check failed, 2 bad arguments, 3 the endpoint does not answer yet (still booting).

**SSH is off by default:** a new Pod exposes only `8000/http`. `create-pod.sh --ssh` (or `CREATE_POD_SSH=1` for `start-any.sh`) also opens `22/tcp` and starts ssh. That needs SSH public keys registered in your RunPod account and an sshd in the container, which is not verified for this image, and it allows root login: use keys only.

## 14/5 scheduling

The intended schedule is **05:00 to 19:00 local time, Monday to Friday** (14 hours, 5 days). The early start is deliberate: the owner's experience is that a free B300 is easier to find early in the morning (not verified here; stock changes within minutes, check with `scripts/gpu-availability.sh` or `scripts/wait-for-gpu.sh`).

| | start 05:00 | stop 19:00 |
|---|---|---|
| summer time (CEST, UTC+2) | 03:00 UTC | 17:00 UTC |
| winter time (CET, UTC+1) | 04:00 UTC | 18:00 UTC |

GitHub Actions cron runs in UTC only, so the cron lines must be changed twice a year (last Sunday of March and October), or you use a timezone-aware external scheduler.

`docs/schedule.example.yml` is deliberately **disabled** and kept outside `.github/workflows/`, so GitHub never runs it. It documents the intended GitHub Actions shape without risking accidental GPU spend: the start job runs `scripts/start-any.sh`, which restarts the pool Pods one after the other and creates a new one if none can start, repeating every 60 s for at most `MAX_WAIT_SECONDS` (7200 = 2 h), then gives up and fails the job (the Pod stays stopped that day; GitHub usually, not reliably, notifies you); the job has a hard `timeout-minutes` cap; the stop job runs `scripts/stop-any.sh`; scheduled runs derive start/stop from the cron entry. The secrets are `RUNPOD_API_KEY` (write access to Pods) and `NETWORK_VOLUME_ID` (needed to create new Pods). **Every successful start bills the GPU**, so review the file before enabling it. GitHub only keeps one pending run per concurrency group: do not dispatch manual runs while a start is still retrying, or a queued stop can be dropped. Cron runs can be delayed or dropped, and scheduled workflows of inactive public repos are disabled after 60 days, both relevant for the stop job. Move it to `.github/workflows/` and enable it only after pinning actions by SHA and deciding how to handle European DST.

All API calls time out (10 s connect, 60 s total; override with `API_CONNECT_TIMEOUT` / `API_MAX_TIME`), so a stalled connection cannot hang a scheduled job. If the connection breaks after a start/stop request was sent, the scripts say the outcome is unknown; check with `scripts/v2-smoke.sh` before retrying.

`scripts/pod-start.sh` and `scripts/pod-stop.sh` call the REST v2 endpoint `POST /v2/pods/{id}/action` (`start`/`stop`); no `runpodctl` is needed, only `curl` and `python3`. Both first print the target (name, status, hourly cost, datacenter) so a stale `RUNPOD_POD_ID` is visible, and do nothing if the Pod is already in the wanted state. Starting bills the GPU immediately. Stopping is risky for a scheduled setup: see "If the GPU is occupied". Do not automate destructive redeploy until the exact migration/redeploy behavior has been tested on the account.

## If the GPU is occupied

A stopped Pod keeps its machine assignment and resumes on the same host. If someone else rents the GPU meanwhile, `pod start` cannot succeed. Observed on 2026-09-24: `HTTP 400 {"detail":"There are not enough free GPUs on the host machine to start this pod."}`; nothing is started or billed in that case. RunPod's docs describe three options:

1. **Wait.** The GPU frees up once the other user stops their Pod. `./scripts/start-when-free.sh [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (defaults 7200 s, 60 s) retries the actual start while the GPU is occupied and stops after one success or at the cap. That is the right tool for a stopped Pod: it resumes on its own machine, which the catalog stock says nothing about, and a failed attempt costs nothing. `pod-start.sh` returns exit code 5 for "GPU occupied" and 6 for "Pod could not be read, nothing sent" (`start-when-free.sh` retries 6 up to 10 times in a row; `start-any.sh` just skips such a Pod in that round); any other failure aborts at once so a possibly started Pod is never started twice. Cancelling the run stops the running attempt, but a start request that was already sent cannot be undone (the script then says to check `scripts/v2-smoke.sh`). **A successful start bills the GPU.** If you only want to be notified, not to start, `./scripts/wait-for-gpu.sh B300` (uses the datacenter of your Pod from `RUNPOD_POD_ID`; name another datacenter explicitly, or `any` for the overall stock) polls the stock read-only every 60 s and rings the terminal bell when the GPU is available; it never starts anything (a typo in the GPU or datacenter aborts with exit 4 instead of polling forever). Stock changes within minutes, so act right away and expect that a start can still fail.
2. **Redeploy (recommended with a Network Volume).** Create a new Pod that attaches the same volume; `/workspace` (model, HF and vLLM caches) is untouched, and RunPod's docs say a Network Volume can be attached to several Pods, so the stopped Pod does not have to be terminated first. RunPod picks a machine with a free B300 in the volume's datacenter:

   ```bash
   ./scripts/create-pod.sh          # dry run
   ./scripts/create-pod.sh --yes    # creates and verifies (bills the GPU)
   ```

   Use `./scripts/gpu-availability.sh` beforehand; a create can still fail for capacity (exit code 5, nothing created).
3. **Console migration (beta).** The RunPod console offers to migrate a stopped Pod to a machine with a free GPU. Their docs describe no API or CLI equivalent.

Redeploy and migration both produce a **new Pod ID, IP and proxy URL**. Afterwards update `RUNPOD_POD_ID` (local `.env`, GitHub secret) and `GLM_URL` (Claude Code), and re-run `check-endpoint.sh`.

For the 14/5 schedule this means: stop/start is cheap but can fail overnight; terminate/recreate is robust against machine binding but can fail on B300 capacity and changes the Pod ID daily. Decide deliberately. If the GPU is taken at 05:00, the start is retried (see "Wait" above) for at most two hours; if it stays taken, the day is skipped (no attempt begins after the cap; one already running can finish about 2 minutes later).

## Pod pool: several Pods on different machines

A stopped Pod resumes only on its own machine (see above). Keeping several Pods, each on a different machine, gives more chances that one of them can start, and a restart is faster than a new Pod (5:56 min against 10:09 min, measured). A stopped Pod costs nothing per hour and the Network Volume is shared and billed once; whether RunPod limits the number of Pods per account was not checked.

**The pool is not stored anywhere.** It is every Pod of your account whose name **starts with** `glm-5.3-flash-b300` (`POOL_PREFIX`), read live on every call and ignoring terminated ones. No Pod IDs are written into the repository or into `.env`, and Pods with other names are never touched.

```bash
./scripts/start-any.sh --dry-run    # show the pool, the order and the next name; sends nothing
./scripts/start-any.sh --wait       # get one Pod running, then measure the time to ready
./scripts/stop-any.sh               # stop the running pool Pod (ends the GPU billing)
```

`start-any.sh [--no-create] [--dry-run] [--wait] [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (defaults 1200 s and 30 s, interval at least 30 s) works in rounds:

1. If a pool Pod is already active (any status except `EXITED`, `ERROR` and `TERMINATED`, so an unexpected status counts as active too), it does nothing: **never two pool Pods at once** (they share `/workspace/vllm-cache` and would bill twice). A lock in `$TMPDIR` also keeps two runs on the same machine from starting or creating at the same time (the second one exits with code 4).
2. It tries to start the stopped pool Pods one after the other, the most recently used first. A try on an occupied machine costs nothing.
3. If none can start and the pool has fewer than `POOL_MAX` Pods (default 6), it creates a new Pod like `create-pod.sh --yes`, named `glm-5.3-flash-b300`, `glm-5.3-flash-b300-2`, and so on (`--no-create` turns this off), and verifies it with `verify-pod.sh`.
4. Otherwise it waits and repeats. No attempt begins after `MAX_WAIT_SECONDS` (exit code 3); an attempt already running is not cut off, and with many pool Pods a round can last minutes (each Pod tried costs up to two API calls of up to 60 s; a round makes about 5 + 2N calls for N stopped Pods).

Only "machine occupied" (`pod-start.sh` exit 5), "no capacity" (`create-pod.sh` exit 5) and a temporarily unreadable Pod are retried. Every other failure stops at once, so a Pod that may have been started or created is never retried. If a created Pod fails verification, `create-pod.sh` stops and renames it (see step 4) and `start-any.sh` stops without trying anything else. Cancelling stops the running attempt, but a request that was already sent cannot be undone. **A success bills the GPU (about $7.89/h).**

The script prints the ID and URL of the running Pod (`RUNPOD_POD_ID`, `GLM_URL`). With a pool, the ID in `.env` no longer has to name the running Pod; `--wait` measures exactly that Pod (an old `GLM_URL` from `.env` is ignored for it; `READY_TIMEOUT` sets the wait in seconds, default 3600). If the Pod runs but `wait-for-ready.sh` cannot confirm readiness, the exit code is 7 and the message says the Pod is running and billing. Remove Pods you no longer need with `pod-terminate.sh` (the volume stays); a full pool creates no new Pod. Exit codes: 0 a pool Pod is running, 3 gave up (nothing running), 4 another start/create is in progress, 7 running but not confirmed ready (`--wait`), 130 interrupted, 2 bad arguments, 1 other failure.

## Stop billing

- `pod-stop.sh` (one Pod) and `stop-any.sh` (every active pool Pod; it retries reading the Pod list up to five times before giving up) stop the GPU billing. Per RunPod's pricing docs a stopped Pod is not charged for its container disk (only for a Pod-local volume disk, at a higher rate); the Network Volume bills separately (about $0.07/GB/month) whether or not a Pod runs.
- `pod-terminate.sh --yes` deletes a Pod permanently. It does **not** delete the Network Volume, so the model and caches survive.

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

`VLLM_API_KEY` here is the client-side copy of the same value as the RunPod Secret (see `.env.example`). The vLLM image serves the Anthropic-style `/v1/messages` and `/v1/messages/count_tokens` endpoints (verified by the owner, including a tool-use round trip). The RunPod HTTP proxy closes connections after 100 seconds (HTTP 524), so use streaming clients; a slow first token with a very long context can otherwise hit that limit.

## vLLM concurrency note

`--max-num-seqs 6` matches the previously validated Pod (its configuration was read via the API on 2026-09-24). It caps concurrent sequences, which bounds KV-cache use with the 1M context; do not raise it without measuring memory and latency on the Pod.

## vLLM memory note

Keep `--gpu-memory-utilization 0.96` with MTP5. Do not reuse a fixed KV-cache byte value measured without MTP.

`HF_HUB_OFFLINE=1` (default, `offline_mode = true`) assumes the complete checkpoint is already on the persistent Network Volume.

## Startup times

Values measured by the owner on the validated deployment (B300, `--safetensors-load-strategy prefetch`, checkpoint already on the Network Volume). They are not produced by this repo's scripts:

| Phase | Time |
|---|---|
| Model loading without `prefetch` | about 1128 s (18:48 min) |
| Model loading with `prefetch` | about 216 s (3:36 min); the full prefetch took about 233 s |
| FlashInfer autotune | about 3 min, only on the first run; the result is cached under `/workspace/vllm-cache` |
| **Total, new Pod on a new machine** (Pod start to the first `/v1/models` 200) | **609 s (10:09 min), ±15 s**; measured 2026-09-26 by polling every 15 s from the Pod's `startedAt` (model and `vllm-cache` already on the volume) |
| **Total, restart of a stopped Pod on its old machine** | **356 s (5:56 min), ±10 s**; measured 2026-09-26 with `start-when-free.sh` and `wait-for-ready.sh` from the API's `startedAt` |

Each total was measured **once**. The new Pod ran on a machine that had not run it before, so image and container setup are included; a download of the weights is in neither. The restart of a stopped Pod on its old machine was about four minutes faster (plausibly because the image is already there on that machine, which is not measured). Measure it yourself with:

```bash
set -a; source .env; set +a
./scripts/start-when-free.sh 1200 30 && ./scripts/wait-for-ready.sh
```

`start-when-free.sh` retries the start every 30 s for up to 1200 s (20 minutes) while the GPU is occupied and ends after the first successful start; the interval must be at least 30 s, and you do not call `pod-start.sh` separately. Because of the `&&`, the measurement only begins after a successful start and never if the start failed. For a single attempt without retries use `./scripts/pod-start.sh && ./scripts/wait-for-ready.sh` instead. `wait-for-ready.sh` needs `VLLM_API_KEY` and `RUNPOD_POD_ID` (or `GLM_URL`) in your `.env`; without the key it aborts right after the Pod has already started and is billing. **A successful start bills the GPU.**

`wait-for-ready.sh` polls `/v1/models` with your `VLLM_API_KEY` (through `GLM_URL` or `https://$RUNPOD_POD_ID-8000.proxy.runpod.net`), prints the elapsed time and appends it to `.startup-times.log` (git-ignored, with `source=startedAt` or `source=script`). The clock starts at the Pod's `startedAt` from the API (needs `RUNPOD_API_KEY` and the Pod ID from the proxy URL or `RUNPOD_POD_ID`), so the result does not depend on when you launch the script; the API did update `startedAt` on a restart in the 2026-09-26 measurement, and your local clock must be accurate. Otherwise it says so and counts from its own start. The resolution is the polling interval (15 s by default). It is read-only. Every answer except 200 and 401/403 counts as "not ready yet" (the RunPod proxy answers 502/524 while the container boots; 404, 500 and connection errors are retried too); 401/403 aborts, because the key will not fix itself. If the Pod already answers on the first poll, nothing is logged (it was already running); if it was already `STARTING` when you began, the logged time is only partial. `GLM_URL` may end in `/v1`, which is stripped. `VLLM_ENGINE_READY_TIMEOUT_S=3600` is a generous limit, not a measurement.

## License

MIT, see [LICENSE](LICENSE). The license covers the code and documentation in this repository only, not RunPod, the model or the vLLM image, which have their own terms.
