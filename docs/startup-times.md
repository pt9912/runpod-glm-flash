# Startup times

[Deutsch](startup-times.de.md) | English · [← Guide](guide.md)

Values measured by the owner on the validated deployment (B300, `--safetensors-load-strategy
prefetch`, checkpoint already on the Network Volume). They are not produced by this repo's scripts:

| Phase | Time |
|---|---|
| Model loading without `prefetch` | about 1128 s (18:48 min) |
| Model loading with `prefetch` | about 216 s (3:36 min); the full prefetch took about 233 s |
| FlashInfer autotune | about 3 min, only on the first run; the result is cached under `/workspace/vllm-cache` |
| **Total, new Pod on a new machine** (Pod start to the first `/v1/models` 200) | **609 s (10:09 min), ±15 s**; measured 2026-09-26 by polling every 15 s from the Pod's `startedAt` (model and `vllm-cache` already on the volume) |
| **Total, restart of a stopped Pod on its old machine** | **356 s (5:56 min), ±10 s**; measured 2026-09-26 with `start-when-free.sh` and `wait-for-ready.sh` from the API's `startedAt` |

Each total was measured **once**. The new Pod ran on a machine that had not run it before, so image
and container setup are included; a download of the weights is in neither. The restart of a stopped
Pod on its old machine was about four minutes faster (plausibly because the image is already there
on that machine, which is not measured). Measure it yourself with:

```bash
make start-when-free ARGS='1200 30' && make wait-ready
```

`start-when-free.sh` retries the start every 30 s for up to 1200 s (20 minutes) while the GPU is
occupied and ends after the first successful start; the interval must be at least 30 s, and you do
not call `pod-start` separately. Because of the `&&`, the measurement only begins after a successful
start and never if the start failed. For a single attempt without retries use `make pod-start &&
make wait-ready` instead. `wait-for-ready.sh` needs `VLLM_API_KEY` and `RUNPOD_POD_ID` (or
`GLM_URL`) in your `.env`; without the key it aborts right after the Pod has already started and is
billing. **A successful start bills the GPU.**

`wait-for-ready.sh` polls `/v1/models` with your `VLLM_API_KEY` (for the single active pool Pod,
else `RUNPOD_POD_ID`, else `GLM_URL`; the choice is printed), prints the elapsed time and appends it
to `.startup-times.log` (git-ignored, with `source=startedAt` or `source=script`; `make wait-ready`
bind-mounts this one file read-write so it survives past the container that wrote it). The clock
starts at the Pod's `startedAt` from the API (needs `RUNPOD_API_KEY` and the Pod ID from the proxy
URL or `RUNPOD_POD_ID`), so the result does not depend on when you launch the script; the API did
update `startedAt` on a restart in the 2026-09-26 measurement, and your local clock must be
accurate. Otherwise it says so and counts from its own start. The resolution is the polling interval
(15 s by default). It is read-only. Every answer except 200 and 401/403 counts as "not ready yet"
(the RunPod proxy answers 502/524 while the container boots; 404, 500 and connection errors are
retried too); 401/403 aborts, because the key will not fix itself. If the Pod already answers on the
first poll, nothing is logged (it was already running); if it was already `STARTING` when you began,
the logged time is only partial. `GLM_URL` may end in `/v1`, which is stripped.
`VLLM_ENGINE_READY_TIMEOUT_S=3600` is a generous limit, not a measurement.
