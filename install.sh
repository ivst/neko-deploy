#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/neko"
DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
USER_PASSWORD="${NEKO_USER_PASSWORD:-}"
ADMIN_PASSWORD="${NEKO_ADMIN_PASSWORD:-}"
CONFIGURE_UFW=0
NO_START=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh [options]

Options:
  --domain DOMAIN          Public hostname, e.g. subdomain.example.com
  --public-ip IP           Public IPv4 address. Auto-detected if omitted.
  Passwords can be supplied through environment variables on the first install.
  Password arguments are forbidden (process-list and shell-history exposure).
  --install-dir DIR        Install directory (default: /opt/neko)
  --ufw                    Add UFW rules for 80/tcp, 443/tcp and 52000:52100/udp
  --no-start               Prepare configuration but do not start containers
  -h, --help               Show help

Environment variables can also be used:
  DOMAIN, PUBLIC_IP, NEKO_USER_PASSWORD, NEKO_ADMIN_PASSWORD

Example:
  sudo ./install.sh \
    --domain subdomain.example.com \
    --public-ip 203.0.113.10 \
    --ufw
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:?missing value for --domain}"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="${2:?missing value for --public-ip}"
      shift 2
      ;;
    --user-password|--admin-password)
      echo "ERROR: Passwords in command-line arguments are unsafe." >&2
      echo "Use NEKO_USER_PASSWORD / NEKO_ADMIN_PASSWORD or edit the protected .env." >&2
      exit 2
      ;;
    --install-dir)
      INSTALL_DIR="${2:?missing value for --install-dir}"
      shift 2
      ;;
    --ufw)
      CONFIGURE_UFW=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root: sudo ./install.sh ..." >&2
  exit 1
fi

# Existing credentials must not be silently rotated on reinstall.
REUSE_CONFIG=0
if [[ -e "${INSTALL_DIR}/.env" || -L "${INSTALL_DIR}/.env" ]]; then
  if [[ ! -f "${INSTALL_DIR}/.env" || -L "${INSTALL_DIR}/.env" ]]; then
    echo "ERROR: ${INSTALL_DIR}/.env must be a regular file, not a symlink." >&2
    exit 1
  fi
  REUSE_CONFIG=1
  echo "==> Preserving existing ${INSTALL_DIR}/.env"
  if [[ -n "$DOMAIN" || -n "$PUBLIC_IP" || -n "$USER_PASSWORD" || -n "$ADMIN_PASSWORD" ]]; then
    echo "WARNING: Domain, IP and password overrides ignored on reinstall." >&2
    echo "Edit ${INSTALL_DIR}/.env explicitly to change existing settings." >&2
  fi
  # Only parse known keys, never source .env as executable shell code.
  DOMAIN="$(sed -n 's/^DOMAIN=//p' "${INSTALL_DIR}/.env" | head -n 1)"
  PUBLIC_IP="$(sed -n 's/^PUBLIC_IP=//p' "${INSTALL_DIR}/.env" | head -n 1)"
else
  if [[ -z "$DOMAIN" && -t 0 ]]; then
    read -r -p "Domain for Neko (e.g. subdomain.example.com): " DOMAIN
  fi
  if [[ -z "$DOMAIN" ]]; then
    echo "DOMAIN is required. Use --domain or DOMAIN=..." >&2
    exit 1
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$PUBLIC_IP" ]]; then
    echo "Could not auto-detect public IPv4. Use --public-ip." >&2
    exit 1
  fi
  if [[ -z "$USER_PASSWORD" ]]; then
    USER_PASSWORD="$(openssl rand -hex 16)"
  fi
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(openssl rand -hex 20)"
  fi
  for value in "$DOMAIN" "$PUBLIC_IP" "$USER_PASSWORD" "$ADMIN_PASSWORD"; do
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
      echo "ERROR: Configuration values must not contain newlines." >&2
      exit 1
    fi
  done
fi
if [[ -z "$DOMAIN" || -z "$PUBLIC_IP" ]]; then
  echo "ERROR: DOMAIN and PUBLIC_IP are required in ${INSTALL_DIR}/.env." >&2
  exit 1
fi

echo "==> Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl

if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker"
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is missing." >&2
  echo "Install docker-compose-plugin for your distribution and run this script again." >&2
  exit 1
fi

echo "==> Preparing ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/firefox-profile" "${INSTALL_DIR}/firefox-policies"

install -m 0644 "${SCRIPT_DIR}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
install -m 0644 "${SCRIPT_DIR}/Caddyfile" "${INSTALL_DIR}/Caddyfile"
install -m 0644 "${SCRIPT_DIR}/firefox-policies/policies.json" \
  "${INSTALL_DIR}/firefox-policies/policies.json"

# Firefox in the official Neko image runs as UID/GID 1000.
chown -R 1000:1000 "${INSTALL_DIR}/firefox-profile"
chmod 700 "${INSTALL_DIR}/firefox-profile"

if [[ "${REUSE_CONFIG}" -eq 0 ]]; then
  umask 077
  cat > "${INSTALL_DIR}/.env" <<EOF
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
NEKO_USER_PASSWORD=${USER_PASSWORD}
NEKO_ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
fi
chmod 600 "${INSTALL_DIR}/.env"

if [[ "${CONFIGURE_UFW}" -eq 1 ]]; then
  if command -v ufw >/dev/null 2>&1; then
    echo "==> Adding UFW rules"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 52000:52100/udp
  else
    echo "WARNING: --ufw requested, but ufw is not installed."
  fi
fi

echo "==> Validating Compose configuration"
(
  cd "${INSTALL_DIR}"
  docker compose config >/dev/null
)

if [[ "${NO_START}" -eq 0 ]]; then
  echo "==> Pulling images"
  (
    cd "${INSTALL_DIR}"
    docker compose pull
  )

  echo "==> Starting Neko and Caddy"
  (
    cd "${INSTALL_DIR}"
    docker compose up -d
  )
fi

cat <<EOF

Installation complete.

Directory:
  ${INSTALL_DIR}

URL:
  https://${DOMAIN}

Public IP:
  ${PUBLIC_IP}

Credentials:
  Stored in ${INSTALL_DIR}/.env (mode 600); never printed automatically.
  To view intentionally: sudo grep '^NEKO_.*_PASSWORD=' ${INSTALL_DIR}/.env

IMPORTANT:
  1. Point the DNS A record for ${DOMAIN} to ${PUBLIC_IP}.
  2. Allow inbound TCP 80/443 and UDP 52000-52100 in the cloud firewall.
  3. Do NOT expose RTMP stream keys in Git or logs.
  4. Firefox data will persist in ${INSTALL_DIR}/firefox-profile.

Useful commands:
  cd ${INSTALL_DIR}
  docker compose ps
  docker logs -f neko
  docker logs -f neko-caddy
  docker stats

Update:
  cd ${INSTALL_DIR}
  docker compose pull
  docker compose up -d

Stop:
  cd ${INSTALL_DIR}
  docker compose down

EOF
