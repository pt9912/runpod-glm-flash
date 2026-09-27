#!/usr/bin/env bash
# Loads .env (bind-mounted read-only at /app/.env by the Makefile) before running the given
# command, the same way you would `set -a; source .env; set +a` locally. Never prints it.
set -euo pipefail
if [ -f /app/.env ]; then
  set -a
  # shellcheck disable=SC1091
  source /app/.env
  set +a
fi
exec "$@"
