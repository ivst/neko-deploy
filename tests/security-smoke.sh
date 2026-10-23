#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Run as root: sudo bash tests/security-smoke.sh" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/backups"

# Stub system effects; never install Docker, access network or start services.
for cmd in apt-get systemctl docker; do
  cat > "$TMP/bin/$cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMP/bin/$cmd"
done
export PATH="$TMP/bin:$PATH"

INSTALL_DIR="$TMP/neko"
SECRET_USER="test-user-secret-value"
SECRET_ADMIN="test-admin-secret-value"
NEKO_USER_PASSWORD="$SECRET_USER" NEKO_ADMIN_PASSWORD="$SECRET_ADMIN" \
  bash "$REPO_DIR/install.sh" --install-dir "$INSTALL_DIR" \
  --domain example.com --public-ip 203.0.113.10 --no-start > "$TMP/install.log" 2>&1

[[ "$(stat -c %a "$INSTALL_DIR/.env")" == "600" ]]
grep -Fqx "NEKO_USER_PASSWORD=$SECRET_USER" "$INSTALL_DIR/.env"
grep -Fqx "NEKO_ADMIN_PASSWORD=$SECRET_ADMIN" "$INSTALL_DIR/.env"
if grep -Fq "$SECRET_USER" "$TMP/install.log" || grep -Fq "$SECRET_ADMIN" "$TMP/install.log"; then
  echo "FAIL: Installer leaked passwords to terminal output" >&2
  exit 1
fi

cp -p "$INSTALL_DIR/.env" "$TMP/original.env"
NEKO_USER_PASSWORD=rotated-secret NEKO_ADMIN_PASSWORD=rotated-admin \
  bash "$REPO_DIR/install.sh" --install-dir "$INSTALL_DIR" \
  --domain changed.example --public-ip 203.0.113.11 --no-start > "$TMP/reinstall.log" 2>&1
cmp -s "$INSTALL_DIR/.env" "$TMP/original.env" || {
  echo "FAIL: Reinstallation modified .env" >&2
  exit 1
}
grep -Fq "Preserving existing" "$TMP/reinstall.log"

if bash "$REPO_DIR/install.sh" --user-password unsafe >/dev/null 2>&1; then
  echo "FAIL: Installer accepted CLI password" >&2
  exit 1
fi

mkdir -p "$TMP/symlink"
ln -s "$TMP/original.env" "$TMP/symlink/.env"
if bash "$REPO_DIR/install.sh" --install-dir "$TMP/symlink" --no-start >/dev/null 2>&1; then
  echo "FAIL: Installer accepted symlinked .env" >&2
  exit 1
fi

# Refuse unencrypted backup by default.
if INSTALL_DIR="$INSTALL_DIR" BACKUP_DIR="$TMP/backups" \
  bash "$REPO_DIR/backup.sh" > "$TMP/backup-error.log" 2>&1; then
  echo "FAIL: Backup succeeded without an encryption recipient" >&2
  exit 1
fi
[[ -z "$(find "$TMP/backups" -type f -print -quit)" ]]

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "ERROR: Install age before running the encryption smoke test" >&2
  exit 1
fi

age-keygen -o "$TMP/identity.txt" >/dev/null 2>&1
recipient="$(age-keygen -y "$TMP/identity.txt")"
encrypted="$(INSTALL_DIR="$INSTALL_DIR" BACKUP_DIR="$TMP/backups" \
  BACKUP_AGE_RECIPIENT="$recipient" bash "$REPO_DIR/backup.sh")"
[[ -f "$encrypted" && "$encrypted" == *.tar.gz.age ]]
[[ "$(stat -c %a "$encrypted")" == "600" ]]
age -d -i "$TMP/identity.txt" "$encrypted" | tar -tzf - | grep -Fq 'neko/.env'

# Invalid recipients must not leave a partially written backup.
if INSTALL_DIR="$INSTALL_DIR" BACKUP_DIR="$TMP/backups" \
  BACKUP_AGE_RECIPIENT="invalid-recipient" bash "$REPO_DIR/backup.sh" >/dev/null 2>&1; then
  echo "FAIL: Backup succeeded with an invalid recipient" >&2
  exit 1
fi
[[ -z "$(find "$TMP/backups" -name '.neko-backup.*' -print -quit)" ]]

plain="$(INSTALL_DIR="$INSTALL_DIR" BACKUP_DIR="$TMP/backups" \
  bash "$REPO_DIR/backup.sh" --plaintext)"
[[ -f "$plain" && "$plain" == *.tar.gz ]]
[[ "$(stat -c %a "$plain")" == "600" ]]
tar -tzf "$plain" | grep -Fq 'neko/.env'

echo "PASS: credential preservation, no output leaks, age encryption and recovery"
