#!/usr/bin/env bash
set -Eeuo pipefail

# update-ytuner.sh - Update YTuner binary in-place inside the LXC.

usage() {
  cat <<'USAGE'
Usage: update-ytuner.sh [options]

Options:
  --version <ver>       Target YTuner version (default: 1.2.6)
  --install-dir <dir>   Install directory (default: /opt/ytuner)
  --no-restart          Do not restart service after update
  --dry-run             Print actions without executing
  -h, --help            Show help
USAGE
}

log() { printf '[update-ytuner] %s\n' "$*"; }
err() { printf '[update-ytuner] ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '+ '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

VERSION="1.2.6"
INSTALL_DIR="/opt/ytuner"
NO_RESTART="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --no-restart) NO_RESTART="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Run as root (use sudo)."
fi

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) PKG="ytuner-${VERSION}-x86_64-linux.zip" ;;
  aarch64|arm64) PKG="ytuner-${VERSION}-aarch64-arm64-armv7-armv8-armv9-linux.zip" ;;
  armv7l|armv7hl) PKG="ytuner-${VERSION}-armhf-armv7-armv8-armv9-linux.zip" ;;
  armv6l|armhf) PKG="ytuner-${VERSION}-armhf-armv6-linux.zip" ;;
  i386|i686) PKG="ytuner-${VERSION}-i386-linux.zip" ;;
  *) die "Unsupported architecture: $ARCH_RAW" ;;
esac

DOWNLOAD_URL="https://github.com/coffeegreg/YTuner/releases/download/${VERSION}/${PKG}"
TMPDIR="$(mktemp -d /tmp/ytuner-update.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

[[ -d "$INSTALL_DIR" ]] || die "Install dir not found: $INSTALL_DIR"

log "Downloading $DOWNLOAD_URL ..."
run wget -q --show-progress -O "$TMPDIR/ytuner.zip" "$DOWNLOAD_URL"
run unzip -q "$TMPDIR/ytuner.zip" -d "$TMPDIR/extracted"
BIN_PATH="$(find "$TMPDIR/extracted" -type f \( -name 'ytuner' -o -name 'ytuner.exe' \) | head -n1 || true)"
[[ -n "$BIN_PATH" ]] || die "ytuner binary not found in archive"

if [[ -f "$INSTALL_DIR/ytuner" ]]; then
  BAK="$INSTALL_DIR/ytuner.bak.$(date +%Y%m%d%H%M%S)"
  log "Backing up current binary to $BAK"
  if [[ "$DRY_RUN" == "1" ]]; then printf '+ cp -f %q %q\n' "$INSTALL_DIR/ytuner" "$BAK"; else cp -f "$INSTALL_DIR/ytuner" "$BAK"; fi
fi

log "Installing new binary..."
if [[ "$DRY_RUN" == "1" ]]; then
  printf '+ install -m 0755 %q %q\n' "$BIN_PATH" "$INSTALL_DIR/ytuner"
else
  install -m 0755 "$BIN_PATH" "$INSTALL_DIR/ytuner"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROXY_SCRIPT_SOURCE="${REPO_DIR}/scripts/ytuner-stream-proxy.py"
PROXY_SERVICE_SOURCE="${REPO_DIR}/systemd/ytuner-stream-proxy.service"
PROXY_DEFAULT_SOURCE="${REPO_DIR}/config/ytuner-stream-proxy.default"
if [[ -f "$PROXY_SCRIPT_SOURCE" ]]; then
  log "Updating stream proxy script..."
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ install -m 0755 %q %q\n' "$PROXY_SCRIPT_SOURCE" "$INSTALL_DIR/ytuner-stream-proxy.py"
  else
    install -m 0755 "$PROXY_SCRIPT_SOURCE" "$INSTALL_DIR/ytuner-stream-proxy.py"
  fi
fi
if [[ -f "$PROXY_SERVICE_SOURCE" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ install -m 0644 %q /etc/systemd/system/ytuner-stream-proxy.service\n' "$PROXY_SERVICE_SOURCE"
  else
    install -m 0644 "$PROXY_SERVICE_SOURCE" /etc/systemd/system/ytuner-stream-proxy.service
  fi
fi
if [[ -f "$PROXY_DEFAULT_SOURCE" && ! -f /etc/default/ytuner-stream-proxy ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ install -m 0644 %q /etc/default/ytuner-stream-proxy\n' "$PROXY_DEFAULT_SOURCE"
  else
    install -m 0644 "$PROXY_DEFAULT_SOURCE" /etc/default/ytuner-stream-proxy
  fi
fi

if [[ "$NO_RESTART" == "0" ]] && command -v systemctl >/dev/null 2>&1; then
  run systemctl daemon-reload || true
  log "Restarting ytuner.service..."
  run systemctl restart ytuner.service
  run systemctl --no-pager --full status ytuner.service || true
  if systemctl list-unit-files | grep -q '^ytuner-stream-proxy\.service'; then
    log "Restarting ytuner-stream-proxy.service..."
    run systemctl restart ytuner-stream-proxy.service || true
    run systemctl --no-pager --full status ytuner-stream-proxy.service || true
  fi
fi

log "Update complete: $VERSION"
