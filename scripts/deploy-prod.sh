#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-news}"
REMOTE_DIR="${REMOTE_DIR:-~/docker/news}"

rsync -az --delete \
  --exclude='/deps/' \
  --exclude='/_build/' \
  --exclude='/.git/' \
  --exclude='/.env' \
  --exclude='/.env.dev' \
  --exclude='/.env.prod' \
  --exclude='/tmp/' \
  --exclude='/cover/' \
  --exclude='/doc/' \
  ./ "${HOST}:${REMOTE_DIR}/"

ssh "${HOST}" "cd ${REMOTE_DIR} && docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --build app"
ssh "${HOST}" "cd ${REMOTE_DIR} && docker compose --env-file .env.prod -f docker-compose.prod.yml exec -T app /app/bin/migrate"
