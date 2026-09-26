#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/neko}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./update.sh" >&2
  exit 1
fi

cd "$INSTALL_DIR"
docker compose pull
docker compose up -d
docker compose ps
