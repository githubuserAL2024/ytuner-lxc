#!/usr/bin/env bash
set -Eeuo pipefail

# backup-config.sh - Backup YTuner config, db, and cache from an install dir.

usage() {
  cat <<'USAGE'
Usage: backup-config.sh [options]

Options:
  --install-dir <dir>   YTuner install dir (default: /opt/ytuner)
  --output <file>       Output tar.gz path (default: ./ytuner-backup-<timestamp>.tar.gz)
  --dry-run             Print actions without executing
  -h, --help            Show help
USAGE
}

log() { printf '[backup-ytuner] %s\n' "$*"; }
err() { printf '[backup-ytuner] ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi
}

INSTALL_DIR="/opt/ytuner"
OUTPUT=""
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -d "$INSTALL_DIR" ]] || die "Install dir not found: $INSTALL_DIR"
if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$(pwd)/ytuner-backup-$(date +%Y%m%d%H%M%S).tar.gz"
fi

TMP_LIST="$(mktemp)"
trap 'rm -f "$TMP_LIST"' EXIT

# Backup key runtime data; include paths only if they exist.
for p in \
  "$INSTALL_DIR/ytuner.ini" \
  "$INSTALL_DIR/config" \
  "$INSTALL_DIR/db" \
  "$INSTALL_DIR/cache" \
  "/etc/systemd/system/ytuner.service" \
  "/var/log/ytuner.log"; do
  if [[ -e "$p" ]]; then
    printf '%s\n' "$p" >> "$TMP_LIST"
  fi
done

[[ -s "$TMP_LIST" ]] || die "Nothing to backup found."

log "Creating backup: $OUTPUT"
# Use tar with absolute paths preserved via -P for simple restore clarity.
if [[ "$DRY_RUN" == "1" ]]; then
  printf '+ tar -czf %q -P -T %q\n' "$OUTPUT" "$TMP_LIST"
else
  tar -czf "$OUTPUT" -P -T "$TMP_LIST"
fi

log "Backup complete."
