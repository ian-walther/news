#!/usr/bin/env bash
set -euo pipefail

NETWORK_NAME="${CDP_DOCKER_NETWORK:-newspaper_browser_control}"
NETWORK_SUBNET="${CDP_DOCKER_SUBNET:-172.31.254.0/29}"
NETWORK_GATEWAY="${CDP_DOCKER_GATEWAY:-172.31.254.1}"

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  actual_subnet="$(
    docker network inspect "${NETWORK_NAME}" \
      --format '{{(index .IPAM.Config 0).Subnet}}'
  )"
  actual_gateway="$(
    docker network inspect "${NETWORK_NAME}" \
      --format '{{(index .IPAM.Config 0).Gateway}}'
  )"
  internal="$(
    docker network inspect "${NETWORK_NAME}" \
      --format '{{.Internal}}'
  )"

  if [[ "${actual_subnet}" != "${NETWORK_SUBNET}" ||
        "${actual_gateway}" != "${NETWORK_GATEWAY}" ||
        "${internal}" != "true" ]]; then
    echo "Docker network ${NETWORK_NAME} does not match the browser-control contract" >&2
    echo "Expected: subnet=${NETWORK_SUBNET} gateway=${NETWORK_GATEWAY} internal=true" >&2
    echo "Actual:   subnet=${actual_subnet} gateway=${actual_gateway} internal=${internal}" >&2
    exit 1
  fi

  exit 0
fi

docker network create \
  --driver bridge \
  --internal \
  --subnet "${NETWORK_SUBNET}" \
  --gateway "${NETWORK_GATEWAY}" \
  "${NETWORK_NAME}" >/dev/null
