#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-news}"
REMOTE_DIR="${REMOTE_DIR:-~/docker/news}"
BRANCH="${BRANCH:-master}"

ssh "${HOST}" "cd ${REMOTE_DIR} && test -d .git"
ssh "${HOST}" "cd ${REMOTE_DIR} && git fetch origin ${BRANCH} && git checkout ${BRANCH} && git pull --ff-only origin ${BRANCH}"
ssh "${HOST}" "cd ${REMOTE_DIR} && sudo scripts/install-browser-host.sh"
