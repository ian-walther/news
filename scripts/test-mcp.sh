#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MCP_DIR="${ROOT_DIR}/mcp"

if [ ! -d "${MCP_DIR}/node_modules" ]; then
  npm ci --prefix "${MCP_DIR}"
fi

npm run check --prefix "${MCP_DIR}"
