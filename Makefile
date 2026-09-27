# THE documented way to run this repo's scripts: `make <target>`, through the Docker image
# (Dockerfile). Do not call scripts/*.sh directly (except scripts/claude-glm.sh, see below);
# only bash, curl and python3 go into the image, not onto your machine.
#
# .env, if present, is bind-mounted read-only into the container (never baked into the image,
# never printed) and sourced there. Without an .env file (for example in CI), the variables
# below are instead forwarded from whatever already exported them into this `make` invocation's
# environment (a GitHub Actions `env:` block, or `export RUNPOD_API_KEY=...` in your shell).
#
# wait-ready additionally bind-mounts .startup-times.log read-write: wait-for-ready.sh appends to
# it, and a `docker run --rm` container's own filesystem (and anything written to it) is discarded
# on exit, so without this mount the log would never survive past a single run.
#
# A container's own pool lock (_pool.sh) never spans two `docker run` invocations: each gets a
# fresh filesystem, so the lock file starts empty every time and would never actually block a
# second run. Anything that can START or CREATE a Pod (create, start, pod-start,
# start-when-free) is therefore serialized HERE, by a lock on the host, before it ever reaches
# the container: only one such target can run at a time.
#
# Extra arguments: ARGS='...', e.g. `make gpu ARGS='B300 EU-NL-1'`.
IMAGE      := runpod-glm-tools
ENV_FILE   := $(CURDIR)/.env
ENV_MOUNT  := $(if $(wildcard $(ENV_FILE)),-v "$(ENV_FILE):/app/.env:ro",)
PASSTHROUGH := -e RUNPOD_API_KEY -e RUNPOD_BASE_URL -e RUNPOD_POD_ID -e NETWORK_VOLUME_ID \
               -e VLLM_API_KEY -e GLM_URL -e POOL_PREFIX -e POOL_MAX
LOCK_FILE  := $(or $(TMPDIR),/tmp)/runpod-glm-make-$(shell id -u).lock
LOG_FILE   := $(CURDIR)/.startup-times.log
DOCKER_RUN_BASE := docker run --rm -i $(ENV_MOUNT) $(PASSTHROUGH)
DOCKER_RUN := $(DOCKER_RUN_BASE) $(IMAGE)
LOCKED     := flock -n -E 99 "$(LOCK_FILE)"

.PHONY: build precheck smoke gpu wait-gpu verify check wait-ready stop pod-stop pod-terminate \
        create start pod-start start-when-free

build:
	docker build -t $(IMAGE) .

# ---- read-only or single-Pod actions: never race a create/start, no host lock needed
precheck: build
	$(DOCKER_RUN) bash scripts/pre-check.sh $(ARGS)
smoke: build
	$(DOCKER_RUN) bash scripts/v2-smoke.sh
gpu: build
	$(DOCKER_RUN) bash scripts/gpu-availability.sh $(ARGS)
wait-gpu: build
	$(DOCKER_RUN) bash scripts/wait-for-gpu.sh $(ARGS)
verify: build
	$(DOCKER_RUN) bash scripts/verify-pod.sh $(ARGS)
check: build
	$(DOCKER_RUN) bash scripts/check-endpoint.sh $(ARGS)
wait-ready: build
	@touch "$(LOG_FILE)"
	$(DOCKER_RUN_BASE) -v "$(LOG_FILE):/app/.startup-times.log" $(IMAGE) bash scripts/wait-for-ready.sh $(ARGS)
stop: build
	$(DOCKER_RUN) bash scripts/stop-any.sh
pod-stop: build
	$(DOCKER_RUN) bash scripts/pod-stop.sh
pod-terminate: build
	$(DOCKER_RUN) bash scripts/pod-terminate.sh $(ARGS)

# ---- these can START or CREATE a Pod (GPU billing): serialized on the host, see above
create: build
	$(LOCKED) $(DOCKER_RUN) bash scripts/create-pod.sh $(ARGS) \
	  || { rc=$$?; [ $$rc -ne 99 ] || echo "Another create/start is already running on this machine (lock $(LOCK_FILE))." >&2; exit $$rc; }
start: build
	$(LOCKED) $(DOCKER_RUN) bash scripts/start-any.sh $(ARGS) \
	  || { rc=$$?; [ $$rc -ne 99 ] || echo "Another create/start is already running on this machine (lock $(LOCK_FILE))." >&2; exit $$rc; }
pod-start: build
	$(LOCKED) $(DOCKER_RUN) bash scripts/pod-start.sh $(ARGS) \
	  || { rc=$$?; [ $$rc -ne 99 ] || echo "Another create/start is already running on this machine (lock $(LOCK_FILE))." >&2; exit $$rc; }
start-when-free: build
	$(LOCKED) $(DOCKER_RUN) bash scripts/start-when-free.sh $(ARGS) \
	  || { rc=$$?; [ $$rc -ne 99 ] || echo "Another create/start is already running on this machine (lock $(LOCK_FILE))." >&2; exit $$rc; }
