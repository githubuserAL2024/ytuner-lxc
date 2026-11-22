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
ADMIN_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKZnJvbSBodHRwIGltcG9ydCBIVFRQU3RhdHVzCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIsIFRocmVhZGluZ0hUVFBTZXJ2ZXIKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gdXJsbGliLnBhcnNlIGltcG9ydCBwYXJzZV9xcywgdXJsc3BsaXQKCgpJTlNUQUxMX0RJUiA9IFBhdGgob3MuZW52aXJvbi5nZXQoIllUVU5FUl9JTlNUQUxMX0RJUiIsICIvb3B0L3l0dW5lciIpKQpDT05GSUdfRElSID0gSU5TVEFMTF9ESVIgLyAiY29uZmlnIgpZVFVORVJfSU5JID0gSU5TVEFMTF9ESVIgLyAieXR1bmVyLmluaSIKQVZSX0lOSSA9IENPTkZJR19ESVIgLyAiYXZyLmluaSIKU1RBVElPTlNfSU5JID0gQ09ORklHX0RJUiAvICJzdGF0aW9ucy5pbmkiClBST1hZX0VOViA9IFBhdGgoIi9ldGMvZGVmYXVsdC95dHVuZXItc3RyZWFtLXByb3h5IikKUFJPWFlfU0NSSVBUID0gSU5TVEFMTF9ESVIgLyAieXR1bmVyLXN0cmVhbS1wcm94eS5weSIKV0VCX0RJUiA9IFBhdGgob3MuZW52aXJvbi5nZXQoIllUVU5FUl9BRE1JTl9XRUJfRElSIiwgIi9vcHQveXR1bmVyL3dlYnVpIikpCkxPR19GSUxFUyA9IHsKICAgICJ5dHVuZXIiOiBQYXRoKCIvdmFyL2xvZy95dHVuZXIubG9nIiksCiAgICAicHJveHkiOiBQYXRoKCIvdmFyL2xvZy95dHVuZXItc3RyZWFtLXByb3h5LmxvZyIpLAp9ClNFUlZJQ0VTID0gWyJ5dHVuZXIiLCAieXR1bmVyLXN0cmVhbS1wcm94eSJdCkFMTE9XX1NZU1RFTUNUTCA9IG9zLmVudmlyb24uZ2V0KCJZVFVORVJfQURNSU5fQUxMT1dfU1lTVEVNQ1RMIiwgIjEiKSAhPSAiMCIKSE9TVCA9IG9zLmVudmlyb24uZ2V0KCJZVFVORVJfQURNSU5fSE9TVCIsICIwLjAuMC4wIikKUE9SVCA9IGludChvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0FETUlOX1BPUlQiLCAiODA5MSIpKQpUT0tFTiA9IG9zLmVudmlyb24uZ2V0KCJZVFVORVJfQURNSU5fVE9LRU4iLCAiIikKCgpkZWYgcnVuX2NtZChjbWQ6IGxpc3Rbc3RyXSwgdGltZW91dDogZmxvYXQgPSAyMC4wKSAtPiBkaWN0OgogICAgdHJ5OgogICAgICAgIHByb2MgPSBzdWJwcm9jZXNzLnJ1bihjbWQsIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD10aW1lb3V0LCBjaGVjaz1GYWxzZSkKICAgICAgICByZXR1cm4gewogICAgICAgICAgICAib2siOiBwcm9jLnJldHVybmNvZGUgPT0gMCwKICAgICAgICAgICAgInJjIjogcHJvYy5yZXR1cm5jb2RlLAogICAgICAgICAgICAic3Rkb3V0IjogcHJvYy5zdGRvdXRbLTgwMDA6XSwKICAgICAgICAgICAgInN0ZGVyciI6IHByb2Muc3RkZXJyWy04MDAwOl0sCiAgICAgICAgICAgICJjbWQiOiBjbWQsCiAgICAgICAgfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7Im9rIjogRmFsc2UsICJyYyI6IC0xLCAic3Rkb3V0IjogIiIsICJzdGRlcnIiOiBzdHIoZXhjKSwgImNtZCI6IGNtZH0KCgpkZWYgcmVhZF90ZXh0KHBhdGg6IFBhdGgpIC0+IHN0cjoKICAgIGlmIG5vdCBwYXRoLmV4aXN0cygpOgogICAgICAgIHJldHVybiAiIgogICAgcmV0dXJuIHBhdGgucmVhZF90ZXh0KGVuY29kaW5nPSJ1dGYtOCIsIGVycm9ycz0icmVwbGFjZSIpCgoKZGVmIHdyaXRlX3RleHRfYXRvbWljKHBhdGg6IFBhdGgsIGNvbnRlbnQ6IHN0cikgLT4gTm9uZToKICAgIHBhdGgucGFyZW50Lm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSkKICAgIHRtcCA9IHBhdGgud2l0aF9zdWZmaXgocGF0aC5zdWZmaXggKyAiLnRtcCIpCiAgICB0bXAud3JpdGVfdGV4dChjb250ZW50LCBlbmNvZGluZz0idXRmLTgiKQogICAgdG1wLnJlcGxhY2UocGF0aCkKCgpkZWYgaW5pX2dldChjb250ZW50OiBzdHIsIHNlY3Rpb246IHN0ciwga2V5OiBzdHIsIGRlZmF1bHQ6IHN0ciA9ICIiKSAtPiBzdHI6CiAgICBpbl9zZWN0aW9uID0gRmFsc2UKICAgIHNlY19yZSA9IHJlLmNvbXBpbGUociJeXHMqXFsoLis/KVxdXHMqJCIpCiAgICBrdl9yZSA9IHJlLmNvbXBpbGUociJeXHMqKFteOyM9XHNdW149XSo/KVxzKj1ccyooLio/KVxzKiQiKQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbSA9IHNlY19yZS5tYXRjaChsaW5lKQogICAgICAgIGlmIG06CiAgICAgICAgICAgIGluX3NlY3Rpb24gPSBtLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBzZWN0aW9uLmxvd2VyKCkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBub3QgaW5fc2VjdGlvbjoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBrbSA9IGt2X3JlLm1hdGNoKGxpbmUpCiAgICAgICAgaWYga20gYW5kIGttLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBrZXkubG93ZXIoKToKICAgICAgICAgICAgcmV0dXJuIGttLmdyb3VwKDIpCiAgICByZXR1cm4gZGVmYXVsdAoKCmRlZiBlbnZfcGFyc2UoY29udGVudDogc3RyKSAtPiBkaWN0W3N0ciwgc3RyXToKICAgIG91dDogZGljdFtzdHIsIHN0cl0gPSB7fQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbGluZSA9IGxpbmUuc3RyaXAoKQogICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpIG9yICI9IiBub3QgaW4gbGluZToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBrLCB2ID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgb3V0W2suc3RyaXAoKV0gPSB2LnN0cmlwKCkuc3RyaXAoJyInKS5zdHJpcCgiJyIpCiAgICByZXR1cm4gb3V0CgoKZGVmIGVudl9yZW5kZXIoZXhpc3Rpbmc6IHN0ciwgdXBkYXRlczogZGljdFtzdHIsIHN0cl0pIC0+IHN0cjoKICAgIGxpbmVzID0gZXhpc3Rpbmcuc3BsaXRsaW5lcygpIGlmIGV4aXN0aW5nIGVsc2UgW10KICAgIHNlZW46IHNldFtzdHJdID0gc2V0KCkKICAgIG91dDogbGlzdFtzdHJdID0gW10KICAgIGZvciBsaW5lIGluIGxpbmVzOgogICAgICAgIGlmICI9IiBpbiBsaW5lIGFuZCBub3QgbGluZS5sc3RyaXAoKS5zdGFydHN3aXRoKCIjIik6CiAgICAgICAgICAgIGsgPSBsaW5lLnNwbGl0KCI9IiwgMSlbMF0uc3RyaXAoKQogICAgICAgICAgICBrdSA9IGsudXBwZXIoKQogICAgICAgICAgICBpZiBrdSBpbiB1cGRhdGVzOgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChmIntrfT17dXBkYXRlc1trdV19IikKICAgICAgICAgICAgICAgIHNlZW4uYWRkKGt1KQogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICBvdXQuYXBwZW5kKGxpbmUpCiAgICBmb3IgaywgdiBpbiB1cGRhdGVzLml0ZW1zKCk6CiAgICAgICAgaWYgayBub3QgaW4gc2VlbjoKICAgICAgICAgICAgb3V0LmFwcGVuZChmIntrfT17dn0iKQogICAgcmV0dXJuICJcbiIuam9pbihvdXQpLnJzdHJpcCgpICsgIlxuIgoKCmRlZiBzZXJ2aWNlX3N0YXR1cyhuYW1lOiBzdHIpIC0+IGRpY3Q6CiAgICBpZiBub3QgQUxMT1dfU1lTVEVNQ1RMIG9yIHNodXRpbC53aGljaCgic3lzdGVtY3RsIikgaXMgTm9uZToKICAgICAgICBhY3RpdmUgPSBydW5fY21kKFsic2giLCAiLWxjIiwgZiJwZ3JlcCAtYWYge25hbWV9ID4vZGV2L251bGwgJiYgZWNobyBhY3RpdmUgfHwgZWNobyBpbmFjdGl2ZSJdLCB0aW1lb3V0PTUpCiAgICAgICAgcmV0dXJuIHsibmFtZSI6IG5hbWUsICJhY3RpdmUiOiBhY3RpdmVbInN0ZG91dCJdLnN0cmlwKCksICJlbmFibGVkIjogInVua25vd24iLCAiZGV0YWlsIjogYWN0aXZlfQogICAgYWN0aXZlID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJpcy1hY3RpdmUiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIGVuYWJsZWQgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgImlzLWVuYWJsZWQiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIHNob3cgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgInNob3ciLCBuYW1lLCAiLS1wcm9wZXJ0eT1BY3RpdmVTdGF0ZSxTdWJTdGF0ZSxVbml0RmlsZVN0YXRlLE1haW5QSUQsRXhlY01haW5TdGF0dXMiXSwgdGltZW91dD0xMCkKICAgIHByb3BzID0ge30KICAgIGZvciBsaW5lIGluIHNob3dbInN0ZG91dCJdLnNwbGl0bGluZXMoKToKICAgICAgICBpZiAiPSIgaW4gbGluZToKICAgICAgICAgICAgaywgdiA9IGxpbmUuc3BsaXQoIj0iLCAxKQogICAgICAgICAgICBwcm9wc1trLnN0cmlwKCldID0gdi5zdHJpcCgpCiAgICByZXR1cm4gewogICAgICAgICJuYW1lIjogbmFtZSwKICAgICAgICAiYWN0aXZlIjogYWN0aXZlWyJzdGRvdXQiXS5zdHJpcCgpIG9yIHByb3BzLmdldCgiQWN0aXZlU3RhdGUiLCAidW5rbm93biIpLAogICAgICAgICJlbmFibGVkIjogZW5hYmxlZFsic3Rkb3V0Il0uc3RyaXAoKSBvciBwcm9wcy5nZXQoIlVuaXRGaWxlU3RhdGUiLCAidW5rbm93biIpLAogICAgICAgICJwcm9wcyI6IHByb3BzLAogICAgfQoKCmRlZiBwb3J0X2NoZWNrKHBvcnQ6IGludCwgaG9zdDogc3RyID0gIjEyNy4wLjAuMSIpIC0+IGRpY3Q6CiAgICBpbXBvcnQgc29ja2V0CgogICAgcyA9IHNvY2tldC5zb2NrZXQoKQogICAgcy5zZXR0aW1lb3V0KDEuNSkKICAgIHRyeToKICAgICAgICBzLmNvbm5lY3QoKGhvc3QsIHBvcnQpKQogICAgICAgIHMuY2xvc2UoKQogICAgICAgIHJldHVybiB7InBvcnQiOiBwb3J0LCAib3BlbiI6IFRydWV9CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgcmV0dXJuIHsicG9ydCI6IHBvcnQsICJvcGVuIjogRmFsc2UsICJlcnJvciI6IHN0cihleGMpfQogICAgZmluYWxseToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHMuY2xvc2UoKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgIHBhc3MKCgpkZWYgaHR0cF9jaGVjayh1cmw6IHN0ciwgdGltZW91dDogZmxvYXQgPSA1LjApIC0+IGRpY3Q6CiAgICBmcm9tIHVybGxpYi5yZXF1ZXN0IGltcG9ydCBSZXF1ZXN0LCB1cmxvcGVuCgogICAgcmVxID0gUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInl0dW5lci1hZG1pbi8wLjEifSkKICAgIHQwID0gdGltZS50aW1lKCkKICAgIHRyeToKICAgICAgICB3aXRoIHVybG9wZW4ocmVxLCB0aW1lb3V0PXRpbWVvdXQpIGFzIHJlc3A6CiAgICAgICAgICAgIGJvZHkgPSByZXNwLnJlYWQoNTEyKQogICAgICAgICAgICByZXR1cm4gewogICAgICAgICAgICAgICAgInVybCI6IHVybCwKICAgICAgICAgICAgICAgICJvayI6IDIwMCA8PSBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApIDwgNTAwLAogICAgICAgICAgICAgICAgInN0YXR1cyI6IGdldGF0dHIocmVzcCwgInN0YXR1cyIsIDIwMCksCiAgICAgICAgICAgICAgICAibXMiOiBpbnQoKHRpbWUudGltZSgpIC0gdDApICogMTAwMCksCiAgICAgICAgICAgICAgICAiYnl0ZXMiOiBsZW4oYm9keSksCiAgICAgICAgICAgIH0KICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJvayI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKSwgIm1zIjogaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApfQoKCmRlZiBjb2xsZWN0X2NvbmZpZygpIC0+IGRpY3Q6CiAgICB5dHVuZXIgPSByZWFkX3RleHQoWVRVTkVSX0lOSSkKICAgIGF2ciA9IHJlYWRfdGV4dChBVlJfSU5JKQogICAgcHJveHkgPSBlbnZfcGFyc2UocmVhZF90ZXh0KFBST1hZX0VOVikpCiAgICByZXR1cm4gewogICAgICAgICJwYXRocyI6IHsKICAgICAgICAgICAgImluc3RhbGxfZGlyIjogc3RyKElOU1RBTExfRElSKSwKICAgICAgICAgICAgInl0dW5lcl9pbmkiOiBzdHIoWVRVTkVSX0lOSSksCiAgICAgICAgICAgICJhdnJfaW5pIjogc3RyKEFWUl9JTkkpLAogICAgICAgICAgICAic3RhdGlvbnNfaW5pIjogc3RyKFNUQVRJT05TX0lOSSksCiAgICAgICAgICAgICJwcm94eV9lbnYiOiBzdHIoUFJPWFlfRU5WKSwKICAgICAgICB9LAogICAgICAgICJ5dHVuZXIiOiB7CiAgICAgICAgICAgICJ3ZWJfcG9ydCI6IGluaV9nZXQoeXR1bmVyLCAiV2ViU2VydmVyIiwgIldlYlNlcnZlclBvcnQiLCAiODAiKSwKICAgICAgICAgICAgImRuc19wb3J0IjogaW5pX2dldCh5dHVuZXIsICJETlNTZXJ2ZXIiLCAiRE5TU2VydmVyUG9ydCIsICI1MyIpLAogICAgICAgICAgICAiZG5zX2VuYWJsZSI6IGluaV9nZXQoeXR1bmVyLCAiRE5TU2VydmVyIiwgIkVuYWJsZSIsICIxIiksCiAgICAgICAgICAgICJpbnRlcmNlcHRfZG5zIjogaW5pX2dldCh5dHVuZXIsICJETlNTZXJ2ZXIiLCAiSW50ZXJjZXB0RE5zIiwgIiIpLAogICAgICAgICAgICAicmJfY2FjaGVfdHlwZSI6IGluaV9nZXQoeXR1bmVyLCAiUmFkaW9icm93c2VyIiwgIlJCQ2FjaGVUeXBlIiwgIiIpLAogICAgICAgICAgICAibWVzc2FnZV9sZXZlbCI6IGluaV9nZXQoeXR1bmVyLCAiQ29uZmlndXJhdGlvbiIsICJNZXNzYWdlSW5mb0xldmVsIiwgIiIpLAogICAgICAgIH0sCiAgICAgICAgImF2ciI6IHsKICAgICAgICAgICAgInByb3RvY29sIjogaW5pX2dldChhdnIsICJDb25maWd1cmF0aW9uIiwgIlByb3RvY29sIiwgIiIpLAogICAgICAgIH0sCiAgICAgICAgInByb3h5IjogewogICAgICAgICAgICAiaG9zdCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX0hPU1QiLCAiMC4wLjAuMCIpLAogICAgICAgICAgICAicG9ydCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX1BPUlQiLCAiODA5MCIpLAogICAgICAgICAgICAidGltZW91dCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX1RJTUVPVVQiLCAiMTUiKSwKICAgICAgICAgICAgIm1heF9yZWRpcmVjdHMiOiBwcm94eS5nZXQoIlNUUkVBTV9QUk9YWV9NQVhfUkVESVJFQ1RTIiwgIjUiKSwKICAgICAgICAgICAgImxvZ19sZXZlbCI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX0xPR19MRVZFTCIsICJJTkZPIiksCiAgICAgICAgfSwKICAgIH0KCgpkZWYgc2F2ZV9wcm94eV9lbnYocGF5bG9hZDogZGljdCkgLT4gZGljdDoKICAgIGFsbG93ZWQgPSB7CiAgICAgICAgIlNUUkVBTV9QUk9YWV9IT1NUIiwKICAgICAgICAiU1RSRUFNX1BST1hZX1BPUlQiLAogICAgICAgICJTVFJFQU1fUFJPWFlfVElNRU9VVCIsCiAgICAgICAgIlNUUkVBTV9QUk9YWV9NQVhfUkVESVJFQ1RTIiwKICAgICAgICAiU1RSRUFNX1BST1hZX0xPR19MRVZFTCIsCiAgICAgICAgIlNUUkVBTV9QUk9YWV9VU0VSX0FHRU5UIiwKICAgIH0KICAgIHVwZGF0ZXMgPSB7fQogICAgZm9yIGssIHYgaW4gcGF5bG9hZC5pdGVtcygpOgogICAgICAgIGt1ID0gay51cHBlcigpCiAgICAgICAgaWYga3UgaW4gYWxsb3dlZCBhbmQgdiBpcyBub3QgTm9uZToKICAgICAgICAgICAgdXBkYXRlc1trdV0gPSBzdHIodikuc3RyaXAoKQogICAgaWYgIlNUUkVBTV9QUk9YWV9QT1JUIiBpbiB1cGRhdGVzIGFuZCBub3QgdXBkYXRlc1siU1RSRUFNX1BST1hZX1BPUlQiXS5pc2RpZ2l0KCk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiU1RSRUFNX1BST1hZX1BPUlQgbXVzdCBiZSBudW1lcmljIikKICAgIGNvbnRlbnQgPSByZWFkX3RleHQoUFJPWFlfRU5WKQogICAgbmV3X2NvbnRlbnQgPSBlbnZfcmVuZGVyKGNvbnRlbnQsIHVwZGF0ZXMpCiAgICB3cml0ZV90ZXh0X2F0b21pYyhQUk9YWV9FTlYsIG5ld19jb250ZW50KQogICAgcmV0dXJuIHsic2F2ZWQiOiBUcnVlLCAicGF0aCI6IHN0cihQUk9YWV9FTlYpLCAidXBkYXRlcyI6IHVwZGF0ZXN9CgoKZGVmIHJ1bl90ZXN0cygpIC0+IGRpY3Q6CiAgICBjZmcgPSBjb2xsZWN0X2NvbmZpZygpCiAgICBwcm94eV9wb3J0ID0gaW50KGNmZ1sicHJveHkiXS5nZXQoInBvcnQiLCAiODA5MCIpIG9yICI4MDkwIikKICAgIHdlYl9wb3J0ID0gaW50KGNmZ1sieXR1bmVyIl0uZ2V0KCJ3ZWJfcG9ydCIsICI4MCIpIG9yICI4MCIpCiAgICBkbnNfcG9ydCA9IGludChjZmdbInl0dW5lciJdLmdldCgiZG5zX3BvcnQiLCAiNTMiKSBvciAiNTMiKQogICAgcmVzdWx0cyA9IFtdCgogICAgZGVmIGFkZChuYW1lOiBzdHIsIG9rOiBib29sLCBkZXRhaWw6IGRpY3QgfCBzdHIpOgogICAgICAgIHJlc3VsdHMuYXBwZW5kKHsibmFtZSI6IG5hbWUsICJvayI6IGJvb2wob2spLCAiZGV0YWlsIjogZGV0YWlsfSkKCiAgICBmb3Igc3ZjIGluIFNFUlZJQ0VTOgogICAgICAgIHN0ID0gc2VydmljZV9zdGF0dXMoc3ZjKQogICAgICAgIGFkZChmInNlcnZpY2U6e3N2Y30iLCBzdC5nZXQoImFjdGl2ZSIpID09ICJhY3RpdmUiLCBzdCkKCiAgICBhZGQoZiJwb3J0Ont3ZWJfcG9ydH0iLCBwb3J0X2NoZWNrKHdlYl9wb3J0KVsib3BlbiJdLCBwb3J0X2NoZWNrKHdlYl9wb3J0KSkKICAgIGFkZChmInBvcnQ6e2Ruc19wb3J0fSIsIHBvcnRfY2hlY2soZG5zX3BvcnQpWyJvcGVuIl0sIHBvcnRfY2hlY2soZG5zX3BvcnQpKQogICAgYWRkKGYicG9ydDp7cHJveHlfcG9ydH0iLCBwb3J0X2NoZWNrKHByb3h5X3BvcnQpWyJvcGVuIl0sIHBvcnRfY2hlY2socHJveHlfcG9ydCkpCgogICAgZm9yIHAgaW4gW1lUVU5FUl9JTkksIEFWUl9JTkksIFNUQVRJT05TX0lOSSwgUFJPWFlfRU5WXToKICAgICAgICBhZGQoZiJmaWxlOntwfSIsIHAuZXhpc3RzKCksIHsicGF0aCI6IHN0cihwKSwgImV4aXN0cyI6IHAuZXhpc3RzKCksICJzaXplIjogcC5zdGF0KCkuc3Rfc2l6ZSBpZiBwLmV4aXN0cygpIGVsc2UgMH0pCgogICAgYWRkKCJodHRwOnl0dW5lciIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt3ZWJfcG9ydH0vIiwgNC4wKVsib2siXSwgaHR0cF9jaGVjayhmImh0dHA6Ly8xMjcuMC4wLjE6e3dlYl9wb3J0fS8iLCA0LjApKQogICAgYWRkKCJodHRwOnByb3h5LWhlYWx0aCIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOntwcm94eV9wb3J0fS9oZWFsdGgiLCA0LjApWyJvayJdLCBodHRwX2NoZWNrKGYiaHR0cDovLzEyNy4wLjAuMTp7cHJveHlfcG9ydH0vaGVhbHRoIiwgNC4wKSkKCiAgICBweWMgPSBydW5fY21kKFsicHl0aG9uMyIsICItbSIsICJweV9jb21waWxlIiwgc3RyKFBST1hZX1NDUklQVCldLCB0aW1lb3V0PTIwKQogICAgYWRkKCJweXRob246cHJveHktY29tcGlsZSIsIHB5Y1sib2siXSwgcHljKQoKICAgIG9rX2NvdW50ID0gc3VtKDEgZm9yIHIgaW4gcmVzdWx0cyBpZiByWyJvayJdKQogICAgcmV0dXJuIHsib2siOiBva19jb3VudCA9PSBsZW4ocmVzdWx0cyksICJ0b3RhbCI6IGxlbihyZXN1bHRzKSwgInBhc3NlZCI6IG9rX2NvdW50LCAiZmFpbGVkIjogbGVuKHJlc3VsdHMpIC0gb2tfY291bnQsICJyZXN1bHRzIjogcmVzdWx0cywgInRzIjogaW50KHRpbWUudGltZSgpKX0KCgpjbGFzcyBIYW5kbGVyKEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgc2VydmVyX3ZlcnNpb24gPSAiWVR1bmVyQWRtaW4vMC4xIgoKICAgIGRlZiBsb2dfbWVzc2FnZShzZWxmLCBmbXQ6IHN0ciwgKmFyZ3MpIC0+IE5vbmU6ICAjIG5vcWE6IEEwMDMKICAgICAgICBzeXMuc3RkZXJyLndyaXRlKCIlcyAtICVzXG4iICUgKHNlbGYuYWRkcmVzc19zdHJpbmcoKSwgZm10ICUgYXJncykpCgogICAgZGVmIF9hdXRoX29rKHNlbGYpIC0+IGJvb2w6CiAgICAgICAgaWYgbm90IFRPS0VOOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIGhkciA9IHNlbGYuaGVhZGVycy5nZXQoIlgtQWRtaW4tVG9rZW4iKSBvciAiIgogICAgICAgIGlmIGhkciA9PSBUT0tFTjoKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBxcyA9IHBhcnNlX3FzKHVybHNwbGl0KHNlbGYucGF0aCkucXVlcnkpCiAgICAgICAgcmV0dXJuIChxcy5nZXQoInRva2VuIikgb3IgWyIiXSlbMF0gPT0gVE9LRU4KCiAgICBkZWYgX3NlbmRfanNvbihzZWxmLCBjb2RlOiBpbnQsIHBheWxvYWQ6IGRpY3QpIC0+IE5vbmU6CiAgICAgICAgZGF0YSA9IGpzb24uZHVtcHMocGF5bG9hZCwgZW5zdXJlX2FzY2lpPUZhbHNlKS5lbmNvZGUoInV0Zi04IikKICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoY29kZSkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LVR5cGUiLCAiYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCIpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5ndGgiLCBzdHIobGVuKGRhdGEpKSkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDYWNoZS1Db250cm9sIiwgIm5vLXN0b3JlIikKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICBzZWxmLndmaWxlLndyaXRlKGRhdGEpCgogICAgZGVmIF9zZW5kX2J5dGVzKHNlbGYsIGNvZGU6IGludCwgZGF0YTogYnl0ZXMsIGNvbnRlbnRfdHlwZTogc3RyKSAtPiBOb25lOgogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZShjb2RlKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsIGNvbnRlbnRfdHlwZSkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0aCIsIHN0cihsZW4oZGF0YSkpKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNhY2hlLUNvbnRyb2wiLCAibm8tc3RvcmUiKQogICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNlbGYud2ZpbGUud3JpdGUoZGF0YSkKCiAgICBkZWYgX3JlYWRfanNvbihzZWxmKSAtPiBkaWN0OgogICAgICAgIG4gPSBpbnQoc2VsZi5oZWFkZXJzLmdldCgiQ29udGVudC1MZW5ndGgiKSBvciAiMCIpCiAgICAgICAgcmF3ID0gc2VsZi5yZmlsZS5yZWFkKG4pIGlmIG4gPiAwIGVsc2UgYiJ7fSIKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJldHVybiBqc29uLmxvYWRzKHJhdy5kZWNvZGUoInV0Zi04IikpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcmV0dXJuIHt9CgogICAgZGVmIF9zZXJ2ZV9zdGF0aWMoc2VsZiwgcGF0aDogc3RyKSAtPiBib29sOgogICAgICAgIHAgPSB1cmxzcGxpdChwYXRoKS5wYXRoCiAgICAgICAgaWYgcCA9PSAiLyI6CiAgICAgICAgICAgIHAgPSAiL2luZGV4Lmh0bWwiCiAgICAgICAgc2FmZSA9IFBhdGgocC5sc3RyaXAoIi8iKSkKICAgICAgICB0YXJnZXQgPSAoV0VCX0RJUiAvIHNhZmUpLnJlc29sdmUoKQogICAgICAgIGlmIFdFQl9ESVIucmVzb2x2ZSgpIG5vdCBpbiB0YXJnZXQucGFyZW50cyBhbmQgdGFyZ2V0ICE9IFdFQl9ESVIucmVzb2x2ZSgpOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAzLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJmb3JiaWRkZW4ifSkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBpZiBub3QgdGFyZ2V0LmV4aXN0cygpIG9yIG5vdCB0YXJnZXQuaXNfZmlsZSgpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBjdHlwZSA9ICJ0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGlmIHRhcmdldC5zdWZmaXggPT0gIi5odG1sIjoKICAgICAgICAgICAgY3R5cGUgPSAidGV4dC9odG1sOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGVsaWYgdGFyZ2V0LnN1ZmZpeCA9PSAiLmNzcyI6CiAgICAgICAgICAgIGN0eXBlID0gInRleHQvY3NzOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGVsaWYgdGFyZ2V0LnN1ZmZpeCA9PSAiLmpzIjoKICAgICAgICAgICAgY3R5cGUgPSAiYXBwbGljYXRpb24vamF2YXNjcmlwdDsgY2hhcnNldD11dGYtOCIKICAgICAgICBlbGlmIHRhcmdldC5zdWZmaXggPT0gIi5qc29uIjoKICAgICAgICAgICAgY3R5cGUgPSAiYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCIKICAgICAgICBzZWxmLl9zZW5kX2J5dGVzKDIwMCwgdGFyZ2V0LnJlYWRfYnl0ZXMoKSwgY3R5cGUpCiAgICAgICAgcmV0dXJuIFRydWUKCiAgICBkZWYgZG9fR0VUKHNlbGYpIC0+IE5vbmU6ICAjIG5vcWE6IE44MDIKICAgICAgICBwYXJzZWQgPSB1cmxzcGxpdChzZWxmLnBhdGgpCiAgICAgICAgcGF0aCA9IHBhcnNlZC5wYXRoCiAgICAgICAgaWYgcGF0aC5zdGFydHN3aXRoKCIvYXBpLyIpIGFuZCBub3Qgc2VsZi5fYXV0aF9vaygpOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAxLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJ1bmF1dGhvcml6ZWQifSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9oZWFsdGgiOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCB7Im9rIjogVHJ1ZSwgInNlcnZpY2UiOiAieXR1bmVyLWFkbWluIn0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvc3RhdHVzIjoKICAgICAgICAgICAgY2ZnID0gY29sbGVjdF9jb25maWcoKQogICAgICAgICAgICBzdGF0dXNlcyA9IFtzZXJ2aWNlX3N0YXR1cyhzKSBmb3IgcyBpbiBTRVJWSUNFU10KICAgICAgICAgICAgcHJveHlfcG9ydCA9IGludChjZmdbInByb3h5Il0uZ2V0KCJwb3J0IiwgIjgwOTAiKSBvciAiODA5MCIpCiAgICAgICAgICAgIHl0dW5lcl9wb3J0ID0gaW50KGNmZ1sieXR1bmVyIl0uZ2V0KCJ3ZWJfcG9ydCIsICI4MCIpIG9yICI4MCIpCiAgICAgICAgICAgIGRuc19wb3J0ID0gaW50KGNmZ1sieXR1bmVyIl0uZ2V0KCJkbnNfcG9ydCIsICI1MyIpIG9yICI1MyIpCiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsKICAgICAgICAgICAgICAgICJvayI6IFRydWUsCiAgICAgICAgICAgICAgICAiY29uZmlnIjogY2ZnLAogICAgICAgICAgICAgICAgInNlcnZpY2VzIjogc3RhdHVzZXMsCiAgICAgICAgICAgICAgICAicG9ydHMiOiBbcG9ydF9jaGVjayh5dHVuZXJfcG9ydCksIHBvcnRfY2hlY2soZG5zX3BvcnQpLCBwb3J0X2NoZWNrKHByb3h5X3BvcnQpXSwKICAgICAgICAgICAgfSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9jb25maWciOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCB7Im9rIjogVHJ1ZSwgImNvbmZpZyI6IGNvbGxlY3RfY29uZmlnKCl9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL2xvZ3MiOgogICAgICAgICAgICBxcyA9IHBhcnNlX3FzKHBhcnNlZC5xdWVyeSkKICAgICAgICAgICAgbmFtZSA9IChxcy5nZXQoIm5hbWUiKSBvciBbInl0dW5lciJdKVswXQogICAgICAgICAgICBsaW5lcyA9IGludCgocXMuZ2V0KCJsaW5lcyIpIG9yIFsiMTIwIl0pWzBdKQogICAgICAgICAgICBsaW5lcyA9IG1heCgxMCwgbWluKGxpbmVzLCAxMDAwKSkKICAgICAgICAgICAgcCA9IExPR19GSUxFUy5nZXQobmFtZSkKICAgICAgICAgICAgaWYgbm90IHA6CiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAwLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJ1bmtub3duIGxvZyJ9KQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIHRleHQgPSByZWFkX3RleHQocCkKICAgICAgICAgICAgdGFpbCA9ICJcbiIuam9pbih0ZXh0LnNwbGl0bGluZXMoKVstbGluZXM6XSkKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICJuYW1lIjogbmFtZSwgInBhdGgiOiBzdHIocCksICJjb250ZW50IjogdGFpbH0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvdGVzdHMvcnVuIjoKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgcnVuX3Rlc3RzKCkpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGguc3RhcnRzd2l0aCgiL2FwaS8iKToKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwNCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibm90IGZvdW5kIn0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHNlbGYuX3NlcnZlX3N0YXRpYyhwYXRoKToKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwNCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibm90IGZvdW5kIn0pCgogICAgZGVmIGRvX1BPU1Qoc2VsZikgLT4gTm9uZTogICMgbm9xYTogTjgwMgogICAgICAgIHBhcnNlZCA9IHVybHNwbGl0KHNlbGYucGF0aCkKICAgICAgICBwYXRoID0gcGFyc2VkLnBhdGgKICAgICAgICBpZiBub3Qgc2VsZi5fYXV0aF9vaygpOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAxLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJ1bmF1dGhvcml6ZWQifSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgcGF5bG9hZCA9IHNlbGYuX3JlYWRfanNvbigpCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9jb25maWcvcHJveHkiOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICByZXMgPSBzYXZlX3Byb3h5X2VudihwYXlsb2FkKQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICoqcmVzfSkKICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKX0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvc2VydmljZS9yZXN0YXJ0IjoKICAgICAgICAgICAgbmFtZSA9IHN0cihwYXlsb2FkLmdldCgibmFtZSIpIG9yICIiKQogICAgICAgICAgICBpZiBuYW1lIG5vdCBpbiBTRVJWSUNFUzoKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDAsIHsib2siOiBGYWxzZSwgImVycm9yIjogImludmFsaWQgc2VydmljZSJ9KQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIGlmIG5vdCBBTExPV19TWVNURU1DVEwgb3Igc2h1dGlsLndoaWNoKCJzeXN0ZW1jdGwiKSBpcyBOb25lOgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAic3lzdGVtY3RsIHVuYXZhaWxhYmxlIn0pCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgcmVzID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJyZXN0YXJ0IiwgbmFtZV0sIHRpbWVvdXQ9MzApCiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAgaWYgcmVzWyJvayJdIGVsc2UgNTAwLCB7Im9rIjogcmVzWyJvayJdLCAicmVzdWx0IjogcmVzLCAic3RhdHVzIjogc2VydmljZV9zdGF0dXMobmFtZSl9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL3Rlc3RzL3J1biI6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHJ1bl90ZXN0cygpKQogICAgICAgICAgICByZXR1cm4KICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDA0LCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJub3QgZm91bmQifSkKCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFwID0gYXJncGFyc2UuQXJndW1lbnRQYXJzZXIoKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWhvc3QiLCBkZWZhdWx0PUhPU1QpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcG9ydCIsIHR5cGU9aW50LCBkZWZhdWx0PVBPUlQpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCiAgICBzZXJ2ZXIgPSBUaHJlYWRpbmdIVFRQU2VydmVyKChhcmdzLmhvc3QsIGFyZ3MucG9ydCksIEhhbmRsZXIpCiAgICBwcmludChmInl0dW5lci1hZG1pbiBsaXN0ZW5pbmcgb24gaHR0cDovL3thcmdzLmhvc3R9OnthcmdzLnBvcnR9IiwgZmx1c2g9VHJ1ZSkKICAgIHRyeToKICAgICAgICBzZXJ2ZXIuc2VydmVfZm9yZXZlcigpCiAgICBleGNlcHQgS2V5Ym9hcmRJbnRlcnJ1cHQ6CiAgICAgICAgcGFzcwogICAgZmluYWxseToKICAgICAgICBzZXJ2ZXIuc2VydmVyX2Nsb3NlKCkKICAgIHJldHVybiAwCgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAgIHJhaXNlIFN5c3RlbUV4aXQobWFpbigpKQo='
AUTOTEST_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzb2NrZXQKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKZnJvbSB1cmxsaWIucmVxdWVzdCBpbXBvcnQgUmVxdWVzdCwgdXJsb3BlbgoKCklOU1RBTExfRElSID0gUGF0aChvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0lOU1RBTExfRElSIiwgIi9vcHQveXR1bmVyIikpCkNPTkZJR19ESVIgPSBJTlNUQUxMX0RJUiAvICJjb25maWciCllUVU5FUl9JTkkgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXIuaW5pIgpBVlJfSU5JID0gQ09ORklHX0RJUiAvICJhdnIuaW5pIgpTVEFUSU9OU19JTkkgPSBDT05GSUdfRElSIC8gInN0YXRpb25zLmluaSIKUFJPWFlfRU5WID0gUGF0aCgiL2V0Yy9kZWZhdWx0L3l0dW5lci1zdHJlYW0tcHJveHkiKQpQUk9YWV9TQ1JJUFQgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXItc3RyZWFtLXByb3h5LnB5IgpBRE1JTl9TQ1JJUFQgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXItYWRtaW4ucHkiClNFUlZJQ0VTID0gWyJ5dHVuZXIiLCAieXR1bmVyLXN0cmVhbS1wcm94eSIsICJ5dHVuZXItYWRtaW4iXQoKCmRlZiBydW5fY21kKGNtZDogbGlzdFtzdHJdLCB0aW1lb3V0OiBmbG9hdCA9IDIwLjApIC0+IGRpY3Q6CiAgICB0cnk6CiAgICAgICAgcHJvYyA9IHN1YnByb2Nlc3MucnVuKGNtZCwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PXRpbWVvdXQsIGNoZWNrPUZhbHNlKQogICAgICAgIHJldHVybiB7Im9rIjogcHJvYy5yZXR1cm5jb2RlID09IDAsICJyYyI6IHByb2MucmV0dXJuY29kZSwgInN0ZG91dCI6IHByb2Muc3Rkb3V0Wy00MDAwOl0sICJzdGRlcnIiOiBwcm9jLnN0ZGVyclstNDAwMDpdLCAiY21kIjogY21kfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7Im9rIjogRmFsc2UsICJyYyI6IC0xLCAic3Rkb3V0IjogIiIsICJzdGRlcnIiOiBzdHIoZXhjKSwgImNtZCI6IGNtZH0KCgpkZWYgcmVhZF90ZXh0KHBhdGg6IFBhdGgpIC0+IHN0cjoKICAgIHJldHVybiBwYXRoLnJlYWRfdGV4dChlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKSBpZiBwYXRoLmV4aXN0cygpIGVsc2UgIiIKCgpkZWYgaW5pX2dldChjb250ZW50OiBzdHIsIHNlY3Rpb246IHN0ciwga2V5OiBzdHIsIGRlZmF1bHQ6IHN0ciA9ICIiKSAtPiBzdHI6CiAgICBpbl9zZWN0aW9uID0gRmFsc2UKICAgIHNlY19yZSA9IHJlLmNvbXBpbGUociJeXHMqXFsoLis/KVxdXHMqJCIpCiAgICBrdl9yZSA9IHJlLmNvbXBpbGUociJeXHMqKFteOyM9XHNdW149XSo/KVxzKj1ccyooLio/KVxzKiQiKQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbSA9IHNlY19yZS5tYXRjaChsaW5lKQogICAgICAgIGlmIG06CiAgICAgICAgICAgIGluX3NlY3Rpb24gPSBtLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBzZWN0aW9uLmxvd2VyKCkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBpbl9zZWN0aW9uOgogICAgICAgICAgICBrbSA9IGt2X3JlLm1hdGNoKGxpbmUpCiAgICAgICAgICAgIGlmIGttIGFuZCBrbS5ncm91cCgxKS5zdHJpcCgpLmxvd2VyKCkgPT0ga2V5Lmxvd2VyKCk6CiAgICAgICAgICAgICAgICByZXR1cm4ga20uZ3JvdXAoMikKICAgIHJldHVybiBkZWZhdWx0CgoKZGVmIGVudl9wYXJzZShjb250ZW50OiBzdHIpIC0+IGRpY3Rbc3RyLCBzdHJdOgogICAgb3V0ID0ge30KICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaywgdiA9IGxpbmUuc3BsaXQoIj0iLCAxKQogICAgICAgIG91dFtrLnN0cmlwKCldID0gdi5zdHJpcCgpLnN0cmlwKCciJykuc3RyaXAoIiciKQogICAgcmV0dXJuIG91dAoKCmRlZiBzZXJ2aWNlX3N0YXR1cyhuYW1lOiBzdHIpIC0+IGRpY3Q6CiAgICBpZiBzaHV0aWwud2hpY2goInN5c3RlbWN0bCIpIGlzIE5vbmU6CiAgICAgICAgcmV0dXJuIHsibmFtZSI6IG5hbWUsICJhY3RpdmUiOiAidW5rbm93biIsICJlbmFibGVkIjogInVua25vd24ifQogICAgYWN0aXZlID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJpcy1hY3RpdmUiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIGVuYWJsZWQgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgImlzLWVuYWJsZWQiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIHJldHVybiB7Im5hbWUiOiBuYW1lLCAiYWN0aXZlIjogYWN0aXZlWyJzdGRvdXQiXS5zdHJpcCgpLCAiZW5hYmxlZCI6IGVuYWJsZWRbInN0ZG91dCJdLnN0cmlwKCl9CgoKZGVmIHBvcnRfY2hlY2socG9ydDogaW50LCBob3N0OiBzdHIgPSAiMTI3LjAuMC4xIikgLT4gZGljdDoKICAgIHMgPSBzb2NrZXQuc29ja2V0KCkKICAgIHMuc2V0dGltZW91dCgxLjUpCiAgICB0cnk6CiAgICAgICAgcy5jb25uZWN0KChob3N0LCBwb3J0KSkKICAgICAgICByZXR1cm4geyJwb3J0IjogcG9ydCwgIm9wZW4iOiBUcnVlfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7InBvcnQiOiBwb3J0LCAib3BlbiI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKX0KICAgIGZpbmFsbHk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzLmNsb3NlKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCgoKZGVmIGh0dHBfY2hlY2sodXJsOiBzdHIsIHRpbWVvdXQ6IGZsb2F0ID0gNS4wKSAtPiBkaWN0OgogICAgcmVxID0gUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInl0dW5lci1hdXRvdGVzdC8wLjEifSkKICAgIHQwID0gdGltZS50aW1lKCkKICAgIHRyeToKICAgICAgICB3aXRoIHVybG9wZW4ocmVxLCB0aW1lb3V0PXRpbWVvdXQpIGFzIHJlc3A6CiAgICAgICAgICAgIGJvZHkgPSByZXNwLnJlYWQoNTEyKQogICAgICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJvayI6IDIwMCA8PSBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApIDwgNTAwLCAic3RhdHVzIjogZ2V0YXR0cihyZXNwLCAic3RhdHVzIiwgMjAwKSwgIm1zIjogaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApLCAiYnl0ZXMiOiBsZW4oYm9keSl9CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4YyksICJtcyI6IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKX0KCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFwID0gYXJncGFyc2UuQXJndW1lbnRQYXJzZXIoZGVzY3JpcHRpb249IllUdW5lciBhdXRvdGVzdCBydW5uZXIiKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWpzb24iLCBhY3Rpb249InN0b3JlX3RydWUiLCBoZWxwPSJKU09OIG91dHB1dCIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0taW5jbHVkZS1hZG1pbiIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIsIGhlbHA9IkluY2x1ZGUgeXR1bmVyLWFkbWluIGNoZWNrcyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgeXR1bmVyID0gcmVhZF90ZXh0KFlUVU5FUl9JTkkpCiAgICBwcm94eV9lbnYgPSBlbnZfcGFyc2UocmVhZF90ZXh0KFBST1hZX0VOVikpCiAgICB5dHVuZXJfcG9ydCA9IGludChpbmlfZ2V0KHl0dW5lciwgIldlYlNlcnZlciIsICJXZWJTZXJ2ZXJQb3J0IiwgIjgwIikgb3IgIjgwIikKICAgIGRuc19wb3J0ID0gaW50KGluaV9nZXQoeXR1bmVyLCAiRE5TU2VydmVyIiwgIkROU1NlcnZlclBvcnQiLCAiNTMiKSBvciAiNTMiKQogICAgcHJveHlfcG9ydCA9IGludChwcm94eV9lbnYuZ2V0KCJTVFJFQU1fUFJPWFlfUE9SVCIsICI4MDkwIikgb3IgIjgwOTAiKQogICAgYWRtaW5fZW52ID0gZW52X3BhcnNlKHJlYWRfdGV4dChQYXRoKCIvZXRjL2RlZmF1bHQveXR1bmVyLWFkbWluIikpKQogICAgYWRtaW5fcG9ydCA9IGludChhZG1pbl9lbnYuZ2V0KCJZVFVORVJfQURNSU5fUE9SVCIsICI4MDkxIikgb3IgIjgwOTEiKQoKICAgIHJlc3VsdHMgPSBbXQogICAgZGVmIGFkZChuYW1lLCBvaywgZGV0YWlsKToKICAgICAgICByZXN1bHRzLmFwcGVuZCh7Im5hbWUiOiBuYW1lLCAib2siOiBib29sKG9rKSwgImRldGFpbCI6IGRldGFpbH0pCgogICAgc2VydmljZXMgPSBTRVJWSUNFUyBpZiBhcmdzLmluY2x1ZGVfYWRtaW4gZWxzZSBbInl0dW5lciIsICJ5dHVuZXItc3RyZWFtLXByb3h5Il0KICAgIGZvciBzdmMgaW4gc2VydmljZXM6CiAgICAgICAgc3QgPSBzZXJ2aWNlX3N0YXR1cyhzdmMpCiAgICAgICAgYWRkKGYic2VydmljZTp7c3ZjfSIsIHN0LmdldCgiYWN0aXZlIikgaW4geyJhY3RpdmUiLCAidW5rbm93biJ9LCBzdCkKCiAgICBmb3IgcCBpbiBbeXR1bmVyX3BvcnQsIGRuc19wb3J0LCBwcm94eV9wb3J0XSArIChbYWRtaW5fcG9ydF0gaWYgYXJncy5pbmNsdWRlX2FkbWluIGVsc2UgW10pOgogICAgICAgIHBjID0gcG9ydF9jaGVjayhwKQogICAgICAgIGFkZChmInBvcnQ6e3B9IiwgcGNbIm9wZW4iXSwgcGMpCgogICAgZm9yIHAgaW4gW1lUVU5FUl9JTkksIEFWUl9JTkksIFNUQVRJT05TX0lOSSwgUFJPWFlfRU5WLCBQUk9YWV9TQ1JJUFRdICsgKFtBRE1JTl9TQ1JJUFRdIGlmIGFyZ3MuaW5jbHVkZV9hZG1pbiBlbHNlIFtdKToKICAgICAgICBhZGQoZiJmaWxlOntwfSIsIHAuZXhpc3RzKCksIHsicGF0aCI6IHN0cihwKSwgImV4aXN0cyI6IHAuZXhpc3RzKCksICJzaXplIjogcC5zdGF0KCkuc3Rfc2l6ZSBpZiBwLmV4aXN0cygpIGVsc2UgMH0pCgogICAgYWRkKCJodHRwOnl0dW5lciIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt5dHVuZXJfcG9ydH0vIilbIm9rIl0sIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt5dHVuZXJfcG9ydH0vIikpCiAgICBhZGQoImh0dHA6cHJveHktaGVhbHRoIiwgaHR0cF9jaGVjayhmImh0dHA6Ly8xMjcuMC4wLjE6e3Byb3h5X3BvcnR9L2hlYWx0aCIpWyJvayJdLCBodHRwX2NoZWNrKGYiaHR0cDovLzEyNy4wLjAuMTp7cHJveHlfcG9ydH0vaGVhbHRoIikpCiAgICBpZiBhcmdzLmluY2x1ZGVfYWRtaW46CiAgICAgICAgYWRkKCJodHRwOmFkbWluLWhlYWx0aCIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnthZG1pbl9wb3J0fS9hcGkvaGVhbHRoIilbIm9rIl0sIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnthZG1pbl9wb3J0fS9hcGkvaGVhbHRoIikpCgogICAgcHljID0gcnVuX2NtZChbInB5dGhvbjMiLCAiLW0iLCAicHlfY29tcGlsZSIsIHN0cihQUk9YWV9TQ1JJUFQpXSwgdGltZW91dD0yMCkKICAgIGFkZCgicHl0aG9uOnByb3h5LWNvbXBpbGUiLCBweWNbIm9rIl0sIHB5YykKICAgIGlmIGFyZ3MuaW5jbHVkZV9hZG1pbiBhbmQgQURNSU5fU0NSSVBULmV4aXN0cygpOgogICAgICAgIHB5YzIgPSBydW5fY21kKFsicHl0aG9uMyIsICItbSIsICJweV9jb21waWxlIiwgc3RyKEFETUlOX1NDUklQVCldLCB0aW1lb3V0PTIwKQogICAgICAgIGFkZCgicHl0aG9uOmFkbWluLWNvbXBpbGUiLCBweWMyWyJvayJdLCBweWMyKQoKICAgIHBhc3NlZCA9IHN1bSgxIGZvciByIGluIHJlc3VsdHMgaWYgclsib2siXSkKICAgIHJlcG9ydCA9IHsib2siOiBwYXNzZWQgPT0gbGVuKHJlc3VsdHMpLCAidG90YWwiOiBsZW4ocmVzdWx0cyksICJwYXNzZWQiOiBwYXNzZWQsICJmYWlsZWQiOiBsZW4ocmVzdWx0cyktcGFzc2VkLCAicmVzdWx0cyI6IHJlc3VsdHMsICJ0cyI6IGludCh0aW1lLnRpbWUoKSl9CiAgICBpZiBhcmdzLmpzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhyZXBvcnQsIGVuc3VyZV9hc2NpaT1GYWxzZSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KGYieydQQVNTJyBpZiByZXBvcnRbJ29rJ10gZWxzZSAnRkFJTCd9IHtwYXNzZWR9L3tsZW4ocmVzdWx0cyl9IikKICAgICAgICBmb3IgciBpbiByZXN1bHRzOgogICAgICAgICAgICBwcmludChmIlt7J09LJyBpZiByWydvayddIGVsc2UgJ0ZBSUwnfV0ge3JbJ25hbWUnXX0iKQogICAgICAgICAgICBpZiBub3Qgclsib2siXToKICAgICAgICAgICAgICAgIHByaW50KCIgICIgKyBqc29uLmR1bXBzKHJbImRldGFpbCJdLCBlbnN1cmVfYXNjaWk9RmFsc2UpWzozMDBdKQogICAgcmV0dXJuIDAgaWYgcmVwb3J0WyJvayJdIGVsc2UgMQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICByYWlzZSBTeXN0ZW1FeGl0KG1haW4oKSkK'
WEB_INDEX_B64='PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImRlIj4KPGhlYWQ+CiAgPG1ldGEgY2hhcnNldD0idXRmLTgiPgogIDxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+CiAgPHRpdGxlPllUdW5lciBBZG1pbjwvdGl0bGU+CiAgPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvc3R5bGVzLmNzcyI+CjwvaGVhZD4KPGJvZHk+CiAgPGhlYWRlciBjbGFzcz0idG9wYmFyIj4KICAgIDxkaXY+CiAgICAgIDxoMT5ZVHVuZXIgQWRtaW48L2gxPgogICAgICA8cCBjbGFzcz0ibXV0ZWQiPkVpbnN0ZWxsdW5nZW4sIFN0YXR1cywgQVBJLVRlc3RzIHVuZCBEaWFnbm9zZSBmw7xyIFlUdW5lciArIFN0cmVhbS1Qcm94eTwvcD4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYWN0aW9ucyI+CiAgICAgIDxidXR0b24gaWQ9InJlZnJlc2hCdG4iPkFrdHVhbGlzaWVyZW48L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBpZD0icnVuVGVzdHNCdG4iIGNsYXNzPSJwcmltYXJ5Ij5UZXN0cyBhdXNmw7xocmVuPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2hlYWRlcj4KCiAgPG1haW4gY2xhc3M9ImdyaWQiPgogICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQiPgogICAgICA8aDI+U3RhdHVzPC9oMj4KICAgICAgPGRpdiBpZD0ic3RhdHVzU3VtbWFyeSIgY2xhc3M9Im11dGVkIj5MYWRlLi4uPC9kaXY+CiAgICAgIDxkaXYgaWQ9InNlcnZpY2VzIiBjbGFzcz0ibGlzdCI+PC9kaXY+CiAgICAgIDxkaXYgaWQ9InBvcnRzIiBjbGFzcz0ibGlzdCI+PC9kaXY+CiAgICA8L3NlY3Rpb24+CgogICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQiPgogICAgICA8aDI+U3RyZWFtLVByb3h5IEVpbnN0ZWxsdW5nZW48L2gyPgogICAgICA8Zm9ybSBpZD0icHJveHlGb3JtIiBjbGFzcz0iZm9ybSI+CiAgICAgICAgPGxhYmVsPkhvc3Q8aW5wdXQgbmFtZT0iU1RSRUFNX1BST1hZX0hPU1QiIHBsYWNlaG9sZGVyPSIwLjAuMC4wIj48L2xhYmVsPgogICAgICAgIDxsYWJlbD5Qb3J0PGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9QT1JUIiB0eXBlPSJudW1iZXIiIG1pbj0iMSIgbWF4PSI2NTUzNSI+PC9sYWJlbD4KICAgICAgICA8bGFiZWw+VGltZW91dCAocyk8aW5wdXQgbmFtZT0iU1RSRUFNX1BST1hZX1RJTUVPVVQiIHR5cGU9Im51bWJlciIgbWluPSIxIiBtYXg9IjEyMCI+PC9sYWJlbD4KICAgICAgICA8bGFiZWw+TWF4IFJlZGlyZWN0czxpbnB1dCBuYW1lPSJTVFJFQU1fUFJPWFlfTUFYX1JFRElSRUNUUyIgdHlwZT0ibnVtYmVyIiBtaW49IjAiIG1heD0iMjAiPjwvbGFiZWw+CiAgICAgICAgPGxhYmVsPkxvZyBMZXZlbAogICAgICAgICAgPHNlbGVjdCBuYW1lPSJTVFJFQU1fUFJPWFlfTE9HX0xFVkVMIj4KICAgICAgICAgICAgPG9wdGlvbj5ERUJVRzwvb3B0aW9uPjxvcHRpb24+SU5GTzwvb3B0aW9uPjxvcHRpb24+V0FSTklORzwvb3B0aW9uPjxvcHRpb24+RVJST1I8L29wdGlvbj4KICAgICAgICAgIDwvc2VsZWN0PgogICAgICAgIDwvbGFiZWw+CiAgICAgICAgPGxhYmVsPlVzZXIgQWdlbnQ8aW5wdXQgbmFtZT0iU1RSRUFNX1BST1hZX1VTRVJfQUdFTlQiIHBsYWNlaG9sZGVyPSJNb3ppbGxhLzUuMCAuLi4iPjwvbGFiZWw+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1hY3Rpb25zIj4KICAgICAgICAgIDxidXR0b24gdHlwZT0ic3VibWl0IiBjbGFzcz0icHJpbWFyeSI+U3BlaWNoZXJuPC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InJlc3RhcnRQcm94eUJ0biI+UHJveHkgbmV1c3RhcnRlbjwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICA8L2Zvcm0+CiAgICAgIDxwcmUgaWQ9InByb3h5U2F2ZVJlc3VsdCIgY2xhc3M9InJlc3VsdCBtdXRlZCI+PC9wcmU+CiAgICA8L3NlY3Rpb24+CgogICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQiPgogICAgICA8aDI+WVR1bmVyIEtvbmZpZ3VyYXRpb24gKHJlYWQtb25seSDDnGJlcmJsaWNrKTwvaDI+CiAgICAgIDxkaXYgaWQ9ImNvbmZpZ1ZpZXciIGNsYXNzPSJrdiI+PC9kaXY+CiAgICAgIDxwIGNsYXNzPSJtdXRlZCBzbWFsbCI+RGF0ZWliYXNpZXJ0ZSBLZXJua29uZmlndXJhdGlvbmVuIHdlcmRlbiBhbmdlemVpZ3Q7IEJlYXJiZWl0dW5nIGVyZm9sZ3Qgd2VpdGVyaGluIMO8YmVyIGRpZSBJTkktRGF0ZWllbi9FbnYtRGF0ZWkgYW0gU2VydmVyLjwvcD4KICAgIDwvc2VjdGlvbj4KCiAgICA8c2VjdGlvbiBjbGFzcz0iY2FyZCB3aWRlIj4KICAgICAgPGgyPkF1dG90ZXN0IC8gRGlhZ25vc2U8L2gyPgogICAgICA8ZGl2IGlkPSJ0ZXN0U3VtbWFyeSIgY2xhc3M9Im11dGVkIj5Ob2NoIGtlaW5lIFRlc3RzIGF1c2dlZsO8aHJ0LjwvZGl2PgogICAgICA8ZGl2IGlkPSJ0ZXN0UmVzdWx0cyIgY2xhc3M9InRlc3QtcmVzdWx0cyI+PC9kaXY+CiAgICA8L3NlY3Rpb24+CgogICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQgd2lkZSI+CiAgICAgIDxoMj5Mb2dzPC9oMj4KICAgICAgPGRpdiBjbGFzcz0idGFicyI+CiAgICAgICAgPGJ1dHRvbiBkYXRhLWxvZz0ieXR1bmVyIiBjbGFzcz0idGFiIGFjdGl2ZSI+eXR1bmVyLmxvZzwvYnV0dG9uPgogICAgICAgIDxidXR0b24gZGF0YS1sb2c9InByb3h5IiBjbGFzcz0idGFiIj5zdHJlYW0tcHJveHkubG9nPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBpZD0icmVmcmVzaExvZ3NCdG4iPkxvZ3MgbGFkZW48L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxwcmUgaWQ9ImxvZ1ZpZXciIGNsYXNzPSJsb2ciPkxhZGUuLi48L3ByZT4KICAgIDwvc2VjdGlvbj4KICA8L21haW4+CgogIDxzY3JpcHQgc3JjPSIvYXBwLmpzIj48L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg=='
WEB_CSS_B64='OnJvb3R7LS1iZzojZjRmNmYxOy0tY2FyZDojZmZmZWY5Oy0taW5rOiMxZDJhMWY7LS1tdXRlZDojNWY2ZTYxOy0tbGluZTojZDdkZGQyOy0tYWNjZW50OiMxZjdhNGQ7LS1hY2NlbnQyOiNjNzViMmM7LS1iYWQ6I2IzMjYxZTstLW9rOiMxYjdmM2E7LS1tb25vOnVpLW1vbm9zcGFjZSxTRk1vbm8tUmVndWxhcixNZW5sbyxtb25vc3BhY2U7LS1zYW5zOiJJQk0gUGxleCBTYW5zIiwiQXZlbmlyIE5leHQiLCJTZWdvZSBVSSIsc2Fucy1zZXJpZn0KKntib3gtc2l6aW5nOmJvcmRlci1ib3h9Ym9keXttYXJnaW46MDtmb250LWZhbWlseTp2YXIoLS1zYW5zKTtjb2xvcjp2YXIoLS1pbmspO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE4MGRlZywjZWVmNGVhIDAlLHZhcigtLWJnKSAxNDBweCl9Ci50b3BiYXJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxNnB4O3BhZGRpbmc6MjRweCAyNHB4IDhweDthbGlnbi1pdGVtczpmbGV4LWVuZH0KaDF7bWFyZ2luOjA7Zm9udC1zaXplOjJyZW07bGV0dGVyLXNwYWNpbmc6LS4wMmVtfWgye21hcmdpbjowIDAgMTJweDtmb250LXNpemU6MS4wNXJlbX0KLm11dGVke2NvbG9yOnZhcigtLW11dGVkKX0uc21hbGx7Zm9udC1zaXplOi44OHJlbX0KLmdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoMixtaW5tYXgoMCwxZnIpKTtnYXA6MTZweDtwYWRkaW5nOjE2cHggMjRweCAzMnB4fQouY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTZweDtib3gtc2hhZG93OjAgMXB4IDAgcmdiYSgwLDAsMCwuMDIpfQouY2FyZC53aWRle2dyaWQtY29sdW1uOjEvLTF9Ci5hY3Rpb25zLC5mb3JtLWFjdGlvbnMsLnRhYnN7ZGlzcGxheTpmbGV4O2dhcDo4cHg7ZmxleC13cmFwOndyYXB9CmJ1dHRvbntib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JhY2tncm91bmQ6I2ZmZjtjb2xvcjp2YXIoLS1pbmspO3BhZGRpbmc6OHB4IDEycHg7Ym9yZGVyLXJhZGl1czoxMHB4O2N1cnNvcjpwb2ludGVyO2ZvbnQ6aW5oZXJpdH0KYnV0dG9uLnByaW1hcnl7YmFja2dyb3VuZDp2YXIoLS1hY2NlbnQpO2NvbG9yOiNmZmY7Ym9yZGVyLWNvbG9yOnZhcigtLWFjY2VudCl9CmJ1dHRvbjpob3ZlcntmaWx0ZXI6YnJpZ2h0bmVzcyguOTgpfQoubGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4fQouaXRlbXtkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6I2ZmZn0KLmJhZGdle3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjk5OXB4O2ZvbnQtc2l6ZTouNzhyZW07Zm9udC13ZWlnaHQ6NjAwfS5va3tiYWNrZ3JvdW5kOiNlOGY1ZWI7Y29sb3I6dmFyKC0tb2spfS5iYWR7YmFja2dyb3VuZDojZmRlY2ViO2NvbG9yOnZhcigtLWJhZCl9Lndhcm57YmFja2dyb3VuZDojZmZmNGRkO2NvbG9yOiM4YTVhMDB9Ci5mb3Jte2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsbWlubWF4KDAsMWZyKSk7Z2FwOjEwcHh9CmxhYmVse2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjRweDtmb250LXNpemU6LjlyZW19CmlucHV0LHNlbGVjdHtwYWRkaW5nOjhweCAxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udDppbmhlcml0O2JhY2tncm91bmQ6I2ZmZn0KLmZvcm0tYWN0aW9uc3tncmlkLWNvbHVtbjoxLy0xO21hcmdpbi10b3A6NHB4fQoua3Z7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxODBweCAxZnI7Z2FwOjZweCAxMnB4O2ZvbnQtc2l6ZTouOTJyZW19Ci5rdiAua3tjb2xvcjp2YXIoLS1tdXRlZCl9Lmt2IC52e2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO3dvcmQtYnJlYWs6YnJlYWstd29yZH0KLnJlc3VsdCwubG9ne2JhY2tncm91bmQ6IzFhMjExYjtjb2xvcjojZGNlN2RjO3BhZGRpbmc6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6YXV0bztmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6Ljg1cmVtO2xpbmUtaGVpZ2h0OjEuNDV9Ci5sb2d7bWluLWhlaWdodDoyNjBweDttYXgtaGVpZ2h0OjQyMHB4fS5yZXN1bHR7bWluLWhlaWdodDo0NHB4fQoudGVzdC1yZXN1bHRze2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhweDttYXJnaW4tdG9wOjEwcHh9Ci50ZXN0e2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDtiYWNrZ3JvdW5kOiNmZmZ9Ci50ZXN0IC5oZWFke2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtmb250LXdlaWdodDo2MDB9Ci50ZXN0IHByZXttYXJnaW46OHB4IDAgMDtiYWNrZ3JvdW5kOiNmNmY4ZjQ7Y29sb3I6IzIxMztwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtvdmVyZmxvdzphdXRvO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZTouOHJlbX0KLnRhYi5hY3RpdmV7YmFja2dyb3VuZDojZThmNWViO2JvcmRlci1jb2xvcjojYjlkN2MzfQpAbWVkaWEgKG1heC13aWR0aDo5MDBweCl7LmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0uZm9ybXtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS50b3BiYXJ7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOnN0cmV0Y2h9fQo='
WEB_JS_B64='YXN5bmMgZnVuY3Rpb24gYXBpKHBhdGgsIG9wdHM9e30pIHsKICBjb25zdCByZXMgPSBhd2FpdCBmZXRjaChwYXRoLCB7aGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nLCAuLi4ob3B0cy5oZWFkZXJzfHx7fSl9LCAuLi5vcHRzfSk7CiAgY29uc3QgdGV4dCA9IGF3YWl0IHJlcy50ZXh0KCk7CiAgbGV0IGRhdGE7IHRyeSB7IGRhdGEgPSBKU09OLnBhcnNlKHRleHQpOyB9IGNhdGNoIHsgZGF0YSA9IHtyYXc6dGV4dH07IH0KICBpZiAoIXJlcy5vaykgdGhyb3cgT2JqZWN0LmFzc2lnbihuZXcgRXJyb3IoZGF0YS5lcnJvciB8fCByZXMuc3RhdHVzVGV4dCksIHtkYXRhLCBzdGF0dXM6cmVzLnN0YXR1c30pOwogIHJldHVybiBkYXRhOwp9CmNvbnN0ICQgPSAocyk9PmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3Iocyk7CmNvbnN0IGVzYyA9IChzKT0+U3RyaW5nKHM/PycnKS5yZXBsYWNlKC9bJjw+IiddL2csYz0+KHsnJic6JyZhbXA7JywnPCc6JyZsdDsnLCc+JzonJmd0OycsJyInOicmcXVvdDsnLCInIjonJiMzOTsnfVtjXSkpOwpmdW5jdGlvbiBiYWRnZShvaywgdGV4dCl7IGNvbnN0IGNscyA9IG9rPT09dHJ1ZT8nb2snOm9rPT09ZmFsc2U/J2JhZCc6J3dhcm4nOyByZXR1cm4gYDxzcGFuIGNsYXNzPSJiYWRnZSAke2Nsc30iPiR7ZXNjKHRleHQpfTwvc3Bhbj5gOyB9Cgphc3luYyBmdW5jdGlvbiBsb2FkU3RhdHVzKCl7CiAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9zdGF0dXMnKTsKICBjb25zdCBzdmMgPSBkLnNlcnZpY2VzfHxbXTsKICBjb25zdCBwb3J0cyA9IGQucG9ydHN8fFtdOwogICQoJyNzdGF0dXNTdW1tYXJ5JykuaW5uZXJIVE1MID0gYEFrdHVhbGlzaWVydDogJHtuZXcgRGF0ZSgpLnRvTG9jYWxlU3RyaW5nKCl9IHwgQVBJIG9rYDsKICAkKCcjc2VydmljZXMnKS5pbm5lckhUTUwgPSBzdmMubWFwKHM9PmA8ZGl2IGNsYXNzPSJpdGVtIj48ZGl2PjxzdHJvbmc+JHtlc2Mocy5uYW1lKX08L3N0cm9uZz48ZGl2IGNsYXNzPSJtdXRlZCBzbWFsbCI+JHtlc2MoSlNPTi5zdHJpbmdpZnkocy5wcm9wc3x8e30pKX08L2Rpdj48L2Rpdj48ZGl2PiR7YmFkZ2Uocy5hY3RpdmU9PT0nYWN0aXZlJywgcy5hY3RpdmUpfSAke2JhZGdlKHMuZW5hYmxlZD09PSdlbmFibGVkJ3x8cy5lbmFibGVkPT09J3N0YXRpYycsIHMuZW5hYmxlZCl9PC9kaXY+PC9kaXY+YCkuam9pbignJyk7CiAgJCgnI3BvcnRzJykuaW5uZXJIVE1MID0gcG9ydHMubWFwKHA9PmA8ZGl2IGNsYXNzPSJpdGVtIj48ZGl2PjxzdHJvbmc+UG9ydCAke2VzYyhwLnBvcnQpfTwvc3Ryb25nPjwvZGl2PiR7YmFkZ2UocC5vcGVuLCBwLm9wZW4/J29wZW4nOidjbG9zZWQnKX08L2Rpdj5gKS5qb2luKCcnKTsKICByZW5kZXJDb25maWcoZC5jb25maWd8fHt9KTsKICBmaWxsUHJveHlGb3JtKChkLmNvbmZpZ3x8e30pLnByb3h5fHx7fSk7Cn0KZnVuY3Rpb24gcmVuZGVyQ29uZmlnKGNmZyl7CiAgY29uc3Qgcm93cz1bXTsKICBjb25zdCBhZGQ9KGssdik9PnJvd3MucHVzaChgPGRpdiBjbGFzcz0iayI+JHtlc2Moayl9PC9kaXY+PGRpdiBjbGFzcz0idiI+JHtlc2ModHlwZW9mIHY9PT0nb2JqZWN0Jz9KU09OLnN0cmluZ2lmeSh2KTp2KX08L2Rpdj5gKTsKICBhZGQoJ2luc3RhbGxfZGlyJywgY2ZnLnBhdGhzPy5pbnN0YWxsX2Rpcik7CiAgYWRkKCd5dHVuZXIuaW5pJywgY2ZnLnBhdGhzPy55dHVuZXJfaW5pKTsKICBhZGQoJ2F2ci5pbmknLCBjZmcucGF0aHM/LmF2cl9pbmkpOwogIGFkZCgnc3RhdGlvbnMuaW5pJywgY2ZnLnBhdGhzPy5zdGF0aW9uc19pbmkpOwogIGFkZCgncHJveHlfZW52JywgY2ZnLnBhdGhzPy5wcm94eV9lbnYpOwogIGFkZCgneXR1bmVyLndlYl9wb3J0JywgY2ZnLnl0dW5lcj8ud2ViX3BvcnQpOwogIGFkZCgneXR1bmVyLmRuc19wb3J0JywgY2ZnLnl0dW5lcj8uZG5zX3BvcnQpOwogIGFkZCgneXR1bmVyLmludGVyY2VwdF9kbnMnLCBjZmcueXR1bmVyPy5pbnRlcmNlcHRfZG5zKTsKICBhZGQoJ3l0dW5lci5yYl9jYWNoZV90eXBlJywgY2ZnLnl0dW5lcj8ucmJfY2FjaGVfdHlwZSk7CiAgYWRkKCdhdnIucHJvdG9jb2wnLCBjZmcuYXZyPy5wcm90b2NvbCk7CiAgJCgnI2NvbmZpZ1ZpZXcnKS5pbm5lckhUTUwgPSByb3dzLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbGxQcm94eUZvcm0ocHJveHkpewogIGNvbnN0IGYgPSAkKCcjcHJveHlGb3JtJyk7CiAgZm9yIChjb25zdCBbayx2XSBvZiBPYmplY3QuZW50cmllcyhwcm94eXx8e30pKXsKICAgIGNvbnN0IGtleSA9ICdTVFJFQU1fUFJPWFlfJyArIGsudG9VcHBlckNhc2UoKTsKICAgIGNvbnN0IGVsID0gZi5lbGVtZW50cy5uYW1lZEl0ZW0oa2V5KTsKICAgIGlmIChlbCkgZWwudmFsdWUgPSB2OwogIH0KfQphc3luYyBmdW5jdGlvbiBzYXZlUHJveHkoZXYpewogIGV2LnByZXZlbnREZWZhdWx0KCk7CiAgY29uc3QgZmQgPSBuZXcgRm9ybURhdGEoZXYudGFyZ2V0KTsKICBjb25zdCBwYXlsb2FkID0gT2JqZWN0LmZyb21FbnRyaWVzKGZkLmVudHJpZXMoKSk7CiAgJCgnI3Byb3h5U2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gJ1NwZWljaGVyZS4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBhcGkoJy9hcGkvY29uZmlnL3Byb3h5Jywge21ldGhvZDonUE9TVCcsIGJvZHk6SlNPTi5zdHJpbmdpZnkocGF5bG9hZCl9KTsKICAgICQoJyNwcm94eVNhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IEpTT04uc3RyaW5naWZ5KGQsIG51bGwsIDIpOwogICAgYXdhaXQgbG9hZFN0YXR1cygpOwogIH0gY2F0Y2goZSl7ICQoJyNwcm94eVNhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IEpTT04uc3RyaW5naWZ5KGUuZGF0YXx8e2Vycm9yOmUubWVzc2FnZX0sIG51bGwsIDIpOyB9Cn0KYXN5bmMgZnVuY3Rpb24gcmVzdGFydFByb3h5KCl7CiAgJCgnI3Byb3h5U2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gJ1N0YXJ0ZSBQcm94eSBuZXUuLi4nOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgYXBpKCcvYXBpL3NlcnZpY2UvcmVzdGFydCcsIHttZXRob2Q6J1BPU1QnLCBib2R5OkpTT04uc3RyaW5naWZ5KHtuYW1lOid5dHVuZXItc3RyZWFtLXByb3h5J30pfSk7CiAgICAkKCcjcHJveHlTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSBKU09OLnN0cmluZ2lmeShkLCBudWxsLCAyKTsKICAgIGF3YWl0IGxvYWRTdGF0dXMoKTsKICB9IGNhdGNoKGUpeyAkKCcjcHJveHlTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSBKU09OLnN0cmluZ2lmeShlLmRhdGF8fHtlcnJvcjplLm1lc3NhZ2V9LCBudWxsLCAyKTsgfQp9CmFzeW5jIGZ1bmN0aW9uIHJ1blRlc3RzKCl7CiAgJCgnI3Rlc3RTdW1tYXJ5JykudGV4dENvbnRlbnQgPSAnVGVzdHMgbGF1ZmVuLi4uJzsKICAkKCcjdGVzdFJlc3VsdHMnKS5pbm5lckhUTUwgPSAnJzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS90ZXN0cy9ydW4nLCB7bWV0aG9kOidQT1NUJ30pOwogICAgcmVuZGVyVGVzdHMoZCk7CiAgfSBjYXRjaChlKXsgJCgnI3Rlc3RTdW1tYXJ5JykudGV4dENvbnRlbnQgPSAnRmVobGVyOiAnICsgZS5tZXNzYWdlOyB9Cn0KZnVuY3Rpb24gcmVuZGVyVGVzdHMoZCl7CiAgJCgnI3Rlc3RTdW1tYXJ5JykuaW5uZXJIVE1MID0gYCR7YmFkZ2UoZC5vaywgZC5vaz8nUEFTUyc6J0ZBSUwnKX0gJHtkLnBhc3NlZH0vJHtkLnRvdGFsfSBiZXN0YW5kZW4sICR7ZC5mYWlsZWR9IGZlaGxnZXNjaGxhZ2VuYDsKICAkKCcjdGVzdFJlc3VsdHMnKS5pbm5lckhUTUwgPSAoZC5yZXN1bHRzfHxbXSkubWFwKHI9PmA8ZGl2IGNsYXNzPSJ0ZXN0Ij48ZGl2IGNsYXNzPSJoZWFkIj48c3Bhbj4ke2VzYyhyLm5hbWUpfTwvc3Bhbj4ke2JhZGdlKHIub2ssci5vaz8nb2snOidmYWlsJyl9PC9kaXY+PHByZT4ke2VzYyhKU09OLnN0cmluZ2lmeShyLmRldGFpbCwgbnVsbCwgMikpfTwvcHJlPjwvZGl2PmApLmpvaW4oJycpOwp9CmxldCBjdXJyZW50TG9nPSd5dHVuZXInOwphc3luYyBmdW5jdGlvbiBsb2FkTG9ncyhuYW1lPWN1cnJlbnRMb2cpewogIGN1cnJlbnRMb2c9bmFtZTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudGFiW2RhdGEtbG9nXScpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBiLmRhdGFzZXQubG9nPT09bmFtZSkpOwogICQoJyNsb2dWaWV3JykudGV4dENvbnRlbnQgPSAnTGFkZS4uLic7CiAgdHJ5IHsgY29uc3QgZCA9IGF3YWl0IGFwaShgL2FwaS9sb2dzP25hbWU9JHtlbmNvZGVVUklDb21wb25lbnQobmFtZSl9JmxpbmVzPTIwMGApOyAkKCcjbG9nVmlldycpLnRleHRDb250ZW50ID0gZC5jb250ZW50IHx8ICcobGVlciknOyB9CiAgY2F0Y2goZSl7ICQoJyNsb2dWaWV3JykudGV4dENvbnRlbnQgPSAnRmVobGVyOiAnK2UubWVzc2FnZTsgfQp9CgokKCcjcmVmcmVzaEJ0bicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCk9PmxvYWRTdGF0dXMoKS5jYXRjaChlPT4kKCcjc3RhdHVzU3VtbWFyeScpLnRleHRDb250ZW50PWUubWVzc2FnZSkpOwokKCcjcnVuVGVzdHNCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIHJ1blRlc3RzKTsKJCgnI3Byb3h5Rm9ybScpLmFkZEV2ZW50TGlzdGVuZXIoJ3N1Ym1pdCcsIHNhdmVQcm94eSk7CiQoJyNyZXN0YXJ0UHJveHlCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIHJlc3RhcnRQcm94eSk7CiQoJyNyZWZyZXNoTG9nc0J0bicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCk9PmxvYWRMb2dzKGN1cnJlbnRMb2cpKTsKZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRhYltkYXRhLWxvZ10nKS5mb3JFYWNoKGI9PmIuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+bG9hZExvZ3MoYi5kYXRhc2V0LmxvZykpKTsKCmxvYWRTdGF0dXMoKS5jYXRjaChlPT4kKCcjc3RhdHVzU3VtbWFyeScpLnRleHRDb250ZW50PSdGZWhsZXI6ICcrZS5tZXNzYWdlKTsKbG9hZExvZ3MoJ3l0dW5lcicpLmNhdGNoKCgpPT57fSk7Cg=='

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
