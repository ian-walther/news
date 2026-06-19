#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "${ROOT_DIR}/newspaper"
mix test

"${ROOT_DIR}/scripts/test-workers.sh"
