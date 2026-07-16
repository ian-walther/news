#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="${ROOT_DIR}/workers/extraction-simple-html"

if [ "$#" -lt 1 ]; then
  echo "Usage: scripts/extract-simple-html.sh URL [--summary|--raw|--text|--html]" >&2
  exit 64
fi

URL="$1"
MODE="${2:---summary}"

if [ ! -d "${WORKER_DIR}/node_modules" ]; then
  npm ci --prefix "${WORKER_DIR}" >&2
fi

REQUEST="$(node -e 'process.stdout.write(JSON.stringify({schema_version: 1, implementation: "extraction.simple_html", url: process.argv[1], options: {timeout_ms: 20000, minimum_text_length: 500}}))' "$URL")"
RESULT="$(printf '%s' "$REQUEST" | "${WORKER_DIR}/bin/extract")"

case "$MODE" in
  --summary)
    printf '%s\n' "$RESULT" | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const result = JSON.parse(input);
  const summary = {
    status: result.status,
    failure_kind: result.failure_kind,
    retryable: result.retryable,
    title: result.title,
    final_url: result.final_url,
    text_length: (result.content_text || "").length,
    quality: result.quality,
    message: result.message
  };

  console.log(JSON.stringify(summary, null, 2));
});
'
    ;;
  --raw)
    printf '%s\n' "$RESULT"
    ;;
  --text)
    printf '%s\n' "$RESULT" | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const result = JSON.parse(input);
  process.stdout.write(result.content_text || "");
  if (result.content_text) {
    process.stdout.write("\n");
  }
});
'
    ;;
  --html)
    printf '%s\n' "$RESULT" | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk);
process.stdin.on("end", () => {
  const result = JSON.parse(input);
  process.stdout.write(result.content_html || "");
  if (result.content_html) {
    process.stdout.write("\n");
  }
});
'
    ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    echo "Usage: scripts/extract-simple-html.sh URL [--summary|--raw|--text|--html]" >&2
    exit 64
    ;;
esac
