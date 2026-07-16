#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "${ROOT_DIR}"
docker compose -f docker-compose.dev.yml up -d postgres

cd "${ROOT_DIR}/newspaper"
mix setup

cd "${ROOT_DIR}"
npm ci --prefix workers
(
  cd workers
  npx playwright install --only-shell chromium
)
