# runpod-glm-flash

[Deutsch](README.de.md) | English

Bash tooling to run the validated GLM-5.3-Flash deployment (vLLM, 1M context) on an NVIDIA B300 in RunPod Secure Cloud.

**Full documentation:** all `make` targets, exit codes, Docker/Make internals, scheduling, the pool, MCP servers, Claude Code and vLLM tuning notes are in **[docs/guide.md](docs/guide.md)**; measured startup times are in **[docs/startup-times.md](docs/startup-times.md)**.

## Requirements

`docker` and `make`. Every script in this repo runs through `make <target>`, containerized (see the `Dockerfile`); you do not need `curl`/`python3` installed locally, and you do not call `scripts/*.sh` directly (the one exception is `scripts/claude-glm.sh`, see the guide).

## Setup

```bash
cp .env.example .env
$EDITOR .env   # fill in RUNPOD_API_KEY and NETWORK_VOLUME_ID
```

`VLLM_API_KEY` and (only for a fresh setup) `HF_TOKEN` are created as RunPod Secrets, not put in `.env`; see the guide's "Secrets" section for API key permissions and secret names.

## Quickstart

```bash
make create ARGS=--yes   # creates the Pod and verifies it (bills the GPU, about $7.89/h)
make wait-ready           # waits until vLLM answers, measures the start time
make check                # confirms the endpoint is protected and serving the right model

make start ARGS=--wait    # every day after: restarts or creates a pool Pod, waits until ready
make stop                 # when you're done (ends the GPU billing)
```

See **[docs/guide.md](docs/guide.md)** for everything else.

## License

MIT, see [LICENSE](LICENSE). The license covers the code and documentation in this repository only, not RunPod, the model or the vLLM image, which have their own terms.
