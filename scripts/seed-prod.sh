#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-news}"
REMOTE_DIR="${REMOTE_DIR:-~/docker/news}"

ssh "${HOST}" "cd ${REMOTE_DIR} && docker compose --env-file .env.prod -f docker-compose.prod.yml exec -T app /app/bin/newspaper eval Newspaper.Release.seed"
