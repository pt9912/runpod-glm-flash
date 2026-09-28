# runpod-glm-flash — Guide

[Deutsch](guide.de.md) | English · [← README](../README.md)

Full documentation for this repo (bash tooling to run the validated GLM-5.3-Flash deployment on
an NVIDIA B300 in RunPod Secure Cloud). The README covers only the quickstart; everything else —
all `make` targets, exit codes, Docker/Make internals, scheduling, the pool, MCP servers, Claude
Code and vLLM tuning notes — is here. Measured startup times are in a separate file:
[docs/startup-times.md](startup-times.md).

All commands below are run from the repository root unless a block says otherwise.

## Current architecture

- **Pod creation:** `make create` (REST v2, verified right after creation). The pool of Pods is
  managed with `make start` / `make stop`.
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

| Make target | What it does | Changes state | GPU billing |
|---|---|---|---|
| `precheck` (`pre-check.sh`) | Checks tools, environment and `NETWORK_VOLUME_ID` (`ARGS=--online`: also one read-only API call) | no | no |
| `smoke` (`v2-smoke.sh`) | Lists your Pods (id, name, status) | no | no |
| `gpu` (`gpu-availability.sh`) | Shows the stock of a GPU type, overall or per datacenter | no | no |
| `wait-gpu` (`wait-for-gpu.sh`) | Polls the stock until the GPU is available; never starts anything | no | no |
| `create` (`create-pod.sh`) | Creates the Pod (dry run by default, `ARGS=--yes` to create) and verifies it | creates a Pod | starts |
| `verify` (`verify-pod.sh`) | Checks that a Pod matches the intended configuration | no | no |
| `check` (`check-endpoint.sh`) | Checks the API through the proxy: 401 without a key, 200 with it, model and context | no | no |
| `wait-ready` (`wait-for-ready.sh`) | Polls until vLLM answers and measures the start time (writes a local log) | no | no |
| `pod-start` (`pod-start.sh`) | Starts one stopped Pod | yes | starts |
| `start-when-free` (`start-when-free.sh`) | Retries `pod-start` for one Pod while its GPU is occupied | yes | starts |
| `start` (`start-any.sh`) | Pool: gets one Pod running, restarting stopped ones first, creating a new one if none can start | yes | starts |
| `pod-stop` (`pod-stop.sh`) | Stops one Pod | yes | ends |
| `stop` (`stop-any.sh`) | Stops every active Pod of the pool | yes | ends |
| `pod-terminate` (`pod-terminate.sh`) | Deletes a Pod permanently (needs `ARGS=--yes`; the volume stays) | yes | ends |

`_api.sh` and `_pool.sh` are helpers that the other scripts source; you do not run them, through
`make` or otherwise. `docs/schedule.example.yml` is a disabled example workflow. `pod-start`,
`pod-stop` and `pod-terminate` print the target (name, status, hourly cost) before they act,
`create` prints the request, and `make start ARGS=--dry-run` shows the pool and the order without
sending anything. The targets marked "starts" begin the GPU billing.

`scripts/claude-glm.sh` is the one script you do run directly, never through `make` (see "Claude
Code" below): it execs the `claude` CLI, which needs to run on your machine, not in the minimal
container `make` uses for everything else.

Typical flows:

```bash
# first time
make precheck ARGS=--online
make create                    # dry run: shows the request and the stock
make create ARGS=--yes         # creates the Pod and verifies it (bills the GPU)
make wait-ready && make check

# every day
make start ARGS=--wait         # gets one pool Pod running and waits until vLLM answers
make check
make stop                      # when you are done (ends the GPU billing)
```

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

**API key permissions:** read-only calls (`v2-smoke.sh`, `gpu-availability.sh`, `pre-check.sh
--online`) work with a read-only key, but `create-pod.sh`, `pod-start.sh`, `pod-stop.sh` and
`pod-terminate.sh` need write access to Pods. With a read-only or too narrowly restricted key they
fail with `HTTP 403` ("Access to the requested resource was denied"). That is a permission problem,
not a full GPU. Create a key with write access in the RunPod console (Settings > API Keys; RunPod
recommends restricted keys with the minimum permissions). Note that `pre-check.sh --online` cannot
detect missing write access, because it only performs a read.

Create these separately in the RunPod console:

- `VLLM_API_KEY`
- `HF_TOKEN` (only needed for a fresh setup with `create-pod.sh --online`)

Secret names are case-sensitive and must match `VLLM_SECRET_NAME` / `HF_SECRET_NAME` exactly
(defaults: `VLLM_API_KEY`, `HF_TOKEN`).

The Pod definition contains only RunPod Secret references (`{{ RUNPOD_SECRET_<name> }}`), never the
values.

## 0. Pre-flight check

```bash
make precheck                    # tools, environment, local files
make precheck ARGS=--online      # additionally one read-only API call to verify the key
```

Checks that `RUNPOD_API_KEY` is exported (a plain `. .env` does not export; use `set -a; source
.env; set +a` — or, through `make`, just have an `.env` file, it is bind-mounted and sourced
automatically) and that `NETWORK_VOLUME_ID` is set. `RUNPOD_POD_ID` and `VLLM_API_KEY` only produce
warnings because they are needed later. Secret values are never printed. Exit code 1 means a
blocking problem.

### Tools

Required: `docker` and `make`. `make <target>` is how every script in this repo is run (see "Docker
/ Make" below); you should not need to install `curl`/`python3` locally or call `scripts/*.sh`
directly (the one exception is `scripts/claude-glm.sh`, see "Claude Code").

`runpodctl` is **not** needed by this repo. Install it only if you want it for other things,
following <https://docs.runpod.io/runpodctl/overview>. One useful case is registering your SSH
public key, which you need for a Pod created with `--ssh` (`ssh-keygen -t ed25519`, then either
paste `~/.ssh/id_ed25519.pub` into the SSH Public Keys field of your RunPod account settings, or run
`runpodctl ssh add-key --key-file ~/.ssh/id_ed25519.pub`).

### Docker / Make

`make <target>` runs the corresponding script in a container built from the `Dockerfile`
(`bash`+`curl`+`python3` only; no model, no compiled artifact, vLLM/GLM never run in this image).
This is **the** documented way to run this repo, not a shortcut alongside calling `scripts/*.sh`
directly:

```bash
make smoke              # scripts/v2-smoke.sh
make start               # scripts/start-any.sh  (ARGS='...' for extra arguments, e.g. --dry-run)
make gpu ARGS='B300 EU-NL-1'
make stop
```

Two ways secrets reach the container, and how they differ:

| | `.env` file present | No `.env` file (e.g. CI) |
|---|---|---|
| Mechanism | bind-mounted read-only, sourced by `docker-entrypoint.sh` (the same as `set -a; source .env; set +a` locally) | already-exported variables (`RUNPOD_API_KEY`, `NETWORK_VOLUME_ID`, ...) forwarded with `-e VARNAME` |
| Baked into the image? | never | never |
| Visible in `docker inspect`? | no | **yes** — the values (not just the names) appear in `Config.Env` to anyone with Docker socket access on that host while the short-lived container runs |
| Precedence | an already-exported variable still wins over the same name in `.env` (a stray `.env` in a CI working directory cannot silently override a secret the job explicitly set) | — |

Each target rebuilds the image first (cheap once cached locally; a GitHub-hosted runner is a fresh
VM each time and rebuilds it from scratch every run) and needs no argument for the common case; see
the `Makefile` for the full target list.

`create`, `start`, `pod-start` and `start-when-free` can start or create a Pod (GPU billing). A
container's own pool lock (`_pool.sh`) cannot protect against two such runs, because each `docker
run` starts with a fresh, empty filesystem — the lock would never actually see a second one. The
Makefile therefore serializes these four targets itself with a lock **on the host** (`flock`,
outside the container) before it ever starts one; a second one prints a message and exits instead of
running. Each of the four gets a fixed container name (`runpod-glm-<target>`), so a stuck one can be
found and stopped: `make abort` (or `docker ps --filter 'name=^/runpod-glm-<target>$'` / `docker
kill <name>` by hand). Prefer that over killing the `make` process itself — Make does not forward
signals to a recipe's children, so that can leave the container (and the lock) running — and never
delete the lock file by hand to "fix" a stuck lock: the lock belongs to the open file, not the path,
so a fresh file at the same path lets a second create/start run immediately alongside a
still-running first one, exactly the double-billing this lock exists to prevent. The lock file
itself lives under `$XDG_RUNTIME_DIR` (like `_pool.sh`'s own lock below), not `$TMPDIR`: unlike
`XDG_RUNTIME_DIR`, `TMPDIR` is not guaranteed to be the same path across two shells of the same user
on every OS, which would silently defeat the serialization.

GNU Make itself always exits `0` or `2`, regardless of the wrapped script's real exit code, so the
fine-grained codes documented throughout this guide (5, 6, 8, 9, ...) are not visible in `$?` after
a `make <target>` call. Every target also writes its real code to a **per-target** file,
`.make-exit-code.<target>` (git-ignored), for anything that scripts around `make`: `make check;
rc=$(cat .make-exit-code.check)`. Per-target, not one shared file, so a `make check` running
alongside a `make start` (for example a monitoring loop polling while a start is in progress) cannot
read back the wrong target's code.

The Dockerfile is pinned by digest (`python:3.13-alpine@sha256:...`) and by exact `apk` package
version (`bash`, `curl`), not just tags, so a rebuild weeks later cannot silently pick up a
different Alpine/Python point release.

`scripts/claude-glm.sh` is deliberately **not** one of these targets: it execs the `claude` CLI,
which needs to run on your machine, not in a minimal container that does not have it.

## 1. Read-only REST v2 check

```bash
make smoke
```

This performs a GET against `/v2/pods`; it does not create a GPU. It prints only id, name and status
per Pod, because the raw response contains every Pod's `env`.

## 2. Configure

Put the ID of your existing Network Volume into `.env` (template: `.env.example`):

```bash
echo 'NETWORK_VOLUME_ID=<your Network Volume ID>' >> .env
```

A Network Volume is bound to one datacenter, so a B300 must be free **in that datacenter**; a free
B300 elsewhere does not help. `create-pod.sh` places the Pod in the volume's datacenter
automatically. Check stock first with `make gpu ARGS='B300 <DATACENTER>'` (without a datacenter it
uses the datacenter of the Pod `RUNPOD_POD_ID` if that is set, otherwise the overall stock; pass
`any` for the overall stock). `B300` matches the exact GPU name; the full GPU id is `NVIDIA B300
SXM6 AC`, which you can pass as well. If no exact id/name matches, it lists every GPU containing the
text and says so.

| Exit code | Meaning |
|---|---|
| 0 | in stock |
| 2 | no stock |
| 4 | unknown GPU type or datacenter (typo) |
| 1 | API error |

By default the Pod runs in offline mode: the checkpoint is expected on the volume,
`HF_HUB_OFFLINE=1` is set and no `HF_TOKEN` is sent. For a fresh setup or re-download use `make
create ARGS=--online`; downloads are then allowed and the `HF_TOKEN` secret is injected.

## 3. Dry run

```bash
make create
```

The default is a **dry run**: it reads the datacenter of the volume, refuses if a Pod with the same
name already exists, prints the complete request (only RunPod Secret references, no secret values)
plus the current stock, and creates nothing. Options (`ARGS='...'`): `--online` (downloads allowed),
`--ssh` (also `22/tcp` and `startSsh`; off by default). Environment overrides: `POD_NAME`, `GPU_ID`,
`DATACENTER`, `CONTAINER_DISK_GB`, `VLLM_SECRET_NAME`, `HF_SECRET_NAME`.

Review the request: 1× B300, `mounts.network` with your volume on `/workspace`, port 8000, the
image, the vLLM arguments (1M context, MTP, `--max-num-seqs 6`) and that `VLLM_API_KEY` is a `{{
RUNPOD_SECRET_... }}` reference.

## 4. Create the Pod

```bash
make create ARGS=--yes
```

This is the step that starts billable B300 compute (about $7.89/h). The script never retries a
request that may have been sent. It then runs `verify-pod.sh` (read-only): 1× B300, the volume on
`/workspace`, port 8000, `VLLM_API_KEY` as a Secret reference (never empty, never a literal value),
the caches on `/workspace` and the key vLLM arguments; it prints env variable names only, never
values. On success, put the printed Pod ID into `.env` as `RUNPOD_POD_ID`. The check reads the Pod
up to three times, so one network hiccup is not read as "the Pod is wrong". If the check **fails**,
the Pod is wrong and billing, so `create-pod.sh` cleans up, every step retried: it **stops** it
(billing ends), **renames** it to `failed-<name>-<id>` (it leaves the pool, so it is never restarted
by accident, but stays for you to inspect) and, if stopping or renaming still did not work,
**terminates** it as a fallback. With `ARGS=--terminate-on-fail` it is deleted right away. The final
message says exactly what worked and, if anything did not, the command to end it:

```bash
RUNPOD_POD_ID=<the new ID> make pod-terminate ARGS=--yes
```

If the check **could not run** at all (the Pod could not be read, exit 6), the Pod is left running
untouched and the message says to run `verify-pod.sh <POD_ID>`; that is not evidence that it is
wrong.

`pod-terminate` deletes a Pod permanently (without `ARGS=--yes` it only shows the target); the
Network Volume is a separate resource and stays, so model and caches survive. `create-pod.sh`
refuses to create a second Pod while another Pod of the pool is active (`ARGS=--force` overrides
that and, if the default name is taken, uses the next free name such as `glm-5.3-flash-b300-2`) and
takes a lock so that two runs on the same machine cannot create at the same time. You can verify any
Pod later with `make verify ARGS=[POD_ID]`.

Exit codes of `create-pod.sh`:

| Exit code | Meaning |
|---|---|
| 0 | done |
| 1 | failure or failed verification |
| 2 | bad arguments (including a `POD_NAME` that does not start with `POOL_PREFIX` without `--force`: no pool guard would ever see that Pod) |
| 3 | a Pod with this name exists or a pool Pod is active |
| 4 | another start/create is in progress |
| 5 | no capacity (nothing created; only the "no instances available" answer counts as capacity, any other HTTP 400 is a rejected request) |
| 6 | created but the verification could not run (including an API response of an unexpected shape) |

## 5. Check the endpoint

```bash
make check
```

Once the Pod answers (`wait-ready`), this read-only check goes through the RunPod HTTPS proxy and
needs no SSH. It prints only statuses, the model id and the context length, never a key. It checks
that:

- **without a key** the API answers `401` (a `200` means the server is open to everyone: stop the
  Pod and check the Secret `VLLM_API_KEY`),
- **with your `VLLM_API_KEY`** it answers `200` (a `401` means the server runs with a different key,
  for example an unresolved Secret placeholder after a mistyped secret name),
- the served model is `glm-5.3-flash` with `max_model_len` 1048576 (a different model root only
  warns).

Which Pod: the ID you pass (`make check ARGS=<POD_ID>`), else the single **active pool Pod**, else
`RUNPOD_POD_ID`, else `GLM_URL`; the chosen Pod and the reason are printed, so a stale ID in `.env`
cannot send the check to a stopped Pod. If several pool Pods are active, give the ID (it must be
lower-case letters and digits). Only the `/v1` API is protected by vLLM; `/health` and `/metrics`
are open by design.

| Exit code | Meaning |
|---|---|
| 0 | all checks passed |
| 1 | a check failed (including an unexpected answer to the no-key test) |
| 2 | bad arguments or missing `VLLM_API_KEY` |
| 3 | the endpoint does not answer (still booting, stopped, or a 5xx/429/404) |

**SSH is off by default:** a new Pod exposes only `8000/http`. `make create ARGS=--ssh` (or
`CREATE_POD_SSH=1` for `make start`) also opens `22/tcp` and starts ssh. That needs SSH public keys
registered in your RunPod account and an sshd in the container, which is not verified for this
image, and it allows root login: use keys only.

## 14/5 scheduling

The intended schedule is **05:00 to 19:00 local time, Monday to Friday** (14 hours, 5 days). The
early start is deliberate: the owner's experience is that a free B300 is easier to find early in the
morning (not verified here; stock changes within minutes, check with `make gpu` or `make wait-gpu`).

| | start 05:00 | stop 19:00 |
|---|---|---|
| summer time (CEST, UTC+2) | 03:00 UTC | 17:00 UTC |
| winter time (CET, UTC+1) | 04:00 UTC | 18:00 UTC |

GitHub Actions cron runs in UTC only, so the cron lines must be changed twice a year (last Sunday of
March and October), or you use a timezone-aware external scheduler.

`docs/schedule.example.yml` is deliberately **disabled** and kept outside `.github/workflows/`, so
GitHub never runs it. It documents the intended GitHub Actions shape without risking accidental GPU
spend: the start job runs `make start` (`start-any.sh` through the Docker image), which restarts the
pool Pods one after the other and creates a new one if none can start, repeating every 60 s for at
most `MAX_WAIT_SECONDS` (7200 = 2 h), then gives up and fails the job (the Pod stays stopped that
day; GitHub usually, not reliably, notifies you); the job has a hard `timeout-minutes` cap; the stop
job runs `make stop`; scheduled runs derive start/stop from the cron entry. `make` builds the image
itself, so no separate build step is needed (cheap once cached locally; a GitHub-hosted runner is a
fresh VM each time and rebuilds from scratch every run). The secrets are `RUNPOD_API_KEY` (write
access to Pods) and `NETWORK_VOLUME_ID` (needed to create new Pods); there is no `.env` file on the
runner, so the Makefile forwards these already-exported secrets into the container instead. **Every
successful start bills the GPU**, so review the file before enabling it. GitHub only keeps one
pending run per concurrency group: do not dispatch manual runs while a start is still retrying, or a
queued stop can be dropped. Cron runs can be delayed or dropped, and scheduled workflows of inactive
public repos are disabled after 60 days, both relevant for the stop job. Move it to
`.github/workflows/` and enable it only after pinning actions by SHA and deciding how to handle
European DST.

All API calls time out (10 s connect, 60 s total; override with `API_CONNECT_TIMEOUT` /
`API_MAX_TIME`), so a stalled connection cannot hang a scheduled job. If the connection breaks after
a start/stop request was sent, the scripts say the outcome is unknown; check with `make smoke`
before retrying.

`pod-start.sh` and `pod-stop.sh` (`make pod-start` / `make pod-stop`) call the REST v2 endpoint
`POST /v2/pods/{id}/action` (`start`/`stop`). Both first print the target (name, status, hourly
cost, datacenter) so a stale `RUNPOD_POD_ID` is visible, and do nothing if the Pod is already in the
wanted state. Starting bills the GPU immediately. Stopping is risky for a scheduled setup: see "If
the GPU is occupied". Do not automate destructive redeploy until the exact migration/redeploy
behavior has been tested on the account.

## If the GPU is occupied

A stopped Pod keeps its machine assignment and resumes on the same host. If someone else rents the
GPU meanwhile, `pod start` cannot succeed: `HTTP 400 {"detail":"There are not enough free GPUs on
the host machine to start this pod."}`; nothing is started or billed in that case. RunPod's docs
describe three options:

1. **Wait.** The GPU frees up once the other user stops their Pod. `make start-when-free
   ARGS='[MAX_WAIT_SECONDS] [INTERVAL_SECONDS]'` (defaults 7200 s, 60 s) retries the actual start
   while the GPU is occupied and stops after one success or at the cap. That is the right tool for a
   stopped Pod: it resumes on its own machine, which the catalog stock says nothing about, and a
   failed attempt costs nothing. Cancelling the run stops the running attempt, but a start request
   that was already sent cannot be undone (the script then says to check `make smoke`). **A
   successful start bills the GPU.**

   `pod-start.sh`'s exit codes, and what `start-when-free`/`start` do with each:

   | Exit code | Meaning | What happens |
   |---|---|---|
   | 9 | another pool Pod is already active | refused unless `ARGS=--force`, so a stale `RUNPOD_POD_ID` cannot start a second billing Pod |
   | 4 | `start-any.sh`/`create-pod.sh` already holds the host lock | refused, nothing sent |
   | 5 | GPU occupied | retried |
   | 6 | Pod could not be read, nothing sent | retried (`start-when-free` up to 10 times in a row; `start` just skips the Pod that round) |
   | 8 | definitively rejected (unknown Pod, wrong status, or a rejected 4xx other than "occupied") | nothing was sent or changed; `start` skips it and tries the next Pod |
   | anything else | — | aborts at once, so a possibly started Pod is never started twice |

   If you only want to be notified, not to start, `make wait-gpu ARGS=B300` (uses the datacenter of
   your Pod from `RUNPOD_POD_ID`; name another datacenter explicitly, or `any` for the overall
   stock) polls the stock read-only every 60 s and rings the terminal bell when the GPU is
   available; it never starts anything (a typo in the GPU or datacenter aborts with exit 4 instead
   of polling forever). Stock changes within minutes, so act right away and expect that a start can
   still fail.
2. **Redeploy (recommended with a Network Volume).** Create a new Pod that attaches the same volume;
   `/workspace` (model, HF and vLLM caches) is untouched, and RunPod's docs say a Network Volume can
   be attached to several Pods, so the stopped Pod does not have to be terminated first. RunPod
   picks a machine with a free B300 in the volume's datacenter:

   ```bash
   make create              # dry run
   make create ARGS=--yes   # creates and verifies (bills the GPU)
   ```

   Use `make gpu` beforehand; a create can still fail for capacity (exit code 5, nothing created).
3. **Console migration (beta).** The RunPod console offers to migrate a stopped Pod to a machine
   with a free GPU. Their docs describe no API or CLI equivalent.

Redeploy and migration both produce a **new Pod ID, IP and proxy URL**. Afterwards update
`RUNPOD_POD_ID` (local `.env`) and `GLM_URL` (Claude Code), and re-run `make check`.

For the 14/5 schedule this means: stop/start is cheap but can fail overnight; terminate/recreate is
robust against machine binding but can fail on B300 capacity and changes the Pod ID daily. Decide
deliberately. If the GPU is taken at 05:00, the start is retried (see "Wait" above) for at most two
hours; if it stays taken, the day is skipped (no attempt begins after the cap; one already running
can finish about 2 minutes later).

## Pod pool: several Pods on different machines

A stopped Pod resumes only on its own machine (see above). Keeping several Pods, each on a different
machine, gives more chances that one of them can start, and a restart is faster than a new Pod (5:56
min against 10:09 min, measured). A stopped Pod costs nothing per hour and the Network Volume is
shared and billed once; whether RunPod limits the number of Pods per account was not checked.

**The pool is not stored anywhere.** It is every Pod of your account whose name **starts with**
`glm-5.3-flash-b300` (`POOL_PREFIX`), read live on every call and ignoring terminated ones. No Pod
IDs are written into the repository or into `.env`, and Pods with other names are never touched.

```bash
make start ARGS=--dry-run    # show the pool, the order and the next name; sends nothing
make start ARGS=--wait       # get one Pod running, then measure the time to ready
make stop                    # stop the running pool Pod (ends the GPU billing)
```

`start-any.sh [--no-create] [--dry-run] [--wait] [MAX_WAIT_SECONDS] [INTERVAL_SECONDS]` (`make start
ARGS='...'`; defaults 1200 s and 30 s, interval at least 30 s) works in rounds:

1. If a pool Pod is already active (any status except `EXITED`, `ERROR` and `TERMINATED`, so an
   unexpected status counts as active too), it does nothing: **never two pool Pods at once** (they
   share `/workspace/vllm-cache` and would bill twice). A kernel file lock (`POOL_LOCKFILE`, by
   default in `$XDG_RUNTIME_DIR` or `/tmp`) also keeps two runs on the same machine from starting or
   creating at the same time (the second one exits with code 4); the lock is released even if a run
   is killed. (Through `make`, this is the container's own lock, good for one `docker run`; the
   Makefile adds its own host-side lock so two `make start`/`make create` invocations are serialized
   too, see "Docker / Make".)
2. It tries to start the stopped pool Pods one after the other, the most recently used first. A try
   on an occupied machine costs nothing.
3. If none can start and the pool has fewer than `POOL_MAX` Pods (default 6), it creates a new Pod
   like `make create ARGS=--yes`, named `glm-5.3-flash-b300`, `glm-5.3-flash-b300-2`, and so on
   (`--no-create` turns this off), and verifies it with `verify-pod.sh`.
4. Otherwise it waits and repeats. No attempt begins after `MAX_WAIT_SECONDS` (exit code 3); an
   attempt already running is not cut off, and with many pool Pods a round can last minutes (each
   Pod tried costs up to three API calls of up to 60 s; a round makes about 5 + 3N calls for N
   stopped Pods).

Retried or skipped instead of aborting the whole round:

| Exit code (of) | Meaning |
|---|---|
| 5 (`pod-start`) | machine occupied |
| 5 (`create`) | no capacity |
| 6 | a temporarily unreadable Pod |
| 8 | a definitively rejected Pod (unknown Pod, wrong status, or a rejected 4xx other than "occupied"; nothing was sent or changed) |

Every other failure stops at once, so a Pod that may have been started or created is never retried.
If a created Pod fails verification, `create-pod.sh` stops and renames it (see step 4) and
`start-any.sh` stops without trying anything else. Cancelling stops the running attempt, but a
request that was already sent cannot be undone. **A success bills the GPU (about $7.89/h).**

The script prints the ID and URL of the running Pod (`RUNPOD_POD_ID`, `GLM_URL`). With a pool, the
ID in `.env` no longer has to name the running Pod; `--wait` measures exactly that Pod (an old
`GLM_URL` from `.env` is ignored for it; `READY_TIMEOUT` sets the wait in seconds, default 3600).
Later, `verify`, `wait-ready` and `check` pick the single active pool Pod on their own and print
which one and why; `pod-start`, `pod-stop` and `pod-terminate` still use `RUNPOD_POD_ID`. If the Pod
runs but `wait-for-ready.sh` cannot confirm readiness, the exit code is 7 and the message says the
Pod is running and billing. Remove Pods you no longer need with `make pod-terminate ARGS=--yes` (the
volume stays); a full pool creates no new Pod.

Exit codes of `start-any.sh`:

| Exit code | Meaning |
|---|---|
| 0 | a pool Pod is running |
| 1 | other failure |
| 2 | bad arguments |
| 3 | gave up (nothing running) |
| 4 | another start/create is in progress |
| 7 | running but not confirmed ready (`--wait`) |
| 130 | interrupted |

## Stop billing

- `make pod-stop` (one Pod) and `make stop` (every active pool Pod; it retries reading the Pod list
  up to five times, `STOP_LIST_TRIES` and `STOP_RETRY_DELAY`, before giving up) stop the GPU
  billing. Per RunPod's pricing docs a stopped Pod is not charged for its container disk (only for a
  Pod-local volume disk, at a higher rate); the Network Volume bills separately (about
  $0.07/GB/month) whether or not a Pod runs.
- `make pod-terminate ARGS=--yes` deletes a Pod permanently. It does **not** delete the Network
  Volume, so the model and caches survive.

## Optional: Runpod MCP servers

This repo does not need MCP. Runpod offers two
[MCP servers](https://docs.runpod.io/get-started/mcp-servers) that let an AI coding agent such as
Claude Code work with Runpod directly. The commands below are taken from Runpod's documentation
and were not tested with this repo; the scripts here work without them.

**Docs server** (read-only documentation search, no login):

```bash
claude mcp add runpod-docs --scope user --transport http https://docs.runpod.io/mcp
```

**API server** (manages Pods, endpoints, templates, network volumes and registries through the REST
API, v2 by default). It has **write access to your account and can start billable Pods**, so treat
it like the API key itself. Recommended setup is the hosted server with "Sign in with Runpod"
(OAuth): a browser opens on first use, and no key is stored on disk.

```bash
claude mcp add --transport http runpod -s user https://mcp.getrunpod.io/
```

Alternatives:

- Guided installer, detects your clients (Claude Code, Claude Desktop, Cursor, Windsurf, VS Code):
  `npx @runpod/mcp-server@latest add`; undo with `npx @runpod/mcp-server@latest remove`.
- Hosted server with an API key instead of OAuth: add `--header "Authorization: Bearer
  $RUNPOD_API_KEY"` to the command above.
- Local server: `claude mcp add runpod --scope user -e RUNPOD_API_KEY=... -- npx -y
  @runpod/mcp-server@latest`. The key is then stored in your Claude Code configuration, so prefer
  the OAuth variant.

Rules of thumb:

- Use `-s user` / `--scope user`. A project-scoped configuration is written to a `.mcp.json` in the
  repository and could end up in a commit; never put a key there.
- Use an API key with only the permissions you need (see "API key permissions"), and disable or
  delete it when you no longer need it.
- Check the connection with `/mcp` inside Claude Code; remove a server with `claude mcp remove
  runpod`.
- Starting or creating Pods through an agent bills the GPU exactly like the scripts do. Keep
  reviewing what the agent is about to do.

## Claude Code

```bash
./scripts/claude-glm.sh
```

It resolves the Pod (the single active pool Pod, else `RUNPOD_POD_ID`, else `GLM_URL`; the choice
and why are printed), waits until `/v1/models` actually answers `200` with your key (`READY_RETRIES`
/ `READY_DELAY`, default 5 / 5 s, so a RunPod proxy still warming up after a start does not fail the
session outright), then sets the environment below and execs `claude --model glm-5.3-flash`, passing
through any arguments. It never starts or creates a Pod; if none is running it says so and points at
`make start`.

```bash
./scripts/claude-glm.sh --resume
./scripts/claude-glm.sh -p "Fix the failing test"
```

| Exit code | Meaning |
|---|---|
| 1 | no pool Pod running (or the endpoint never became ready, or several pool Pods are active) |
| 2 | `VLLM_API_KEY` not set |
| 127 | `claude` not found |
| (other) | `claude`'s own exit code |

The script does not `cd` anywhere and reads no `.env` file itself, so it can be invoked from any
working directory — from another repo, for example — as long as the required variables are already
exported in that shell:

```bash
RUNPOD_GLM=/path/to/runpod-glm
set -a; source "$RUNPOD_GLM/.env"; set +a   # only if the variables live in this repo's .env
"$RUNPOD_GLM/scripts/claude-glm.sh"
```

`claude` still picks up the directory you run it from as its own project context, independent of
where the script lives.

Running the script several times, in parallel or from different shells, starts that many separate
`claude` sessions; there is no per-invocation isolation beyond what Claude Code itself provides. All
of them resolve to, and share, the same Pod/endpoint (`$URL`), so they compete for the same GPU
capacity (see "vLLM concurrency note" below).

Equivalent by hand, without the readiness check:

```bash
export GLM_URL='https://POD_ID-8000.proxy.runpod.net'
export ANTHROPIC_BASE_URL="${GLM_URL%/}"
export ANTHROPIC_AUTH_TOKEN="$VLLM_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=1048576
claude --model glm-5.3-flash
```

`VLLM_API_KEY` here is the client-side copy of the same value as the RunPod Secret (see
`.env.example`). The vLLM image serves the Anthropic-style `/v1/messages` and
`/v1/messages/count_tokens` endpoints (verified by the owner, including a tool-use round trip). The
RunPod HTTP proxy closes connections after 100 seconds (HTTP 524), so use streaming clients; a slow
first token with a very long context can otherwise hit that limit.

## vLLM concurrency note

`--max-num-seqs 6` (set in `create-pod.sh`) caps concurrent sequences, which bounds KV-cache use with
the 1M context; do not raise it without measuring memory and latency on the Pod.

## vLLM memory note

Keep `--gpu-memory-utilization 0.96` with MTP5. Do not reuse a fixed KV-cache byte value measured
without MTP.

`HF_HUB_OFFLINE=1` (the default; `create-pod.sh --online` turns it off) assumes the complete
checkpoint is already on the persistent Network Volume.

## Startup times

Measured startup times and the methodology behind them: **[docs/startup-times.md](startup-times.md)**.
