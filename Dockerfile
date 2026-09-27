# Minimal image for the RunPod-management scripts (bash + curl + python3 only). No compiled
# artifact goes into this repo, so there is no build stage here either: vLLM/GLM never run in
# this image, only on the RunPod Pod itself; this image only talks to the RunPod REST API from
# outside. It does NOT include scripts/claude-glm.sh's job (that execs the `claude` CLI on your
# machine and is meant to run there directly, not containerized); see the README.
FROM python:3.13-alpine

RUN apk add --no-cache bash curl

WORKDIR /app
COPY scripts/ ./scripts/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh scripts/*.sh

ENTRYPOINT ["docker-entrypoint.sh"]
