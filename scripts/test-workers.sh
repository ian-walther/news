#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="${ROOT_DIR}/workers"

if [ ! -d "${WORKER_DIR}/node_modules" ]; then
  npm ci --prefix "${WORKER_DIR}"
fi

(cd "${WORKER_DIR}" && npx playwright install --only-shell chromium)
npm test --prefix "${WORKER_DIR}"
