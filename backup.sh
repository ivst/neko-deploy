#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/neko}"
BACKUP_DIR="${BACKUP_DIR:-/root}"
BACKUP_AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
PLAINTEXT=0

usage() {
  cat <<'EOF'
Usage: sudo BACKUP_AGE_RECIPIENT=age1... ./backup.sh [--plaintext]

Backups MUST be encrypted with age by default.
  BACKUP_AGE_RECIPIENT  Public age recipient (age1... or SSH public key)
  BACKUP_DIR            Output directory (default: /root)
  INSTALL_DIR           Neko installation directory (default: /opt/neko)

Options:
  --plaintext  Explicitly opt out of encryption (unsafe, not recommended)
  -h, --help   Show help

Keep the matching private identity off the VPS if possible.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plaintext)
      PLAINTEXT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./backup.sh" >&2
  exit 1
fi

if [[ "${PLAINTEXT}" -eq 0 ]]; then
  if [[ -z "${BACKUP_AGE_RECIPIENT}" ]]; then
    echo "ERROR: BACKUP_AGE_RECIPIENT required; refusing unencrypted backup." >&2
    echo "To explicitly opt out, use --plaintext (NOT recommended)." >&2
    exit 1
  fi
  if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: age is required. Install: sudo apt-get install age" >&2
    exit 1
  fi
else
  echo "WARNING: Creating UNENCRYPTED backup containing passwords and cookies." >&2
fi

# Owner-only permissions; encrypted path never creates a temporary plain tarball.
umask 077
mkdir -p -- "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp "${BACKUP_DIR%/}/.neko-backup.XXXXXXXX")"
SUFFIX="${TMP##*.neko-backup.}"
if [[ "$PLAINTEXT" -eq 1 ]]; then
  OUT="${BACKUP_DIR%/}/neko-backup-${STAMP}-${SUFFIX}.tar.gz"
else
  OUT="${BACKUP_DIR%/}/neko-backup-${STAMP}-${SUFFIX}.tar.gz.age"
fi
trap 'rm -f -- "$TMP"' EXIT

if [[ "$PLAINTEXT" -eq 1 ]]; then
  tar -C "$(dirname "$INSTALL_DIR")" -czf "$TMP" \
    "$(basename "$INSTALL_DIR")/docker-compose.yml" \
    "$(basename "$INSTALL_DIR")/.env" \
    "$(basename "$INSTALL_DIR")/Caddyfile" \
    "$(basename "$INSTALL_DIR")/firefox-profile" \
    "$(basename "$INSTALL_DIR")/firefox-policies"
else
  tar -C "$(dirname "$INSTALL_DIR")" -czf - \
    "$(basename "$INSTALL_DIR")/docker-compose.yml" \
    "$(basename "$INSTALL_DIR")/.env" \
    "$(basename "$INSTALL_DIR")/Caddyfile" \
    "$(basename "$INSTALL_DIR")/firefox-profile" \
    "$(basename "$INSTALL_DIR")/firefox-policies" \
    | age -r "$BACKUP_AGE_RECIPIENT" > "$TMP"
fi

chmod 600 "$TMP"
mv -- "$TMP" "$OUT"
trap - EXIT
printf '%s\n' "$OUT"
