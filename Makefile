# THE documented way to run this repo's scripts: `make <target>`, through the Docker image
# (Dockerfile). Do not call scripts/*.sh directly (except scripts/claude-glm.sh, see below);
# only bash, curl and python3 go into the image, not onto your machine.
#
# .env, if present, is bind-mounted read-only into the container (never baked into the image,
# never printed) and sourced there; an already-exported variable still wins over the same name
# in .env (docker-entrypoint.sh). Without an .env file (for example in CI), the variables below
# are instead forwarded from whatever already exported them into this `make` invocation's
# environment (a GitHub Actions `env:` block, or `export RUNPOD_API_KEY=...` in your shell).
#
# wait-ready additionally bind-mounts .startup-times.log read-write: wait-for-ready.sh appends to
# it, and a `docker run --rm` container's own filesystem (and anything written to it) is discarded
# on exit, so without this mount the log would never survive past a single run.
#
# EXIT_FILE: GNU Make itself always exits 0 (success) or 2 (any recipe failure) -- verified, it
# does NOT preserve a recipe's actual exit code -- so the fine-grained codes documented in the
# README (5, 6, 8, 9, ...) are not visible in `$?` after a `make` invocation. Every target writes
# its real code to EXIT_FILE (git-ignored) as well, so scripting around `make` can still read it:
#   make check; rc=$$(cat .make-exit-code)
#
# A container's own pool lock (_pool.sh) never spans two `docker run` invocations: each gets a
# fresh filesystem, so the lock file starts empty every time and would never actually block a
# second run. Anything that can START or CREATE a Pod (create, start, pod-start,
# start-when-free) is therefore serialized HERE, by a lock on the host, before it ever reaches
# the container: only one such target can run at a time; a second exits 99 (see EXIT_FILE above)
# with a message. Each of the four gets a fixed, predictable container name (runpod-glm-<target>)
# so a stuck one can be found and stopped: `make abort` (or `docker ps --filter name=runpod-glm-`
# / `docker kill <name>` by hand). Prefer that over killing the `make`/`flock` process itself:
# Make does not forward signals to a recipe's children, so that can leave the container (and the
# lock) running; `docker kill` stops the container, which is what `docker run` (and therefore
# `flock`) is actually waiting on, so the lock is released correctly. Never delete LOCK_FILE by
# hand to "fix" a stuck lock: flock's lock belongs to the open file, not the path, so a fresh file
# at the same path lets a second create/start run immediately alongside a still-running first one
# -- exactly the double-billing this lock exists to prevent.
#
# Extra arguments: ARGS='...', e.g. `make gpu ARGS='B300 EU-NL-1'`.
IMAGE      := runpod-glm-tools
ENV_FILE   := $(CURDIR)/.env
ENV_MOUNT  := $(if $(wildcard $(ENV_FILE)),-v "$(ENV_FILE):/app/.env:ro",)
PASSTHROUGH := -e RUNPOD_API_KEY -e RUNPOD_BASE_URL -e RUNPOD_POD_ID -e NETWORK_VOLUME_ID \
               -e VLLM_API_KEY -e GLM_URL -e POOL_PREFIX -e POOL_MAX
LOCK_FILE  := $(or $(TMPDIR),/tmp)/runpod-glm-make-$(shell id -u).lock
LOG_FILE   := $(CURDIR)/.startup-times.log
EXIT_FILE  := $(CURDIR)/.make-exit-code
DOCKER_RUN_BASE := docker run --rm -i $(ENV_MOUNT) $(PASSTHROUGH)
DOCKER_RUN := $(DOCKER_RUN_BASE) $(IMAGE)
LOCKED     := flock -n -E 99 "$(LOCK_FILE)"

# CAPTURE: append to any recipe line. Persists the real exit code (see EXIT_FILE above) and
# re-raises it so make's own success/failure detection for this recipe is unaffected.
CAPTURE = ; rc=$$?; echo "$$rc" > "$(EXIT_FILE)"; exit $$rc

.PHONY: build precheck smoke gpu wait-gpu verify check wait-ready stop pod-stop pod-terminate \
        create start pod-start start-when-free abort

build:
	docker build -t $(IMAGE) .

# ---- read-only or single-Pod actions: never race a create/start, no host lock needed
precheck: build
	$(DOCKER_RUN) bash scripts/pre-check.sh $(ARGS)$(CAPTURE)
smoke: build
	$(DOCKER_RUN) bash scripts/v2-smoke.sh$(CAPTURE)
gpu: build
	$(DOCKER_RUN) bash scripts/gpu-availability.sh $(ARGS)$(CAPTURE)
wait-gpu: build
	$(DOCKER_RUN) bash scripts/wait-for-gpu.sh $(ARGS)$(CAPTURE)
verify: build
	$(DOCKER_RUN) bash scripts/verify-pod.sh $(ARGS)$(CAPTURE)
check: build
	$(DOCKER_RUN) bash scripts/check-endpoint.sh $(ARGS)$(CAPTURE)
wait-ready: build
	@touch "$(LOG_FILE)"
	$(DOCKER_RUN_BASE) -v "$(LOG_FILE):/app/.startup-times.log" $(IMAGE) bash scripts/wait-for-ready.sh $(ARGS)$(CAPTURE)
stop: build
	$(DOCKER_RUN) bash scripts/stop-any.sh$(CAPTURE)
pod-stop: build
	$(DOCKER_RUN) bash scripts/pod-stop.sh$(CAPTURE)
pod-terminate: build
	$(DOCKER_RUN) bash scripts/pod-terminate.sh $(ARGS)$(CAPTURE)

# ---- these can START or CREATE a Pod (GPU billing): serialized on the host, named for `make abort`
create: build
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-glm-create $(IMAGE) bash scripts/create-pod.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-glm-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(EXIT_FILE)"; exit "$$rc"
start: build
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-glm-start $(IMAGE) bash scripts/start-any.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-glm-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(EXIT_FILE)"; exit "$$rc"
pod-start: build
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-glm-pod-start $(IMAGE) bash scripts/pod-start.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-glm-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(EXIT_FILE)"; exit "$$rc"
start-when-free: build
	$(LOCKED) $(DOCKER_RUN_BASE) --name runpod-glm-start-when-free $(IMAGE) bash scripts/start-when-free.sh $(ARGS); rc=$$?; \
	  [ "$$rc" -ne 99 ] || echo "Another create/start is already running on this machine. Find it: docker ps --filter name=runpod-glm-   Stop it: make abort" >&2; \
	  echo "$$rc" > "$(EXIT_FILE)"; exit "$$rc"

# Finds whichever of the four named containers above is running (there is at most one, the host
# lock guarantees that) and stops it. The correct way to cancel a create/start; see the header.
abort:
	@cid="$$(docker ps -q --filter name=runpod-glm-)"; \
	if [ -z "$$cid" ]; then echo "Nothing to abort: no runpod-glm-* container is running."; exit 0; fi; \
	docker ps --filter name=runpod-glm- --format 'Stopping: {{.Names}} ({{.ID}}), running for {{.RunningFor}}'; \
	docker kill $$cid >/dev/null
