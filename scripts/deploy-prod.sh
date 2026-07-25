#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-news}"
REMOTE_DIR="${REMOTE_DIR:-~/docker/news}"
BRANCH="${BRANCH:-master}"

ssh "${HOST}" "cd ${REMOTE_DIR} && test -d .git"
ssh "${HOST}" "cd ${REMOTE_DIR} && git fetch origin ${BRANCH} && git checkout ${BRANCH} && git pull --ff-only origin ${BRANCH}"
ssh "${HOST}" "cd ${REMOTE_DIR} && docker compose --env-file .env.prod -f docker-compose.prod.yml build app"
ssh "${HOST}" "cd ${REMOTE_DIR} && docker compose --env-file .env.prod -f docker-compose.prod.yml run --rm app /app/bin/migrate"
ssh "${HOST}" "cd ${REMOTE_DIR} && docker compose --env-file .env.prod -f docker-compose.prod.yml up -d --wait app"
