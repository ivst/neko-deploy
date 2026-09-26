#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/neko}"
BACKUP_DIR="${BACKUP_DIR:-/root}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR}/neko-backup-${STAMP}.tar.gz"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./backup.sh" >&2
  exit 1
fi

tar -C "$(dirname "$INSTALL_DIR")" -czf "$OUT" \
  "$(basename "$INSTALL_DIR")/docker-compose.yml" \
  "$(basename "$INSTALL_DIR")/.env" \
  "$(basename "$INSTALL_DIR")/Caddyfile" \
  "$(basename "$INSTALL_DIR")/firefox-profile" \
  "$(basename "$INSTALL_DIR")/firefox-policies"

chmod 600 "$OUT"
echo "$OUT"
