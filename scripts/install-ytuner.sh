#!/usr/bin/env bash
set -Eeuo pipefail

# install-ytuner.sh - Run inside the Debian/Ubuntu LXC to install YTuner.
# Installs official YTuner binary, config templates, and systemd service.

usage() {
  cat <<'USAGE'
Usage: install-ytuner.sh [options]

Options:
  --version <ver>         YTuner version (default: 1.2.6)
  --install-dir <dir>     Install directory (default: /opt/ytuner)
  --config-source <dir>   Directory containing config templates (default: <repo>/config)
  --service-source <file> systemd service template (default: <repo>/systemd/ytuner.service)
  --force-config          Overwrite existing ytuner.ini/avr.ini/stations.ini
  --no-start              Do not enable/start systemd service
  --skip-dns-check        Do not disable systemd-resolved or check port 53
  --dry-run               Print actions without executing
  -h, --help              Show help

Examples:
  sudo bash scripts/install-ytuner.sh
  sudo bash scripts/install-ytuner.sh --version 1.2.6 --force-config
USAGE
}

log() { printf '[install-ytuner] %s\n' "$*"; }
warn() { printf '[install-ytuner] WARN: %s\n' "$*" >&2; }
err() { printf '[install-ytuner] ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

VERSION="1.2.6"
INSTALL_DIR="/opt/ytuner"
CONFIG_SOURCE="${REPO_DIR}/config"
SERVICE_SOURCE="${REPO_DIR}/systemd/ytuner.service"
FORCE_CONFIG="0"
NO_START="0"
SKIP_DNS_CHECK="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --config-source) CONFIG_SOURCE="${2:-}"; shift 2 ;;
    --service-source) SERVICE_SOURCE="${2:-}"; shift 2 ;;
    --force-config) FORCE_CONFIG="1"; shift ;;
    --no-start) NO_START="1"; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Run as root (use sudo)."
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  die "This installer supports Linux only."
fi

for f in "$CONFIG_SOURCE/ytuner.ini" "$CONFIG_SOURCE/avr.ini" "$CONFIG_SOURCE/stations.ini" "$SERVICE_SOURCE"; do
  [[ -f "$f" ]] || die "Missing required template: $f"
done

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64)
    PKG="ytuner-${VERSION}-x86_64-linux.zip"
    ;;
  aarch64|arm64)
    PKG="ytuner-${VERSION}-aarch64-arm64-armv7-armv8-armv9-linux.zip"
    ;;
  armv7l|armv7hl)
    PKG="ytuner-${VERSION}-armhf-armv7-armv8-armv9-linux.zip"
    ;;
  armv6l|armhf)
    PKG="ytuner-${VERSION}-armhf-armv6-linux.zip"
    ;;
  i386|i686)
    PKG="ytuner-${VERSION}-i386-linux.zip"
    ;;
  *)
    die "Unsupported architecture: $ARCH_RAW. Check upstream releases for a matching binary."
    ;;
esac

DOWNLOAD_URL="https://github.com/coffeegreg/YTuner/releases/download/${VERSION}/${PKG}"

log "Detected architecture: $ARCH_RAW"
log "YTuner version: $VERSION"
log "Install dir: $INSTALL_DIR"
log "Package: $PKG"

export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
  log "Installing dependencies via apt-get..."
  run apt-get update
  run apt-get install -y --no-install-recommends \
    ca-certificates wget unzip sqlite3 libsqlite3-0 \
    iproute2 net-tools curl file
else
  warn "apt-get not found; ensure wget/unzip/sqlite3/iproute2 are installed."
fi

# Port 53 conflict: systemd-resolved commonly occupies it on Debian/Ubuntu.
if [[ "$SKIP_DNS_CHECK" == "0" ]]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^systemd-resolved\.service'; then
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null || systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      log "Disabling systemd-resolved to free UDP/TCP port 53 for YTuner..."
      run systemctl stop systemd-resolved || true
      run systemctl disable systemd-resolved || true
    fi
  fi

  # If resolv.conf is a symlink to systemd-resolved stub, replace with a simple static resolv.conf.
  if [[ -L /etc/resolv.conf ]]; then
    target="$(readlink -f /etc/resolv.conf || true)"
    if [[ "$target" == *systemd/resolve/* ]]; then
      log "Replacing /etc/resolv.conf symlink (systemd-resolved stub) with static resolv.conf..."
      if [[ "$DRY_RUN" == "1" ]]; then
        printf '+ write /etc/resolv.conf\n'
      else
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf <<'RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
RESOLV
      fi
    fi
  fi
fi

TMPDIR="$(mktemp -d /tmp/ytuner-install.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

log "Downloading $DOWNLOAD_URL ..."
run wget -q --show-progress -O "$TMPDIR/ytuner.zip" "$DOWNLOAD_URL"

log "Extracting package..."
run unzip -q "$TMPDIR/ytuner.zip" -d "$TMPDIR/extracted"

# Zip may contain a top-level folder; locate the ytuner binary.
BIN_PATH="$(find "$TMPDIR/extracted" -type f \( -name 'ytuner' -o -name 'ytuner.exe' \) | head -n1 || true)"
[[ -n "$BIN_PATH" ]] || die "Could not find ytuner binary in extracted archive"
BIN_DIR="$(dirname "$BIN_PATH")"

run mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/config" "$INSTALL_DIR/cache" "$INSTALL_DIR/db"

# Backup existing binary if present
if [[ -f "$INSTALL_DIR/ytuner" && "$DRY_RUN" != "1" ]]; then
  cp -f "$INSTALL_DIR/ytuner" "$INSTALL_DIR/ytuner.bak.$(date +%Y%m%d%H%M%S)"
fi

log "Installing binary to $INSTALL_DIR/ytuner ..."
if [[ "$DRY_RUN" == "1" ]]; then
  printf '+ install -m 0755 %q %q\n' "$BIN_PATH" "$INSTALL_DIR/ytuner"
else
  install -m 0755 "$BIN_PATH" "$INSTALL_DIR/ytuner"
fi

# Copy bundled upstream config files only if missing and templates not forced? We prefer our templates.
copy_cfg() {
  local src="$1" dst="$2"
  if [[ -f "$dst" && "$FORCE_CONFIG" != "1" ]]; then
    log "Keeping existing config: $dst"
    return 0
  fi
  log "Installing config: $dst"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ install -m 0644 %q %q\n' "$src" "$dst"
  else
    install -m 0644 "$src" "$dst"
  fi
}

copy_cfg "$CONFIG_SOURCE/ytuner.ini" "$INSTALL_DIR/ytuner.ini"
copy_cfg "$CONFIG_SOURCE/avr.ini" "$INSTALL_DIR/config/avr.ini"
copy_cfg "$CONFIG_SOURCE/stations.ini" "$INSTALL_DIR/config/stations.ini"

# If upstream ships extra default files (bookmark.xml etc.), copy them if not present.
for extra in bookmark.xml; do
  src_extra="$(find "$BIN_DIR" -maxdepth 2 -type f -name "$extra" | head -n1 || true)"
  if [[ -n "$src_extra" && ! -f "$INSTALL_DIR/config/$extra" ]]; then
    log "Installing upstream default: $INSTALL_DIR/config/$extra"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '+ install -m 0644 %q %q\n' "$src_extra" "$INSTALL_DIR/config/$extra"
    else
      install -m 0644 "$src_extra" "$INSTALL_DIR/config/$extra"
    fi
  fi
done

log "Installing systemd service..."
if [[ "$DRY_RUN" == "1" ]]; then
  printf '+ install -m 0644 %q /etc/systemd/system/ytuner.service\n' "$SERVICE_SOURCE"
else
  install -m 0644 "$SERVICE_SOURCE" /etc/systemd/system/ytuner.service
fi

if [[ "$NO_START" == "0" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl daemon-reload
    run systemctl enable ytuner.service
    run systemctl restart ytuner.service
    sleep 2
    run systemctl --no-pager --full status ytuner.service || true
  else
    warn "systemctl not available; start manually: $INSTALL_DIR/ytuner"
  fi
else
  log "--no-start set; skipping service enable/start."
fi

log "Verifying listeners (ports 80/tcp, 53/udp)..."
if command -v ss >/dev/null 2>&1; then
  ss -lntup | grep -E ':80\s|:53\s' || warn "Expected ports 80/53 not visible yet. Check: journalctl -u ytuner -n 100 --no-pager"
else
  netstat -lntup 2>/dev/null | grep -E ':80\s|:53\s' || warn "Could not verify ports (ss/netstat missing or ports not bound)."
fi

log "Installation complete."
log "Config: $INSTALL_DIR/ytuner.ini"
log "Logs:   /var/log/ytuner.log (and journalctl -u ytuner)"
log "Next:   point your AVR DNS to this container's IP."
