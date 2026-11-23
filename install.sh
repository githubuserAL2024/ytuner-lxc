#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# YTuner - One-shot installer for Debian/Ubuntu LXC (Proxmox-friendly)
#
# Usage:
#   wget -O install.sh http://192.168.50.88:3000/alex/ytuner-lxc/raw/branch/main/install.sh
#   sudo bash install.sh
#
# Or:
#   curl -fsSL http://192.168.50.88:3000/alex/ytuner-lxc/raw/branch/main/install.sh | sudo bash
#
# This script installs everything needed inside the container:
#   - required packages
#   - official YTuner binary (architecture-matched)
#   - default configuration files (if missing)
#   - systemd service
#   - disables systemd-resolved if it blocks port 53
#   - enables and starts YTuner
# -----------------------------------------------------------------------------

VERSION="1.2.6"
INSTALL_DIR="/opt/ytuner"
FORCE_CONFIG="0"
NO_START="0"
SKIP_DNS_CHECK="0"
DRY_RUN="0"

usage() {
  cat <<'USAGE'
YTuner one-shot installer

Usage:
  sudo bash install.sh [options]

Options:
  --version <ver>       YTuner release version (default: 1.2.6)
  --install-dir <dir>   Install directory (default: /opt/ytuner)
  --force-config        Overwrite existing ytuner.ini/avr.ini/stations.ini
  --no-start            Install files but do not enable/start systemd service
  --skip-dns-check      Do not disable systemd-resolved / do not touch resolv.conf
  --dry-run             Print actions without making changes
  -h, --help            Show this help

Examples:
  sudo bash install.sh
  sudo bash install.sh --version 1.2.6 --force-config
  sudo bash install.sh --no-start
USAGE
}

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install] WARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[install] ERROR:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

write_file() {
  # write_file <path> <mode> <content>
  local path="$1" mode="$2" content="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ write %s (mode %s)\n' "$path" "$mode"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$content" > "$path"
  chmod "$mode" "$path"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --force-config) FORCE_CONFIG="1"; shift ;;
    --no-start) NO_START="1"; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Run as root (use: sudo bash install.sh)"
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  die "This installer supports Linux only."
fi

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
    die "Unsupported architecture: $ARCH_RAW. Check https://github.com/coffeegreg/YTuner/releases for a matching binary."
    ;;
esac

DOWNLOAD_URL="https://github.com/coffeegreg/YTuner/releases/download/${VERSION}/${PKG}"

log "YTuner version:    $VERSION"
log "Architecture:      $ARCH_RAW"
log "Install dir:       $INSTALL_DIR"
log "Release asset:     $PKG"

export DEBIAN_FRONTEND=noninteractive

# --- Dependencies -------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  log "Installing dependencies via apt-get..."
  run apt-get update
  run apt-get install -y --no-install-recommends \
    ca-certificates wget curl unzip tar sqlite3 libsqlite3-0 \
    python3 iproute2 net-tools file coreutils
else
  warn "apt-get not found; please ensure wget/curl, unzip, sqlite3, python3, iproute2 are installed."
fi

need_cmd wget
need_cmd unzip

# --- DNS / port 53 ------------------------------------------------------------
if [[ "$SKIP_DNS_CHECK" == "0" ]]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    if systemctl is-enabled --quiet systemd-resolved 2>/dev/null || systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      log "Disabling systemd-resolved to free port 53 for YTuner DNS..."
      run systemctl stop systemd-resolved || true
      run systemctl disable systemd-resolved || true
    fi
  fi

  if [[ -L /etc/resolv.conf ]]; then
    target="$(readlink -f /etc/resolv.conf || true)"
    if [[ "$target" == *systemd/resolve/* ]]; then
      log "Replacing systemd-resolved stub /etc/resolv.conf with static DNS..."
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
else
  warn "Skipping DNS/port 53 checks (--skip-dns-check)."
fi

# --- Download & install binary ------------------------------------------------
TMPDIR="$(mktemp -d /tmp/ytuner-install.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

log "Downloading $DOWNLOAD_URL"
run wget -q --show-progress -O "$TMPDIR/ytuner.zip" "$DOWNLOAD_URL"

log "Extracting archive..."
run unzip -q "$TMPDIR/ytuner.zip" -d "$TMPDIR/extracted"

BIN_PATH="$(find "$TMPDIR/extracted" -type f \( -name 'ytuner' -o -name 'ytuner.exe' \) | head -n1 || true)"
[[ -n "$BIN_PATH" ]] || die "ytuner binary not found in archive"

run mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/config" "$INSTALL_DIR/cache" "$INSTALL_DIR/db"

if [[ -f "$INSTALL_DIR/ytuner" && "$DRY_RUN" != "1" ]]; then
  BAK="$INSTALL_DIR/ytuner.bak.$(date +%Y%m%d%H%M%S)"
  log "Backing up existing binary to $BAK"
  cp -f "$INSTALL_DIR/ytuner" "$BAK"
fi

log "Installing binary to $INSTALL_DIR/ytuner"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '+ install -m 0755 %q %q\n' "$BIN_PATH" "$INSTALL_DIR/ytuner"
else
  install -m 0755 "$BIN_PATH" "$INSTALL_DIR/ytuner"
fi

# --- Config files -------------------------------------------------------------
install_cfg() {
  local path="$1" mode="$2" content="$3"
  if [[ -f "$path" && "$FORCE_CONFIG" != "1" ]]; then
    log "Keeping existing config: $path"
    return 0
  fi
  log "Writing config: $path"
  write_file "$path" "$mode" "$content"
}

YTUNER_INI='[Configuration]
; Please do not change this value !
INIVersion=1.2.2

; Force the use of the selected IP address of one of the existing interfaces.
; Leave "default" when you have one IP address or are unsure.
IPAddress=default

; Useful in rare proxy/container cases. Leave "default" if unsure.
ActAsHost=default

; Use SSL. 1-Yes 0-No ; Default = 1
UseSSL=1

; Force HTTP code for redirect. Default = 302
RedirectHTTPCode=302

; Log message level. 0-None, 1-Info, 2-Warning, 3-Error, 4-Debug ; Default = 0 ; Initial = 4
MessageInfoLevel=1

; Station logo icon size (width & height). Default = 200
; Some devices (e.g. Pioneer N-50) need 75.
IconSize=200

; Cache icon files. 1-Yes 0-No ; Default = 1
IconCache=1

; Some devices need "jpg". Leave blank by default.
IconEndPointExtension=

; Sixteen hex chars token. Changes bookmark/config file naming when not using common files.
MyToken=0123456789ABCDEF

; One common avr.ini/translator for all AVRs. 1-Yes 0-No ; Default = 0
CommonAVRini=1

; Folder locations. Empty or "default" = same as YTuner app location.
CacheFolderLocation=default
ConfigFolderLocation=default
DBFolderLocation=default

; SQLite3 library path. "default" lets YTuner find it.
; Required for RBCacheType catDB/catMemDB/catPermMemDB.
DBLibFile=default

[MyStations]
; Enables support for stations.ini/stations.yaml. 1-Yes 0-No ; Default = 1
Enable=1

; File name in config dir. Default = stations.ini
MyStationsFile=stations.ini

; Auto refresh period (minutes). 0 = no refresh ; Default = 0
MyStationsAutoRefreshPeriod=0

[Radiobrowser]
; Enables radio-browser.info support. 1-Yes 0-No ; Default = 1
Enable=1

; Radio-browser.info API URL. Default = http://all.api.radio-browser.info
RBAPIURL=http://all.api.radio-browser.info

; Most popular stations limit. Default = 100
RBPopularAndSearchStationsLimit=100

; Minimum stations per category. Default = 1
RBMinStationsPerCategory=1

; UUIDs cache TTL (hours). 0 = never refresh ; Default = 0
RBUUIDsCacheTTL=0

; UUIDs cache auto refresh when TTL>0. 1-Yes 0-No ; Default = 0
RBUUIDsCacheAutoRefresh=0

; Cache type: catNone,catFile,catMemStr,catDB,catMemDB,catPermMemDB
; catPermMemDB gives best UX when sqlite3 is available and RAM is sufficient.
RBCacheType=catPermMemDB

; Stations cache TTL (hours). 0 = never refresh ; Default = 0
RBCacheTTL=0

[Bookmark]
; Enables bookmarks (AVR must support bookmarks). 1-Yes 0-No ; Default = 1
Enable=1

; One common bookmark.xml for all AVRs. 1-Yes 0-No ; Default = 1
CommonBookmark=1

; Bookmark stations limit. Default = 100
BookmarkStationsLimit=100

[WebServer]
; "default" = same as Configuration.IPAddress
WebServerIPAddress=default
; Web server TCP port. Default = 80
WebServerPort=80

[DNSServer]
; Enable built-in DNS proxy. 1-Yes 0-No ; Default = 1
Enable=1

; "default" = same as Configuration.IPAddress
DNSServerIPAddress=default
; DNS UDP port. Default = 53
DNSServerPort=53

; Domains to intercept (comma separated, wildcard prefix supported).
InterceptDNs=*.vtuner.com,*.radiosetup.com,*.my-noxon.net,*.radiomarantz.com

; Upstream DNS servers used for non-intercepted queries.
DNSServers=8.8.8.8,9.9.9.9

[MaintenanceServer]
; Maintenance endpoint (http://IP:Port/ytuner/down). Keep disabled unless needed.
Enable=0
MaintenanceServerIPAddress=127.0.0.1
MaintenanceServerPort=8080
'

AVR_INI='[Configuration]
; Please do not change this value!
INIVersion=1.0.2

; [https,http,all-as-http] or blank. Default: all-as-http.
Protocol=all-as-http

[MainMenu Items]
; IdentifiersList: mystations;radiobrowser;bookmarks;about
; LabelsList must have same number of elements.
IdentifiersList=about;bookmarks;mystations;radiobrowser
LabelsList=*** YTuner ***;Favourites;My Stations;Radio Browser

[RadioBrowser Filtering]
; Leave filters blank to avoid over-filtering. Customize as needed.
AllowedTags=
NotAllowedTags=
AllowedCountries=
AllowedLanguages=
AllowedCodecs=
NotAllowedCodecs=AAC*
BitrateMax=
NotAllowedInName=aac
NotAllowedInURL=.aac

[RadioBrowser Sorting]
; order: name, url, homepage, favicon, tags, country, state, language, votes, codec,
; bitrate, lastcheckok, lastchecktime, clicktimestamp, clickcount, clicktrend, random
Order=name
; 0 = ascending; 1 = descending
Reverse=0

[Translator]
; Optional. Set your translation preferences in a translator file if needed.
'

STATIONS_INI='; Custom stations for YTuner "My Stations" menu.
; Format: Station Name=stream_url|optional_logo_url

[Example]
Radio Paradise Main Mix=https://stream.radioparadise.com/mp3-192|https://radioparadise.com/apple-touch-icon.png
SomaFM Groove Salad=https://ice1.somafm.com/groovesalad-128-mp3|https://somafm.com/img3/groovesalad-400.jpg
'

install_cfg "$INSTALL_DIR/ytuner.ini" "0644" "$YTUNER_INI"
install_cfg "$INSTALL_DIR/config/avr.ini" "0644" "$AVR_INI"
install_cfg "$INSTALL_DIR/config/stations.ini" "0644" "$STATIONS_INI"

# --- systemd service ----------------------------------------------------------
SERVICE_UNIT='[Unit]
Description=YTuner vTuner replacement service
Documentation=https://github.com/coffeegreg/YTuner
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/ytuner
ExecStart=/opt/ytuner/ytuner
Restart=always
RestartSec=5
StandardOutput=append:/var/log/ytuner.log
StandardError=append:/var/log/ytuner.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
'

log "Installing systemd unit: /etc/systemd/system/ytuner.service"
write_file "/etc/systemd/system/ytuner.service" "0644" "$SERVICE_UNIT"

# --- Enable & start -----------------------------------------------------------
if [[ "$NO_START" == "0" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl daemon-reload
    run systemctl enable ytuner.service
    run systemctl restart ytuner.service
    sleep 2
    run systemctl --no-pager --full status ytuner.service || true
  else
    warn "systemctl not found. Start manually: $INSTALL_DIR/ytuner"
  fi
else
  log "--no-start set; skipping service enable/start."
fi

# --- Stream proxy (HTTPS -> HTTP) --------------------------------------------
PROXY_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiIKeXR1bmVyLXN0cmVhbS1wcm94eSAtIEhUVFBTLT5IVFRQIHN0cmVhbSByZWxheSBmb3Igb2xkIEFWUnMuCgpMaXN0ZW5zIG9uIEhUVFAgYW5kIHByb3hpZXMgYXVkaW8gc3RyZWFtcyBmcm9tIEhUVFBTIChvciBIVFRQKSB1cHN0cmVhbXMuCkRlc2lnbmVkIGZvciBZVHVuZXIvQVZSIHNldHVwcyB3aGVyZSB0aGUgQVZSIGNhbm5vdCBzcGVhayBUTFMuCgpVc2FnZSBleGFtcGxlczoKICBodHRwOi8vPGhvc3Q+OjgwOTAvc3RyZWFtP3VybD1odHRwczovL2V4YW1wbGUuY29tL3JhZGlvLm1wMwogIGh0dHA6Ly88aG9zdD46ODA5MC9odHRwczovL2V4YW1wbGUuY29tL3JhZGlvLm1wMwoKRW52aXJvbm1lbnQgdmFyaWFibGVzOgogIFNUUkVBTV9QUk9YWV9IT1NUICAgICAgIEJpbmQgYWRkcmVzcyAoZGVmYXVsdDogMC4wLjAuMCkKICBTVFJFQU1fUFJPWFlfUE9SVCAgICAgICBCaW5kIHBvcnQgKGRlZmF1bHQ6IDgwOTApCiAgU1RSRUFNX1BST1hZX1RJTUVPVVQgICAgVXBzdHJlYW0gY29ubmVjdC9yZWFkIHRpbWVvdXQgc2Vjb25kcyAoZGVmYXVsdDogMTUpCiAgU1RSRUFNX1BST1hZX01BWF9SRURJUkVDVFMgIE1heCByZWRpcmVjdHMgdG8gZm9sbG93IChkZWZhdWx0OiA1KQogIFNUUkVBTV9QUk9YWV9VU0VSX0FHRU5UIFVzZXItQWdlbnQgc2VudCB1cHN0cmVhbSAoZGVmYXVsdDogTW96aWxsYS81LjAgLi4uKQogIFNUUkVBTV9QUk9YWV9MT0dfTEVWRUwgIERFQlVHLCBJTkZPLCBXQVJOSU5HLCBFUlJPUiAoZGVmYXVsdDogSU5GTykKIiIiCgpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgbG9nZ2luZwppbXBvcnQgb3MKaW1wb3J0IHNvY2tldAppbXBvcnQgc3lzCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIsIFRocmVhZGluZ0hUVFBTZXJ2ZXIKZnJvbSB1cmxsaWIuZXJyb3IgaW1wb3J0IEhUVFBFcnJvciwgVVJMRXJyb3IKZnJvbSB1cmxsaWIucGFyc2UgaW1wb3J0IHBhcnNlX3FzLCB1cmxzcGxpdCwgdXJsdW5zcGxpdApmcm9tIHVybGxpYi5yZXF1ZXN0IGltcG9ydCBSZXF1ZXN0LCBidWlsZF9vcGVuZXIsIEhUVFBSZWRpcmVjdEhhbmRsZXIsIEhUVFBTSGFuZGxlciwgSFRUUEhhbmRsZXIKCgpIT1NUID0gb3MuZW52aXJvbi5nZXQoIlNUUkVBTV9QUk9YWV9IT1NUIiwgIjAuMC4wLjAiKQpQT1JUID0gaW50KG9zLmVudmlyb24uZ2V0KCJTVFJFQU1fUFJPWFlfUE9SVCIsICI4MDkwIikpClRJTUVPVVQgPSBmbG9hdChvcy5lbnZpcm9uLmdldCgiU1RSRUFNX1BST1hZX1RJTUVPVVQiLCAiMTUiKSkKTUFYX1JFRElSRUNUUyA9IGludChvcy5lbnZpcm9uLmdldCgiU1RSRUFNX1BST1hZX01BWF9SRURJUkVDVFMiLCAiNSIpKQpVU0VSX0FHRU5UID0gb3MuZW52aXJvbi5nZXQoCiAgICAiU1RSRUFNX1BST1hZX1VTRVJfQUdFTlQiLAogICAgIk1vemlsbGEvNS4wIChjb21wYXRpYmxlOyBZVHVuZXItU3RyZWFtLVByb3h5LzAuMTsgK2h0dHBzOi8vZ2l0aHViLmNvbS9jb2ZmZWVncmVnL1lUdW5lcikiLAopCkxPR19MRVZFTCA9IG9zLmVudmlyb24uZ2V0KCJTVFJFQU1fUFJPWFlfTE9HX0xFVkVMIiwgIklORk8iKS51cHBlcigpCgpIT1BfQllfSE9QID0gewogICAgImNvbm5lY3Rpb24iLAogICAgImtlZXAtYWxpdmUiLAogICAgInByb3h5LWF1dGhlbnRpY2F0ZSIsCiAgICAicHJveHktYXV0aG9yaXphdGlvbiIsCiAgICAidGUiLAogICAgInRyYWlsZXJzIiwKICAgICJ0cmFuc2Zlci1lbmNvZGluZyIsCiAgICAidXBncmFkZSIsCiAgICAicHJveHktY29ubmVjdGlvbiIsCn0KCgpkZWYgc2V0dXBfbG9nZ2luZygpIC0+IGxvZ2dpbmcuTG9nZ2VyOgogICAgbG9nZ2luZy5iYXNpY0NvbmZpZygKICAgICAgICBsZXZlbD1nZXRhdHRyKGxvZ2dpbmcsIExPR19MRVZFTCwgbG9nZ2luZy5JTkZPKSwKICAgICAgICBmb3JtYXQ9IiUoYXNjdGltZSlzICUobGV2ZWxuYW1lKXMgJShtZXNzYWdlKXMiLAogICAgICAgIHN0cmVhbT1zeXMuc3Rkb3V0LAogICAgKQogICAgcmV0dXJuIGxvZ2dpbmcuZ2V0TG9nZ2VyKCJ5dHVuZXItc3RyZWFtLXByb3h5IikKCgpMT0cgPSBzZXR1cF9sb2dnaW5nKCkKCgpjbGFzcyBMaW1pdGVkUmVkaXJlY3RIYW5kbGVyKEhUVFBSZWRpcmVjdEhhbmRsZXIpOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIG1heF9yZWRpcmVjdHM6IGludCkgLT4gTm9uZToKICAgICAgICBzZWxmLm1heF9yZWRpcmVjdHMgPSBtYXhfcmVkaXJlY3RzCiAgICAgICAgc2VsZi5yZWRpcmVjdF9jb3VudCA9IDAKCiAgICBkZWYgcmVkaXJlY3RfcmVxdWVzdChzZWxmLCByZXEsIGZwLCBjb2RlLCBtc2csIGhlYWRlcnMsIG5ld3VybCk6ICAjIG5vcWE6IEFOTjAwMQogICAgICAgIHNlbGYucmVkaXJlY3RfY291bnQgKz0gMQogICAgICAgIGlmIHNlbGYucmVkaXJlY3RfY291bnQgPiBzZWxmLm1heF9yZWRpcmVjdHM6CiAgICAgICAgICAgIHJhaXNlIEhUVFBFcnJvcihuZXd1cmwsIGNvZGUsIGYiVG9vIG1hbnkgcmVkaXJlY3RzICg+e3NlbGYubWF4X3JlZGlyZWN0c30pIiwgaGVhZGVycywgZnApCiAgICAgICAgTE9HLmRlYnVnKCJSZWRpcmVjdCAlcyAtPiAlcyIsIHJlcS5mdWxsX3VybCwgbmV3dXJsKQogICAgICAgIG5ld19yZXEgPSBzdXBlcigpLnJlZGlyZWN0X3JlcXVlc3QocmVxLCBmcCwgY29kZSwgbXNnLCBoZWFkZXJzLCBuZXd1cmwpCiAgICAgICAgaWYgbmV3X3JlcSBpcyBub3QgTm9uZToKICAgICAgICAgICAgIyBQcmVzZXJ2ZSBVQSBvbiByZWRpcmVjdHMKICAgICAgICAgICAgbmV3X3JlcS5hZGRfdW5yZWRpcmVjdGVkX2hlYWRlcigiVXNlci1BZ2VudCIsIFVTRVJfQUdFTlQpCiAgICAgICAgcmV0dXJuIG5ld19yZXEKCgpkZWYgYnVpbGRfdXJsX29wZW5lcigpIC0+IG9iamVjdDoKICAgIHJlZGlyZWN0X2hhbmRsZXIgPSBMaW1pdGVkUmVkaXJlY3RIYW5kbGVyKE1BWF9SRURJUkVDVFMpCiAgICByZXR1cm4gYnVpbGRfb3BlbmVyKEhUVFBIYW5kbGVyKCksIEhUVFBTSGFuZGxlcigpLCByZWRpcmVjdF9oYW5kbGVyKQoKCmRlZiBzYW5pdGl6ZV91cHN0cmVhbV91cmwocmF3OiBzdHIpIC0+IHN0cjoKICAgIHJhdyA9IChyYXcgb3IgIiIpLnN0cmlwKCkKICAgIGlmIG5vdCByYXc6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiTWlzc2luZyB1cHN0cmVhbSBVUkwiKQoKICAgICMgQWxsb3cgL2h0dHBzOi8vLi4uIHNob3J0aGFuZAogICAgaWYgcmF3LnN0YXJ0c3dpdGgoImh0dHBzOi8vIikgb3IgcmF3LnN0YXJ0c3dpdGgoImh0dHA6Ly8iKToKICAgICAgICBjYW5kaWRhdGUgPSByYXcKICAgIGVsc2U6CiAgICAgICAgIyB0b2xlcmF0ZSBtaXNzaW5nIHNjaGVtZSBpbiA/dXJsPWhvc3QvcGF0aAogICAgICAgIGNhbmRpZGF0ZSA9ICJodHRwOi8vIiArIHJhdwoKICAgIHBhcnRzID0gdXJsc3BsaXQoY2FuZGlkYXRlKQogICAgc2NoZW1lID0gcGFydHMuc2NoZW1lLmxvd2VyKCkKICAgIGlmIHNjaGVtZSBub3QgaW4gKCJodHRwIiwgImh0dHBzIik6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcihmIlVuc3VwcG9ydGVkIFVSTCBzY2hlbWU6IHtwYXJ0cy5zY2hlbWV9IikKICAgIGlmIG5vdCBwYXJ0cy5uZXRsb2M6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiVXBzdHJlYW0gVVJMIG1pc3NpbmcgaG9zdCIpCgogICAgIyBCbG9jayBvYnZpb3VzIGxvY2FsL3ByaXZhdGUgYWJ1c2UgdGFyZ2V0cz8gV2Uga2VlcCBpdCBzaW1wbGUgYnV0IGJsb2NrCiAgICAjIG5vbi1odHRwKHMpIGFscmVhZHk7IHRoZSBwcm94eSBpcyBpbnRlbmRlZCBmb3IgTEFOIHVzZS4KICAgICMgTm9ybWFsaXplIHBhdGgKICAgIHBhdGggPSBwYXJ0cy5wYXRoIG9yICIvIgogICAgbm9ybWFsaXplZCA9IHVybHVuc3BsaXQoKHNjaGVtZSwgcGFydHMubmV0bG9jLCBwYXRoLCBwYXJ0cy5xdWVyeSwgIiIpKQogICAgcmV0dXJuIG5vcm1hbGl6ZWQKCgpkZWYgZXh0cmFjdF90YXJnZXRfdXJsKHBhdGg6IHN0cikgLT4gc3RyOgogICAgIyBGb3JtcyBzdXBwb3J0ZWQ6CiAgICAjICAvc3RyZWFtP3VybD1odHRwczovLy4uLgogICAgIyAgL3Byb3h5P3VybD1odHRwczovLy4uLgogICAgIyAgL2h0dHBzOi8vLi4uCiAgICAjICAvaHR0cDovLy4uLgogICAgaWYgcGF0aC5zdGFydHN3aXRoKCIvaHR0cDovLyIpIG9yIHBhdGguc3RhcnRzd2l0aCgiL2h0dHBzOi8vIik6CiAgICAgICAgcmV0dXJuIHNhbml0aXplX3Vwc3RyZWFtX3VybChwYXRoWzE6XSkKCiAgICBwYXJ0cyA9IHVybHNwbGl0KHBhdGgpCiAgICBpZiBwYXJ0cy5wYXRoIGluICgiL3N0cmVhbSIsICIvcHJveHkiLCAiLyIpOgogICAgICAgIHFzID0gcGFyc2VfcXMocGFydHMucXVlcnkpCiAgICAgICAgdmFsdWVzID0gcXMuZ2V0KCJ1cmwiKSBvciBxcy5nZXQoInUiKSBvciBxcy5nZXQoInN0cmVhbSIpCiAgICAgICAgaWYgbm90IHZhbHVlczoKICAgICAgICAgICAgaWYgcGFydHMucGF0aCA9PSAiLyI6CiAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCJpbmRleCIpCiAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoIk1pc3NpbmcgJ3VybCcgcXVlcnkgcGFyYW1ldGVyIikKICAgICAgICByZXR1cm4gc2FuaXRpemVfdXBzdHJlYW1fdXJsKHZhbHVlc1swXSkKCiAgICAjIEFsbG93IC88YW55dGhpbmc+P3VybD0uLi4KICAgIHFzID0gcGFyc2VfcXMocGFydHMucXVlcnkpCiAgICB2YWx1ZXMgPSBxcy5nZXQoInVybCIpIG9yIHFzLmdldCgidSIpIG9yIHFzLmdldCgic3RyZWFtIikKICAgIGlmIHZhbHVlczoKICAgICAgICByZXR1cm4gc2FuaXRpemVfdXBzdHJlYW1fdXJsKHZhbHVlc1swXSkKCiAgICByYWlzZSBWYWx1ZUVycm9yKCJVbnN1cHBvcnRlZCBwYXRoLiBVc2UgL3N0cmVhbT91cmw9aHR0cHM6Ly8uLi4iKQoKCmNsYXNzIFByb3h5SGFuZGxlcihCYXNlSFRUUFJlcXVlc3RIYW5kbGVyKToKICAgIHNlcnZlcl92ZXJzaW9uID0gIllUdW5lclN0cmVhbVByb3h5LzAuMSIKICAgIHN5c192ZXJzaW9uID0gIiIKCiAgICBkZWYgbG9nX21lc3NhZ2Uoc2VsZiwgZm10OiBzdHIsICphcmdzKSAtPiBOb25lOiAgIyBub3FhOiBBMDAzCiAgICAgICAgTE9HLmluZm8oIiVzIC0gJXMiLCBzZWxmLmFkZHJlc3Nfc3RyaW5nKCksIGZtdCAlIGFyZ3MpCgogICAgZGVmIF9zZW5kX3RleHQoc2VsZiwgY29kZTogaW50LCBib2R5OiBzdHIsIGNvbnRlbnRfdHlwZTogc3RyID0gInRleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgiKSAtPiBOb25lOgogICAgICAgIGRhdGEgPSBib2R5LmVuY29kZSgidXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKQogICAgICAgIHRyeToKICAgICAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKGNvZGUpCiAgICAgICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsIGNvbnRlbnRfdHlwZSkKICAgICAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5ndGgiLCBzdHIobGVuKGRhdGEpKSkKICAgICAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ2FjaGUtQ29udHJvbCIsICJuby1zdG9yZSIpCiAgICAgICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgICAgICBzZWxmLndmaWxlLndyaXRlKGRhdGEpCiAgICAgICAgZXhjZXB0IChCcm9rZW5QaXBlRXJyb3IsIENvbm5lY3Rpb25SZXNldEVycm9yLCBzb2NrZXQudGltZW91dCk6CiAgICAgICAgICAgIHBhc3MKCiAgICBkZWYgX3NlbmRfaW5kZXgoc2VsZikgLT4gTm9uZToKICAgICAgICBob3N0ID0gc2VsZi5oZWFkZXJzLmdldCgiSG9zdCIpIG9yIGYie0hPU1R9OntQT1JUfSIKICAgICAgICBib2R5ID0gKAogICAgICAgICAgICAiWVR1bmVyIEhUVFBTLT5IVFRQIFN0cmVhbSBQcm94eVxuXG4iCiAgICAgICAgICAgICJVc2FnZTpcbiIKICAgICAgICAgICAgZiIgIGh0dHA6Ly97aG9zdH0vc3RyZWFtP3VybD1odHRwczovL2V4YW1wbGUuY29tL3N0cmVhbS5tcDNcbiIKICAgICAgICAgICAgZiIgIGh0dHA6Ly97aG9zdH0vaHR0cHM6Ly9leGFtcGxlLmNvbS9zdHJlYW0ubXAzXG5cbiIKICAgICAgICAgICAgIkhlYWx0aDpcbiIKICAgICAgICAgICAgZiIgIGh0dHA6Ly97aG9zdH0vaGVhbHRoXG4iCiAgICAgICAgKQogICAgICAgIHNlbGYuX3NlbmRfdGV4dCgyMDAsIGJvZHkpCgogICAgZGVmIGRvX0dFVChzZWxmKSAtPiBOb25lOiAgIyBub3FhOiBOODAyCiAgICAgICAgaWYgc2VsZi5wYXRoIGluICgiL2hlYWx0aCIsICIvaGVhbHRoeiIpOgogICAgICAgICAgICBzZWxmLl9zZW5kX3RleHQoMjAwLCAib2tcbiIpCiAgICAgICAgICAgIHJldHVybgoKICAgICAgICB0cnk6CiAgICAgICAgICAgIHVwc3RyZWFtX3VybCA9IGV4dHJhY3RfdGFyZ2V0X3VybChzZWxmLnBhdGgpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3IgYXMgZXhjOgogICAgICAgICAgICBpZiBzdHIoZXhjKSA9PSAiaW5kZXgiOgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9pbmRleCgpCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgc2VsZi5fc2VuZF90ZXh0KDQwMCwgZiJCYWQgcmVxdWVzdDoge2V4Y31cbiIpCiAgICAgICAgICAgIHJldHVybgoKICAgICAgICBzZWxmLl9wcm94eSh1cHN0cmVhbV91cmwsIGhlYWRfb25seT1GYWxzZSkKCiAgICBkZWYgZG9fSEVBRChzZWxmKSAtPiBOb25lOiAgIyBub3FhOiBOODAyCiAgICAgICAgaWYgc2VsZi5wYXRoIGluICgiL2hlYWx0aCIsICIvaGVhbHRoeiIpOgogICAgICAgICAgICBzZWxmLl9zZW5kX3RleHQoMjAwLCAib2tcbiIpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIHRyeToKICAgICAgICAgICAgdXBzdHJlYW1fdXJsID0gZXh0cmFjdF90YXJnZXRfdXJsKHNlbGYucGF0aCkKICAgICAgICBleGNlcHQgVmFsdWVFcnJvciBhcyBleGM6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfdGV4dCg0MDAsIGYiQmFkIHJlcXVlc3Q6IHtleGN9XG4iKQogICAgICAgICAgICByZXR1cm4KICAgICAgICBzZWxmLl9wcm94eSh1cHN0cmVhbV91cmwsIGhlYWRfb25seT1UcnVlKQoKICAgIGRlZiBfcHJveHkoc2VsZiwgdXBzdHJlYW1fdXJsOiBzdHIsIGhlYWRfb25seTogYm9vbCkgLT4gTm9uZToKICAgICAgICByZXFfaGVhZGVycyA9IHsKICAgICAgICAgICAgIlVzZXItQWdlbnQiOiBVU0VSX0FHRU5ULAogICAgICAgICAgICAiQWNjZXB0IjogIiovKiIsCiAgICAgICAgICAgICJDb25uZWN0aW9uIjogImNsb3NlIiwKICAgICAgICB9CiAgICAgICAgIyBQYXNzIHRocm91Z2ggUmFuZ2UgaWYgQVZSL3BsYXllciBzZW5kcyBpdCAocmFyZSwgYnV0IGhhcm1sZXNzKQogICAgICAgIHJhbmdlX2hlYWRlciA9IHNlbGYuaGVhZGVycy5nZXQoIlJhbmdlIikKICAgICAgICBpZiByYW5nZV9oZWFkZXI6CiAgICAgICAgICAgIHJlcV9oZWFkZXJzWyJSYW5nZSJdID0gcmFuZ2VfaGVhZGVyCiAgICAgICAgaWN5ID0gc2VsZi5oZWFkZXJzLmdldCgiSWN5LU1ldGFEYXRhIikKICAgICAgICBpZiBpY3k6CiAgICAgICAgICAgIHJlcV9oZWFkZXJzWyJJY3ktTWV0YURhdGEiXSA9IGljeQoKICAgICAgICByZXF1ZXN0ID0gUmVxdWVzdCh1cHN0cmVhbV91cmwsIGhlYWRlcnM9cmVxX2hlYWRlcnMsIG1ldGhvZD0iSEVBRCIgaWYgaGVhZF9vbmx5IGVsc2UgIkdFVCIpCiAgICAgICAgb3BlbmVyID0gYnVpbGRfdXJsX29wZW5lcigpCgogICAgICAgIExPRy5pbmZvKCJQcm94eWluZyAlcyAtPiAlcyIsIHNlbGYuY29tbWFuZCwgdXBzdHJlYW1fdXJsKQogICAgICAgIHRyeToKICAgICAgICAgICAgcmVzcCA9IG9wZW5lci5vcGVuKHJlcXVlc3QsIHRpbWVvdXQ9VElNRU9VVCkKICAgICAgICBleGNlcHQgSFRUUEVycm9yIGFzIGV4YzoKICAgICAgICAgICAgYm9keSA9IGYiVXBzdHJlYW0gSFRUUCBlcnJvcjoge2V4Yy5jb2RlfSB7ZXhjLnJlYXNvbn1cblVSTDoge3Vwc3RyZWFtX3VybH1cbiIKICAgICAgICAgICAgc2VsZi5fc2VuZF90ZXh0KDUwMiwgYm9keSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgZXhjZXB0IFVSTEVycm9yIGFzIGV4YzoKICAgICAgICAgICAgYm9keSA9IGYiVXBzdHJlYW0gY29ubmVjdGlvbiBlcnJvcjoge2V4Yy5yZWFzb259XG5VUkw6IHt1cHN0cmVhbV91cmx9XG4iCiAgICAgICAgICAgIHNlbGYuX3NlbmRfdGV4dCg1MDIsIGJvZHkpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICAgICAgYm9keSA9IGYiUHJveHkgZXJyb3I6IHtleGN9XG5VUkw6IHt1cHN0cmVhbV91cmx9XG4iCiAgICAgICAgICAgIHNlbGYuX3NlbmRfdGV4dCg1MDIsIGJvZHkpCiAgICAgICAgICAgIHJldHVybgoKICAgICAgICB3aXRoIHJlc3A6CiAgICAgICAgICAgIHN0YXR1cyA9IGdldGF0dHIocmVzcCwgInN0YXR1cyIsIDIwMCkKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKHN0YXR1cykKICAgICAgICAgICAgZXhjZXB0IChCcm9rZW5QaXBlRXJyb3IsIENvbm5lY3Rpb25SZXNldEVycm9yKToKICAgICAgICAgICAgICAgIHJldHVybgoKICAgICAgICAgICAgIyBGb3J3YXJkIHNlbGVjdGVkIGhlYWRlcnMKICAgICAgICAgICAgY29udGVudF90eXBlID0gcmVzcC5oZWFkZXJzLmdldCgiQ29udGVudC1UeXBlIikKICAgICAgICAgICAgaWYgY29udGVudF90eXBlOgogICAgICAgICAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1UeXBlIiwgY29udGVudF90eXBlKQogICAgICAgICAgICBjb250ZW50X2xlbmd0aCA9IHJlc3AuaGVhZGVycy5nZXQoIkNvbnRlbnQtTGVuZ3RoIikKICAgICAgICAgICAgaWYgY29udGVudF9sZW5ndGggYW5kIG5vdCBoZWFkX29ubHk6CiAgICAgICAgICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0aCIsIGNvbnRlbnRfbGVuZ3RoKQogICAgICAgICAgICBjb250ZW50X3JhbmdlID0gcmVzcC5oZWFkZXJzLmdldCgiQ29udGVudC1SYW5nZSIpCiAgICAgICAgICAgIGlmIGNvbnRlbnRfcmFuZ2U6CiAgICAgICAgICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LVJhbmdlIiwgY29udGVudF9yYW5nZSkKICAgICAgICAgICAgYWNjZXB0X3JhbmdlcyA9IHJlc3AuaGVhZGVycy5nZXQoIkFjY2VwdC1SYW5nZXMiKQogICAgICAgICAgICBpZiBhY2NlcHRfcmFuZ2VzOgogICAgICAgICAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQWNjZXB0LVJhbmdlcyIsIGFjY2VwdF9yYW5nZXMpCgogICAgICAgICAgICAjIFBhc3MgdGhyb3VnaCBJQ1kgaGVhZGVycyB1c2VmdWwgZm9yIGludGVybmV0IHJhZGlvCiAgICAgICAgICAgIGZvciBrZXksIHZhbHVlIGluIHJlc3AuaGVhZGVycy5pdGVtcygpOgogICAgICAgICAgICAgICAgbGsgPSBrZXkubG93ZXIoKQogICAgICAgICAgICAgICAgaWYgbGsuc3RhcnRzd2l0aCgiaWN5LSIpOgogICAgICAgICAgICAgICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoa2V5LCB2YWx1ZSkKCiAgICAgICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNhY2hlLUNvbnRyb2wiLCAibm8tc3RvcmUiKQogICAgICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb25uZWN0aW9uIiwgImNsb3NlIikKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgc2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgICAgIGV4Y2VwdCAoQnJva2VuUGlwZUVycm9yLCBDb25uZWN0aW9uUmVzZXRFcnJvcik6CiAgICAgICAgICAgICAgICByZXR1cm4KCiAgICAgICAgICAgIGlmIGhlYWRfb25seToKICAgICAgICAgICAgICAgIHJldHVybgoKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2hpbGUgVHJ1ZToKICAgICAgICAgICAgICAgICAgICBjaHVuayA9IHJlc3AucmVhZCg2NCAqIDEwMjQpCiAgICAgICAgICAgICAgICAgICAgaWYgbm90IGNodW5rOgogICAgICAgICAgICAgICAgICAgICAgICBicmVhawogICAgICAgICAgICAgICAgICAgIHNlbGYud2ZpbGUud3JpdGUoY2h1bmspCiAgICAgICAgICAgIGV4Y2VwdCAoQnJva2VuUGlwZUVycm9yLCBDb25uZWN0aW9uUmVzZXRFcnJvciwgQ29ubmVjdGlvbkFib3J0ZWRFcnJvciwgc29ja2V0LnRpbWVvdXQpOgogICAgICAgICAgICAgICAgTE9HLmluZm8oIkNsaWVudCBkaXNjb25uZWN0ZWQ6ICVzIiwgdXBzdHJlYW1fdXJsKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgICAgICAgICBMT0cud2FybmluZygiU3RyZWFtIGVycm9yIGZvciAlczogJXMiLCB1cHN0cmVhbV91cmwsIGV4YykKCgpjbGFzcyBQcm94eVNlcnZlcihUaHJlYWRpbmdIVFRQU2VydmVyKToKICAgIGRhZW1vbl90aHJlYWRzID0gVHJ1ZQoKICAgIGRlZiBoYW5kbGVfZXJyb3Ioc2VsZiwgcmVxdWVzdCwgY2xpZW50X2FkZHJlc3MpIC0+IE5vbmU6ICAjIG5vcWE6IEFOTjAwMQogICAgICAgIGV4YyA9IHN5cy5leGNfaW5mbygpWzFdCiAgICAgICAgaWYgaXNpbnN0YW5jZShleGMsIChCcm9rZW5QaXBlRXJyb3IsIENvbm5lY3Rpb25SZXNldEVycm9yLCBDb25uZWN0aW9uQWJvcnRlZEVycm9yLCBzb2NrZXQudGltZW91dCkpOgogICAgICAgICAgICBMT0cuZGVidWcoIkNsaWVudCBjb25uZWN0aW9uIGVycm9yIGZyb20gJXM6ICVzIiwgY2xpZW50X2FkZHJlc3MsIGV4YykKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgc3VwZXIoKS5oYW5kbGVfZXJyb3IocmVxdWVzdCwgY2xpZW50X2FkZHJlc3MpCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBzZXJ2ZXIgPSBQcm94eVNlcnZlcigoSE9TVCwgUE9SVCksIFByb3h5SGFuZGxlcikKICAgIExPRy5pbmZvKCJMaXN0ZW5pbmcgb24gaHR0cDovLyVzOiVzIiwgSE9TVCwgUE9SVCkKICAgIExPRy5pbmZvKCJFeGFtcGxlOiBodHRwOi8vPGhvc3Q+OiVzL3N0cmVhbT91cmw9aHR0cHM6Ly9leGFtcGxlLmNvbS9yYWRpby5tcDMiLCBQT1JUKQogICAgdHJ5OgogICAgICAgIHNlcnZlci5zZXJ2ZV9mb3JldmVyKCkKICAgIGV4Y2VwdCBLZXlib2FyZEludGVycnVwdDoKICAgICAgICBMT0cuaW5mbygiU2h1dHRpbmcgZG93biIpCiAgICBmaW5hbGx5OgogICAgICAgIHNlcnZlci5zZXJ2ZXJfY2xvc2UoKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgcmFpc2UgU3lzdGVtRXhpdChtYWluKCkpCg=='

PROXY_DEFAULT='STREAM_PROXY_HOST=0.0.0.0
STREAM_PROXY_PORT=8090
STREAM_PROXY_TIMEOUT=15
STREAM_PROXY_MAX_REDIRECTS=5
STREAM_PROXY_LOG_LEVEL=INFO
'

PROXY_SERVICE_UNIT='[Unit]
Description=YTuner HTTPS->HTTP stream proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=-/etc/default/ytuner-stream-proxy
ExecStart=/usr/bin/python3 /opt/ytuner/ytuner-stream-proxy.py
Restart=always
RestartSec=3
StandardOutput=append:/var/log/ytuner-stream-proxy.log
StandardError=append:/var/log/ytuner-stream-proxy.log
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
'

# --- Admin WebUI/API ----------------------------------------------------------
ADMIN_DEFAULT='YTUNER_ADMIN_HOST=0.0.0.0
YTUNER_ADMIN_PORT=8091
YTUNER_ADMIN_TOKEN=
YTUNER_ADMIN_ALLOW_SYSTEMCTL=1
'

ADMIN_SERVICE_UNIT='[Unit]
Description=YTuner Admin WebUI and API
After=network-online.target ytuner.service ytuner-stream-proxy.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/ytuner
EnvironmentFile=-/etc/default/ytuner-admin
ExecStart=/usr/bin/python3 /opt/ytuner/ytuner-admin.py
Restart=always
RestartSec=3
StandardOutput=append:/var/log/ytuner-admin.log
StandardError=append:/var/log/ytuner-admin.log

[Install]
WantedBy=multi-user.target
'

# Admin and webui files are shipped as base64 in one-shot mode to keep installer self-contained.
ADMIN_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKZnJvbSBodHRwIGltcG9ydCBIVFRQU3RhdHVzCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIsIFRocmVhZGluZ0hUVFBTZXJ2ZXIKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gdXJsbGliLnBhcnNlIGltcG9ydCBwYXJzZV9xcywgdXJsc3BsaXQKCgpJTlNUQUxMX0RJUiA9IFBhdGgob3MuZW52aXJvbi5nZXQoIllUVU5FUl9JTlNUQUxMX0RJUiIsICIvb3B0L3l0dW5lciIpKQpDT05GSUdfRElSID0gSU5TVEFMTF9ESVIgLyAiY29uZmlnIgoKCmRlZiBfZmlyc3RfZXhpc3RpbmcoKnBhdGhzOiBQYXRoKSAtPiBQYXRoOgogICAgZm9yIHAgaW4gcGF0aHM6CiAgICAgICAgaWYgcC5leGlzdHMoKToKICAgICAgICAgICAgcmV0dXJuIHAKICAgIHJldHVybiBwYXRoc1swXQoKCllUVU5FUl9JTkkgPSBfZmlyc3RfZXhpc3RpbmcoSU5TVEFMTF9ESVIgLyAieXR1bmVyLmluaSIsIENPTkZJR19ESVIgLyAieXR1bmVyLmluaSIpCkFWUl9JTkkgPSBfZmlyc3RfZXhpc3RpbmcoQ09ORklHX0RJUiAvICJhdnIuaW5pIiwgSU5TVEFMTF9ESVIgLyAiYXZyLmluaSIpClNUQVRJT05TX0lOSSA9IF9maXJzdF9leGlzdGluZyhDT05GSUdfRElSIC8gInN0YXRpb25zLmluaSIsIElOU1RBTExfRElSIC8gInN0YXRpb25zLmluaSIpClBST1hZX0VOViA9IF9maXJzdF9leGlzdGluZyhQYXRoKCIvZXRjL2RlZmF1bHQveXR1bmVyLXN0cmVhbS1wcm94eSIpLCBDT05GSUdfRElSIC8gInl0dW5lci1zdHJlYW0tcHJveHkuZGVmYXVsdCIpClBST1hZX1NDUklQVCA9IF9maXJzdF9leGlzdGluZyhJTlNUQUxMX0RJUiAvICJ5dHVuZXItc3RyZWFtLXByb3h5LnB5IiwgSU5TVEFMTF9ESVIgLyAic2NyaXB0cyIgLyAieXR1bmVyLXN0cmVhbS1wcm94eS5weSIpCldFQl9ESVIgPSBfZmlyc3RfZXhpc3RpbmcoUGF0aChvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0FETUlOX1dFQl9ESVIiLCAiL29wdC95dHVuZXIvd2VidWkiKSksIElOU1RBTExfRElSIC8gIndlYnVpIikKTE9HX0ZJTEVTID0gewogICAgInl0dW5lciI6IFBhdGgoIi92YXIvbG9nL3l0dW5lci5sb2ciKSwKICAgICJwcm94eSI6IFBhdGgoIi92YXIvbG9nL3l0dW5lci1zdHJlYW0tcHJveHkubG9nIiksCiAgICAiYWRtaW4iOiBQYXRoKCIvdmFyL2xvZy95dHVuZXItYWRtaW4ubG9nIiksCn0KU0VSVklDRVMgPSBbInl0dW5lciIsICJ5dHVuZXItc3RyZWFtLXByb3h5IiwgInl0dW5lci1hZG1pbiJdCkFMTE9XX1NZU1RFTUNUTCA9IG9zLmVudmlyb24uZ2V0KCJZVFVORVJfQURNSU5fQUxMT1dfU1lTVEVNQ1RMIiwgIjEiKSAhPSAiMCIKSE9TVCA9IG9zLmVudmlyb24uZ2V0KCJZVFVORVJfQURNSU5fSE9TVCIsICIwLjAuMC4wIikKUE9SVCA9IGludChvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0FETUlOX1BPUlQiLCAiODA5MSIpKQpUT0tFTiA9IG9zLmVudmlyb24uZ2V0KCJZVFVORVJfQURNSU5fVE9LRU4iLCAiIikKCgpkZWYgcnVuX2NtZChjbWQ6IGxpc3Rbc3RyXSwgdGltZW91dDogZmxvYXQgPSAyMC4wKSAtPiBkaWN0OgogICAgdHJ5OgogICAgICAgIHByb2MgPSBzdWJwcm9jZXNzLnJ1bihjbWQsIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD10aW1lb3V0LCBjaGVjaz1GYWxzZSkKICAgICAgICByZXR1cm4gewogICAgICAgICAgICAib2siOiBwcm9jLnJldHVybmNvZGUgPT0gMCwKICAgICAgICAgICAgInJjIjogcHJvYy5yZXR1cm5jb2RlLAogICAgICAgICAgICAic3Rkb3V0IjogcHJvYy5zdGRvdXRbLTgwMDA6XSwKICAgICAgICAgICAgInN0ZGVyciI6IHByb2Muc3RkZXJyWy04MDAwOl0sCiAgICAgICAgICAgICJjbWQiOiBjbWQsCiAgICAgICAgfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7Im9rIjogRmFsc2UsICJyYyI6IC0xLCAic3Rkb3V0IjogIiIsICJzdGRlcnIiOiBzdHIoZXhjKSwgImNtZCI6IGNtZH0KCgpkZWYgcmVhZF90ZXh0KHBhdGg6IFBhdGgpIC0+IHN0cjoKICAgIGlmIG5vdCBwYXRoLmV4aXN0cygpOgogICAgICAgIHJldHVybiAiIgogICAgcmV0dXJuIHBhdGgucmVhZF90ZXh0KGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0icmVwbGFjZSIpCgoKZGVmIHdyaXRlX3RleHRfYXRvbWljKHBhdGg6IFBhdGgsIGNvbnRlbnQ6IHN0cikgLT4gTm9uZToKICAgIHBhdGgucGFyZW50Lm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSkKICAgIHRtcCA9IHBhdGgud2l0aF9zdWZmaXgocGF0aC5zdWZmaXggKyAiLnRtcCIpCiAgICB0bXAud3JpdGVfdGV4dChjb250ZW50LCBlbmNvZGluZz0idXRmLTgiKQogICAgdG1wLnJlcGxhY2UocGF0aCkKCgpkZWYgaW5pX2dldChjb250ZW50OiBzdHIsIHNlY3Rpb246IHN0ciwga2V5OiBzdHIsIGRlZmF1bHQ6IHN0ciA9ICIiKSAtPiBzdHI6CiAgICBpbl9zZWN0aW9uID0gRmFsc2UKICAgIHNlY19yZSA9IHJlLmNvbXBpbGUociJeXHMqXFsoLis/KVxdXHMqJCIpCiAgICBrdl9yZSA9IHJlLmNvbXBpbGUociJeXHMqKFteOyM9XHNdW149XSo/KVxzKj1ccyooLio/KVxzKiQiKQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbSA9IHNlY19yZS5tYXRjaChsaW5lKQogICAgICAgIGlmIG06CiAgICAgICAgICAgIGluX3NlY3Rpb24gPSBtLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBzZWN0aW9uLmxvd2VyKCkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBub3QgaW5fc2VjdGlvbjoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBrbSA9IGt2X3JlLm1hdGNoKGxpbmUpCiAgICAgICAgaWYga20gYW5kIGttLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBrZXkubG93ZXIoKToKICAgICAgICAgICAgcmV0dXJuIGttLmdyb3VwKDIpCiAgICByZXR1cm4gZGVmYXVsdAoKCmRlZiBlbnZfcGFyc2UoY29udGVudDogc3RyKSAtPiBkaWN0W3N0ciwgc3RyXToKICAgIG91dDogZGljdFtzdHIsIHN0cl0gPSB7fQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpIG9yICI9IiBub3QgaW4gbGluZToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgb3V0W2suc3RyaXAoKV0gPSB2LnN0cmlwKCkuc3RyaXAoJyInKS5zdHJpcCgiJyIpCiAgICByZXR1cm4gb3V0CgoKZGVmIGVudl9yZW5kZXIoZXhpc3Rpbmc6IHN0ciwgdXBkYXRlczogZGljdFtzdHIsIHN0cl0pIC0+IHN0cjoKICAgIGxpbmVzID0gZXhpc3Rpbmcuc3BsaXRsaW5lcygpIGlmIGV4aXN0aW5nIGVsc2UgW10KICAgIHNlZW46IHNldFtzdHJdID0gc2V0KCkKICAgIG91dDogbGlzdFtzdHJdID0gW10KICAgIGZvciBsaW5lIGluIGxpbmVzOgogICAgICAgIGlmICI9IiBpbiBsaW5lIGFuZCBub3QgbGluZS5sc3RyaXAoKS5zdGFydHN3aXRoKCIjIik6CiAgICAgICAgICAgIGsgPSBsaW5lLnNwbGl0KCI9IiwgMSlbMF0uc3RyaXAoKQogICAgICAgICAgICBrdSA9IGsudXBwZXIoKQogICAgICAgICAgICBpZiBrdSBpbiB1cGRhdGVzOgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChmIntrfT17dXBkYXRlc1trdV19IikKICAgICAgICAgICAgICAgIHNlZW4uYWRkKGt1KQogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCiAgICBmb3IgaywgdiBpbiB1cGRhdGVzLml0ZW1zKCk6CiAgICAgICAgaWYgayBub3QgaW4gc2VlbjoKICAgICAgICAgICAgb3V0LmFwcGVuZChmIntrfT17dn0iKQogICAgcmV0dXJuICJcbiIuam9pbihvdXQpLnJzdHJpcCgpICsgIlxuIgoKCmRlZiBzZXJ2aWNlX3N0YXR1cyhuYW1lOiBzdHIpIC0+IGRpY3Q6CiAgICBpZiBub3QgQUxMT1dfU1lTVEVNQ1RMIG9yIHNodXRpbC53aGljaCgic3lzdGVtY3RsIikgaXMgTm9uZToKICAgICAgICBwYXR0ZXJucyA9IHsKICAgICAgICAgICAgInl0dW5lciI6ICJbeV10dW5lciIsCiAgICAgICAgICAgICJ5dHVuZXItc3RyZWFtLXByb3h5IjogIlt5XXR1bmVyLXN0cmVhbS1wcm94eS5weSIsCiAgICAgICAgICAgICJ5dHVuZXItYWRtaW4iOiAiW3lddHVuZXItYWRtaW4ucHkiLAogICAgICAgIH0KICAgICAgICBwYXQgPSBwYXR0ZXJucy5nZXQobmFtZSwgZiJbe25hbWVbOjFdfV17bmFtZVsxOl19IiBpZiBuYW1lIGVsc2UgbmFtZSkKICAgICAgICBhY3RpdmUgPSBydW5fY21kKFsic2giLCAiLWxjIiwgZiJwZ3JlcCAtYWYgJ3twYXR9JyA+L2Rldi9udWxsICYmIGVjaG8gYWN0aXZlIHx8IGVjaG8gaW5hY3RpdmUiXSwgdGltZW91dD01KQogICAgICAgIHJldHVybiB7Im5hbWUiOiBuYW1lLCAiYWN0aXZlIjogYWN0aXZlWyJzdGRvdXQiXS5zdHJpcCgpIG9yICJpbmFjdGl2ZSIsICJlbmFibGVkIjogIm4vYSIsICJkZXRhaWwiOiBhY3RpdmV9CiAgICBhY3RpdmUgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgImlzLWFjdGl2ZSIsIG5hbWVdLCB0aW1lb3V0PTEwKQogICAgZW5hYmxlZCA9IHJ1bl9jbWQoWyJzeXN0ZW1jdGwiLCAiaXMtZW5hYmxlZCIsIG5hbWVdLCB0aW1lb3V0PTEwKQogICAgc2hvdyA9IHJ1bl9jbWQoWyJzeXN0ZW1jdGwiLCAic2hvdyIsIG5hbWUsICItLXByb3BlcnR5PUFjdGl2ZVN0YXRlLFN1YlN0YXRlLFVuaXRGaWxlU3RhdGUsTWFpblBJRCxFeGVjTWFpblN0YXR1cyJdLCB0aW1lb3V0PTEwKQogICAgcHJvcHMgPSB7fQogICAgZm9yIGxpbmUgaW4gc2hvd1sic3Rkb3V0Il0uc3BsaXRsaW5lcygpOgogICAgICAgIGlmICI9IiBpbiBsaW5lOgogICAgICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgICAgIHByb3BzW2suc3RyaXAoKV0gPSB2LnN0cmlwKCkKICAgIHJldHVybiB7CiAgICAgICAgIm5hbWUiOiBuYW1lLAogICAgICAgICJhY3RpdmUiOiBhY3RpdmVbInN0ZG91dCJdLnN0cmlwKCkgb3IgcHJvcHMuZ2V0KCJBY3RpdmVTdGF0ZSIsICJ1bmtub3duIiksCiAgICAgICAgImVuYWJsZWQiOiBlbmFibGVkWyJzdGRvdXQiXS5zdHJpcCgpIG9yIHByb3BzLmdldCgiVW5pdEZpbGVTdGF0ZSIsICJ1bmtub3duIiksCiAgICAgICAgInByb3BzIjogcHJvcHMsCiAgICB9CgoKZGVmIHBvcnRfY2hlY2socG9ydDogaW50LCBob3N0OiBzdHIgPSAiMTI3LjAuMC4xIikgLT4gZGljdDoKICAgIGltcG9ydCBzb2NrZXQKCiAgICBzID0gc29ja2V0LnNvY2tldCgpCiAgICBzLnNldHRpbWVvdXQoMS41KQogICAgdHJ5OgogICAgICAgIHMuY29ubmVjdCgoaG9zdCwgcG9ydCkpCiAgICAgICAgcy5jbG9zZSgpCiAgICAgICAgcmV0dXJuIHsicG9ydCI6IHBvcnQsICJvcGVuIjogVHJ1ZSwgImhvc3QiOiBob3N0fQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIGVyciA9IHN0cihleGMpCiAgICBmaW5hbGx5OgogICAgICAgIHRyeToKICAgICAgICAgICAgcy5jbG9zZSgpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwoKICAgICMgRmFsbGJhY2sgZm9yIGNvbnRhaW5lcml6ZWQvYm91bmQtdG8tbm9uLWxvb3BiYWNrIGxpc3RlbmVyczogaW5zcGVjdCBzcy9uZXRzdGF0LgogICAgc3MgPSBydW5fY21kKFsic2giLCAiLWxjIiwgZiJzcyAtbG50SCAnKCBzcG9ydCA9IDp7aW50KHBvcnQpfSApJyAyPi9kZXYvbnVsbCB8IGhlYWQgLW4gMSJdLCB0aW1lb3V0PTUpCiAgICBsaW5lID0gKHNzLmdldCgic3Rkb3V0Iikgb3IgIiIpLnN0cmlwKCkKICAgIGlmIHNzLmdldCgib2siKSBhbmQgbGluZToKICAgICAgICByZXR1cm4geyJwb3J0IjogcG9ydCwgIm9wZW4iOiBUcnVlLCAiaG9zdCI6IGhvc3QsICJ2aWEiOiAic3MiLCAibGlzdGVuZXIiOiBsaW5lfQoKICAgIG5zID0gcnVuX2NtZChbInNoIiwgIi1sYyIsIGYibmV0c3RhdCAtbG50IDI+L2Rldi9udWxsIHwgYXdrICckNCB+IC86e2ludChwb3J0KX0kLycgfCBoZWFkIC1uIDEiXSwgdGltZW91dD01KQogICAgbmxpbmUgPSAobnMuZ2V0KCJzdGRvdXQiKSBvciAiIikuc3RyaXAoKQogICAgaWYgbnMuZ2V0KCJvayIpIGFuZCBubGluZToKICAgICAgICByZXR1cm4geyJwb3J0IjogcG9ydCwgIm9wZW4iOiBUcnVlLCAiaG9zdCI6IGhvc3QsICJ2aWEiOiAibmV0c3RhdCIsICJsaXN0ZW5lciI6IG5saW5lfQoKICAgIHJldHVybiB7InBvcnQiOiBwb3J0LCAib3BlbiI6IEZhbHNlLCAiZXJyb3IiOiBlcnIsICJob3N0IjogaG9zdH0KCgpkZWYgaHR0cF9jaGVjayh1cmw6IHN0ciwgdGltZW91dDogZmxvYXQgPSA1LjApIC0+IGRpY3Q6CiAgICBmcm9tIHVybGxpYi5yZXF1ZXN0IGltcG9ydCBSZXF1ZXN0LCB1cmxvcGVuCiAgICBmcm9tIHVybGxpYi5wYXJzZSBpbXBvcnQgdXJsc3BsaXQsIHVybHVuc3BsaXQKCiAgICBkZWYgX3RyeSh1OiBzdHIpIC0+IGRpY3Q6CiAgICAgICAgcmVxID0gUmVxdWVzdCh1LCBoZWFkZXJzPXsiVXNlci1BZ2VudCI6ICJ5dHVuZXItYWRtaW4vMC4xIn0pCiAgICAgICAgdDAgPSB0aW1lLnRpbWUoKQogICAgICAgIHRyeToKICAgICAgICAgICAgd2l0aCB1cmxvcGVuKHJlcSwgdGltZW91dD10aW1lb3V0KSBhcyByZXNwOgogICAgICAgICAgICAgICAgYm9keSA9IHJlc3AucmVhZCg1MTIpCiAgICAgICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgICAgICJ1cmwiOiB1LAogICAgICAgICAgICAgICAgICAgICJvayI6IDIwMCA8PSBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApIDwgNTAwLAogICAgICAgICAgICAgICAgICAgICJzdGF0dXMiOiBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApLAogICAgICAgICAgICAgICAgICAgICJtcyI6IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKSwKICAgICAgICAgICAgICAgICAgICAiYnl0ZXMiOiBsZW4oYm9keSksCiAgICAgICAgICAgICAgICB9CiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICByZXR1cm4geyJ1cmwiOiB1LCAib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4YyksICJtcyI6IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKX0KCiAgICByZXMgPSBfdHJ5KHVybCkKICAgIGlmIHJlcy5nZXQoIm9rIik6CiAgICAgICAgcmV0dXJuIHJlcwogICAgIyBJZiBsb2NhbGhvc3QgZmFpbGVkLCB0cnkgbG9jYWwgaW50ZXJmYWNlIElQcyAoc29tZSBzZXJ2aWNlcyBiaW5kIG9ubHkgdG8gY29udGFpbmVyIElQKQogICAgdHJ5OgogICAgICAgIHNwID0gdXJsc3BsaXQodXJsKQogICAgICAgIGlmIHNwLmhvc3RuYW1lIGluIHsiMTI3LjAuMC4xIiwgImxvY2FsaG9zdCJ9OgogICAgICAgICAgICBpcHMgPSBydW5fY21kKFsic2giLCAiLWxjIiwgImhvc3RuYW1lIC1JIDI+L2Rldi9udWxsIHx8IHRydWUiXSwgdGltZW91dD01KQogICAgICAgICAgICBmb3IgaXAgaW4gKGlwcy5nZXQoInN0ZG91dCIpIG9yICIiKS5zcGxpdCgpOgogICAgICAgICAgICAgICAgaWYgaXAuc3RhcnRzd2l0aCgiMTI3LiIpOgogICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgICAgICBhbHQgPSB1cmx1bnNwbGl0KChzcC5zY2hlbWUsIGYie2lwfTp7c3AucG9ydH0iIGlmIHNwLnBvcnQgZWxzZSBpcCwgc3AucGF0aCwgc3AucXVlcnksIHNwLmZyYWdtZW50KSkKICAgICAgICAgICAgICAgIHIyID0gX3RyeShhbHQpCiAgICAgICAgICAgICAgICBpZiByMi5nZXQoIm9rIik6CiAgICAgICAgICAgICAgICAgICAgcjJbImZhbGxiYWNrX2Zyb20iXSA9IHVybAogICAgICAgICAgICAgICAgICAgIHJldHVybiByMgogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCiAgICByZXR1cm4gcmVzCgoKZGVmIGNoZWNrX3N0cmVhbV91cmwodXJsOiBzdHIsIHRpbWVvdXQ6IGZsb2F0ID0gNi4wKSAtPiBkaWN0OgogICAgIiIiQ2hlY2sgaWYgYSByYWRpbyBzdHJlYW0gVVJMIGlzIHJlYWNoYWJsZS4gUmV0dXJucyBzdGF0dXMvY29udGVudC10eXBlIGluZm8uIiIiCiAgICBmcm9tIHVybGxpYi5yZXF1ZXN0IGltcG9ydCBSZXF1ZXN0LCB1cmxvcGVuCiAgICBmcm9tIHVybGxpYi5lcnJvciBpbXBvcnQgSFRUUEVycm9yLCBVUkxFcnJvcgoKICAgIHVybCA9ICh1cmwgb3IgIiIpLnN0cmlwKCkKICAgIGlmIG5vdCB1cmw6CiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAicmVhY2hhYmxlIjogRmFsc2UsICJlcnJvciI6ICJlbXB0eSB1cmwifQogICAgIyBhbGxvdyBvbmx5IGh0dHAvaHR0cHMKICAgIGlmIG5vdCByZS5tYXRjaChyJ15odHRwcz86Ly8nLCB1cmwsIHJlLkkpOgogICAgICAgIHJldHVybiB7InVybCI6IHVybCwgInJlYWNoYWJsZSI6IEZhbHNlLCAiZXJyb3IiOiAib25seSBodHRwL2h0dHBzIHN1cHBvcnRlZCJ9CgogICAgcmVxID0gUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInl0dW5lci1hZG1pbi8wLjEiLCAiSWN5LU1ldGFEYXRhIjogIjEifSwgbWV0aG9kPSJHRVQiKQogICAgdDAgPSB0aW1lLnRpbWUoKQogICAgdHJ5OgogICAgICAgIHdpdGggdXJsb3BlbihyZXEsIHRpbWVvdXQ9dGltZW91dCkgYXMgcmVzcDoKICAgICAgICAgICAgc3RhdHVzID0gZ2V0YXR0cihyZXNwLCAic3RhdHVzIiwgMjAwKQogICAgICAgICAgICBjdHlwZSA9IHJlc3AuaGVhZGVycy5nZXQoIkNvbnRlbnQtVHlwZSIsICIiKQogICAgICAgICAgICBib2R5ID0gcmVzcC5yZWFkKDEwMjQpICAjIHJlYWQgYSBzbWFsbCBjaHVuayB0byBjb25maXJtIHN0cmVhbSBmbG93cwogICAgICAgICAgICBtcyA9IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKQogICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgInVybCI6IHVybCwKICAgICAgICAgICAgICAgICJyZWFjaGFibGUiOiAyMDAgPD0gc3RhdHVzIDwgNDAwLAogICAgICAgICAgICAgICAgInN0YXR1cyI6IHN0YXR1cywKICAgICAgICAgICAgICAgICJjb250ZW50X3R5cGUiOiBjdHlwZSwKICAgICAgICAgICAgICAgICJtcyI6IG1zLAogICAgICAgICAgICAgICAgImJ5dGVzIjogbGVuKGJvZHkpLAogICAgICAgICAgICB9CiAgICBleGNlcHQgSFRUUEVycm9yIGFzIGV4YzoKICAgICAgICBtcyA9IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKQogICAgICAgIHJldHVybiB7InVybCI6IHVybCwgInJlYWNoYWJsZSI6IEZhbHNlLCAic3RhdHVzIjogZXhjLmNvZGUsICJlcnJvciI6IHN0cihleGMucmVhc29uKSwgIm1zIjogbXN9CiAgICBleGNlcHQgVVJMRXJyb3IgYXMgZXhjOgogICAgICAgIG1zID0gaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApCiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAicmVhY2hhYmxlIjogRmFsc2UsICJlcnJvciI6IHN0cihleGMucmVhc29uKSwgIm1zIjogbXN9CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgbXMgPSBpbnQoKHRpbWUudGltZSgpIC0gdDApICogMTAwMCkKICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJyZWFjaGFibGUiOiBGYWxzZSwgImVycm9yIjogc3RyKGV4YyksICJtcyI6IG1zfQoKCmRlZiBwYXJzZV9zdGF0aW9uc19pbmkoY29udGVudDogc3RyKSAtPiBsaXN0W2RpY3RdOgogICAgZ3JvdXBzOiBsaXN0W2RpY3RdID0gW10KICAgIGN1cnJlbnQ6IGRpY3QgfCBOb25lID0gTm9uZQogICAgZm9yIHJhdyBpbiBjb250ZW50LnNwbGl0bGluZXMoKToKICAgICAgICBsaW5lID0gcmF3LnN0cmlwKCkKICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIjsiKSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBsaW5lLnN0YXJ0c3dpdGgoIlsiKSBhbmQgbGluZS5lbmRzd2l0aCgiXSIpOgogICAgICAgICAgICBjdXJyZW50ID0geyJuYW1lIjogbGluZVsxOi0xXS5zdHJpcCgpLCAic3RhdGlvbnMiOiBbXX0KICAgICAgICAgICAgZ3JvdXBzLmFwcGVuZChjdXJyZW50KQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmICI9IiBub3QgaW4gbGluZToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBuYW1lLCB2YWx1ZSA9IGxpbmUuc3BsaXQoIj0iLCAxKQogICAgICAgIHN0YXRpb25fbmFtZSA9IG5hbWUuc3RyaXAoKQogICAgICAgIHJlc3QgPSB2YWx1ZS5zdHJpcCgpCiAgICAgICAgdXJsLCBsb2dvID0gcmVzdCwgIiIKICAgICAgICBpZiAifCIgaW4gcmVzdDoKICAgICAgICAgICAgdXJsLCBsb2dvID0gcmVzdC5zcGxpdCgifCIsIDEpCiAgICAgICAgaXRlbSA9IHsibmFtZSI6IHN0YXRpb25fbmFtZSwgInVybCI6IHVybC5zdHJpcCgpLCAibG9nbyI6IGxvZ28uc3RyaXAoKX0KICAgICAgICBpZiBjdXJyZW50IGlzIE5vbmU6CiAgICAgICAgICAgIGN1cnJlbnQgPSB7Im5hbWUiOiAiVW5ncm91cGVkIiwgInN0YXRpb25zIjogW119CiAgICAgICAgICAgIGdyb3Vwcy5hcHBlbmQoY3VycmVudCkKICAgICAgICBjdXJyZW50WyJzdGF0aW9ucyJdLmFwcGVuZChpdGVtKQogICAgcmV0dXJuIGdyb3VwcwoKCmRlZiByZW5kZXJfc3RhdGlvbnNfaW5pKGdyb3VwczogbGlzdFtkaWN0XSkgLT4gc3RyOgogICAgbGluZXMgPSBbCiAgICAgICAgIjsgQ3VzdG9tIHN0YXRpb25zIGZvciBZVHVuZXIgXCJNeSBTdGF0aW9uc1wiIG1lbnUuIiwKICAgICAgICAiOyBGb3JtYXQ6IFN0YXRpb24gTmFtZT1zdHJlYW1fdXJsfG9wdGlvbmFsX2xvZ29fdXJsIiwKICAgICAgICAiIiwKICAgIF0KICAgIGZvciBnIGluIGdyb3VwczoKICAgICAgICBnbmFtZSA9IHN0cihnLmdldCgibmFtZSIsICIiKSkuc3RyaXAoKSBvciAiVW5ncm91cGVkIgogICAgICAgIGxpbmVzLmFwcGVuZChmIlt7Z25hbWV9XSIpCiAgICAgICAgZm9yIHN0IGluIGcuZ2V0KCJzdGF0aW9ucyIsIFtdKSBvciBbXToKICAgICAgICAgICAgbmFtZSA9IHN0cihzdC5nZXQoIm5hbWUiLCAiIikpLnN0cmlwKCkKICAgICAgICAgICAgdXJsID0gc3RyKHN0LmdldCgidXJsIiwgIiIpKS5zdHJpcCgpCiAgICAgICAgICAgIGxvZ28gPSBzdHIoc3QuZ2V0KCJsb2dvIiwgIiIpKS5zdHJpcCgpCiAgICAgICAgICAgIGlmIG5vdCBuYW1lIG9yIG5vdCB1cmw6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBpZiBhbnkoYyBpbiBuYW1lIGZvciBjIGluICJcclxuPSIpIG9yIGFueShjIGluIHVybCBmb3IgYyBpbiAiXHJcbnwiKSBvciBhbnkoYyBpbiBsb2dvIGZvciBjIGluICJcclxuIik6CiAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCJJbnZhbGlkIGNoYXJhY3RlcnMgaW4gc3RhdGlvbiBmaWVsZHMiKQogICAgICAgICAgICBsaW5lcy5hcHBlbmQoZiJ7bmFtZX09e3VybH0iICsgKGYifHtsb2dvfSIgaWYgbG9nbyBlbHNlICIiKSkKICAgICAgICBsaW5lcy5hcHBlbmQoIiIpCiAgICByZXR1cm4gIlxuIi5qb2luKGxpbmVzKS5yc3RyaXAoKSArICJcbiIKCgpkZWYgY29sbGVjdF9jb25maWcoKSAtPiBkaWN0OgogICAgeXR1bmVyID0gcmVhZF90ZXh0KFlUVU5FUl9JTkkpCiAgICBhdnIgPSByZWFkX3RleHQoQVZSX0lOSSkKICAgIHByb3h5ID0gZW52X3BhcnNlKHJlYWRfdGV4dChQUk9YWV9FTlYpKQogICAgc3RhdGlvbnNfY29udGVudCA9IHJlYWRfdGV4dChTVEFUSU9OU19JTkkpCiAgICByZXR1cm4gewogICAgICAgICJwYXRocyI6IHsKICAgICAgICAgICAgImluc3RhbGxfZGlyIjogc3RyKElOU1RBTExfRElSKSwKICAgICAgICAgICAgInl0dW5lcl9pbmkiOiBzdHIoWVRVTkVSX0lOSSksCiAgICAgICAgICAgICJhdnJfaW5pIjogc3RyKEFWUl9JTkkpLAogICAgICAgICAgICAic3RhdGlvbnNfaW5pIjogc3RyKFNUQVRJT05TX0lOSSksCiAgICAgICAgICAgICJwcm94eV9lbnYiOiBzdHIoUFJPWFlfRU5WKSwKICAgICAgICB9LAogICAgICAgICJ5dHVuZXIiOiB7CiAgICAgICAgICAgICJ3ZWJfcG9ydCI6IGluaV9nZXQoeXR1bmVyLCAiV2ViU2VydmVyIiwgIldlYlNlcnZlclBvcnQiLCAiODAiKSwKICAgICAgICAgICAgImRuc19wb3J0IjogaW5pX2dldCh5dHVuZXIsICJETlNTZXJ2ZXIiLCAiRE5TU2VydmVyUG9ydCIsICI1MyIpLAogICAgICAgICAgICAiZG5zX2VuYWJsZSI6IGluaV9nZXQoeXR1bmVyLCAiRE5TU2VydmVyIiwgIkVuYWJsZSIsICIxIiksCiAgICAgICAgICAgICJpbnRlcmNlcHRfZG5zIjogaW5pX2dldCh5dHVuZXIsICJETlNTZXJ2ZXIiLCAiSW50ZXJjZXB0RE5zIiwgIiIpLAogICAgICAgICAgICAicmJfY2FjaGVfdHlwZSI6IGluaV9nZXQoeXR1bmVyLCAiUmFkaW9icm93c2VyIiwgIlJCQ2FjaGVUeXBlIiwgIiIpLAogICAgICAgICAgICAibWVzc2FnZV9sZXZlbCI6IGluaV9nZXQoeXR1bmVyLCAiQ29uZmlndXJhdGlvbiIsICJNZXNzYWdlSW5mb0xldmVsIiwgIiIpLAogICAgICAgIH0sCiAgICAgICAgImF2ciI6IHsKICAgICAgICAgICAgInByb3RvY29sIjogaW5pX2dldChhdnIsICJDb25maWd1cmF0aW9uIiwgIlByb3RvY29sIiwgIiIpLAogICAgICAgIH0sCiAgICAgICAgInByb3h5IjogewogICAgICAgICAgICAiaG9zdCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX0hPU1QiLCAiMC4wLjAuMCIpLAogICAgICAgICAgICAicG9ydCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX1BPUlQiLCAiODA5MCIpLAogICAgICAgICAgICAidGltZW91dCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX1RJTUVPVVQiLCAiMTUiKSwKICAgICAgICAgICAgIm1heF9yZWRpcmVjdHMiOiBwcm94eS5nZXQoIlNUUkVBTV9QUk9YWV9NQVhfUkVESVJFQ1RTIiwgIjUiKSwKICAgICAgICAgICAgImxvZ19sZXZlbCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX0xPR19MRVZFTCIsICJJTkZPIiksCiAgICAgICAgfSwKICAgICAgICAic3RhdGlvbnMiOiB7CiAgICAgICAgICAgICJwYXRoIjogc3RyKFNUQVRJT05TX0lOSSksCiAgICAgICAgICAgICJncm91cHMiOiBwYXJzZV9zdGF0aW9uc19pbmkoc3RhdGlvbnNfY29udGVudCksCiAgICAgICAgICAgICJyYXciOiBzdGF0aW9uc19jb250ZW50LAogICAgICAgIH0sCiAgICB9CgoKZGVmIHNhdmVfcHJveHlfZW52KHBheWxvYWQ6IGRpY3QpIC0+IGRpY3Q6CiAgICBhbGxvd2VkID0gewogICAgICAgICJTVFJFQU1fUFJPWFlfSE9TVCIsCiAgICAgICAgIlNUUkVBTV9QUk9YWV9QT1JUIiwKICAgICAgICAiU1RSRUFNX1BST1hZX1RJTUVPVVQiLAogICAgICAgICJTVFJFQU1fUFJPWFlfTUFYX1JFRElSRUNUUyIsCiAgICAgICAgIlNUUkVBTV9QUk9YWV9MT0dfTEVWRUwiLAogICAgICAgICJTVFJFQU1fUFJPWFlfVVNFUl9BR0VOVCIsCiAgICB9CiAgICB1cGRhdGVzID0ge30KICAgIGZvciBrLCB2IGluIHBheWxvYWQuaXRlbXMoKToKICAgICAgICBrdSA9IGsudXBwZXIoKQogICAgICAgIGlmIGt1IGluIGFsbG93ZWQgYW5kIHYgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIHVwZGF0ZXNba3VdID0gc3RyKHYpLnN0cmlwKCkKICAgIGlmICJTVFJFQU1fUFJPWFlfUE9SVCIgaW4gdXBkYXRlcyBhbmQgbm90IHVwZGF0ZXNbIlNUUkVBTV9QUk9YWV9QT1JUIl0uaXNkaWdpdCgpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoIlNUUkVBTV9QUk9YWV9QT1JUIG11c3QgYmUgbnVtZXJpYyIpCiAgICBjb250ZW50ID0gcmVhZF90ZXh0KFBST1hZX0VOVikKICAgIG5ld19jb250ZW50ID0gZW52X3JlbmRlcihjb250ZW50LCB1cGRhdGVzKQogICAgd3JpdGVfdGV4dF9hdG9taWMoUFJPWFlfRU5WLCBuZXdfY29udGVudCkKICAgIHJldHVybiB7InNhdmVkIjogVHJ1ZSwgInBhdGgiOiBzdHIoUFJPWFlfRU5WKSwgInVwZGF0ZXMiOiB1cGRhdGVzfQoKCmRlZiBydW5fdGVzdHMoKSAtPiBkaWN0OgogICAgY2ZnID0gY29sbGVjdF9jb25maWcoKQogICAgcHJveHlfcG9ydCA9IGludChjZmdbInByb3h5Il0uZ2V0KCJwb3J0IiwgIjgwOTAiKSBvciAiODA5MCIpCiAgICB3ZWJfcG9ydCA9IGludChjZmdbInl0dW5lciJdLmdldCgid2ViX3BvcnQiLCAiODAiKSBvciAiODAiKQogICAgZG5zX3BvcnQgPSBpbnQoY2ZnWyJ5dHVuZXIiXS5nZXQoImRuc19wb3J0IiwgIjUzIikgb3IgIjUzIikKICAgIHJlc3VsdHMgPSBbXQoKICAgIGRlZiBhZGQobmFtZTogc3RyLCBvazogYm9vbCwgZGV0YWlsOiBkaWN0IHwgc3RyKToKICAgICAgICByZXN1bHRzLmFwcGVuZCh7Im5hbWUiOiBuYW1lLCAib2siOiBib29sKG9rKSwgImRldGFpbCI6IGRldGFpbH0pCgogICAgZm9yIHN2YyBpbiBTRVJWSUNFUzoKICAgICAgICBzdCA9IHNlcnZpY2Vfc3RhdHVzKHN2YykKICAgICAgICBvayA9IHN0LmdldCgiYWN0aXZlIikgPT0gImFjdGl2ZSIgb3IgKG5vdCBBTExPV19TWVNURU1DVEwgYW5kIHN0LmdldCgiZW5hYmxlZCIpID09ICJuL2EiKQogICAgICAgIGFkZChmInNlcnZpY2U6e3N2Y30iLCBvaywgc3QpCgogICAgZm9yIHAsIGxhYmVsIGluIFsod2ViX3BvcnQsICJ5dHVuZXItd2ViIiksIChkbnNfcG9ydCwgInl0dW5lci1kbnMiKSwgKHByb3h5X3BvcnQsICJzdHJlYW0tcHJveHkiKV06CiAgICAgICAgcGMgPSBwb3J0X2NoZWNrKHApCiAgICAgICAgb2sgPSBwY1sib3BlbiJdIG9yIChub3QgQUxMT1dfU1lTVEVNQ1RMKSAgIyBpbiBwcmV2aWV3L2RldiB3aXRob3V0IHNlcnZpY2VzLCBkb24ndCBoYXJkLWZhaWwKICAgICAgICBkZXRhaWwgPSB7KipwYywgImxhYmVsIjogbGFiZWwsICJzdHJpY3QiOiBBTExPV19TWVNURU1DVEx9CiAgICAgICAgYWRkKGYicG9ydDp7cH0iLCBvaywgZGV0YWlsKQoKICAgIHJlcXVpcmVkX2ZpbGVzID0gW0FWUl9JTkksIFNUQVRJT05TX0lOSSwgUFJPWFlfRU5WLCBQUk9YWV9TQ1JJUFRdCiAgICBvcHRpb25hbF9maWxlcyA9IFtZVFVORVJfSU5JXQogICAgZm9yIHAgaW4gcmVxdWlyZWRfZmlsZXM6CiAgICAgICAgZXhpc3RzID0gcC5leGlzdHMoKQogICAgICAgIGFkZChmImZpbGU6e3B9IiwgZXhpc3RzIG9yIChub3QgQUxMT1dfU1lTVEVNQ1RMIGFuZCBwIGluIHtQUk9YWV9FTlZ9KSwgeyJwYXRoIjogc3RyKHApLCAiZXhpc3RzIjogZXhpc3RzLCAic2l6ZSI6IHAuc3RhdCgpLnN0X3NpemUgaWYgZXhpc3RzIGVsc2UgMCwgInN0cmljdCI6IEFMTE9XX1NZU1RFTUNUTH0pCiAgICBmb3IgcCBpbiBvcHRpb25hbF9maWxlczoKICAgICAgICBleGlzdHMgPSBwLmV4aXN0cygpCiAgICAgICAgYWRkKGYiZmlsZTp7cH0iLCBleGlzdHMgb3IgKG5vdCBBTExPV19TWVNURU1DVEwpLCB7InBhdGgiOiBzdHIocCksICJleGlzdHMiOiBleGlzdHMsICJzaXplIjogcC5zdGF0KCkuc3Rfc2l6ZSBpZiBleGlzdHMgZWxzZSAwLCAib3B0aW9uYWwiOiBUcnVlLCAic3RyaWN0IjogQUxMT1dfU1lTVEVNQ1RMfSkKCiAgICB5dCA9IGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt3ZWJfcG9ydH0vIiwgNC4wKQogICAgcGggPSBodHRwX2NoZWNrKGYiaHR0cDovLzEyNy4wLjAuMTp7cHJveHlfcG9ydH0vaGVhbHRoIiwgNC4wKQogICAgYWRkKCJodHRwOnl0dW5lciIsIHl0WyJvayJdIG9yIChub3QgQUxMT1dfU1lTVEVNQ1RMKSwgeyoqeXQsICJzdHJpY3QiOiBBTExPV19TWVNURU1DVEx9KQogICAgYWRkKCJodHRwOnByb3h5LWhlYWx0aCIsIHBoWyJvayJdIG9yIChub3QgQUxMT1dfU1lTVEVNQ1RMKSwgeyoqcGgsICJzdHJpY3QiOiBBTExPV19TWVNURU1DVEx9KQoKICAgIHB5YyA9IHJ1bl9jbWQoWyJweXRob24zIiwgIi1tIiwgInB5X2NvbXBpbGUiLCBzdHIoUFJPWFlfU0NSSVBUKV0sIHRpbWVvdXQ9MjApCiAgICBhZGQoInB5dGhvbjpwcm94eS1jb21waWxlIiwgcHljWyJvayJdLCBweWMpCgogICAgb2tfY291bnQgPSBzdW0oMSBmb3IgciBpbiByZXN1bHRzIGlmIHJbIm9rIl0pCiAgICByZXR1cm4geyJvayI6IG9rX2NvdW50ID09IGxlbihyZXN1bHRzKSwgInRvdGFsIjogbGVuKHJlc3VsdHMpLCAicGFzc2VkIjogb2tfY291bnQsICJmYWlsZWQiOiBsZW4ocmVzdWx0cykgLSBva19jb3VudCwgInJlc3VsdHMiOiByZXN1bHRzLCAidHMiOiBpbnQodGltZS50aW1lKCkpfQoKCmNsYXNzIEhhbmRsZXIoQmFzZUhUVFBSZXF1ZXN0SGFuZGxlcik6CiAgICBzZXJ2ZXJfdmVyc2lvbiA9ICJZVHVuZXJBZG1pbi8wLjEiCgogICAgZGVmIGxvZ19tZXNzYWdlKHNlbGYsIGZtdDogc3RyLCAqYXJncykgLT4gTm9uZTogICMgbm9xYTogQTAwMwogICAgICAgIHN5cy5zdGRlcnIud3JpdGUoIiVzIC0gJXNcbiIgJSAoc2VsZi5hZGRyZXNzX3N0cmluZygpLCBmbXQgJSBhcmdzKSkKCiAgICBkZWYgX2F1dGhfb2soc2VsZikgLT4gYm9vbDoKICAgICAgICBpZiBub3QgVE9LRU46CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAgaGRyID0gc2VsZi5oZWFkZXJzLmdldCgiWC1BZG1pbi1Ub2tlbiIpIG9yICIiCiAgICAgICAgaWYgaGRyID09IFRPS0VOOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIHFzID0gcGFyc2VfcXModXJsc3BsaXQoc2VsZi5wYXRoKS5xdWVyeSkKICAgICAgICByZXR1cm4gKHFzLmdldCgidG9rZW4iKSBvciBbIiJdKVswXSA9PSBUT0tFTgoKICAgIGRlZiBfc2VuZF9qc29uKHNlbGYsIGNvZGU6IGludCwgcGF5bG9hZDogZGljdCkgLT4gTm9uZToKICAgICAgICBkYXRhID0ganNvbi5kdW1wcyhwYXlsb2FkLCBlbnN1cmVfYXNjaWk9RmFsc2UpLmVuY29kZSgidXRmLTgiKQogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZShjb2RlKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsICJhcHBsaWNhdGlvbi9qc29uOyBjaGFyc2V0PXV0Zi04IikKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0aCIsIHN0cihsZW4oZGF0YSkpKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNhY2hlLUNvbnRyb2wiLCAibm8tc3RvcmUiKQogICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNlbGYud2ZpbGUud3JpdGUoZGF0YSkKCiAgICBkZWYgX3NlbmRfYnl0ZXMoc2VsZiwgY29kZTogaW50LCBkYXRhOiBieXRlcywgY29udGVudF90eXBlOiBzdHIpIC0+IE5vbmU6CiAgICAgICAgc2VsZi5zZW5kX3Jlc3BvbnNlKGNvZGUpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1UeXBlIiwgY29udGVudF90eXBlKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtTGVuZ3RoIiwgc3RyKGxlbihkYXRhKSkpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ2FjaGUtQ29udHJvbCIsICJuby1zdG9yZSIpCiAgICAgICAgc2VsZi5lbmRfaGVhZGVycygpCiAgICAgICAgc2VsZi53ZmlsZS53cml0ZShkYXRhKQoKICAgIGRlZiBfcmVhZF9qc29uKHNlbGYpIC0+IGRpY3Q6CiAgICAgICAgbiA9IGludChzZWxmLmhlYWRlcnMuZ2V0KCJDb250ZW50LUxlbmd0aCIpIG9yICIwIikKICAgICAgICByYXcgPSBzZWxmLnJmaWxlLnJlYWQobikgaWYgbiA+IDAgZWxzZSBiInt9IgogICAgICAgIHRyeToKICAgICAgICAgICAgcmV0dXJuIGpzb24ubG9hZHMocmF3LmRlY29kZSgidXRmLTgiKSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICByZXR1cm4ge30KCiAgICBkZWYgX3NlcnZlX3N0YXRpYyhzZWxmLCBwYXRoOiBzdHIpIC0+IGJvb2w6CiAgICAgICAgcCA9IHVybHNwbGl0KHBhdGgpLnBhdGgKICAgICAgICBpZiBwID09ICIvIjoKICAgICAgICAgICAgcCA9ICIvaW5kZXguaHRtbCIKICAgICAgICBzYWZlID0gUGF0aChwLmxzdHJpcCgiLyIpKQogICAgICAgIHRhcmdldCA9IChXRUJfRElSIC8gc2FmZSkucmVzb2x2ZSgpCiAgICAgICAgaWYgV0VCX0RJUi5yZXNvbHZlKCkgbm90IGluIHRhcmdldC5wYXJlbnRzIGFuZCB0YXJnZXQgIT0gV0VCX0RJUi5yZXNvbHZlKCk6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDMsIHsib2siOiBGYWxzZSwgImVycm9yIjogImZvcmJpZGRlbiJ9KQogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIGlmIG5vdCB0YXJnZXQuZXhpc3RzKCkgb3Igbm90IHRhcmdldC5pc19maWxlKCk6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgICAgIGN0eXBlID0gInRleHQvcGxhaW47IGNoYXJzZXQ9dXRmLTgiCiAgICAgICAgaWYgdGFyZ2V0LnN1ZmZpeCA9PSAiLmh0bWwiOgogICAgICAgICAgICBjdHlwZSA9ICJ0ZXh0L2h0bWw7IGNoYXJzZXQ9dXRmLTgiCiAgICAgICAgZWxpZiB0YXJnZXQuc3VmZml4ID09ICIuY3NzIjoKICAgICAgICAgICAgY3R5cGUgPSAidGV4dC9jc3M7IGNoYXJzZXQ9dXRmLTgiCiAgICAgICAgZWxpZiB0YXJnZXQuc3VmZml4ID09ICIuanMiOgogICAgICAgICAgICBjdHlwZSA9ICJhcHBsaWNhdGlvbi9qYXZhc2NyaXB0OyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGVsaWYgdGFyZ2V0LnN1ZmZpeCA9PSAiLmpzb24iOgogICAgICAgICAgICBjdHlwZSA9ICJhcHBsaWNhdGlvbi9qc29uOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIHNlbGYuX3NlbmRfYnl0ZXMoMjAwLCB0YXJnZXQucmVhZF9ieXRlcygpLCBjdHlwZSkKICAgICAgICByZXR1cm4gVHJ1ZQoKICAgIGRlZiBkb19HRVQoc2VsZikgLT4gTm9uZTogICMgbm9xYTogTjgwMgogICAgICAgIHBhcnNlZCA9IHVybHNwbGl0KHNlbGYucGF0aCkKICAgICAgICBwYXRoID0gcGFyc2VkLnBhdGgKICAgICAgICBpZiBwYXRoLnN0YXJ0c3dpdGgoIi9hcGkvIikgYW5kIG5vdCBzZWxmLl9hdXRoX29rKCk6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDEsIHsib2siOiBGYWxzZSwgImVycm9yIjogInVuYXV0aG9yaXplZCJ9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL2hlYWx0aCI6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAic2VydmljZSI6ICJ5dHVuZXItYWRtaW4ifSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9zdGF0dXMiOgogICAgICAgICAgICBjZmcgPSBjb2xsZWN0X2NvbmZpZygpCiAgICAgICAgICAgIHN0YXR1c2VzID0gW3NlcnZpY2Vfc3RhdHVzKHMpIGZvciBzIGluIFNFUlZJQ0VTXQogICAgICAgICAgICBwcm94eV9wb3J0ID0gaW50KGNmZ1sicHJveHkiXS5nZXQoInBvcnQiLCAiODA5MCIpIG9yICI4MDkwIikKICAgICAgICAgICAgeXR1bmVyX3BvcnQgPSBpbnQoY2ZnWyJ5dHVuZXIiXS5nZXQoIndlYl9wb3J0IiwgIjgwIikgb3IgIjgwIikKICAgICAgICAgICAgZG5zX3BvcnQgPSBpbnQoY2ZnWyJ5dHVuZXIiXS5nZXQoImRuc19wb3J0IiwgIjUzIikgb3IgIjUzIikKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgewogICAgICAgICAgICAgICAgIm9rIjogVHJ1ZSwKICAgICAgICAgICAgICAgICJjb25maWciOiBjZmcsCiAgICAgICAgICAgICAgICAic2VydmljZXMiOiBzdGF0dXNlcywKICAgICAgICAgICAgICAgICJwb3J0cyI6IFtwb3J0X2NoZWNrKHl0dW5lcl9wb3J0KSwgcG9ydF9jaGVjayhkbnNfcG9ydCksIHBvcnRfY2hlY2socHJveHlfcG9ydCldLAogICAgICAgICAgICB9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL2NvbmZpZyI6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAiY29uZmlnIjogY29sbGVjdF9jb25maWcoKX0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvc3RhdGlvbnMiOgogICAgICAgICAgICBjb250ZW50ID0gcmVhZF90ZXh0KFNUQVRJT05TX0lOSSkKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICJwYXRoIjogc3RyKFNUQVRJT05TX0lOSSksICJncm91cHMiOiBwYXJzZV9zdGF0aW9uc19pbmkoY29udGVudCksICJyYXciOiBjb250ZW50fSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9zdGF0aW9ucy9jaGVjayI6CiAgICAgICAgICAgIHFzID0gcGFyc2VfcXMocGFyc2VkLnF1ZXJ5KQogICAgICAgICAgICB1cmwgPSAocXMuZ2V0KCJ1cmwiKSBvciBbIiJdKVswXS5zdHJpcCgpCiAgICAgICAgICAgIGlmIG5vdCB1cmw6CiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAwLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJtaXNzaW5nIHVybCJ9KQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHJlc3VsdCA9IGNoZWNrX3N0cmVhbV91cmwodXJsKQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICoqcmVzdWx0fSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICJ1cmwiOiB1cmwsICJyZWFjaGFibGUiOiBGYWxzZSwgImVycm9yIjogc3RyKGV4Yyl9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL2xvZ3MiOgogICAgICAgICAgICBxcyA9IHBhcnNlX3FzKHBhcnNlZC5xdWVyeSkKICAgICAgICAgICAgbmFtZSA9IChxcy5nZXQoIm5hbWUiKSBvciBbInl0dW5lciJdKVswXQogICAgICAgICAgICBsaW5lcyA9IGludCgocXMuZ2V0KCJsaW5lcyIpIG9yIFsiMTIwIl0pWzBdKQogICAgICAgICAgICBsaW5lcyA9IG1heCgxMCwgbWluKGxpbmVzLCAxMDAwKSkKICAgICAgICAgICAgcCA9IExPR19GSUxFUy5nZXQobmFtZSkKICAgICAgICAgICAgaWYgbm90IHA6CiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAwLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJ1bmtub3duIGxvZyJ9KQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIHRleHQgPSByZWFkX3RleHQocCkKICAgICAgICAgICAgdGFpbCA9ICJcbiIuam9pbih0ZXh0LnNwbGl0bGluZXMoKVstbGluZXM6XSkKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICJuYW1lIjogbmFtZSwgInBhdGgiOiBzdHIocCksICJjb250ZW50IjogdGFpbH0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvdGVzdHMvcnVuIjoKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgcnVuX3Rlc3RzKCkpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGguc3RhcnRzd2l0aCgiL2FwaS8iKToKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwNCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibm90IGZvdW5kIn0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHNlbGYuX3NlcnZlX3N0YXRpYyhwYXRoKToKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwNCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibm90IGZvdW5kIn0pCgogICAgZGVmIGRvX1BPU1Qoc2VsZikgLT4gTm9uZTogICMgbm9xYTogTjgwMgogICAgICAgIHBhcnNlZCA9IHVybHNwbGl0KHNlbGYucGF0aCkKICAgICAgICBwYXRoID0gcGFyc2VkLnBhdGgKICAgICAgICBpZiBub3Qgc2VsZi5fYXV0aF9vaygpOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAxLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJ1bmF1dGhvcml6ZWQifSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgcGF5bG9hZCA9IHNlbGYuX3JlYWRfanNvbigpCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9jb25maWcvcHJveHkiOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICByZXMgPSBzYXZlX3Byb3h5X2VudihwYXlsb2FkKQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICoqcmVzfSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKX0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvc3RhdGlvbnMiOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBpZiAicmF3IiBpbiBwYXlsb2FkIGFuZCBpc2luc3RhbmNlKHBheWxvYWQuZ2V0KCJyYXciKSwgc3RyKToKICAgICAgICAgICAgICAgICAgICByYXcgPSBwYXlsb2FkWyJyYXciXQogICAgICAgICAgICAgICAgICAgICMgdmFsaWRhdGUgYnkgcGFyc2luZyBhbmQgbm9ybWFsaXppbmcgdGhyb3VnaCByZW5kZXJlciBpZiBncm91cHMgY2FuIGJlIGRlcml2ZWQ/IGtlZXAgcmF3IGJ1dCBiYXNpYyBjaGVjawogICAgICAgICAgICAgICAgICAgIGlmIGxlbihyYXcpID4gMjAwMDAwOgogICAgICAgICAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCJzdGF0aW9ucy5pbmkgdG9vIGxhcmdlIikKICAgICAgICAgICAgICAgICAgICB3cml0ZV90ZXh0X2F0b21pYyhTVEFUSU9OU19JTkksIHJhdyBpZiByYXcuZW5kc3dpdGgoIlxuIikgZWxzZSByYXcgKyAiXG4iKQogICAgICAgICAgICAgICAgICAgIGNvbnRlbnQgPSByZWFkX3RleHQoU1RBVElPTlNfSU5JKQogICAgICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAic2F2ZWQiOiBUcnVlLCAicGF0aCI6IHN0cihTVEFUSU9OU19JTkkpLCAiZ3JvdXBzIjogcGFyc2Vfc3RhdGlvbnNfaW5pKGNvbnRlbnQpLCAicmF3IjogY29udGVudH0pCiAgICAgICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgICAgICBncm91cHMgPSBwYXlsb2FkLmdldCgiZ3JvdXBzIikKICAgICAgICAgICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKGdyb3VwcywgbGlzdCk6CiAgICAgICAgICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiRXhwZWN0ZWQgJ2dyb3VwcycgbGlzdCBvciAncmF3JyBzdHJpbmciKQogICAgICAgICAgICAgICAgcmVuZGVyZWQgPSByZW5kZXJfc3RhdGlvbnNfaW5pKGdyb3VwcykKICAgICAgICAgICAgICAgIHdyaXRlX3RleHRfYXRvbWljKFNUQVRJT05TX0lOSSwgcmVuZGVyZWQpCiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCB7Im9rIjogVHJ1ZSwgInNhdmVkIjogVHJ1ZSwgInBhdGgiOiBzdHIoU1RBVElPTlNfSU5JKSwgImdyb3VwcyI6IHBhcnNlX3N0YXRpb25zX2luaShyZW5kZXJlZCksICJyYXciOiByZW5kZXJlZH0pCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDAsIHsib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4Yyl9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL3NlcnZpY2UvcmVzdGFydCI6CiAgICAgICAgICAgIG5hbWUgPSBzdHIocGF5bG9hZC5nZXQoIm5hbWUiKSBvciAiIikKICAgICAgICAgICAgaWYgbmFtZSBub3QgaW4gU0VSVklDRVM6CiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAwLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJpbnZhbGlkIHNlcnZpY2UifSkKICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICBpZiBub3QgQUxMT1dfU1lTVEVNQ1RMIG9yIHNodXRpbC53aGljaCgic3lzdGVtY3RsIikgaXMgTm9uZToKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDAsIHsib2siOiBGYWxzZSwgImVycm9yIjogInN5c3RlbWN0bCB1bmF2YWlsYWJsZSJ9KQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIHJlcyA9IHJ1bl9jbWQoWyJzeXN0ZW1jdGwiLCAicmVzdGFydCIsIG5hbWVdLCB0aW1lb3V0PTMwKQogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwIGlmIHJlc1sib2siXSBlbHNlIDUwMCwgeyJvayI6IHJlc1sib2siXSwgInJlc3VsdCI6IHJlcywgInN0YXR1cyI6IHNlcnZpY2Vfc3RhdHVzKG5hbWUpfSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS90ZXN0cy9ydW4iOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCBydW5fdGVzdHMoKSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwNCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibm90IGZvdW5kIn0pCgoKZGVmIG1haW4oKSAtPiBpbnQ6CiAgICBhcCA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKCkKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1ob3N0IiwgZGVmYXVsdD1IT1NUKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLXBvcnQiLCB0eXBlPWludCwgZGVmYXVsdD1QT1JUKQogICAgYXJncyA9IGFwLnBhcnNlX2FyZ3MoKQogICAgc2VydmVyID0gVGhyZWFkaW5nSFRUUFNlcnZlcigoYXJncy5ob3N0LCBhcmdzLnBvcnQpLCBIYW5kbGVyKQogICAgcHJpbnQoZiJ5dHVuZXItYWRtaW4gbGlzdGVuaW5nIG9uIGh0dHA6Ly97YXJncy5ob3N0fTp7YXJncy5wb3J0fSIsIGZsdXNoPVRydWUpCiAgICB0cnk6CiAgICAgICAgc2VydmVyLnNlcnZlX2ZvcmV2ZXIoKQogICAgZXhjZXB0IEtleWJvYXJkSW50ZXJydXB0OgogICAgICAgIHBhc3MKICAgIGZpbmFsbHk6CiAgICAgICAgc2VydmVyLnNlcnZlcl9jbG9zZSgpCiAgICByZXR1cm4gMAoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICByYWlzZSBTeXN0ZW1FeGl0KG1haW4oKSkK'
AUTOTEST_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzb2NrZXQKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKZnJvbSB1cmxsaWIucmVxdWVzdCBpbXBvcnQgUmVxdWVzdCwgdXJsb3BlbgoKCklOU1RBTExfRElSID0gUGF0aChvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0lOU1RBTExfRElSIiwgIi9vcHQveXR1bmVyIikpCkNPTkZJR19ESVIgPSBJTlNUQUxMX0RJUiAvICJjb25maWciCllUVU5FUl9JTkkgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXIuaW5pIgpBVlJfSU5JID0gQ09ORklHX0RJUiAvICJhdnIuaW5pIgpTVEFUSU9OU19JTkkgPSBDT05GSUdfRElSIC8gInN0YXRpb25zLmluaSIKUFJPWFlfRU5WID0gUGF0aCgiL2V0Yy9kZWZhdWx0L3l0dW5lci1zdHJlYW0tcHJveHkiKQpQUk9YWV9TQ1JJUFQgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXItc3RyZWFtLXByb3h5LnB5IgpBRE1JTl9TQ1JJUFQgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXItYWRtaW4ucHkiClNFUlZJQ0VTID0gWyJ5dHVuZXIiLCAieXR1bmVyLXN0cmVhbS1wcm94eSIsICJ5dHVuZXItYWRtaW4iXQoKCmRlZiBydW5fY21kKGNtZDogbGlzdFtzdHJdLCB0aW1lb3V0OiBmbG9hdCA9IDIwLjApIC0+IGRpY3Q6CiAgICB0cnk6CiAgICAgICAgcHJvYyA9IHN1YnByb2Nlc3MucnVuKGNtZCwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PXRpbWVvdXQsIGNoZWNrPUZhbHNlKQogICAgICAgIHJldHVybiB7Im9rIjogcHJvYy5yZXR1cm5jb2RlID09IDAsICJyYyI6IHByb2MucmV0dXJuY29kZSwgInN0ZG91dCI6IHByb2Muc3Rkb3V0Wy00MDAwOl0sICJzdGRlcnIiOiBwcm9jLnN0ZGVyclstNDAwMDpdLCAiY21kIjogY21kfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7Im9rIjogRmFsc2UsICJyYyI6IC0xLCAic3Rkb3V0IjogIiIsICJzdGRlcnIiOiBzdHIoZXhjKSwgImNtZCI6IGNtZH0KCgpkZWYgcmVhZF90ZXh0KHBhdGg6IFBhdGgpIC0+IHN0cjoKICAgIHJldHVybiBwYXRoLnJlYWRfdGV4dChlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKSBpZiBwYXRoLmV4aXN0cygpIGVsc2UgIiIKCgpkZWYgaW5pX2dldChjb250ZW50OiBzdHIsIHNlY3Rpb246IHN0ciwga2V5OiBzdHIsIGRlZmF1bHQ6IHN0ciA9ICIiKSAtPiBzdHI6CiAgICBpbl9zZWN0aW9uID0gRmFsc2UKICAgIHNlY19yZSA9IHJlLmNvbXBpbGUociJeXHMqXFsoLis/KVxdXHMqJCIpCiAgICBrdl9yZSA9IHJlLmNvbXBpbGUociJeXHMqKFteOyM9XHNdW149XSo/KVxzKj1ccyooLio/KVxzKiQiKQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbSA9IHNlY19yZS5tYXRjaChsaW5lKQogICAgICAgIGlmIG06CiAgICAgICAgICAgIGluX3NlY3Rpb24gPSBtLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBzZWN0aW9uLmxvd2VyKCkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBpbl9zZWN0aW9uOgogICAgICAgICAgICBrbSA9IGt2X3JlLm1hdGNoKGxpbmUpCiAgICAgICAgICAgIGlmIGttIGFuZCBrbS5ncm91cCgxKS5zdHJpcCgpLmxvd2VyKCkgPT0ga2V5Lmxvd2VyKCk6CiAgICAgICAgICAgICAgICByZXR1cm4ga20uZ3JvdXAoMikKICAgIHJldHVybiBkZWZhdWx0CgoKZGVmIGVudl9wYXJzZShjb250ZW50OiBzdHIpIC0+IGRpY3Rbc3RyLCBzdHJdOgogICAgb3V0ID0ge30KICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaywgdiA9IGxpbmUuc3BsaXQoIj0iLCAxKQogICAgICAgIG91dFtrLnN0cmlwKCldID0gdi5zdHJpcCgpLnN0cmlwKCciJykuc3RyaXAoIiciKQogICAgcmV0dXJuIG91dAoKCmRlZiBzZXJ2aWNlX3N0YXR1cyhuYW1lOiBzdHIpIC0+IGRpY3Q6CiAgICBpZiBzaHV0aWwud2hpY2goInN5c3RlbWN0bCIpIGlzIE5vbmU6CiAgICAgICAgcmV0dXJuIHsibmFtZSI6IG5hbWUsICJhY3RpdmUiOiAidW5rbm93biIsICJlbmFibGVkIjogInVua25vd24ifQogICAgYWN0aXZlID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJpcy1hY3RpdmUiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIGVuYWJsZWQgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgImlzLWVuYWJsZWQiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIHJldHVybiB7Im5hbWUiOiBuYW1lLCAiYWN0aXZlIjogYWN0aXZlWyJzdGRvdXQiXS5zdHJpcCgpLCAiZW5hYmxlZCI6IGVuYWJsZWRbInN0ZG91dCJdLnN0cmlwKCl9CgoKZGVmIHBvcnRfY2hlY2socG9ydDogaW50LCBob3N0OiBzdHIgPSAiMTI3LjAuMC4xIikgLT4gZGljdDoKICAgIHMgPSBzb2NrZXQuc29ja2V0KCkKICAgIHMuc2V0dGltZW91dCgxLjUpCiAgICB0cnk6CiAgICAgICAgcy5jb25uZWN0KChob3N0LCBwb3J0KSkKICAgICAgICByZXR1cm4geyJwb3J0IjogcG9ydCwgIm9wZW4iOiBUcnVlfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7InBvcnQiOiBwb3J0LCAib3BlbiI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKX0KICAgIGZpbmFsbHk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzLmNsb3NlKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCgoKZGVmIGh0dHBfY2hlY2sodXJsOiBzdHIsIHRpbWVvdXQ6IGZsb2F0ID0gNS4wKSAtPiBkaWN0OgogICAgcmVxID0gUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInl0dW5lci1hdXRvdGVzdC8wLjEifSkKICAgIHQwID0gdGltZS50aW1lKCkKICAgIHRyeToKICAgICAgICB3aXRoIHVybG9wZW4ocmVxLCB0aW1lb3V0PXRpbWVvdXQpIGFzIHJlc3A6CiAgICAgICAgICAgIGJvZHkgPSByZXNwLnJlYWQoNTEyKQogICAgICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJvayI6IDIwMCA8PSBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApIDwgNTAwLCAic3RhdHVzIjogZ2V0YXR0cihyZXNwLCAic3RhdHVzIiwgMjAwKSwgIm1zIjogaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApLCAiYnl0ZXMiOiBsZW4oYm9keSl9CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4YyksICJtcyI6IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKX0KCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFwID0gYXJncGFyc2UuQXJndW1lbnRQYXJzZXIoZGVzY3JpcHRpb249IllUdW5lciBhdXRvdGVzdCBydW5uZXIiKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWpzb24iLCBhY3Rpb249InN0b3JlX3RydWUiLCBoZWxwPSJKU09OIG91dHB1dCIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0taW5jbHVkZS1hZG1pbiIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIsIGhlbHA9IkluY2x1ZGUgeXR1bmVyLWFkbWluIGNoZWNrcyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgeXR1bmVyID0gcmVhZF90ZXh0KFlUVU5FUl9JTkkpCiAgICBwcm94eV9lbnYgPSBlbnZfcGFyc2UocmVhZF90ZXh0KFBST1hZX0VOVikpCiAgICB5dHVuZXJfcG9ydCA9IGludChpbmlfZ2V0KHl0dW5lciwgIldlYlNlcnZlciIsICJXZWJTZXJ2ZXJQb3J0IiwgIjgwIikgb3IgIjgwIikKICAgIGRuc19wb3J0ID0gaW50KGluaV9nZXQoeXR1bmVyLCAiRE5TU2VydmVyIiwgIkROU1NlcnZlclBvcnQiLCAiNTMiKSBvciAiNTMiKQogICAgcHJveHlfcG9ydCA9IGludChwcm94eV9lbnYuZ2V0KCJTVFJFQU1fUFJPWFlfUE9SVCIsICI4MDkwIikgb3IgIjgwOTAiKQogICAgYWRtaW5fZW52ID0gZW52X3BhcnNlKHJlYWRfdGV4dChQYXRoKCIvZXRjL2RlZmF1bHQveXR1bmVyLWFkbWluIikpKQogICAgYWRtaW5fcG9ydCA9IGludChhZG1pbl9lbnYuZ2V0KCJZVFVORVJfQURNSU5fUE9SVCIsICI4MDkxIikgb3IgIjgwOTEiKQoKICAgIHJlc3VsdHMgPSBbXQogICAgZGVmIGFkZChuYW1lLCBvaywgZGV0YWlsKToKICAgICAgICByZXN1bHRzLmFwcGVuZCh7Im5hbWUiOiBuYW1lLCAib2siOiBib29sKG9rKSwgImRldGFpbCI6IGRldGFpbH0pCgogICAgc2VydmljZXMgPSBTRVJWSUNFUyBpZiBhcmdzLmluY2x1ZGVfYWRtaW4gZWxzZSBbInl0dW5lciIsICJ5dHVuZXItc3RyZWFtLXByb3h5Il0KICAgIGZvciBzdmMgaW4gc2VydmljZXM6CiAgICAgICAgc3QgPSBzZXJ2aWNlX3N0YXR1cyhzdmMpCiAgICAgICAgYWRkKGYic2VydmljZTp7c3ZjfSIsIHN0LmdldCgiYWN0aXZlIikgaW4geyJhY3RpdmUiLCAidW5rbm93biJ9LCBzdCkKCiAgICBmb3IgcCBpbiBbeXR1bmVyX3BvcnQsIGRuc19wb3J0LCBwcm94eV9wb3J0XSArIChbYWRtaW5fcG9ydF0gaWYgYXJncy5pbmNsdWRlX2FkbWluIGVsc2UgW10pOgogICAgICAgIHBjID0gcG9ydF9jaGVjayhwKQogICAgICAgIGFkZChmInBvcnQ6e3B9IiwgcGNbIm9wZW4iXSwgcGMpCgogICAgZm9yIHAgaW4gW1lUVU5FUl9JTkksIEFWUl9JTkksIFNUQVRJT05TX0lOSSwgUFJPWFlfRU5WLCBQUk9YWV9TQ1JJUFRdICsgKFtBRE1JTl9TQ1JJUFRdIGlmIGFyZ3MuaW5jbHVkZV9hZG1pbiBlbHNlIFtdKToKICAgICAgICBhZGQoZiJmaWxlOntwfSIsIHAuZXhpc3RzKCksIHsicGF0aCI6IHN0cihwKSwgImV4aXN0cyI6IHAuZXhpc3RzKCksICJzaXplIjogcC5zdGF0KCkuc3Rfc2l6ZSBpZiBwLmV4aXN0cygpIGVsc2UgMH0pCgogICAgYWRkKCJodHRwOnl0dW5lciIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt5dHVuZXJfcG9ydH0vIilbIm9rIl0sIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt5dHVuZXJfcG9ydH0vIikpCiAgICBhZGQoImh0dHA6cHJveHktaGVhbHRoIiwgaHR0cF9jaGVjayhmImh0dHA6Ly8xMjcuMC4wLjE6e3Byb3h5X3BvcnR9L2hlYWx0aCIpWyJvayJdLCBodHRwX2NoZWNrKGYiaHR0cDovLzEyNy4wLjAuMTp7cHJveHlfcG9ydH0vaGVhbHRoIikpCiAgICBpZiBhcmdzLmluY2x1ZGVfYWRtaW46CiAgICAgICAgYWRkKCJodHRwOmFkbWluLWhlYWx0aCIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnthZG1pbl9wb3J0fS9hcGkvaGVhbHRoIilbIm9rIl0sIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnthZG1pbl9wb3J0fS9hcGkvaGVhbHRoIikpCgogICAgcHljID0gcnVuX2NtZChbInB5dGhvbjMiLCAiLW0iLCAicHlfY29tcGlsZSIsIHN0cihQUk9YWV9TQ1JJUFQpXSwgdGltZW91dD0yMCkKICAgIGFkZCgicHl0aG9uOnByb3h5LWNvbXBpbGUiLCBweWNbIm9rIl0sIHB5YykKICAgIGlmIGFyZ3MuaW5jbHVkZV9hZG1pbiBhbmQgQURNSU5fU0NSSVBULmV4aXN0cygpOgogICAgICAgIHB5YzIgPSBydW5fY21kKFsicHl0aG9uMyIsICItbSIsICJweV9jb21waWxlIiwgc3RyKEFETUlOX1NDUklQVCldLCB0aW1lb3V0PTIwKQogICAgICAgIGFkZCgicHl0aG9uOmFkbWluLWNvbXBpbGUiLCBweWMyWyJvayJdLCBweWMyKQoKICAgIHBhc3NlZCA9IHN1bSgxIGZvciByIGluIHJlc3VsdHMgaWYgclsib2siXSkKICAgIHJlcG9ydCA9IHsib2siOiBwYXNzZWQgPT0gbGVuKHJlc3VsdHMpLCAidG90YWwiOiBsZW4ocmVzdWx0cyksICJwYXNzZWQiOiBwYXNzZWQsICJmYWlsZWQiOiBsZW4ocmVzdWx0cyktcGFzc2VkLCAicmVzdWx0cyI6IHJlc3VsdHMsICJ0cyI6IGludCh0aW1lLnRpbWUoKSl9CiAgICBpZiBhcmdzLmpzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhyZXBvcnQsIGVuc3VyZV9hc2NpaT1GYWxzZSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KGYieydQQVNTJyBpZiByZXBvcnRbJ29rJ10gZWxzZSAnRkFJTCd9IHtwYXNzZWR9L3tsZW4ocmVzdWx0cyl9IikKICAgICAgICBmb3IgciBpbiByZXN1bHRzOgogICAgICAgICAgICBwcmludChmIlt7J09LJyBpZiByWydvayddIGVsc2UgJ0ZBSUwnfV0ge3JbJ25hbWUnXX0iKQogICAgICAgICAgICBpZiBub3Qgclsib2siXToKICAgICAgICAgICAgICAgIHByaW50KCIgICIgKyBqc29uLmR1bXBzKHJbImRldGFpbCJdLCBlbnN1cmVfYXNjaWk9RmFsc2UpWzozMDBdKQogICAgcmV0dXJuIDAgaWYgcmVwb3J0WyJvayJdIGVsc2UgMQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICByYWlzZSBTeXN0ZW1FeGl0KG1haW4oKSkK'
WEB_INDEX_B64='PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImRlIj4KPGhlYWQ+CiAgPG1ldGEgY2hhcnNldD0idXRmLTgiPgogIDxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+CiAgPHRpdGxlPllUdW5lciBBZG1pbjwvdGl0bGU+CiAgPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvc3R5bGVzLmNzcyI+CjwvaGVhZD4KPGJvZHk+CiAgPGhlYWRlciBjbGFzcz0idG9wYmFyIj4KICAgIDxkaXY+CiAgICAgIDxoMT5ZVHVuZXIgQWRtaW48L2gxPgogICAgICA8cCBjbGFzcz0ibXV0ZWQiPldlYm9iZXJmbMOkY2hlIGbDvHIgWVR1bmVyLCBTdHJlYW0tUHJveHkgdW5kIERpYWdub3NlPC9wPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhY3Rpb25zIj4KICAgICAgPGJ1dHRvbiBpZD0icmVmcmVzaEJ0biI+QWt0dWFsaXNpZXJlbjwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9oZWFkZXI+CgogIDxuYXYgY2xhc3M9Im1haW4tdGFicyI+CiAgICA8YnV0dG9uIGNsYXNzPSJtYWluLXRhYiBhY3RpdmUiIGRhdGEtdGFiPSJzdGF0aW9ucyI+MS4gUmFkaW9zZW5kZXIgcGZsZWdlbjwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0ibWFpbi10YWIiIGRhdGEtdGFiPSJhZG1pbiI+Mi4gQWRtaW5pc3RyYXRpb24gLyBUZXN0czwvYnV0dG9uPgogIDwvbmF2PgoKICA8bWFpbj4KICAgIDwhLS0gVEFCIDE6IFJhZGlvc2VuZGVyIHBmbGVnZW4gLS0+CiAgICA8c2VjdGlvbiBpZD0idGFiLXN0YXRpb25zIiBjbGFzcz0idGFiLXBhbmVsIGFjdGl2ZSI+CiAgICAgIDxkaXYgY2xhc3M9ImdyaWQiPgogICAgICAgIDxzZWN0aW9uIGNsYXNzPSJjYXJkIHdpZGUiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VjdGlvbi1oZWFkIj4KICAgICAgICAgICAgPGRpdj4KICAgICAgICAgICAgICA8aDI+U2VuZGVybGlzdGUgKHN0YXRpb25zLmluaSk8L2gyPgogICAgICAgICAgICAgIDxwIGNsYXNzPSJtdXRlZCBzbWFsbCI+U2VuZGVyIGbDvHIgIk15IFN0YXRpb25zIiBwZmxlZ2VuLiBOYWNoIGRlbSBTcGVpY2hlcm4gbGllc3QgWVR1bmVyIGRpZSBEYXRlaSBqZSBuYWNoIEVpbnN0ZWxsdW5nIG5ldSBlaW4gKGdnZi4gU2VydmljZSBuZXUgc3RhcnRlbiBvZGVyIEF1dG8tUmVmcmVzaCBudXR6ZW4pLjwvcD4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImFjdGlvbnMiPgogICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2hlY2tBbGxTdGF0aW9uc0J0biI+QWxsZSBwcsO8ZmVuPC9idXR0b24+CiAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJhZGRTdGF0aW9uQnRuIj5TZW5kZXIgaGluenVmw7xnZW48L2J1dHRvbj4KICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InJlbG9hZFN0YXRpb25zQnRuIj5OZXUgbGFkZW48L2J1dHRvbj4KICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InNhdmVTdGF0aW9uc0J0biIgY2xhc3M9InByaW1hcnkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBpZD0ic3RhdGlvbnNFZGl0b3IiIGNsYXNzPSJzdGF0aW9ucy1lZGl0b3IiPjwvZGl2PgogICAgICAgICAgPGRldGFpbHMgc3R5bGU9Im1hcmdpbi10b3A6MTJweCI+CiAgICAgICAgICAgIDxzdW1tYXJ5PlJhdyBzdGF0aW9ucy5pbmkgYmVhcmJlaXRlbjwvc3VtbWFyeT4KICAgICAgICAgICAgPHRleHRhcmVhIGlkPSJzdGF0aW9uc1JhdyIgY2xhc3M9InJhdy1lZGl0b3IiIHNwZWxsY2hlY2s9ImZhbHNlIj48L3RleHRhcmVhPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWFjdGlvbnMiPjxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0ic2F2ZVN0YXRpb25zUmF3QnRuIj5SYXcgc3BlaWNoZXJuPC9idXR0b24+PC9kaXY+CiAgICAgICAgICA8L2RldGFpbHM+CiAgICAgICAgICA8cHJlIGlkPSJzdGF0aW9uc1NhdmVSZXN1bHQiIGNsYXNzPSJyZXN1bHQgbXV0ZWQiPjwvcHJlPgogICAgICAgIDwvc2VjdGlvbj4KICAgICAgPC9kaXY+CiAgICA8L3NlY3Rpb24+CgogICAgPCEtLSBUQUIgMjogQWRtaW5pc3RyYXRpb24gLyBUZXN0cyAtLT4KICAgIDxzZWN0aW9uIGlkPSJ0YWItYWRtaW4iIGNsYXNzPSJ0YWItcGFuZWwiPgogICAgICA8ZGl2IGNsYXNzPSJncmlkIj4KICAgICAgICA8c2VjdGlvbiBjbGFzcz0iY2FyZCI+CiAgICAgICAgICA8aDI+U3RhdHVzPC9oMj4KICAgICAgICAgIDxkaXYgaWQ9InN0YXR1c1N1bW1hcnkiIGNsYXNzPSJtdXRlZCI+TGFkZS4uLjwvZGl2PgogICAgICAgICAgPGRpdiBpZD0ic2VydmljZXMiIGNsYXNzPSJsaXN0Ij48L2Rpdj4KICAgICAgICAgIDxkaXYgaWQ9InBvcnRzIiBjbGFzcz0ibGlzdCI+PC9kaXY+CiAgICAgICAgPC9zZWN0aW9uPgoKICAgICAgICA8c2VjdGlvbiBjbGFzcz0iY2FyZCI+CiAgICAgICAgICA8aDI+U3RyZWFtLVByb3h5IEVpbnN0ZWxsdW5nZW48L2gyPgogICAgICAgICAgPGZvcm0gaWQ9InByb3h5Rm9ybSIgY2xhc3M9ImZvcm0iPgogICAgICAgICAgICA8bGFiZWw+SG9zdDxpbnB1dCBuYW1lPSJTVFJFQU1fUFJPWFlfSE9TVCIgcGxhY2Vob2xkZXI9IjAuMC4wLjAiPjwvbGFiZWw+CiAgICAgICAgICAgIDxsYWJlbD5Qb3J0PGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9QT1JUIiB0eXBlPSJudW1iZXIiIG1pbj0iMSIgbWF4PSI2NTUzNSI+PC9sYWJlbD4KICAgICAgICAgICAgPGxhYmVsPlRpbWVvdXQgKHMpPGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9USU1FT1VUIiB0eXBlPSJudW1iZXIiIG1pbj0iMSIgbWF4PSIxMjAiPjwvbGFiZWw+CiAgICAgICAgICAgIDxsYWJlbD5NYXggUmVkaXJlY3RzPGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9NQVhfUkVESVJFQ1RTIiB0eXBlPSJudW1iZXIiIG1pbj0iMCIgbWF4PSIyMCI+PC9sYWJlbD4KICAgICAgICAgICAgPGxhYmVsPkxvZyBMZXZlbAogICAgICAgICAgICAgIDxzZWxlY3QgbmFtZT0iU1RSRUFNX1BST1hZX0xPR19MRVZFTCI+CiAgICAgICAgICAgICAgICA8b3B0aW9uPkRFQlVHPC9vcHRpb24+PG9wdGlvbj5JTkZPPC9vcHRpb24+PG9wdGlvbj5XQVJOSU5HPC9vcHRpb24+PG9wdGlvbj5FUlJPUjwvb3B0aW9uPgogICAgICAgICAgICAgIDwvc2VsZWN0PgogICAgICAgICAgICA8L2xhYmVsPgogICAgICAgICAgICA8bGFiZWw+VXNlciBBZ2VudDxpbnB1dCBuYW1lPSJTVFJFQU1fUFJPWFlfVVNFUl9BR0VOVCIgcGxhY2Vob2xkZXI9Ik1vemlsbGEvNS4wIC4uLiI+PC9sYWJlbD4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1hY3Rpb25zIj4KICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9InN1Ym1pdCIgY2xhc3M9InByaW1hcnkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0icmVzdGFydFByb3h5QnRuIj5Qcm94eSBuZXVzdGFydGVuPC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPC9mb3JtPgogICAgICAgICAgPHByZSBpZD0icHJveHlTYXZlUmVzdWx0IiBjbGFzcz0icmVzdWx0IG11dGVkIj48L3ByZT4KICAgICAgICA8L3NlY3Rpb24+CgogICAgICAgIDxzZWN0aW9uIGNsYXNzPSJjYXJkIj4KICAgICAgICAgIDxoMj5ZVHVuZXIgS29uZmlndXJhdGlvbiAocmVhZC1vbmx5IMOcYmVyYmxpY2spPC9oMj4KICAgICAgICAgIDxkaXYgaWQ9ImNvbmZpZ1ZpZXciIGNsYXNzPSJrdiI+PC9kaXY+CiAgICAgICAgICA8cCBjbGFzcz0ibXV0ZWQgc21hbGwiPkRhdGVpYmFzaWVydGUgS2VybmtvbmZpZ3VyYXRpb25lbiB3ZXJkZW4gYW5nZXplaWd0OyBCZWFyYmVpdHVuZyBlcmZvbGd0IMO8YmVyIElOSS9FbnYtRGF0ZWllbiBhbSBTZXJ2ZXIuPC9wPgogICAgICAgIDwvc2VjdGlvbj4KCiAgICAgICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQgd2lkZSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWN0aW9uLWhlYWQiPgogICAgICAgICAgICA8aDI+QXV0b3Rlc3QgLyBEaWFnbm9zZTwvaDI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImFjdGlvbnMiPjxidXR0b24gaWQ9InJ1blRlc3RzQnRuIiBjbGFzcz0icHJpbWFyeSI+VGVzdHMgYXVzZsO8aHJlbjwvYnV0dG9uPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJtYXRyaXgtd3JhcCI+CiAgICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgICAgPGRpdiBpZD0idGVzdE1hdHJpeCIgY2xhc3M9InRlc3QtbWF0cml4IiBhcmlhLWxhYmVsPSJUZXN0bWF0cml4Ij48L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJtYXRyaXgtbGVnZW5kIG11dGVkIHNtYWxsIj48c3Bhbj48aSBjbGFzcz0ibGFtcCByZWQiPjwvaT4gbmljaHQgYmVzdGFuZGVuL29mZmVuPC9zcGFuPjxzcGFuPjxpIGNsYXNzPSJsYW1wIHllbGxvdyI+PC9pPiBsw6R1ZnQ8L3NwYW4+PHNwYW4+PGkgY2xhc3M9ImxhbXAgZ3JlZW4iPjwvaT4gYmVzdGFuZGVuPC9zcGFuPjwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ibWF0cml4LW1ldGEiPgogICAgICAgICAgICAgIDxkaXYgaWQ9InRlc3RTdW1tYXJ5IiBjbGFzcz0ibXV0ZWQiPk5vY2gga2VpbmUgVGVzdHMgYXVzZ2Vmw7xocnQuPC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBpZD0ibWF0cml4U3RhdHVzIiBjbGFzcz0ibXV0ZWQgc21hbGwiPk1hdHJpeCB3aXJkIG5hY2ggVGVzdGxhdWYgZ2VsYWRlbi48L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgaWQ9InRlc3RSZXN1bHRzIiBjbGFzcz0idGVzdC1yZXN1bHRzIj48L2Rpdj4KICAgICAgICA8L3NlY3Rpb24+CgogICAgICAgIDxzZWN0aW9uIGNsYXNzPSJjYXJkIHdpZGUiPgogICAgICAgICAgPGgyPkxvZ3M8L2gyPgogICAgICAgICAgPGRpdiBjbGFzcz0idGFicyI+CiAgICAgICAgICAgIDxidXR0b24gZGF0YS1sb2c9Inl0dW5lciIgY2xhc3M9InRhYiBhY3RpdmUiPnl0dW5lci5sb2c8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiBkYXRhLWxvZz0icHJveHkiIGNsYXNzPSJ0YWIiPnN0cmVhbS1wcm94eS5sb2c8L2J1dHRvbj4KICAgICAgICAgICAgPGJ1dHRvbiBkYXRhLWxvZz0iYWRtaW4iIGNsYXNzPSJ0YWIiPmFkbWluLmxvZzwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIGlkPSJyZWZyZXNoTG9nc0J0biI+TG9ncyBsYWRlbjwvYnV0dG9uPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8cHJlIGlkPSJsb2dWaWV3IiBjbGFzcz0ibG9nIj5MYWRlLi4uPC9wcmU+CiAgICAgICAgPC9zZWN0aW9uPgogICAgICA8L2Rpdj4KICAgIDwvc2VjdGlvbj4KICA8L21haW4+CgogIDxzY3JpcHQgc3JjPSIvYXBwLmpzIj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg=='
WEB_CSS_B64='OnJvb3R7LS1iZzojZjRmNmYxOy0tY2FyZDojZmZmZWY5Oy0taW5rOiMxZDJhMWY7LS1tdXRlZDojNWY2ZTYxOy0tbGluZTojZDdkZGQyOy0tYWNjZW50OiMxZjdhNGQ7LS1hY2NlbnQyOiNjNzViMmM7LS1iYWQ6I2IzMjYxZTstLW9rOiMxYjdmM2E7LS13YXJuOiM4YTVhMDA7LS1tb25vOnVpLW1vbm9zcGFjZSxTRk1vbm8tUmVndWxhcixNZW5sbyxtb25vc3BhY2U7LS1zYW5zOiJJQk0gUGxleCBTYW5zIiwiQXZlbmlyIE5leHQiLCJTZWdvZSBVSSIsc2Fucy1zZXJpZn0KKntib3gtc2l6aW5nOmJvcmRlci1ib3h9Ym9keXttYXJnaW46MDtmb250LWZhbWlseTp2YXIoLS1zYW5zKTtjb2xvcjp2YXIoLS1pbmspO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE4MGRlZywjZWVmNGVhIDAlLHZhcigtLWJnKSAxODBweCl9Ci50b3BiYXJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxNnB4O3BhZGRpbmc6MjRweCAyNHB4IDhweDthbGlnbi1pdGVtczpmbGV4LWVuZH0KaDF7bWFyZ2luOjA7Zm9udC1zaXplOjJyZW07bGV0dGVyLXNwYWNpbmc6LS4wMmVtfWgye21hcmdpbjowIDAgMTJweDtmb250LXNpemU6MS4wNXJlbX0KLm11dGVke2NvbG9yOnZhcigtLW11dGVkKX0uc21hbGx7Zm9udC1zaXplOi44OHJlbX0KLm1haW4tdGFic3tkaXNwbGF5OmZsZXg7Z2FwOjhweDtwYWRkaW5nOjAgMjRweCAxNnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUpfQoubWFpbi10YWJ7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7YmFja2dyb3VuZDojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo2MDB9Ci5tYWluLXRhYi5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1hY2NlbnQpO2NvbG9yOiNmZmY7Ym9yZGVyLWNvbG9yOnZhcigtLWFjY2VudCl9Ci50YWItcGFuZWx7ZGlzcGxheTpub25lfS50YWItcGFuZWwuYWN0aXZle2Rpc3BsYXk6YmxvY2t9Ci5ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsbWlubWF4KDAsMWZyKSk7Z2FwOjE2cHg7cGFkZGluZzoxNnB4IDI0cHggMzJweH0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7Ym94LXNoYWRvdzowIDFweCAwIHJnYmEoMCwwLDAsLjAyKX0KLmNhcmQud2lkZXtncmlkLWNvbHVtbjoxLy0xfQouc2VjdGlvbi1oZWFke2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O21hcmdpbi1ib3R0b206MTJweH0KLnNlY3Rpb24taGVhZCBoMnttYXJnaW4tYm90dG9tOjRweH0KLmFjdGlvbnMsLmZvcm0tYWN0aW9ucywudGFic3tkaXNwbGF5OmZsZXg7Z2FwOjhweDtmbGV4LXdyYXA6d3JhcH0KYnV0dG9ue2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7YmFja2dyb3VuZDojZmZmO2NvbG9yOnZhcigtLWluayk7cGFkZGluZzo4cHggMTJweDtib3JkZXItcmFkaXVzOjEwcHg7Y3Vyc29yOnBvaW50ZXI7Zm9udDppbmhlcml0fQpidXR0b24ucHJpbWFyeXtiYWNrZ3JvdW5kOnZhcigtLWFjY2VudCk7Y29sb3I6I2ZmZjtib3JkZXItY29sb3I6dmFyKC0tYWNjZW50KX0KYnV0dG9uOmhvdmVye2ZpbHRlcjpicmlnaHRuZXNzKC45OCl9IGJ1dHRvbjpkaXNhYmxlZHtvcGFjaXR5Oi42O2N1cnNvcjp3YWl0fQoubGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4fQouaXRlbXtkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6I2ZmZn0KLmJhZGdle3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjk5OXB4O2ZvbnQtc2l6ZTouNzhyZW07Zm9udC13ZWlnaHQ6NjAwO3doaXRlLXNwYWNlOm5vd3JhcH0ub2t7YmFja2dyb3VuZDojZThmNWViO2NvbG9yOnZhcigtLW9rKX0uYmFke2JhY2tncm91bmQ6I2ZkZWNlYjtjb2xvcjp2YXIoLS1iYWQpfS53YXJue2JhY2tncm91bmQ6I2ZmZjRkZDtjb2xvcjp2YXIoLS13YXJuKX0KLmZvcm17ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoMixtaW5tYXgoMCwxZnIpKTtnYXA6MTBweH0KbGFiZWx7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6NHB4O2ZvbnQtc2l6ZTouOXJlbX0KaW5wdXQsc2VsZWN0LHRleHRhcmVhe3BhZGRpbmc6OHB4IDEwcHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjhweDtmb250OmluaGVyaXQ7YmFja2dyb3VuZDojZmZmfQouZm9ybS1hY3Rpb25ze2dyaWQtY29sdW1uOjEvLTE7bWFyZ2luLXRvcDo0cHh9Ci5rdntkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjE4MHB4IDFmcjtnYXA6NnB4IDEycHg7Zm9udC1zaXplOi45MnJlbX0KLmt2IC5re2NvbG9yOnZhcigtLW11dGVkKX0ua3YgLnZ7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7d29yZC1icmVhazpicmVhay13b3JkfQoucmVzdWx0LC5sb2d7YmFja2dyb3VuZDojMWEyMTFiO2NvbG9yOiNkY2U3ZGM7cGFkZGluZzoxMnB4O2JvcmRlci1yYWRpdXM6MTBweDtvdmVyZmxvdzphdXRvO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZTouODVyZW07bGluZS1oZWlnaHQ6MS40NX0KLmxvZ3ttaW4taGVpZ2h0OjI2MHB4O21heC1oZWlnaHQ6NDIwcHh9LnJlc3VsdHttaW4taGVpZ2h0OjQ0cHg7bWFyZ2luLXRvcDoxMHB4fQoubWF0cml4LXdyYXB7ZGlzcGxheTpmbGV4O2dhcDoyMHB4O2FsaWduLWl0ZW1zOmZsZXgtc3RhcnQ7ZmxleC13cmFwOndyYXA7bWFyZ2luLWJvdHRvbToxMnB4fQoudGVzdC1tYXRyaXh7ZGlzcGxheTpncmlkO2dhcDo4cHg7cGFkZGluZzoxMnB4O2JhY2tncm91bmQ6IzE1MWIxNjtib3JkZXItcmFkaXVzOjEycHg7Ym9yZGVyOjFweCBzb2xpZCAjMjYzMjI4O3dpZHRoOm1heC1jb250ZW50O21heC13aWR0aDoxMDAlfQoubGFtcHt3aWR0aDoyMHB4O2hlaWdodDoyMHB4O2JvcmRlci1yYWRpdXM6NTAlO2Rpc3BsYXk6aW5saW5lLWJsb2NrO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDAsMCwuMjUpO2JveC1zaGFkb3c6aW5zZXQgMCAxcHggM3B4IHJnYmEoMjU1LDI1NSwyNTUsLjE1KX0KLnRlc3QtbWF0cml4IC5sYW1we3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7cGFkZGluZzowO2N1cnNvcjpwb2ludGVyfQoudGVzdC1tYXRyaXggLmxhbXA6aG92ZXJ7dHJhbnNmb3JtOnNjYWxlKDEuMTUpO2ZpbHRlcjpicmlnaHRuZXNzKDEuMSl9Ci50ZXN0LW1hdHJpeCAubGFtcDpmb2N1c3tvdXRsaW5lOjJweCBzb2xpZCAjZmZmO291dGxpbmUtb2Zmc2V0OjJweH0KLmxhbXAucmVke2JhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGNpcmNsZSBhdCAzMCUgMzAlLCNmZjhhODAsI2M2MjgyOCA3MCUpO2JveC1zaGFkb3c6MCAwIDRweCByZ2JhKDE5OCw0MCw0MCwuMzUpfQoubGFtcC55ZWxsb3d7YmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoY2lyY2xlIGF0IDMwJSAzMCUsI2ZmZjU5ZCwjZjlhODI1IDcwJSk7Ym94LXNoYWRvdzowIDAgOHB4IHJnYmEoMjQ5LDE2OCwzNywuNyk7YW5pbWF0aW9uOnB1bHNlIDFzIGluZmluaXRlfQoubGFtcC5ncmVlbntiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChjaXJjbGUgYXQgMzAlIDMwJSwjYTVkNmE3LCMyZTdkMzIgNzAlKTtib3gtc2hhZG93OjAgMCA4cHggcmdiYSg0NiwxMjUsNTAsLjcpfQoudGVzdC5mbGFzaHtvdXRsaW5lOjJweCBzb2xpZCB2YXIoLS1hY2NlbnQpO2JveC1zaGFkb3c6MCAwIDAgNHB4IHJnYmEoNDcsMTExLDk0LC4xNSk7dHJhbnNpdGlvbjpvdXRsaW5lLWNvbG9yIC4yc30KQGtleWZyYW1lcyBwdWxzZXswJSwxMDAle2ZpbHRlcjpicmlnaHRuZXNzKDEpfTUwJXtmaWx0ZXI6YnJpZ2h0bmVzcygxLjM1KX19Ci5tYXRyaXgtbGVnZW5ke2Rpc3BsYXk6ZmxleDtnYXA6MTRweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweH0ubWF0cml4LWxlZ2VuZCBzcGFue2Rpc3BsYXk6aW5saW5lLWZsZXg7Z2FwOjZweDthbGlnbi1pdGVtczpjZW50ZXJ9Ci5tYXRyaXgtbWV0YXtmbGV4OjE7bWluLXdpZHRoOjI0MHB4fQoudGVzdC1yZXN1bHRze2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhweDttYXJnaW4tdG9wOjEwcHh9Ci50ZXN0e2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDtiYWNrZ3JvdW5kOiNmZmZ9Ci50ZXN0IC5oZWFke2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtmb250LXdlaWdodDo2MDB9Ci50ZXN0IHByZXttYXJnaW46OHB4IDAgMDtiYWNrZ3JvdW5kOiNmNmY4ZjQ7Y29sb3I6IzIxMztwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtvdmVyZmxvdzphdXRvO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZTouOHJlbX0KLnRhYi5hY3RpdmV7YmFja2dyb3VuZDojZThmNWViO2JvcmRlci1jb2xvcjojYjlkN2MzfQouc3RhdGlvbnMtZWRpdG9ye2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjEycHh9Ci5zdGF0aW9uLWdyb3Vwe2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTJweDtiYWNrZ3JvdW5kOiNmZmZ9Ci5zdGF0aW9uLWdyb3VwIC5ncm91cC1oZWFke2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlcjttYXJnaW4tYm90dG9tOjEwcHg7ZmxleC13cmFwOndyYXB9Ci5zdGF0aW9uLWdyb3VwIC5ncm91cC1oZWFkIGlucHV0e2ZsZXg6MTttaW4td2lkdGg6MTgwcHg7Zm9udC13ZWlnaHQ6NjAwfQouc3RhdGlvbi1yb3d7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxLjJmciAyZnIgMS4yZnIgYXV0byBhdXRvO2dhcDo4cHg7bWFyZ2luLWJvdHRvbTo4cHg7YWxpZ24taXRlbXM6c3RhcnR9Ci5zdGF0aW9uLXJvdyBpbnB1dHt3aWR0aDoxMDAlfQouc3RhdGlvbi1zdGF0dXN7Zm9udC1zaXplOi43OHJlbTtwYWRkaW5nOjZweCA4cHg7Ym9yZGVyLXJhZGl1czo4cHg7YmFja2dyb3VuZDojZjNmNWYxO2NvbG9yOnZhcigtLW11dGVkKTttaW4td2lkdGg6MTQwcHg7bWF4LXdpZHRoOjI2MHB4O292ZXJmbG93OmhpZGRlbjt0ZXh0LW92ZXJmbG93OmVsbGlwc2lzfQouc3RhdGlvbi1zdGF0dXMub2t7YmFja2dyb3VuZDojZThmNWViO2NvbG9yOnZhcigtLW9rKX0KLnN0YXRpb24tc3RhdHVzLmJhZHtiYWNrZ3JvdW5kOiNmZGVjZWI7Y29sb3I6dmFyKC0tYmFkKX0KLnN0YXRpb24tc3RhdHVzLndhcm57YmFja2dyb3VuZDojZmZmNGRkO2NvbG9yOnZhcigtLXdhcm4pfQoucmF3LWVkaXRvcnt3aWR0aDoxMDAlO21pbi1oZWlnaHQ6MjIwcHg7bWFyZ2luLXRvcDo4cHg7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Zm9udC1zaXplOi44NXJlbX0KQG1lZGlhIChtYXgtd2lkdGg6MTEwMHB4KXsuc3RhdGlvbi1yb3d7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnJ9fQpAbWVkaWEgKG1heC13aWR0aDo5MDBweCl7LmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0uZm9ybXtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS50b3BiYXJ7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOnN0cmV0Y2h9LnN0YXRpb24tcm93e2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQo='
WEB_JS_B64='YXN5bmMgZnVuY3Rpb24gYXBpKHBhdGgsIG9wdHM9e30pIHsKICBjb25zdCByZXMgPSBhd2FpdCBmZXRjaChwYXRoLCB7aGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nLCAuLi4ob3B0cy5oZWFkZXJzfHx7fSl9LCAuLi5vcHRzfSk7CiAgY29uc3QgdGV4dCA9IGF3YWl0IHJlcy50ZXh0KCk7CiAgbGV0IGRhdGE7IHRyeSB7IGRhdGEgPSBKU09OLnBhcnNlKHRleHQpOyB9IGNhdGNoIHsgZGF0YSA9IHtyYXc6dGV4dH07IH0KICBpZiAoIXJlcy5vaykgdGhyb3cgT2JqZWN0LmFzc2lnbihuZXcgRXJyb3IoZGF0YS5lcnJvciB8fCByZXMuc3RhdHVzVGV4dCksIHtkYXRhLCBzdGF0dXM6cmVzLnN0YXR1c30pOwogIHJldHVybiBkYXRhOwp9CmNvbnN0ICQgPSAocyk9PmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3Iocyk7CmNvbnN0ICQkID0gKHMpPT5BcnJheS5mcm9tKGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwocykpOwpjb25zdCBlc2MgPSAocyk9PlN0cmluZyhzPz8nJykucmVwbGFjZSgvWyY8PiInXS9nLGM9Pih7JyYnOicmYW1wOycsJzwnOicmbHQ7JywnPic6JyZndDsnLCciJzonJnF1b3Q7JywiJyI6JyYjMzk7J31bY10pKTsKZnVuY3Rpb24gYmFkZ2Uob2ssIHRleHQpeyBjb25zdCBjbHMgPSBvaz09PXRydWU/J29rJzpvaz09PWZhbHNlPydiYWQnOid3YXJuJzsgcmV0dXJuIGA8c3BhbiBjbGFzcz0iYmFkZ2UgJHtjbHN9Ij4ke2VzYyh0ZXh0KX08L3NwYW4+YDsgfQoKLyogLS0tLSBUYWJzIC0tLS0gKi8KJCQoJy5tYWluLXRhYicpLmZvckVhY2goYnRuPT5idG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+ewogICQkKCcubWFpbi10YWInKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogICQkKCcudGFiLXBhbmVsJykuZm9yRWFjaChwPT5wLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgJCgnI3RhYi0nICsgYnRuLmRhdGFzZXQudGFiKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKfSkpOwoKLyogLS0tLSBTdGF0dXMgLyBDb25maWcgLS0tLSAqLwphc3luYyBmdW5jdGlvbiBsb2FkU3RhdHVzKCl7CiAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9zdGF0dXMnKTsKICBjb25zdCBzdmMgPSBkLnNlcnZpY2VzfHxbXTsKICBjb25zdCBwb3J0cyA9IGQucG9ydHN8fFtdOwogICQoJyNzdGF0dXNTdW1tYXJ5JykuaW5uZXJIVE1MID0gYEFrdHVhbGlzaWVydDogJHtuZXcgRGF0ZSgpLnRvTG9jYWxlU3RyaW5nKCl9IHwgQVBJIG9rYDsKICAkKCcjc2VydmljZXMnKS5pbm5lckhUTUwgPSBzdmMubWFwKHM9PmA8ZGl2IGNsYXNzPSJpdGVtIj48ZGl2PjxzdHJvbmc+JHtlc2Mocy5uYW1lKX08L3N0cm9uZz48ZGl2IGNsYXNzPSJtdXRlZCBzbWFsbCI+JHtlc2MoSlNPTi5zdHJpbmdpZnkocy5wcm9wc3x8e30pKX08L2Rpdj48L2Rpdj48ZGl2PiR7YmFkZ2Uocy5hY3RpdmU9PT0nYWN0aXZlJywgcy5hY3RpdmUpfSAke2JhZGdlKHMuZW5hYmxlZD09PSdlbmFibGVkJ3x8cy5lbmFibGVkPT09J3N0YXRpYyd8fHMuZW5hYmxlZD09PSd1bmtub3duJywgcy5lbmFibGVkKX08L2Rpdj48L2Rpdj5gKS5qb2luKCcnKTsKICAkKCcjcG9ydHMnKS5pbm5lckhUTUwgPSBwb3J0cy5tYXAocD0+YDxkaXYgY2xhc3M9Iml0ZW0iPjxkaXY+PHN0cm9uZz5Qb3J0ICR7ZXNjKHAucG9ydCl9PC9zdHJvbmc+PC9kaXY+JHtiYWRnZShwLm9wZW4sIHAub3Blbj8nb3Blbic6J2Nsb3NlZCcpfTwvZGl2PmApLmpvaW4oJycpOwogIHJlbmRlckNvbmZpZyhkLmNvbmZpZ3x8e30pOwogIGZpbGxQcm94eUZvcm0oKGQuY29uZmlnfHx7fSkucHJveHl8fHt9KTsKfQpmdW5jdGlvbiByZW5kZXJDb25maWcoY2ZnKXsKICBjb25zdCByb3dzPVtdOwogIGNvbnN0IGFkZD0oayx2KT0+cm93cy5wdXNoKGA8ZGl2IGNsYXNzPSJrIj4ke2VzYyhrKX08L2Rpdj48ZGl2IGNsYXNzPSJ2Ij4ke2VzYyh0eXBlb2Ygdj09PSdvYmplY3QnP0pTT04uc3RyaW5naWZ5KHYpOnYpfTwvZGl2PmApOwogIGFkZCgnaW5zdGFsbF9kaXInLCBjZmcucGF0aHM/Lmluc3RhbGxfZGlyKTsKICBhZGQoJ3l0dW5lci5pbmknLCBjZmcucGF0aHM/Lnl0dW5lcl9pbmkpOwogIGFkZCgnYXZyLmluaScsIGNmZy5wYXRocz8uYXZyX2luaSk7CiAgYWRkKCdzdGF0aW9ucy5pbmknLCBjZmcucGF0aHM/LnN0YXRpb25zX2luaSk7CiAgYWRkKCdwcm94eV9lbnYnLCBjZmcucGF0aHM/LnByb3h5X2Vudik7CiAgYWRkKCd5dHVuZXIud2ViX3BvcnQnLCBjZmcueXR1bmVyPy53ZWJfcG9ydCk7CiAgYWRkKCd5dHVuZXIuZG5zX3BvcnQnLCBjZmcueXR1bmVyPy5kbnNfcG9ydCk7CiAgYWRkKCd5dHVuZXIuaW50ZXJjZXB0X2RucycsIGNmZy55dHVuZXI/LmludGVyY2VwdF9kbnMpOwogIGFkZCgneXR1bmVyLnJiX2NhY2hlX3R5cGUnLCBjZmcueXR1bmVyPy5yYl9jYWNoZV90eXBlKTsKICBhZGQoJ2F2ci5wcm90b2NvbCcsIGNmZy5hdnI/LnByb3RvY29sKTsKICAkKCcjY29uZmlnVmlldycpLmlubmVySFRNTCA9IHJvd3Muam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsbFByb3h5Rm9ybShwcm94eSl7CiAgY29uc3QgZiA9ICQoJyNwcm94eUZvcm0nKTsKICBmb3IgKGNvbnN0IFtrLHZdIG9mIE9iamVjdC5lbnRyaWVzKHByb3h5fHx7fSkpewogICAgY29uc3Qga2V5ID0gJ1NUUkVBTV9QUk9YWV8nICsgay50b1VwcGVyQ2FzZSgpOwogICAgY29uc3QgZWwgPSBmLmVsZW1lbnRzLm5hbWVkSXRlbShrZXkpOwogICAgaWYgKGVsKSBlbC52YWx1ZSA9IHY7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIHNhdmVQcm94eShldil7CiAgZXYucHJldmVudERlZmF1bHQoKTsKICBjb25zdCBmZCA9IG5ldyBGb3JtRGF0YShldi50YXJnZXQpOwogIGNvbnN0IHBheWxvYWQgPSBPYmplY3QuZnJvbUVudHJpZXMoZmQuZW50cmllcygpKTsKICAkKCcjcHJveHlTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSAnU3BlaWNoZXJlLi4uJzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9jb25maWcvcHJveHknLCB7bWV0aG9kOidQT1NUJywgYm9keTpKU09OLnN0cmluZ2lmeShwYXlsb2FkKX0pOwogICAgJCgnI3Byb3h5U2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gSlNPTi5zdHJpbmdpZnkoZCwgbnVsbCwgMik7CiAgICBhd2FpdCBsb2FkU3RhdHVzKCk7CiAgfSBjYXRjaChlKXsgJCgnI3Byb3h5U2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gSlNPTi5zdHJpbmdpZnkoZS5kYXRhfHx7ZXJyb3I6ZS5tZXNzYWdlfSwgbnVsbCwgMik7IH0KfQphc3luYyBmdW5jdGlvbiByZXN0YXJ0UHJveHkoKXsKICAkKCcjcHJveHlTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSAnU3RhcnRlIFByb3h5IG5ldS4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBhcGkoJy9hcGkvc2VydmljZS9yZXN0YXJ0Jywge21ldGhvZDonUE9TVCcsIGJvZHk6SlNPTi5zdHJpbmdpZnkoe25hbWU6J3l0dW5lci1zdHJlYW0tcHJveHknfSl9KTsKICAgICQoJyNwcm94eVNhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IEpTT04uc3RyaW5naWZ5KGQsIG51bGwsIDIpOwogICAgYXdhaXQgbG9hZFN0YXR1cygpOwogIH0gY2F0Y2goZSl7ICQoJyNwcm94eVNhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IEpTT04uc3RyaW5naWZ5KGUuZGF0YXx8e2Vycm9yOmUubWVzc2FnZX0sIG51bGwsIDIpOyB9Cn0KCi8qIC0tLS0gVGVzdHMgLS0tLSAqLwpsZXQgTUFUUklYX1NJWkUgPSAwOwpsZXQgbWF0cml4U3RhdGUgPSBbXTsKZnVuY3Rpb24gc2V0TWF0cml4U2l6ZShuKXsKICBNQVRSSVhfU0laRSA9IE1hdGgubWF4KDAsIG58MCk7CiAgbWF0cml4U3RhdGUgPSBBcnJheShNQVRSSVhfU0laRSkuZmlsbCgncmVkJyk7CiAgcmVuZGVyTWF0cml4KCk7Cn0KZnVuY3Rpb24gcmVuZGVyTWF0cml4KCl7CiAgY29uc3QgbSA9ICQoJyN0ZXN0TWF0cml4Jyk7CiAgaWYgKCFtKSByZXR1cm47CiAgbS5zdHlsZS5ncmlkVGVtcGxhdGVDb2x1bW5zID0gYHJlcGVhdCgke01hdGguY2VpbChNYXRoLnNxcnQoTUFUUklYX1NJWkUgfHwgMSkpfSwgMjJweClgOwogIG0uaW5uZXJIVE1MID0gbWF0cml4U3RhdGUubWFwKChzLGkpPT5gPGJ1dHRvbiB0eXBlPSJidXR0b24iIGNsYXNzPSJsYW1wICR7c30iIGRhdGEtdGVzdC1pZHg9IiR7aX0iIHRpdGxlPSJUZXN0ICR7aSsxfTogJHtzfSAtIGtsaWNrZW4genVtIFNwcmluZ2VuIj48L2J1dHRvbj5gKS5qb2luKCcnKTsKICBtLnF1ZXJ5U2VsZWN0b3JBbGwoJy5sYW1wW2RhdGEtdGVzdC1pZHhdJykuZm9yRWFjaChidG49PmJ0bi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT57CiAgICBjb25zdCBpZHggPSArYnRuLmRhdGFzZXQudGVzdElkeDsKICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoYHRlc3Qtcm93LSR7aWR4fWApOwogICAgaWYgKGVsKSB7IGVsLnNjcm9sbEludG9WaWV3KHtiZWhhdmlvcjonc21vb3RoJywgYmxvY2s6J2NlbnRlcid9KTsgZWwuY2xhc3NMaXN0LmFkZCgnZmxhc2gnKTsgc2V0VGltZW91dCgoKT0+ZWwuY2xhc3NMaXN0LnJlbW92ZSgnZmxhc2gnKSwgMTIwMCk7IH0KICB9KSk7CiAgY29uc3QgbGFiZWwgPSAkKCcjbWF0cml4U3RhdHVzJyk7CiAgaWYgKGxhYmVsICYmICFtYXRyaXhTdGF0ZS5sZW5ndGgpIGxhYmVsLnRleHRDb250ZW50ID0gJ0tlaW5lIFRlc3RzIGdlbGFkZW4uJzsKfQpmdW5jdGlvbiBzZXRNYXRyaXhBbGwoc3RhdGUpeyBpZiAoTUFUUklYX1NJWkUpIHsgbWF0cml4U3RhdGUgPSBBcnJheShNQVRSSVhfU0laRSkuZmlsbChzdGF0ZSk7IHJlbmRlck1hdHJpeCgpOyB9IH0KZnVuY3Rpb24gYXBwbHlNYXRyaXhSZXN1bHRzKHJlc3VsdHMpewogIGNvbnN0IHJlcyA9IHJlc3VsdHMgfHwgW107CiAgaWYgKHJlcy5sZW5ndGggIT09IE1BVFJJWF9TSVpFKSBzZXRNYXRyaXhTaXplKHJlcy5sZW5ndGgpOwogIG1hdHJpeFN0YXRlID0gcmVzLm1hcChyID0+IHIub2sgPyAnZ3JlZW4nIDogJ3JlZCcpOwogIHJlbmRlck1hdHJpeCgpOwogICQoJyNtYXRyaXhTdGF0dXMnKS50ZXh0Q29udGVudCA9IGAke01BVFJJWF9TSVpFfSBUZXN0czogJHtyZXMuZmlsdGVyKHI9PnIub2spLmxlbmd0aH0gZ3LDvG4sICR7cmVzLmZpbHRlcihyPT4hci5vaykubGVuZ3RofSByb3QuYDsKfQphc3luYyBmdW5jdGlvbiBydW5UZXN0cygpewogICQoJyN0ZXN0U3VtbWFyeScpLnRleHRDb250ZW50ID0gJ1Rlc3RzIGxhdWZlbi4uLic7CiAgJCgnI3Rlc3RSZXN1bHRzJykuaW5uZXJIVE1MID0gJyc7CiAgLy8gb3B0aW1pc3RpYzogc2hvdyBhbGwgeWVsbG93IHdoaWxlIHJlcXVlc3QgaXMgcnVubmluZwogIGlmIChNQVRSSVhfU0laRSA+IDApIHsgc2V0TWF0cml4QWxsKCd5ZWxsb3cnKTsgJCgnI21hdHJpeFN0YXR1cycpLnRleHRDb250ZW50ID0gYCR7TUFUUklYX1NJWkV9IFRlc3RzIGxhdWZlbi4uLmA7IH0KICBlbHNlIHsgJCgnI21hdHJpeFN0YXR1cycpLnRleHRDb250ZW50ID0gJ1Rlc3RzIGxhdWZlbi4uLic7IH0KICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS90ZXN0cy9ydW4nLCB7bWV0aG9kOidQT1NUJ30pOwogICAgcmVuZGVyVGVzdHMoZCk7CiAgfQogIGNhdGNoKGUpewogICAgaWYgKE1BVFJJWF9TSVpFID4gMCkgc2V0TWF0cml4QWxsKCdyZWQnKTsKICAgICQoJyNtYXRyaXhTdGF0dXMnKS50ZXh0Q29udGVudCA9IE1BVFJJWF9TSVpFID8gYCR7TUFUUklYX1NJWkV9IFRlc3RzOiBMYXVmIGZlaGxnZXNjaGxhZ2VuLmAgOiAnVGVzdGxhdWYgZmVobGdlc2NobGFnZW4uJzsKICAgICQoJyN0ZXN0U3VtbWFyeScpLnRleHRDb250ZW50ID0gJ0ZlaGxlcjogJyArIGUubWVzc2FnZTsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyVGVzdHMoZCl7CiAgJCgnI3Rlc3RTdW1tYXJ5JykuaW5uZXJIVE1MID0gYCR7YmFkZ2UoZC5vaywgZC5vaz8nUEFTUyc6J0ZBSUwnKX0gJHtkLnBhc3NlZH0vJHtkLnRvdGFsfSBiZXN0YW5kZW4sICR7ZC5mYWlsZWR9IGZlaGxnZXNjaGxhZ2VuYDsKICAkKCcjdGVzdFJlc3VsdHMnKS5pbm5lckhUTUwgPSAoZC5yZXN1bHRzfHxbXSkubWFwKChyLGkpPT5gPGRpdiBjbGFzcz0idGVzdCIgaWQ9InRlc3Qtcm93LSR7aX0iPjxkaXYgY2xhc3M9ImhlYWQiPjxzcGFuPiR7aSsxfS4gJHtlc2Moci5uYW1lKX08L3NwYW4+JHtiYWRnZShyLm9rLHIub2s/J29rJzonZmFpbCcpfTwvZGl2PjxwcmU+JHtlc2MoSlNPTi5zdHJpbmdpZnkoci5kZXRhaWwsIG51bGwsIDIpKX08L3ByZT48L2Rpdj5gKS5qb2luKCcnKTsKICBhcHBseU1hdHJpeFJlc3VsdHMoZC5yZXN1bHRzfHxbXSk7Cn0KCi8qIC0tLS0gU3RhdGlvbnMgLS0tLSAqLwpsZXQgc3RhdGlvbnNNb2RlbCA9IFtdOwpmdW5jdGlvbiBub3JtYWxpemVTdGF0aW9ucyhncm91cHMpewogIGlmICghQXJyYXkuaXNBcnJheShncm91cHMpIHx8ICFncm91cHMubGVuZ3RoKSByZXR1cm4gW3tuYW1lOidNeSBTdGF0aW9ucycsIHN0YXRpb25zOltdfV07CiAgcmV0dXJuIGdyb3Vwcy5tYXAoZz0+KHtuYW1lOiBTdHJpbmcoZz8ubmFtZXx8J1VuZ3JvdXBlZCcpLCBzdGF0aW9uczogQXJyYXkuaXNBcnJheShnPy5zdGF0aW9ucyk/Zy5zdGF0aW9ucy5tYXAocz0+KHtuYW1lOlN0cmluZyhzPy5uYW1lfHwnJyksIHVybDpTdHJpbmcocz8udXJsfHwnJyksIGxvZ286U3RyaW5nKHM/LmxvZ298fCcnKSwgX3N0YXR1czpzLl9zdGF0dXN8fG51bGx9KSk6W119KSk7Cn0KZnVuY3Rpb24gc3RhdHVzSHRtbChzdCl7CiAgaWYgKCFzdCB8fCAhc3QudXJsKSByZXR1cm4gJzxzcGFuIGNsYXNzPSJzdGF0aW9uLXN0YXR1cyB3YXJuIj5rZWluZSBVUkw8L3NwYW4+JzsKICBpZiAoIXN0Ll9zdGF0dXMpIHJldHVybiAnPHNwYW4gY2xhc3M9InN0YXRpb24tc3RhdHVzIj5uaWNodCBnZXByw7xmdDwvc3Bhbj4nOwogIGNvbnN0IHMgPSBzdC5fc3RhdHVzOwogIGlmIChzLmNoZWNraW5nKSByZXR1cm4gJzxzcGFuIGNsYXNzPSJzdGF0aW9uLXN0YXR1cyB3YXJuIj5wcsO8ZmUuLi48L3NwYW4+JzsKICBpZiAocy5yZWFjaGFibGUpIHJldHVybiBgPHNwYW4gY2xhc3M9InN0YXRpb24tc3RhdHVzIG9rIj5PSyAke2VzYyhzLnN0YXR1cz8/JycpfSAke2VzYyhzLmNvbnRlbnRfdHlwZXx8JycpfSAke2VzYyhzLm1zPz8nJyl9bXM8L3NwYW4+YDsKICByZXR1cm4gYDxzcGFuIGNsYXNzPSJzdGF0aW9uLXN0YXR1cyBiYWQiPkZBSUwgJHtlc2Mocy5zdGF0dXM/PycnKX0gJHtlc2Mocy5lcnJvcnx8JycpfTwvc3Bhbj5gOwp9CmZ1bmN0aW9uIHJlbmRlclN0YXRpb25zRWRpdG9yKCl7CiAgY29uc3Qgcm9vdCA9ICQoJyNzdGF0aW9uc0VkaXRvcicpOwogIHJvb3QuaW5uZXJIVE1MID0gc3RhdGlvbnNNb2RlbC5tYXAoKGcsZ2kpPT5gCiAgICA8ZGl2IGNsYXNzPSJzdGF0aW9uLWdyb3VwIiBkYXRhLWdpPSIke2dpfSI+CiAgICAgIDxkaXYgY2xhc3M9Imdyb3VwLWhlYWQiPgogICAgICAgIDxpbnB1dCB2YWx1ZT0iJHtlc2MoZy5uYW1lKX0iIHBsYWNlaG9sZGVyPSJHcnVwcGVubmFtZSIgZGF0YS1maWVsZD0iZ3JvdXAtbmFtZSI+CiAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0aW9uPSJhZGQtc3RhdGlvbiI+KyBTZW5kZXI8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Rpb249ImNoZWNrLWdyb3VwIj5HcnVwcGUgcHLDvGZlbjwvYnV0dG9uPgogICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdGlvbj0icmVtb3ZlLWdyb3VwIj5HcnVwcGUgbMO2c2NoZW48L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgICR7KGcuc3RhdGlvbnN8fFtdKS5tYXAoKHMsc2kpPT5gCiAgICAgICAgPGRpdiBjbGFzcz0ic3RhdGlvbi1yb3ciIGRhdGEtc2k9IiR7c2l9Ij4KICAgICAgICAgIDxpbnB1dCB2YWx1ZT0iJHtlc2Mocy5uYW1lKX0iIHBsYWNlaG9sZGVyPSJTZW5kZXJuYW1lIiBkYXRhLWZpZWxkPSJuYW1lIj4KICAgICAgICAgIDxpbnB1dCB2YWx1ZT0iJHtlc2Mocy51cmwpfSIgcGxhY2Vob2xkZXI9IlN0cmVhbSBVUkwgKGh0dHAvaHR0cHMpIiBkYXRhLWZpZWxkPSJ1cmwiPgogICAgICAgICAgPGlucHV0IHZhbHVlPSIke2VzYyhzLmxvZ28pfSIgcGxhY2Vob2xkZXI9IkxvZ28gVVJMIChvcHRpb25hbCkiIGRhdGEtZmllbGQ9ImxvZ28iPgogICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0aW9uPSJjaGVjay1zdGF0aW9uIj5QcsO8ZmVuPC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Rpb249InJlbW92ZS1zdGF0aW9uIj5FbnRmZXJuZW48L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJtYXJnaW46LTRweCAwIDEwcHggMCI+JHtzdGF0dXNIdG1sKHMpfTwvZGl2PmApLmpvaW4oJycpfQogICAgPC9kaXY+YCkuam9pbignJyk7Cn0KZnVuY3Rpb24gY29sbGVjdFN0YXRpb25zRnJvbUVkaXRvcigpewogIGNvbnN0IGdyb3Vwcz1bXTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc3RhdGlvbi1ncm91cCcpLmZvckVhY2goZ0VsPT57CiAgICBjb25zdCBnaSA9IE51bWJlcihnRWwuZGF0YXNldC5naSk7CiAgICBjb25zdCBvbGQgPSBzdGF0aW9uc01vZGVsW2dpXSB8fCB7c3RhdGlvbnM6W119OwogICAgY29uc3QgbmFtZSA9IGdFbC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1maWVsZD0iZ3JvdXAtbmFtZSJdJykudmFsdWUudHJpbSgpIHx8ICdVbmdyb3VwZWQnOwogICAgY29uc3Qgc3RhdGlvbnM9W107CiAgICBnRWwucXVlcnlTZWxlY3RvckFsbCgnLnN0YXRpb24tcm93JykuZm9yRWFjaChyRWw9PnsKICAgICAgY29uc3Qgc2kgPSBOdW1iZXIockVsLmRhdGFzZXQuc2kpOwogICAgICBjb25zdCBwcmV2ID0gKG9sZC5zdGF0aW9uc3x8W10pW3NpXSB8fCB7fTsKICAgICAgY29uc3Qgc3Q9e25hbWU6ckVsLnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWZpZWxkPSJuYW1lIl0nKS52YWx1ZS50cmltKCksIHVybDpyRWwucXVlcnlTZWxlY3RvcignW2RhdGEtZmllbGQ9InVybCJdJykudmFsdWUudHJpbSgpLCBsb2dvOnJFbC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1maWVsZD0ibG9nbyJdJykudmFsdWUudHJpbSgpLCBfc3RhdHVzOnByZXYuX3N0YXR1c3x8bnVsbH07CiAgICAgIC8vIGludmFsaWRhdGUgc3RhdHVzIGlmIHVybCBjaGFuZ2VkCiAgICAgIGlmIChwcmV2LnVybCAhPT0gc3QudXJsKSBzdC5fc3RhdHVzID0gbnVsbDsKICAgICAgaWYgKHN0Lm5hbWUgfHwgc3QudXJsIHx8IHN0LmxvZ28pIHN0YXRpb25zLnB1c2goc3QpOwogICAgfSk7CiAgICBncm91cHMucHVzaCh7bmFtZSwgc3RhdGlvbnN9KTsKICB9KTsKICBzdGF0aW9uc01vZGVsID0gbm9ybWFsaXplU3RhdGlvbnMoZ3JvdXBzKTsKICByZXR1cm4gc3RhdGlvbnNNb2RlbDsKfQphc3luYyBmdW5jdGlvbiBsb2FkU3RhdGlvbnMoKXsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9zdGF0aW9ucycpOwogICAgc3RhdGlvbnNNb2RlbCA9IG5vcm1hbGl6ZVN0YXRpb25zKGQuZ3JvdXBzfHxbXSk7CiAgICAkKCcjc3RhdGlvbnNSYXcnKS52YWx1ZSA9IGQucmF3IHx8ICcnOwogICAgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsKICAgICQoJyNzdGF0aW9uc1NhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IGBHZWxhZGVuOiAke2QucGF0aH1gOwogIH0gY2F0Y2goZSl7ICQoJyNzdGF0aW9uc1NhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9ICdGZWhsZXI6ICcrKGUuZGF0YT8uZXJyb3J8fGUubWVzc2FnZSk7IH0KfQphc3luYyBmdW5jdGlvbiBzYXZlU3RhdGlvbnMoZ3JvdXBzKXsKICAkKCcjc3RhdGlvbnNTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSAnU3BlaWNoZXJlIHN0YXRpb25zLmluaS4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBhcGkoJy9hcGkvc3RhdGlvbnMnLCB7bWV0aG9kOidQT1NUJywgYm9keTogSlNPTi5zdHJpbmdpZnkoZ3JvdXBzID8ge2dyb3Vwc30gOiB7cmF3OiAkKCcjc3RhdGlvbnNSYXcnKS52YWx1ZX0pfSk7CiAgICAvLyBwcmVzZXJ2ZSBzdGF0dXMgYnkgVVJMCiAgICBjb25zdCBvbGRTdGF0dXMgPSBuZXcgTWFwKCk7CiAgICBzdGF0aW9uc01vZGVsLmZsYXRNYXAoZz0+Zy5zdGF0aW9uc3x8W10pLmZvckVhY2gocz0+eyBpZihzLnVybCAmJiBzLl9zdGF0dXMpIG9sZFN0YXR1cy5zZXQocy51cmwsIHMuX3N0YXR1cyk7IH0pOwogICAgc3RhdGlvbnNNb2RlbCA9IG5vcm1hbGl6ZVN0YXRpb25zKGQuZ3JvdXBzfHxbXSkubWFwKGc9Pih7Li4uZywgc3RhdGlvbnM6Zy5zdGF0aW9ucy5tYXAocz0+KHsuLi5zLCBfc3RhdHVzOm9sZFN0YXR1cy5nZXQocy51cmwpfHxudWxsfSkpfSkpOwogICAgJCgnI3N0YXRpb25zUmF3JykudmFsdWUgPSBkLnJhdyB8fCAnJzsKICAgIHJlbmRlclN0YXRpb25zRWRpdG9yKCk7CiAgICAkKCcjc3RhdGlvbnNTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSAnR2VzcGVpY2hlcnQ6ICcrZC5wYXRoOwogIH0gY2F0Y2goZSl7ICQoJyNzdGF0aW9uc1NhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9ICdGZWhsZXI6ICcrSlNPTi5zdHJpbmdpZnkoZS5kYXRhfHx7ZXJyb3I6ZS5tZXNzYWdlfSk7IH0KfQphc3luYyBmdW5jdGlvbiBjaGVja1N0YXRpb24oZ2ksIHNpKXsKICBjb2xsZWN0U3RhdGlvbnNGcm9tRWRpdG9yKCk7CiAgY29uc3Qgc3QgPSBzdGF0aW9uc01vZGVsPy5bZ2ldPy5zdGF0aW9ucz8uW3NpXTsKICBpZiAoIXN0IHx8ICFzdC51cmwpIHJldHVybjsKICBzdC5fc3RhdHVzID0ge2NoZWNraW5nOnRydWV9OwogIHJlbmRlclN0YXRpb25zRWRpdG9yKCk7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBhcGkoJy9hcGkvc3RhdGlvbnMvY2hlY2s/dXJsPScgKyBlbmNvZGVVUklDb21wb25lbnQoc3QudXJsKSk7CiAgICBzdC5fc3RhdHVzID0gZDsKICB9IGNhdGNoKGUpeyBzdC5fc3RhdHVzID0ge3JlYWNoYWJsZTpmYWxzZSwgZXJyb3I6ZS5tZXNzYWdlfTsgfQogIHJlbmRlclN0YXRpb25zRWRpdG9yKCk7Cn0KYXN5bmMgZnVuY3Rpb24gY2hlY2tBbGxTdGF0aW9ucygpewogIGNvbGxlY3RTdGF0aW9uc0Zyb21FZGl0b3IoKTsKICBjb25zdCBqb2JzPVtdOwogIHN0YXRpb25zTW9kZWwuZm9yRWFjaCgoZyxnaSk9PiAoZy5zdGF0aW9uc3x8W10pLmZvckVhY2goKHMsc2kpPT57IGlmKHMudXJsKSBqb2JzLnB1c2goW2dpLHNpXSk7IH0pKTsKICBmb3IgKGNvbnN0IFtnaSxzaV0gb2Ygam9icykgeyBhd2FpdCBjaGVja1N0YXRpb24oZ2ksc2kpOyB9Cn0KCiQoJyNzdGF0aW9uc0VkaXRvcicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKGV2KT0+ewogIGNvbnN0IGJ0biA9IGV2LnRhcmdldC5jbG9zZXN0KCdidXR0b25bZGF0YS1hY3Rpb25dJyk7IGlmKCFidG4pIHJldHVybjsKICBjb25zdCBnRWwgPSBidG4uY2xvc2VzdCgnLnN0YXRpb24tZ3JvdXAnKTsgY29uc3QgZ2kgPSBOdW1iZXIoZ0VsLmRhdGFzZXQuZ2kpOwogIGNvbGxlY3RTdGF0aW9uc0Zyb21FZGl0b3IoKTsKICBpZiAoYnRuLmRhdGFzZXQuYWN0aW9uPT09J2FkZC1zdGF0aW9uJykgc3RhdGlvbnNNb2RlbFtnaV0uc3RhdGlvbnMucHVzaCh7bmFtZTonJyx1cmw6JycsbG9nbzonJyxfc3RhdHVzOm51bGx9KTsKICBpZiAoYnRuLmRhdGFzZXQuYWN0aW9uPT09J3JlbW92ZS1ncm91cCcpIHN0YXRpb25zTW9kZWwuc3BsaWNlKGdpLDEpOwogIGlmIChidG4uZGF0YXNldC5hY3Rpb249PT0ncmVtb3ZlLXN0YXRpb24nKSB7IGNvbnN0IHNpPU51bWJlcihidG4uY2xvc2VzdCgnLnN0YXRpb24tcm93JykuZGF0YXNldC5zaSk7IHN0YXRpb25zTW9kZWxbZ2ldLnN0YXRpb25zLnNwbGljZShzaSwxKTsgfQogIGlmIChidG4uZGF0YXNldC5hY3Rpb249PT0nY2hlY2stc3RhdGlvbicpIHsgY29uc3Qgc2k9TnVtYmVyKGJ0bi5jbG9zZXN0KCcuc3RhdGlvbi1yb3cnKS5kYXRhc2V0LnNpKTsgY2hlY2tTdGF0aW9uKGdpLHNpKTsgcmV0dXJuOyB9CiAgaWYgKGJ0bi5kYXRhc2V0LmFjdGlvbj09PSdjaGVjay1ncm91cCcpIHsgKHN0YXRpb25zTW9kZWxbZ2ldLnN0YXRpb25zfHxbXSkuZm9yRWFjaCgoXyxzaSk9Pnt9KTsgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsgKGFzeW5jKCk9PnsgZm9yKGxldCBzaT0wOyBzaTwoc3RhdGlvbnNNb2RlbFtnaV0/LnN0YXRpb25zfHxbXSkubGVuZ3RoOyBzaSsrKSBhd2FpdCBjaGVja1N0YXRpb24oZ2ksc2kpOyB9KSgpOyByZXR1cm47IH0KICBzdGF0aW9uc01vZGVsID0gbm9ybWFsaXplU3RhdGlvbnMoc3RhdGlvbnNNb2RlbCk7CiAgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsKfSk7CiQoJyNhZGRTdGF0aW9uQnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+eyBjb2xsZWN0U3RhdGlvbnNGcm9tRWRpdG9yKCk7IGlmKCFzdGF0aW9uc01vZGVsLmxlbmd0aCkgc3RhdGlvbnNNb2RlbD1be25hbWU6J015IFN0YXRpb25zJyxzdGF0aW9uczpbXX1dOyBzdGF0aW9uc01vZGVsWzBdLnN0YXRpb25zLnB1c2goe25hbWU6JycsdXJsOicnLGxvZ286JycsX3N0YXR1czpudWxsfSk7IHJlbmRlclN0YXRpb25zRWRpdG9yKCk7IH0pOwokKCcjc2F2ZVN0YXRpb25zQnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+c2F2ZVN0YXRpb25zKGNvbGxlY3RTdGF0aW9uc0Zyb21FZGl0b3IoKSkpOwokKCcjc2F2ZVN0YXRpb25zUmF3QnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+c2F2ZVN0YXRpb25zKG51bGwpKTsKJCgnI3JlbG9hZFN0YXRpb25zQnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBsb2FkU3RhdGlvbnMpOwokKCcjY2hlY2tBbGxTdGF0aW9uc0J0bicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgY2hlY2tBbGxTdGF0aW9ucyk7CgovKiAtLS0tIExvZ3MgLS0tLSAqLwpsZXQgY3VycmVudExvZz0neXR1bmVyJzsKYXN5bmMgZnVuY3Rpb24gbG9hZExvZ3MobmFtZT1jdXJyZW50TG9nKXsKICBjdXJyZW50TG9nPW5hbWU7CiAgJCQoJy50YWJbZGF0YS1sb2ddJykuZm9yRWFjaChiPT5iLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIGIuZGF0YXNldC5sb2c9PT1uYW1lKSk7CiAgJCgnI2xvZ1ZpZXcnKS50ZXh0Q29udGVudCA9ICdMYWRlLi4uJzsKICB0cnkgeyBjb25zdCBkID0gYXdhaXQgYXBpKGAvYXBpL2xvZ3M/bmFtZT0ke2VuY29kZVVSSUNvbXBvbmVudChuYW1lKX0mbGluZXM9MjAwYCk7ICQoJyNsb2dWaWV3JykudGV4dENvbnRlbnQgPSBkLmNvbnRlbnQgfHwgJyhsZWVyKSc7IH0KICBjYXRjaChlKXsgJCgnI2xvZ1ZpZXcnKS50ZXh0Q29udGVudCA9ICdGZWhsZXI6ICcrZS5tZXNzYWdlOyB9Cn0KCi8qIC0tLS0gV2lyZSB1cCAtLS0tICovCiQoJyNyZWZyZXNoQnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+eyBsb2FkU3RhdHVzKCkuY2F0Y2goZT0+JCgnI3N0YXR1c1N1bW1hcnknKS50ZXh0Q29udGVudD1lLm1lc3NhZ2UpOyBsb2FkU3RhdGlvbnMoKS5jYXRjaCgoKT0+e30pOyB9KTsKJCgnI3J1blRlc3RzQnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBydW5UZXN0cyk7CiQoJyNwcm94eUZvcm0nKS5hZGRFdmVudExpc3RlbmVyKCdzdWJtaXQnLCBzYXZlUHJveHkpOwokKCcjcmVzdGFydFByb3h5QnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCByZXN0YXJ0UHJveHkpOwokKCcjcmVmcmVzaExvZ3NCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT5sb2FkTG9ncyhjdXJyZW50TG9nKSk7CiQkKCcudGFiW2RhdGEtbG9nXScpLmZvckVhY2goYj0+Yi5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT5sb2FkTG9ncyhiLmRhdGFzZXQubG9nKSkpOwoKcmVuZGVyTWF0cml4KCk7CmxvYWRTdGF0dXMoKS5jYXRjaChlPT4kKCcjc3RhdHVzU3VtbWFyeScpLnRleHRDb250ZW50PSdGZWhsZXI6ICcrZS5tZXNzYWdlKTsKbG9hZFN0YXRpb25zKCkuY2F0Y2goKCk9Pnt9KTsKbG9hZExvZ3MoJ3l0dW5lcicpLmNhdGNoKCgpPT57fSk7Cg=='

write_b64_file() {
  local path="$1" mode="$2" b64="$3"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ write_b64 %s (mode %s)\n' "$path" "$mode"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s' "$b64" | base64 -d > "$path"
  chmod "$mode" "$path"
}

log "Installing HTTPS->HTTP stream proxy..."
write_b64_file "$INSTALL_DIR/ytuner-stream-proxy.py" "0755" "$PROXY_PY_B64"
if [[ -f /etc/default/ytuner-stream-proxy && "$FORCE_CONFIG" != "1" ]]; then
  log "Keeping existing config: /etc/default/ytuner-stream-proxy"
else
  write_file "/etc/default/ytuner-stream-proxy" "0644" "$PROXY_DEFAULT"
fi
write_file "/etc/systemd/system/ytuner-stream-proxy.service" "0644" "$PROXY_SERVICE_UNIT"

log "Installing Admin WebUI/API and autotest..."
write_b64_file "$INSTALL_DIR/ytuner-admin.py" "0755" "$ADMIN_PY_B64"
write_b64_file "$INSTALL_DIR/ytuner-autotest.py" "0755" "$AUTOTEST_PY_B64"
write_b64_file "$INSTALL_DIR/webui/index.html" "0644" "$WEB_INDEX_B64"
write_b64_file "$INSTALL_DIR/webui/styles.css" "0644" "$WEB_CSS_B64"
write_b64_file "$INSTALL_DIR/webui/app.js" "0644" "$WEB_JS_B64"
if [[ -f /etc/default/ytuner-admin && "$FORCE_CONFIG" != "1" ]]; then
  log "Keeping existing config: /etc/default/ytuner-admin"
else
  write_file "/etc/default/ytuner-admin" "0644" "$ADMIN_DEFAULT"
fi
write_file "/etc/systemd/system/ytuner-admin.service" "0644" "$ADMIN_SERVICE_UNIT"

# --- Enable & start -----------------------------------------------------------
if [[ "$NO_START" == "0" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl daemon-reload
    run systemctl enable ytuner.service
    run systemctl enable ytuner-stream-proxy.service
    run systemctl enable ytuner-admin.service
    run systemctl restart ytuner.service
    run systemctl restart ytuner-stream-proxy.service
    run systemctl restart ytuner-admin.service
    sleep 2
    run systemctl --no-pager --full status ytuner.service || true
    run systemctl --no-pager --full status ytuner-stream-proxy.service || true
    run systemctl --no-pager --full status ytuner-admin.service || true
  else
    warn "systemctl not found. Start manually: $INSTALL_DIR/ytuner, $INSTALL_DIR/ytuner-stream-proxy.py, $INSTALL_DIR/ytuner-admin.py"
  fi
else
  log "--no-start set; skipping service enable/start."
fi

# --- Verification -------------------------------------------------------------
log "Verifying listeners 80/tcp, 53/udp, 8090/tcp, 8091/tcp..."
if command -v ss >/dev/null 2>&1; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ ss -lntup | grep -E ":80 |:53 |:8090 |:8091 "\n'
  else
    ss -lntup | grep -E ':80\s|:53\s|:8090\s|:8091\s' || warn "Ports 80/53/8090/8091 not visible yet. Check logs: journalctl -u ytuner -n 100 --no-pager; journalctl -u ytuner-stream-proxy -n 100 --no-pager; journalctl -u ytuner-admin -n 100 --no-pager"
  fi
fi

IP_HINT="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
IP_HINT="${IP_HINT:-<CONTAINER-IP>}"

cat <<EOF

=============================================
  YTuner installation complete
=============================================

Install dir:  $INSTALL_DIR
Config:       $INSTALL_DIR/ytuner.ini
AVR config:   $INSTALL_DIR/config/avr.ini
Stations:     $INSTALL_DIR/config/stations.ini
Proxy:        http://${IP_HINT}:8090/stream?url=https://...
Admin UI:     http://${IP_HINT}:8091/
Proxy cfg:    /etc/default/ytuner-stream-proxy
Admin cfg:    /etc/default/ytuner-admin
Logs:         /var/log/ytuner.log
              /var/log/ytuner-stream-proxy.log
              /var/log/ytuner-admin.log
Services:     systemctl status ytuner
              systemctl status ytuner-stream-proxy
              systemctl status ytuner-admin

Next steps:
  1) Ensure this container has a stable IP (DHCP reservation or static).
  2) On your AVR, set DNS server to: $IP_HINT
  3) Disable AVR proxy if configured.
  4) For HTTPS-only stations, use:
     http://${IP_HINT}:8090/stream?url=https://STREAM-URL
  5) Open Admin UI: http://${IP_HINT}:8091/ (Status, Settings, Autotests, Logs)

Checks:
  ss -lntup | grep -E ':80 |:53 |:8090 |:8091 '
  dig @${IP_HINT} pioneer.vtuner.com +short
  curl -I "http://${IP_HINT}:8090/health"
  curl -I "http://${IP_HINT}:8091/api/health"
  /usr/bin/python3 ${INSTALL_DIR}/ytuner-autotest.py --json
  tail -f /var/log/ytuner.log

Docs: https://github.com/coffeegreg/YTuner
EOF
