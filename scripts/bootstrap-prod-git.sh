#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-news}"
REMOTE_DIR="${REMOTE_DIR:-~/docker/news}"
BRANCH="${BRANCH:-master}"
REPLACE_EXISTING="${REPLACE_EXISTING:-0}"

if [ -z "${REPO_URL:-}" ]; then
  echo "REPO_URL is required, for example:" >&2
  echo "  REPO_URL=git@github.com:ianwalther/news.git scripts/bootstrap-prod-git.sh" >&2
  exit 1
fi

ssh "${HOST}" "REPO_URL='${REPO_URL}' REMOTE_DIR='${REMOTE_DIR}' BRANCH='${BRANCH}' REPLACE_EXISTING='${REPLACE_EXISTING}' bash -s" <<'REMOTE'
set -euo pipefail

expanded_remote_dir="$(eval echo "${REMOTE_DIR}")"

if [ -d "${expanded_remote_dir}/.git" ]; then
  cd "${expanded_remote_dir}"
  git remote set-url origin "${REPO_URL}"
  git fetch origin "${BRANCH}"
  git checkout "${BRANCH}"
  git pull --ff-only origin "${BRANCH}"
  exit 0
fi

if [ -e "${expanded_remote_dir}" ] && [ "$(find "${expanded_remote_dir}" -mindepth 1 -maxdepth 1 | head -n 1)" ]; then
  if [ "${REPLACE_EXISTING}" != "1" ]; then
    echo "${expanded_remote_dir} exists and is not a git checkout." >&2
    echo "Set REPLACE_EXISTING=1 to move it aside, clone the repo, and copy .env.prod forward." >&2
    exit 1
  fi

  backup_dir="${expanded_remote_dir}.pre-git.$(date +%Y%m%d%H%M%S)"
  mv "${expanded_remote_dir}" "${backup_dir}"
  git clone --branch "${BRANCH}" "${REPO_URL}" "${expanded_remote_dir}"

  if [ -f "${backup_dir}/.env.prod" ]; then
    cp "${backup_dir}/.env.prod" "${expanded_remote_dir}/.env.prod"
  fi

  echo "Moved existing deploy directory to ${backup_dir}"
  exit 0
fi

mkdir -p "$(dirname "${expanded_remote_dir}")"
git clone --branch "${BRANCH}" "${REPO_URL}" "${expanded_remote_dir}"
REMOTE
