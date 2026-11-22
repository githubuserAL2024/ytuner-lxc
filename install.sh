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
ADMIN_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRpbWUKZnJvbSBodHRwIGltcG9ydCBIVFRQU3RhdHVzCmZyb20gaHR0cC5zZXJ2ZXIgaW1wb3J0IEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIsIFRocmVhZGluZ0hUVFBTZXJ2ZXIKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gdXJsbGliLnBhcnNlIGltcG9ydCBwYXJzZV9xcywgdXJsc3BsaXQKCgpJTlNUQUxMX0RJUiA9IFBhdGgob3MuZW52aXJvbi5nZXQoIllUVU5FUl9JTlNUQUxMX0RJUiIsICIvb3B0L3l0dW5lciIpKQpDT05GSUdfRElSID0gSU5TVEFMTF9ESVIgLyAiY29uZmlnIgpZVFVORVJfSU5JID0gSU5TVEFMTF9ESVIgLyAieXR1bmVyLmluaSIKQVZSX0lOSSA9IENPTkZJR19ESVIgLyAiYXZyLmluaSIKU1RBVElPTlNfSU5JID0gQ09ORklHX0RJUiAvICJzdGF0aW9ucy5pbmkiClBST1hZX0VOViA9IFBhdGgoIi9ldGMvZGVmYXVsdC95dHVuZXItc3RyZWFtLXByb3h5IikKUFJPWFlfU0NSSVBUID0gSU5TVEFMTF9ESVIgLyAieXR1bmVyLXN0cmVhbS1wcm94eS5weSIKV0VCX0RJUiA9IFBhdGgob3MuZW52aXJvbi5nZXQoIllUVU5FUl9BRE1JTl9XRUJfRElSIiwgIi9vcHQveXR1bmVyL3dlYnVpIikpCkxPR19GSUxFUyA9IHsKICAgICJ5dHVuZXIiOiBQYXRoKCIvdmFyL2xvZy95dHVuZXIubG9nIiksCiAgICAicHJveHkiOiBQYXRoKCIvdmFyL2xvZy95dHVuZXItc3RyZWFtLXByb3h5LmxvZyIpLAogICAgImFkbWluIjogUGF0aCgiL3Zhci9sb2cveXR1bmVyLWFkbWluLmxvZyIpLAp9ClNFUlZJQ0VTID0gWyJ5dHVuZXIiLCAieXR1bmVyLXN0cmVhbS1wcm94eSIsICJ5dHVuZXItYWRtaW4iXQpBTExPV19TWVNURU1DVEwgPSBvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0FETUlOX0FMTE9XX1NZU1RFTUNUTCIsICIxIikgIT0gIjAiCkhPU1QgPSBvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0FETUlOX0hPU1QiLCAiMC4wLjAuMCIpClBPUlQgPSBpbnQob3MuZW52aXJvbi5nZXQoIllUVU5FUl9BRE1JTl9QT1JUIiwgIjgwOTEiKSkKVE9LRU4gPSBvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0FETUlOX1RPS0VOIiwgIiIpCgoKZGVmIHJ1bl9jbWQoY21kOiBsaXN0W3N0cl0sIHRpbWVvdXQ6IGZsb2F0ID0gMjAuMCkgLT4gZGljdDoKICAgIHRyeToKICAgICAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oY21kLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9dGltZW91dCwgY2hlY2s9RmFsc2UpCiAgICAgICAgcmV0dXJuIHsKICAgICAgICAgICAgIm9rIjogcHJvYy5yZXR1cm5jb2RlID09IDAsCiAgICAgICAgICAgICJyYyI6IHByb2MucmV0dXJuY29kZSwKICAgICAgICAgICAgInN0ZG91dCI6IHByb2Muc3Rkb3V0Wy04MDAwOl0sCiAgICAgICAgICAgICJzdGRlcnIiOiBwcm9jLnN0ZGVyclstODAwMDpdLAogICAgICAgICAgICAiY21kIjogY21kLAogICAgICAgIH0KICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICByZXR1cm4geyJvayI6IEZhbHNlLCAicmMiOiAtMSwgInN0ZG91dCI6ICIiLCAic3RkZXJyIjogc3RyKGV4YyksICJjbWQiOiBjbWR9CgoKZGVmIHJlYWRfdGV4dChwYXRoOiBQYXRoKSAtPiBzdHI6CiAgICBpZiBub3QgcGF0aC5leGlzdHMoKToKICAgICAgICByZXR1cm4gIiIKICAgIHJldHVybiBwYXRoLnJlYWRfdGV4dChlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKQoKCmRlZiB3cml0ZV90ZXh0X2F0b21pYyhwYXRoOiBQYXRoLCBjb250ZW50OiBzdHIpIC0+IE5vbmU6CiAgICBwYXRoLnBhcmVudC5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCiAgICB0bXAgPSBwYXRoLndpdGhfc3VmZml4KHBhdGguc3VmZml4ICsgIi50bXAiKQogICAgdG1wLndyaXRlX3RleHQoY29udGVudCwgZW5jb2Rpbmc9InV0Zi04IikKICAgIHRtcC5yZXBsYWNlKHBhdGgpCgoKZGVmIGluaV9nZXQoY29udGVudDogc3RyLCBzZWN0aW9uOiBzdHIsIGtleTogc3RyLCBkZWZhdWx0OiBzdHIgPSAiIikgLT4gc3RyOgogICAgaW5fc2VjdGlvbiA9IEZhbHNlCiAgICBzZWNfcmUgPSByZS5jb21waWxlKHIiXlxzKlxbKC4rPylcXVxzKiQiKQogICAga3ZfcmUgPSByZS5jb21waWxlKHIiXlxzKihbXjsjPVxzXVtePV0qPylccyo9XHMqKC4qPylccyokIikKICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIG0gPSBzZWNfcmUubWF0Y2gobGluZSkKICAgICAgICBpZiBtOgogICAgICAgICAgICBpbl9zZWN0aW9uID0gbS5ncm91cCgxKS5zdHJpcCgpLmxvd2VyKCkgPT0gc2VjdGlvbi5sb3dlcigpCiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaWYgbm90IGluX3NlY3Rpb246CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAga20gPSBrdl9yZS5tYXRjaChsaW5lKQogICAgICAgIGlmIGttIGFuZCBrbS5ncm91cCgxKS5zdHJpcCgpLmxvd2VyKCkgPT0ga2V5Lmxvd2VyKCk6CiAgICAgICAgICAgIHJldHVybiBrbS5ncm91cCgyKQogICAgcmV0dXJuIGRlZmF1bHQKCgpkZWYgZW52X3BhcnNlKGNvbnRlbnQ6IHN0cikgLT4gZGljdFtzdHIsIHN0cl06CiAgICBvdXQ6IGRpY3Rbc3RyLCBzdHJdID0ge30KICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaywgdiA9IGxpbmUuc3BsaXQoIj0iLCAxKQogICAgICAgIG91dFtrLnN0cmlwKCldID0gdi5zdHJpcCgpLnN0cmlwKCciJykuc3RyaXAoIiciKQogICAgcmV0dXJuIG91dAoKCmRlZiBlbnZfcmVuZGVyKGV4aXN0aW5nOiBzdHIsIHVwZGF0ZXM6IGRpY3Rbc3RyLCBzdHJdKSAtPiBzdHI6CiAgICBsaW5lcyA9IGV4aXN0aW5nLnNwbGl0bGluZXMoKSBpZiBleGlzdGluZyBlbHNlIFtdCiAgICBzZWVuOiBzZXRbc3RyXSA9IHNldCgpCiAgICBvdXQ6IGxpc3Rbc3RyXSA9IFtdCiAgICBmb3IgbGluZSBpbiBsaW5lczoKICAgICAgICBpZiAiPSIgaW4gbGluZSBhbmQgbm90IGxpbmUubHN0cmlwKCkuc3RhcnRzd2l0aCgiIyIpOgogICAgICAgICAgICBrID0gbGluZS5zcGxpdCgiPSIsIDEpWzBdLnN0cmlwKCkKICAgICAgICAgICAga3UgPSBrLnVwcGVyKCkKICAgICAgICAgICAgaWYga3UgaW4gdXBkYXRlczoKICAgICAgICAgICAgICAgIG91dC5hcHBlbmQoZiJ7a309e3VwZGF0ZXNba3VdfSIpCiAgICAgICAgICAgICAgICBzZWVuLmFkZChrdSkKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgb3V0LmFwcGVuZChsaW5lKQogICAgZm9yIGssIHYgaW4gdXBkYXRlcy5pdGVtcygpOgogICAgICAgIGlmIGsgbm90IGluIHNlZW46CiAgICAgICAgICAgIG91dC5hcHBlbmQoZiJ7a309e3Z9IikKICAgIHJldHVybiAiXG4iLmpvaW4ob3V0KS5yc3RyaXAoKSArICJcbiIKCgpkZWYgc2VydmljZV9zdGF0dXMobmFtZTogc3RyKSAtPiBkaWN0OgogICAgaWYgbm90IEFMTE9XX1NZU1RFTUNUTCBvciBzaHV0aWwud2hpY2goInN5c3RlbWN0bCIpIGlzIE5vbmU6CiAgICAgICAgYWN0aXZlID0gcnVuX2NtZChbInNoIiwgIi1sYyIsIGYicGdyZXAgLWFmIHtuYW1lfSA+L2Rldi9udWxsICYmIGVjaG8gYWN0aXZlIHx8IGVjaG8gaW5hY3RpdmUiXSwgdGltZW91dD01KQogICAgICAgIHJldHVybiB7Im5hbWUiOiBuYW1lLCAiYWN0aXZlIjogYWN0aXZlWyJzdGRvdXQiXS5zdHJpcCgpLCAiZW5hYmxlZCI6ICJ1bmtub3duIiwgImRldGFpbCI6IGFjdGl2ZX0KICAgIGFjdGl2ZSA9IHJ1bl9jbWQoWyJzeXN0ZW1jdGwiLCAiaXMtYWN0aXZlIiwgbmFtZV0sIHRpbWVvdXQ9MTApCiAgICBlbmFibGVkID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJpcy1lbmFibGVkIiwgbmFtZV0sIHRpbWVvdXQ9MTApCiAgICBzaG93ID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJzaG93IiwgbmFtZSwgIi0tcHJvcGVydHk9QWN0aXZlU3RhdGUsU3ViU3RhdGUsVW5pdEZpbGVTdGF0ZSxNYWluUElELEV4ZWNNYWluU3RhdHVzIl0sIHRpbWVvdXQ9MTApCiAgICBwcm9wcyA9IHt9CiAgICBmb3IgbGluZSBpbiBzaG93WyJzdGRvdXQiXS5zcGxpdGxpbmVzKCk6CiAgICAgICAgaWYgIj0iIGluIGxpbmU6CiAgICAgICAgICAgIGssIHYgPSBsaW5lLnNwbGl0KCI9IiwgMSkKICAgICAgICAgICAgcHJvcHNbay5zdHJpcCgpXSA9IHYuc3RyaXAoKQogICAgcmV0dXJuIHsKICAgICAgICAibmFtZSI6IG5hbWUsCiAgICAgICAgImFjdGl2ZSI6IGFjdGl2ZVsic3Rkb3V0Il0uc3RyaXAoKSBvciBwcm9wcy5nZXQoIkFjdGl2ZVN0YXRlIiwgInVua25vd24iKSwKICAgICAgICAiZW5hYmxlZCI6IGVuYWJsZWRbInN0ZG91dCJdLnN0cmlwKCkgb3IgcHJvcHMuZ2V0KCJVbml0RmlsZVN0YXRlIiwgInVua25vd24iKSwKICAgICAgICAicHJvcHMiOiBwcm9wcywKICAgIH0KCgpkZWYgcG9ydF9jaGVjayhwb3J0OiBpbnQsIGhvc3Q6IHN0ciA9ICIxMjcuMC4wLjEiKSAtPiBkaWN0OgogICAgaW1wb3J0IHNvY2tldAoKICAgIHMgPSBzb2NrZXQuc29ja2V0KCkKICAgIHMuc2V0dGltZW91dCgxLjUpCiAgICB0cnk6CiAgICAgICAgcy5jb25uZWN0KChob3N0LCBwb3J0KSkKICAgICAgICBzLmNsb3NlKCkKICAgICAgICByZXR1cm4geyJwb3J0IjogcG9ydCwgIm9wZW4iOiBUcnVlfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7InBvcnQiOiBwb3J0LCAib3BlbiI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKX0KICAgIGZpbmFsbHk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzLmNsb3NlKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCgoKZGVmIGh0dHBfY2hlY2sodXJsOiBzdHIsIHRpbWVvdXQ6IGZsb2F0ID0gNS4wKSAtPiBkaWN0OgogICAgZnJvbSB1cmxsaWIucmVxdWVzdCBpbXBvcnQgUmVxdWVzdCwgdXJsb3BlbgoKICAgIHJlcSA9IFJlcXVlc3QodXJsLCBoZWFkZXJzPXsiVXNlci1BZ2VudCI6ICJ5dHVuZXItYWRtaW4vMC4xIn0pCiAgICB0MCA9IHRpbWUudGltZSgpCiAgICB0cnk6CiAgICAgICAgd2l0aCB1cmxvcGVuKHJlcSwgdGltZW91dD10aW1lb3V0KSBhcyByZXNwOgogICAgICAgICAgICBib2R5ID0gcmVzcC5yZWFkKDUxMikKICAgICAgICAgICAgcmV0dXJuIHsKICAgICAgICAgICAgICAgICJ1cmwiOiB1cmwsCiAgICAgICAgICAgICAgICAib2siOiAyMDAgPD0gZ2V0YXR0cihyZXNwLCAic3RhdHVzIiwgMjAwKSA8IDUwMCwKICAgICAgICAgICAgICAgICJzdGF0dXMiOiBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApLAogICAgICAgICAgICAgICAgIm1zIjogaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApLAogICAgICAgICAgICAgICAgImJ5dGVzIjogbGVuKGJvZHkpLAogICAgICAgICAgICB9CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4YyksICJtcyI6IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKX0KCgpkZWYgY2hlY2tfc3RyZWFtX3VybCh1cmw6IHN0ciwgdGltZW91dDogZmxvYXQgPSA2LjApIC0+IGRpY3Q6CiAgICAiIiJDaGVjayBpZiBhIHJhZGlvIHN0cmVhbSBVUkwgaXMgcmVhY2hhYmxlLiBSZXR1cm5zIHN0YXR1cy9jb250ZW50LXR5cGUgaW5mby4iIiIKICAgIGZyb20gdXJsbGliLnJlcXVlc3QgaW1wb3J0IFJlcXVlc3QsIHVybG9wZW4KICAgIGZyb20gdXJsbGliLmVycm9yIGltcG9ydCBIVFRQRXJyb3IsIFVSTEVycm9yCgogICAgdXJsID0gKHVybCBvciAiIikuc3RyaXAoKQogICAgaWYgbm90IHVybDoKICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJyZWFjaGFibGUiOiBGYWxzZSwgImVycm9yIjogImVtcHR5IHVybCJ9CiAgICAjIGFsbG93IG9ubHkgaHR0cC9odHRwcwogICAgaWYgbm90IHJlLm1hdGNoKHInXmh0dHBzPzovLycsIHVybCwgcmUuSSk6CiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAicmVhY2hhYmxlIjogRmFsc2UsICJlcnJvciI6ICJvbmx5IGh0dHAvaHR0cHMgc3VwcG9ydGVkIn0KCiAgICByZXEgPSBSZXF1ZXN0KHVybCwgaGVhZGVycz17IlVzZXItQWdlbnQiOiAieXR1bmVyLWFkbWluLzAuMSIsICJJY3ktTWV0YURhdGEiOiAiMSJ9LCBtZXRob2Q9IkdFVCIpCiAgICB0MCA9IHRpbWUudGltZSgpCiAgICB0cnk6CiAgICAgICAgd2l0aCB1cmxvcGVuKHJlcSwgdGltZW91dD10aW1lb3V0KSBhcyByZXNwOgogICAgICAgICAgICBzdGF0dXMgPSBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApCiAgICAgICAgICAgIGN0eXBlID0gcmVzcC5oZWFkZXJzLmdldCgiQ29udGVudC1UeXBlIiwgIiIpCiAgICAgICAgICAgIGJvZHkgPSByZXNwLnJlYWQoMTAyNCkgICMgcmVhZCBhIHNtYWxsIGNodW5rIHRvIGNvbmZpcm0gc3RyZWFtIGZsb3dzCiAgICAgICAgICAgIG1zID0gaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApCiAgICAgICAgICAgIHJldHVybiB7CiAgICAgICAgICAgICAgICAidXJsIjogdXJsLAogICAgICAgICAgICAgICAgInJlYWNoYWJsZSI6IDIwMCA8PSBzdGF0dXMgPCA0MDAsCiAgICAgICAgICAgICAgICAic3RhdHVzIjogc3RhdHVzLAogICAgICAgICAgICAgICAgImNvbnRlbnRfdHlwZSI6IGN0eXBlLAogICAgICAgICAgICAgICAgIm1zIjogbXMsCiAgICAgICAgICAgICAgICAiYnl0ZXMiOiBsZW4oYm9keSksCiAgICAgICAgICAgIH0KICAgIGV4Y2VwdCBIVFRQRXJyb3IgYXMgZXhjOgogICAgICAgIG1zID0gaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApCiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAicmVhY2hhYmxlIjogRmFsc2UsICJzdGF0dXMiOiBleGMuY29kZSwgImVycm9yIjogc3RyKGV4Yy5yZWFzb24pLCAibXMiOiBtc30KICAgIGV4Y2VwdCBVUkxFcnJvciBhcyBleGM6CiAgICAgICAgbXMgPSBpbnQoKHRpbWUudGltZSgpIC0gdDApICogMTAwMCkKICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJyZWFjaGFibGUiOiBGYWxzZSwgImVycm9yIjogc3RyKGV4Yy5yZWFzb24pLCAibXMiOiBtc30KICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICBtcyA9IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKQogICAgICAgIHJldHVybiB7InVybCI6IHVybCwgInJlYWNoYWJsZSI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKSwgIm1zIjogbXN9CgoKZGVmIHBhcnNlX3N0YXRpb25zX2luaShjb250ZW50OiBzdHIpIC0+IGxpc3RbZGljdF06CiAgICBncm91cHM6IGxpc3RbZGljdF0gPSBbXQogICAgY3VycmVudDogZGljdCB8IE5vbmUgPSBOb25lCiAgICBmb3IgcmF3IGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIGxpbmUgPSByYXcuc3RyaXAoKQogICAgICAgIGlmIG5vdCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgiOyIpIG9yIGxpbmUuc3RhcnRzd2l0aCgiIyIpOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGlmIGxpbmUuc3RhcnRzd2l0aCgiWyIpIGFuZCBsaW5lLmVuZHN3aXRoKCJdIik6CiAgICAgICAgICAgIGN1cnJlbnQgPSB7Im5hbWUiOiBsaW5lWzE6LTFdLnN0cmlwKCksICJzdGF0aW9ucyI6IFtdfQogICAgICAgICAgICBncm91cHMuYXBwZW5kKGN1cnJlbnQpCiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaWYgIj0iIG5vdCBpbiBsaW5lOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIG5hbWUsIHZhbHVlID0gbGluZS5zcGxpdCgiPSIsIDEpCiAgICAgICAgc3RhdGlvbl9uYW1lID0gbmFtZS5zdHJpcCgpCiAgICAgICAgcmVzdCA9IHZhbHVlLnN0cmlwKCkKICAgICAgICB1cmwsIGxvZ28gPSByZXN0LCAiIgogICAgICAgIGlmICJ8IiBpbiByZXN0OgogICAgICAgICAgICB1cmwsIGxvZ28gPSByZXN0LnNwbGl0KCJ8IiwgMSkKICAgICAgICBpdGVtID0geyJuYW1lIjogc3RhdGlvbl9uYW1lLCAidXJsIjogdXJsLnN0cmlwKCksICJsb2dvIjogbG9nby5zdHJpcCgpfQogICAgICAgIGlmIGN1cnJlbnQgaXMgTm9uZToKICAgICAgICAgICAgY3VycmVudCA9IHsibmFtZSI6ICJVbmdyb3VwZWQiLCAic3RhdGlvbnMiOiBbXX0KICAgICAgICAgICAgZ3JvdXBzLmFwcGVuZChjdXJyZW50KQogICAgICAgIGN1cnJlbnRbInN0YXRpb25zIl0uYXBwZW5kKGl0ZW0pCiAgICByZXR1cm4gZ3JvdXBzCgoKZGVmIHJlbmRlcl9zdGF0aW9uc19pbmkoZ3JvdXBzOiBsaXN0W2RpY3RdKSAtPiBzdHI6CiAgICBsaW5lcyA9IFsKICAgICAgICAiOyBDdXN0b20gc3RhdGlvbnMgZm9yIFlUdW5lciBcIk15IFN0YXRpb25zXCIgbWVudS4iLAogICAgICAgICI7IEZvcm1hdDogU3RhdGlvbiBOYW1lPXN0cmVhbV91cmx8b3B0aW9uYWxfbG9nb191cmwiLAogICAgICAgICIiLAogICAgXQogICAgZm9yIGcgaW4gZ3JvdXBzOgogICAgICAgIGduYW1lID0gc3RyKGcuZ2V0KCJuYW1lIiwgIiIpKS5zdHJpcCgpIG9yICJVbmdyb3VwZWQiCiAgICAgICAgbGluZXMuYXBwZW5kKGYiW3tnbmFtZX1dIikKICAgICAgICBmb3Igc3QgaW4gZy5nZXQoInN0YXRpb25zIiwgW10pIG9yIFtdOgogICAgICAgICAgICBuYW1lID0gc3RyKHN0LmdldCgibmFtZSIsICIiKSkuc3RyaXAoKQogICAgICAgICAgICB1cmwgPSBzdHIoc3QuZ2V0KCJ1cmwiLCAiIikpLnN0cmlwKCkKICAgICAgICAgICAgbG9nbyA9IHN0cihzdC5nZXQoImxvZ28iLCAiIikpLnN0cmlwKCkKICAgICAgICAgICAgaWYgbm90IG5hbWUgb3Igbm90IHVybDoKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGlmIGFueShjIGluIG5hbWUgZm9yIGMgaW4gIlxyXG49Iikgb3IgYW55KGMgaW4gdXJsIGZvciBjIGluICJcclxufCIpIG9yIGFueShjIGluIGxvZ28gZm9yIGMgaW4gIlxyXG4iKToKICAgICAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoIkludmFsaWQgY2hhcmFjdGVycyBpbiBzdGF0aW9uIGZpZWxkcyIpCiAgICAgICAgICAgIGxpbmVzLmFwcGVuZChmIntuYW1lfT17dXJsfSIgKyAoZiJ8e2xvZ299IiBpZiBsb2dvIGVsc2UgIiIpKQogICAgICAgIGxpbmVzLmFwcGVuZCgiIikKICAgIHJldHVybiAiXG4iLmpvaW4obGluZXMpLnJzdHJpcCgpICsgIlxuIgoKCmRlZiBjb2xsZWN0X2NvbmZpZygpIC0+IGRpY3Q6CiAgICB5dHVuZXIgPSByZWFkX3RleHQoWVRVTkVSX0lOSSkKICAgIGF2ciA9IHJlYWRfdGV4dChBVlJfSU5JKQogICAgcHJveHkgPSBlbnZfcGFyc2UocmVhZF90ZXh0KFBST1hZX0VOVikpCiAgICBzdGF0aW9uc19jb250ZW50ID0gcmVhZF90ZXh0KFNUQVRJT05TX0lOSSkKICAgIHJldHVybiB7CiAgICAgICAgInBhdGhzIjogewogICAgICAgICAgICAiaW5zdGFsbF9kaXIiOiBzdHIoSU5TVEFMTF9ESVIpLAogICAgICAgICAgICAieXR1bmVyX2luaSI6IHN0cihZVFVORVJfSU5JKSwKICAgICAgICAgICAgImF2cl9pbmkiOiBzdHIoQVZSX0lOSSksCiAgICAgICAgICAgICJzdGF0aW9uc19pbmkiOiBzdHIoU1RBVElPTlNfSU5JKSwKICAgICAgICAgICAgInByb3h5X2VudiI6IHN0cihQUk9YWV9FTlYpLAogICAgICAgIH0sCiAgICAgICAgInl0dW5lciI6IHsKICAgICAgICAgICAgIndlYl9wb3J0IjogaW5pX2dldCh5dHVuZXIsICJXZWJTZXJ2ZXIiLCAiV2ViU2VydmVyUG9ydCIsICI4MCIpLAogICAgICAgICAgICAiZG5zX3BvcnQiOiBpbmlfZ2V0KHl0dW5lciwgIkROU1NlcnZlciIsICJETlNTZXJ2ZXJQb3J0IiwgIjUzIiksCiAgICAgICAgICAgICJkbnNfZW5hYmxlIjogaW5pX2dldCh5dHVuZXIsICJETlNTZXJ2ZXIiLCAiRW5hYmxlIiwgIjEiKSwKICAgICAgICAgICAgImludGVyY2VwdF9kbnMiOiBpbmlfZ2V0KHl0dW5lciwgIkROU1NlcnZlciIsICJJbnRlcmNlcHRETnMiLCAiIiksCiAgICAgICAgICAgICJyYl9jYWNoZV90eXBlIjogaW5pX2dldCh5dHVuZXIsICJSYWRpb2Jyb3dzZXIiLCAiUkJDYWNoZVR5cGUiLCAiIiksCiAgICAgICAgICAgICJtZXNzYWdlX2xldmVsIjogaW5pX2dldCh5dHVuZXIsICJDb25maWd1cmF0aW9uIiwgIk1lc3NhZ2VJbmZvTGV2ZWwiLCAiIiksCiAgICAgICAgfSwKICAgICAgICAiYXZyIjogewogICAgICAgICAgICAicHJvdG9jb2wiOiBpbmlfZ2V0KGF2ciwgIkNvbmZpZ3VyYXRpb24iLCAiUHJvdG9jb2wiLCAiIiksCiAgICAgICAgfSwKICAgICAgICAicHJveHkiOiB7CiAgICAgICAgICAgICJob3N0IjogcHJveHkuZ2V0KCJTVFJFQU1fUFJPWFlfSE9TVCIsICIwLjAuMC4wIiksCiAgICAgICAgICAgICJwb3J0IjogcHJveHkuZ2V0KCJTVFJFQU1fUFJPWFlfUE9SVCIsICI4MDkwIiksCiAgICAgICAgICAgICJ0aW1lb3V0IjogcHJveHkuZ2V0KCJTVFJFQU1fUFJPWFlfVElNRU9VVCIsICIxNSIpLAogICAgICAgICAgICAibWF4X3JlZGlyZWN0cyI6IHByb3h5LmdldCgiU1RSRUFNX1BST1hZX01BWF9SRURJUkVDVFMiLCAiNSIpLAogICAgICAgICAgICAibG9nX2xldmVsIjogcHJveHkuZ2V0KCJTVFJFQU1fUFJPWFlfTE9HX0xFVkVMIiwgIklORk8iKSwKICAgICAgICB9LAogICAgICAgICJzdGF0aW9ucyI6IHsKICAgICAgICAgICAgInBhdGgiOiBzdHIoU1RBVElPTlNfSU5JKSwKICAgICAgICAgICAgImdyb3VwcyI6IHBhcnNlX3N0YXRpb25zX2luaShzdGF0aW9uc19jb250ZW50KSwKICAgICAgICAgICAgInJhdyI6IHN0YXRpb25zX2NvbnRlbnQsCiAgICAgICAgfSwKICAgIH0KCgpkZWYgc2F2ZV9wcm94eV9lbnYocGF5bG9hZDogZGljdCkgLT4gZGljdDoKICAgIGFsbG93ZWQgPSB7CiAgICAgICAgIlNUUkVBTV9QUk9YWV9IT1NUIiwKICAgICAgICAiU1RSRUFNX1BST1hZX1BPUlQiLAogICAgICAgICJTVFJFQU1fUFJPWFlfVElNRU9VVCIsCiAgICAgICAgIlNUUkVBTV9QUk9YWV9NQVhfUkVESVJFQ1RTIiwKICAgICAgICAiU1RSRUFNX1BST1hZX0xPR19MRVZFTCIsCiAgICAgICAgIlNUUkVBTV9QUk9YWV9VU0VSX0FHRU5UIiwKICAgIH0KICAgIHVwZGF0ZXMgPSB7fQogICAgZm9yIGssIHYgaW4gcGF5bG9hZC5pdGVtcygpOgogICAgICAgIGt1ID0gay51cHBlcigpCiAgICAgICAgaWYga3UgaW4gYWxsb3dlZCBhbmQgdiBpcyBub3QgTm9uZToKICAgICAgICAgICAgdXBkYXRlc1trdV0gPSBzdHIodikuc3RyaXAoKQogICAgaWYgIlNUUkVBTV9QUk9YWV9QT1JUIiBpbiB1cGRhdGVzIGFuZCBub3QgdXBkYXRlc1siU1RSRUFNX1BST1hZX1BPUlQiXS5pc2RpZ2l0KCk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigiU1RSRUFNX1BST1hZX1BPUlQgbXVzdCBiZSBudW1lcmljIikKICAgIGNvbnRlbnQgPSByZWFkX3RleHQoUFJPWFlfRU5WKQogICAgbmV3X2NvbnRlbnQgPSBlbnZfcmVuZGVyKGNvbnRlbnQsIHVwZGF0ZXMpCiAgICB3cml0ZV90ZXh0X2F0b21pYyhQUk9YWV9FTlYsIG5ld19jb250ZW50KQogICAgcmV0dXJuIHsic2F2ZWQiOiBUcnVlLCAicGF0aCI6IHN0cihQUk9YWV9FTlYpLCAidXBkYXRlcyI6IHVwZGF0ZXN9CgoKZGVmIHJ1bl90ZXN0cygpIC0+IGRpY3Q6CiAgICBjZmcgPSBjb2xsZWN0X2NvbmZpZygpCiAgICBwcm94eV9wb3J0ID0gaW50KGNmZ1sicHJveHkiXS5nZXQoInBvcnQiLCAiODA5MCIpIG9yICI4MDkwIikKICAgIHdlYl9wb3J0ID0gaW50KGNmZ1sieXR1bmVyIl0uZ2V0KCJ3ZWJfcG9ydCIsICI4MCIpIG9yICI4MCIpCiAgICBkbnNfcG9ydCA9IGludChjZmdbInl0dW5lciJdLmdldCgiZG5zX3BvcnQiLCAiNTMiKSBvciAiNTMiKQogICAgcmVzdWx0cyA9IFtdCgogICAgZGVmIGFkZChuYW1lOiBzdHIsIG9rOiBib29sLCBkZXRhaWw6IGRpY3QgfCBzdHIpOgogICAgICAgIHJlc3VsdHMuYXBwZW5kKHsibmFtZSI6IG5hbWUsICJvayI6IGJvb2wob2spLCAiZGV0YWlsIjogZGV0YWlsfSkKCiAgICBmb3Igc3ZjIGluIFNFUlZJQ0VTOgogICAgICAgIHN0ID0gc2VydmljZV9zdGF0dXMoc3ZjKQogICAgICAgIGFkZChmInNlcnZpY2U6e3N2Y30iLCBzdC5nZXQoImFjdGl2ZSIpID09ICJhY3RpdmUiLCBzdCkKCiAgICBhZGQoZiJwb3J0Ont3ZWJfcG9ydH0iLCBwb3J0X2NoZWNrKHdlYl9wb3J0KVsib3BlbiJdLCBwb3J0X2NoZWNrKHdlYl9wb3J0KSkKICAgIGFkZChmInBvcnQ6e2Ruc19wb3J0fSIsIHBvcnRfY2hlY2soZG5zX3BvcnQpWyJvcGVuIl0sIHBvcnRfY2hlY2soZG5zX3BvcnQpKQogICAgYWRkKGYicG9ydDp7cHJveHlfcG9ydH0iLCBwb3J0X2NoZWNrKHByb3h5X3BvcnQpWyJvcGVuIl0sIHBvcnRfY2hlY2socHJveHlfcG9ydCkpCgogICAgZm9yIHAgaW4gW1lUVU5FUl9JTkksIEFWUl9JTkksIFNUQVRJT05TX0lOSSwgUFJPWFlfRU5WXToKICAgICAgICBhZGQoZiJmaWxlOntwfSIsIHAuZXhpc3RzKCksIHsicGF0aCI6IHN0cihwKSwgImV4aXN0cyI6IHAuZXhpc3RzKCksICJzaXplIjogcC5zdGF0KCkuc3Rfc2l6ZSBpZiBwLmV4aXN0cygpIGVsc2UgMH0pCgogICAgYWRkKCJodHRwOnl0dW5lciIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt3ZWJfcG9ydH0vIiwgNC4wKVsib2siXSwgaHR0cF9jaGVjayhmImh0dHA6Ly8xMjcuMC4wLjE6e3dlYl9wb3J0fS8iLCA0LjApKQogICAgYWRkKCJodHRwOnByb3h5LWhlYWx0aCIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOntwcm94eV9wb3J0fS9oZWFsdGgiLCA0LjApWyJvayJdLCBodHRwX2NoZWNrKGYiaHR0cDovLzEyNy4wLjAuMTp7cHJveHlfcG9ydH0vaGVhbHRoIiwgNC4wKSkKCiAgICBweWMgPSBydW5fY21kKFsicHl0aG9uMyIsICItbSIsICJweV9jb21waWxlIiwgc3RyKFBST1hZX1NDUklQVCldLCB0aW1lb3V0PTIwKQogICAgYWRkKCJweXRob246cHJveHktY29tcGlsZSIsIHB5Y1sib2siXSwgcHljKQoKICAgIG9rX2NvdW50ID0gc3VtKDEgZm9yIHIgaW4gcmVzdWx0cyBpZiByWyJvayJdKQogICAgcmV0dXJuIHsib2siOiBva19jb3VudCA9PSBsZW4ocmVzdWx0cyksICJ0b3RhbCI6IGxlbihyZXN1bHRzKSwgInBhc3NlZCI6IG9rX2NvdW50LCAiZmFpbGVkIjogbGVuKHJlc3VsdHMpIC0gb2tfY291bnQsICJyZXN1bHRzIjogcmVzdWx0cywgInRzIjogaW50KHRpbWUudGltZSgpKX0KCgpjbGFzcyBIYW5kbGVyKEJhc2VIVFRQUmVxdWVzdEhhbmRsZXIpOgogICAgc2VydmVyX3ZlcnNpb24gPSAiWVR1bmVyQWRtaW4vMC4xIgoKICAgIGRlZiBsb2dfbWVzc2FnZShzZWxmLCBmbXQ6IHN0ciwgKmFyZ3MpIC0+IE5vbmU6ICAjIG5vcWE6IEEwMDMKICAgICAgICBzeXMuc3RkZXJyLndyaXRlKCIlcyAtICVzXG4iICUgKHNlbGYuYWRkcmVzc19zdHJpbmcoKSwgZm10ICUgYXJncykpCgogICAgZGVmIF9hdXRoX29rKHNlbGYpIC0+IGJvb2w6CiAgICAgICAgaWYgbm90IFRPS0VOOgogICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgIGhkciA9IHNlbGYuaGVhZGVycy5nZXQoIlgtQWRtaW4tVG9rZW4iKSBvciAiIgogICAgICAgIGlmIGhkciA9PSBUT0tFTjoKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBxcyA9IHBhcnNlX3FzKHVybHNwbGl0KHNlbGYucGF0aCkucXVlcnkpCiAgICAgICAgcmV0dXJuIChxcy5nZXQoInRva2VuIikgb3IgWyIiXSlbMF0gPT0gVE9LRU4KCiAgICBkZWYgX3NlbmRfanNvbihzZWxmLCBjb2RlOiBpbnQsIHBheWxvYWQ6IGRpY3QpIC0+IE5vbmU6CiAgICAgICAgZGF0YSA9IGpzb24uZHVtcHMocGF5bG9hZCwgZW5zdXJlX2FzY2lpPUZhbHNlKS5lbmNvZGUoInV0Zi04IikKICAgICAgICBzZWxmLnNlbmRfcmVzcG9uc2UoY29kZSkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LVR5cGUiLCAiYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCIpCiAgICAgICAgc2VsZi5zZW5kX2hlYWRlcigiQ29udGVudC1MZW5ndGgiLCBzdHIobGVuKGRhdGEpKSkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDYWNoZS1Db250cm9sIiwgIm5vLXN0b3JlIikKICAgICAgICBzZWxmLmVuZF9oZWFkZXJzKCkKICAgICAgICBzZWxmLndmaWxlLndyaXRlKGRhdGEpCgogICAgZGVmIF9zZW5kX2J5dGVzKHNlbGYsIGNvZGU6IGludCwgZGF0YTogYnl0ZXMsIGNvbnRlbnRfdHlwZTogc3RyKSAtPiBOb25lOgogICAgICAgIHNlbGYuc2VuZF9yZXNwb25zZShjb2RlKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNvbnRlbnQtVHlwZSIsIGNvbnRlbnRfdHlwZSkKICAgICAgICBzZWxmLnNlbmRfaGVhZGVyKCJDb250ZW50LUxlbmd0aCIsIHN0cihsZW4oZGF0YSkpKQogICAgICAgIHNlbGYuc2VuZF9oZWFkZXIoIkNhY2hlLUNvbnRyb2wiLCAibm8tc3RvcmUiKQogICAgICAgIHNlbGYuZW5kX2hlYWRlcnMoKQogICAgICAgIHNlbGYud2ZpbGUud3JpdGUoZGF0YSkKCiAgICBkZWYgX3JlYWRfanNvbihzZWxmKSAtPiBkaWN0OgogICAgICAgIG4gPSBpbnQoc2VsZi5oZWFkZXJzLmdldCgiQ29udGVudC1MZW5ndGgiKSBvciAiMCIpCiAgICAgICAgcmF3ID0gc2VsZi5yZmlsZS5yZWFkKG4pIGlmIG4gPiAwIGVsc2UgYiJ7fSIKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJldHVybiBqc29uLmxvYWRzKHJhdy5kZWNvZGUoInV0Zi04IikpCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcmV0dXJuIHt9CgogICAgZGVmIF9zZXJ2ZV9zdGF0aWMoc2VsZiwgcGF0aDogc3RyKSAtPiBib29sOgogICAgICAgIHAgPSB1cmxzcGxpdChwYXRoKS5wYXRoCiAgICAgICAgaWYgcCA9PSAiLyI6CiAgICAgICAgICAgIHAgPSAiL2luZGV4Lmh0bWwiCiAgICAgICAgc2FmZSA9IFBhdGgocC5sc3RyaXAoIi8iKSkKICAgICAgICB0YXJnZXQgPSAoV0VCX0RJUiAvIHNhZmUpLnJlc29sdmUoKQogICAgICAgIGlmIFdFQl9ESVIucmVzb2x2ZSgpIG5vdCBpbiB0YXJnZXQucGFyZW50cyBhbmQgdGFyZ2V0ICE9IFdFQl9ESVIucmVzb2x2ZSgpOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAzLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJmb3JiaWRkZW4ifSkKICAgICAgICAgICAgcmV0dXJuIFRydWUKICAgICAgICBpZiBub3QgdGFyZ2V0LmV4aXN0cygpIG9yIG5vdCB0YXJnZXQuaXNfZmlsZSgpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UKICAgICAgICBjdHlwZSA9ICJ0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGlmIHRhcmdldC5zdWZmaXggPT0gIi5odG1sIjoKICAgICAgICAgICAgY3R5cGUgPSAidGV4dC9odG1sOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGVsaWYgdGFyZ2V0LnN1ZmZpeCA9PSAiLmNzcyI6CiAgICAgICAgICAgIGN0eXBlID0gInRleHQvY3NzOyBjaGFyc2V0PXV0Zi04IgogICAgICAgIGVsaWYgdGFyZ2V0LnN1ZmZpeCA9PSAiLmpzIjoKICAgICAgICAgICAgY3R5cGUgPSAiYXBwbGljYXRpb24vamF2YXNjcmlwdDsgY2hhcnNldD11dGYtOCIKICAgICAgICBlbGlmIHRhcmdldC5zdWZmaXggPT0gIi5qc29uIjoKICAgICAgICAgICAgY3R5cGUgPSAiYXBwbGljYXRpb24vanNvbjsgY2hhcnNldD11dGYtOCIKICAgICAgICBzZWxmLl9zZW5kX2J5dGVzKDIwMCwgdGFyZ2V0LnJlYWRfYnl0ZXMoKSwgY3R5cGUpCiAgICAgICAgcmV0dXJuIFRydWUKCiAgICBkZWYgZG9fR0VUKHNlbGYpIC0+IE5vbmU6ICAjIG5vcWE6IE44MDIKICAgICAgICBwYXJzZWQgPSB1cmxzcGxpdChzZWxmLnBhdGgpCiAgICAgICAgcGF0aCA9IHBhcnNlZC5wYXRoCiAgICAgICAgaWYgcGF0aC5zdGFydHN3aXRoKCIvYXBpLyIpIGFuZCBub3Qgc2VsZi5fYXV0aF9vaygpOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAxLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJ1bmF1dGhvcml6ZWQifSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9oZWFsdGgiOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCB7Im9rIjogVHJ1ZSwgInNlcnZpY2UiOiAieXR1bmVyLWFkbWluIn0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvc3RhdHVzIjoKICAgICAgICAgICAgY2ZnID0gY29sbGVjdF9jb25maWcoKQogICAgICAgICAgICBzdGF0dXNlcyA9IFtzZXJ2aWNlX3N0YXR1cyhzKSBmb3IgcyBpbiBTRVJWSUNFU10KICAgICAgICAgICAgcHJveHlfcG9ydCA9IGludChjZmdbInByb3h5Il0uZ2V0KCJwb3J0IiwgIjgwOTAiKSBvciAiODA5MCIpCiAgICAgICAgICAgIHl0dW5lcl9wb3J0ID0gaW50KGNmZ1sieXR1bmVyIl0uZ2V0KCJ3ZWJfcG9ydCIsICI4MCIpIG9yICI4MCIpCiAgICAgICAgICAgIGRuc19wb3J0ID0gaW50KGNmZ1sieXR1bmVyIl0uZ2V0KCJkbnNfcG9ydCIsICI1MyIpIG9yICI1MyIpCiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsKICAgICAgICAgICAgICAgICJvayI6IFRydWUsCiAgICAgICAgICAgICAgICAiY29uZmlnIjogY2ZnLAogICAgICAgICAgICAgICAgInNlcnZpY2VzIjogc3RhdHVzZXMsCiAgICAgICAgICAgICAgICAicG9ydHMiOiBbcG9ydF9jaGVjayh5dHVuZXJfcG9ydCksIHBvcnRfY2hlY2soZG5zX3BvcnQpLCBwb3J0X2NoZWNrKHByb3h5X3BvcnQpXSwKICAgICAgICAgICAgfSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9jb25maWciOgogICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCB7Im9rIjogVHJ1ZSwgImNvbmZpZyI6IGNvbGxlY3RfY29uZmlnKCl9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL3N0YXRpb25zIjoKICAgICAgICAgICAgY29udGVudCA9IHJlYWRfdGV4dChTVEFUSU9OU19JTkkpCiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAicGF0aCI6IHN0cihTVEFUSU9OU19JTkkpLCAiZ3JvdXBzIjogcGFyc2Vfc3RhdGlvbnNfaW5pKGNvbnRlbnQpLCAicmF3IjogY29udGVudH0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvc3RhdGlvbnMvY2hlY2siOgogICAgICAgICAgICBxcyA9IHBhcnNlX3FzKHBhcnNlZC5xdWVyeSkKICAgICAgICAgICAgdXJsID0gKHFzLmdldCgidXJsIikgb3IgWyIiXSlbMF0uc3RyaXAoKQogICAgICAgICAgICBpZiBub3QgdXJsOgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAibWlzc2luZyB1cmwifSkKICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICByZXN1bHQgPSBjaGVja19zdHJlYW1fdXJsKHVybCkKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAqKnJlc3VsdH0pCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAidXJsIjogdXJsLCAicmVhY2hhYmxlIjogRmFsc2UsICJlcnJvciI6IHN0cihleGMpfSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9sb2dzIjoKICAgICAgICAgICAgcXMgPSBwYXJzZV9xcyhwYXJzZWQucXVlcnkpCiAgICAgICAgICAgIG5hbWUgPSAocXMuZ2V0KCJuYW1lIikgb3IgWyJ5dHVuZXIiXSlbMF0KICAgICAgICAgICAgbGluZXMgPSBpbnQoKHFzLmdldCgibGluZXMiKSBvciBbIjEyMCJdKVswXSkKICAgICAgICAgICAgbGluZXMgPSBtYXgoMTAsIG1pbihsaW5lcywgMTAwMCkpCiAgICAgICAgICAgIHAgPSBMT0dfRklMRVMuZ2V0KG5hbWUpCiAgICAgICAgICAgIGlmIG5vdCBwOgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAidW5rbm93biBsb2cifSkKICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICB0ZXh0ID0gcmVhZF90ZXh0KHApCiAgICAgICAgICAgIHRhaWwgPSAiXG4iLmpvaW4odGV4dC5zcGxpdGxpbmVzKClbLWxpbmVzOl0pCiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAibmFtZSI6IG5hbWUsICJwYXRoIjogc3RyKHApLCAiY29udGVudCI6IHRhaWx9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL3Rlc3RzL3J1biI6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHJ1bl90ZXN0cygpKQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoLnN0YXJ0c3dpdGgoIi9hcGkvIik6CiAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDQsIHsib2siOiBGYWxzZSwgImVycm9yIjogIm5vdCBmb3VuZCJ9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBzZWxmLl9zZXJ2ZV9zdGF0aWMocGF0aCk6CiAgICAgICAgICAgIHJldHVybgogICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDQsIHsib2siOiBGYWxzZSwgImVycm9yIjogIm5vdCBmb3VuZCJ9KQoKICAgIGRlZiBkb19QT1NUKHNlbGYpIC0+IE5vbmU6ICAjIG5vcWE6IE44MDIKICAgICAgICBwYXJzZWQgPSB1cmxzcGxpdChzZWxmLnBhdGgpCiAgICAgICAgcGF0aCA9IHBhcnNlZC5wYXRoCiAgICAgICAgaWYgbm90IHNlbGYuX2F1dGhfb2soKToKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMSwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAidW5hdXRob3JpemVkIn0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIHBheWxvYWQgPSBzZWxmLl9yZWFkX2pzb24oKQogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvY29uZmlnL3Byb3h5IjoKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgcmVzID0gc2F2ZV9wcm94eV9lbnYocGF5bG9hZCkKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbigyMDAsIHsib2siOiBUcnVlLCAqKnJlc30pCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOiAgIyBub3FhOiBCTEUwMDEKICAgICAgICAgICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDAsIHsib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4Yyl9KQogICAgICAgICAgICByZXR1cm4KICAgICAgICBpZiBwYXRoID09ICIvYXBpL3N0YXRpb25zIjoKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgaWYgInJhdyIgaW4gcGF5bG9hZCBhbmQgaXNpbnN0YW5jZShwYXlsb2FkLmdldCgicmF3IiksIHN0cik6CiAgICAgICAgICAgICAgICAgICAgcmF3ID0gcGF5bG9hZFsicmF3Il0KICAgICAgICAgICAgICAgICAgICAjIHZhbGlkYXRlIGJ5IHBhcnNpbmcgYW5kIG5vcm1hbGl6aW5nIHRocm91Z2ggcmVuZGVyZXIgaWYgZ3JvdXBzIGNhbiBiZSBkZXJpdmVkPyBrZWVwIHJhdyBidXQgYmFzaWMgY2hlY2sKICAgICAgICAgICAgICAgICAgICBpZiBsZW4ocmF3KSA+IDIwMDAwMDoKICAgICAgICAgICAgICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigic3RhdGlvbnMuaW5pIHRvbyBsYXJnZSIpCiAgICAgICAgICAgICAgICAgICAgd3JpdGVfdGV4dF9hdG9taWMoU1RBVElPTlNfSU5JLCByYXcgaWYgcmF3LmVuZHN3aXRoKCJcbiIpIGVsc2UgcmF3ICsgIlxuIikKICAgICAgICAgICAgICAgICAgICBjb250ZW50ID0gcmVhZF90ZXh0KFNUQVRJT05TX0lOSSkKICAgICAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oMjAwLCB7Im9rIjogVHJ1ZSwgInNhdmVkIjogVHJ1ZSwgInBhdGgiOiBzdHIoU1RBVElPTlNfSU5JKSwgImdyb3VwcyI6IHBhcnNlX3N0YXRpb25zX2luaShjb250ZW50KSwgInJhdyI6IGNvbnRlbnR9KQogICAgICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICAgICAgZ3JvdXBzID0gcGF5bG9hZC5nZXQoImdyb3VwcyIpCiAgICAgICAgICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShncm91cHMsIGxpc3QpOgogICAgICAgICAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoIkV4cGVjdGVkICdncm91cHMnIGxpc3Qgb3IgJ3Jhdycgc3RyaW5nIikKICAgICAgICAgICAgICAgIHJlbmRlcmVkID0gcmVuZGVyX3N0YXRpb25zX2luaShncm91cHMpCiAgICAgICAgICAgICAgICB3cml0ZV90ZXh0X2F0b21pYyhTVEFUSU9OU19JTkksIHJlbmRlcmVkKQogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgeyJvayI6IFRydWUsICJzYXZlZCI6IFRydWUsICJwYXRoIjogc3RyKFNUQVRJT05TX0lOSSksICJncm91cHMiOiBwYXJzZV9zdGF0aW9uc19pbmkocmVuZGVyZWQpLCAicmF3IjogcmVuZGVyZWR9KQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAwLCB7Im9rIjogRmFsc2UsICJlcnJvciI6IHN0cihleGMpfSkKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgaWYgcGF0aCA9PSAiL2FwaS9zZXJ2aWNlL3Jlc3RhcnQiOgogICAgICAgICAgICBuYW1lID0gc3RyKHBheWxvYWQuZ2V0KCJuYW1lIikgb3IgIiIpCiAgICAgICAgICAgIGlmIG5hbWUgbm90IGluIFNFUlZJQ0VTOgogICAgICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDQwMCwgeyJvayI6IEZhbHNlLCAiZXJyb3IiOiAiaW52YWxpZCBzZXJ2aWNlIn0pCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgaWYgbm90IEFMTE9XX1NZU1RFTUNUTCBvciBzaHV0aWwud2hpY2goInN5c3RlbWN0bCIpIGlzIE5vbmU6CiAgICAgICAgICAgICAgICBzZWxmLl9zZW5kX2pzb24oNDAwLCB7Im9rIjogRmFsc2UsICJlcnJvciI6ICJzeXN0ZW1jdGwgdW5hdmFpbGFibGUifSkKICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICByZXMgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgInJlc3RhcnQiLCBuYW1lXSwgdGltZW91dD0zMCkKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCBpZiByZXNbIm9rIl0gZWxzZSA1MDAsIHsib2siOiByZXNbIm9rIl0sICJyZXN1bHQiOiByZXMsICJzdGF0dXMiOiBzZXJ2aWNlX3N0YXR1cyhuYW1lKX0pCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIHBhdGggPT0gIi9hcGkvdGVzdHMvcnVuIjoKICAgICAgICAgICAgc2VsZi5fc2VuZF9qc29uKDIwMCwgcnVuX3Rlc3RzKCkpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIHNlbGYuX3NlbmRfanNvbig0MDQsIHsib2siOiBGYWxzZSwgImVycm9yIjogIm5vdCBmb3VuZCJ9KQoKCmRlZiBtYWluKCkgLT4gaW50OgogICAgYXAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcigpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0taG9zdCIsIGRlZmF1bHQ9SE9TVCkKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1wb3J0IiwgdHlwZT1pbnQsIGRlZmF1bHQ9UE9SVCkKICAgIGFyZ3MgPSBhcC5wYXJzZV9hcmdzKCkKICAgIHNlcnZlciA9IFRocmVhZGluZ0hUVFBTZXJ2ZXIoKGFyZ3MuaG9zdCwgYXJncy5wb3J0KSwgSGFuZGxlcikKICAgIHByaW50KGYieXR1bmVyLWFkbWluIGxpc3RlbmluZyBvbiBodHRwOi8ve2FyZ3MuaG9zdH06e2FyZ3MucG9ydH0iLCBmbHVzaD1UcnVlKQogICAgdHJ5OgogICAgICAgIHNlcnZlci5zZXJ2ZV9mb3JldmVyKCkKICAgIGV4Y2VwdCBLZXlib2FyZEludGVycnVwdDoKICAgICAgICBwYXNzCiAgICBmaW5hbGx5OgogICAgICAgIHNlcnZlci5zZXJ2ZXJfY2xvc2UoKQogICAgcmV0dXJuIDAKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgcmFpc2UgU3lzdGVtRXhpdChtYWluKCkpCg=='
AUTOTEST_PY_B64='IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwpmcm9tIF9fZnV0dXJlX18gaW1wb3J0IGFubm90YXRpb25zCgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzb2NrZXQKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGltZQpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKZnJvbSB1cmxsaWIucmVxdWVzdCBpbXBvcnQgUmVxdWVzdCwgdXJsb3BlbgoKCklOU1RBTExfRElSID0gUGF0aChvcy5lbnZpcm9uLmdldCgiWVRVTkVSX0lOU1RBTExfRElSIiwgIi9vcHQveXR1bmVyIikpCkNPTkZJR19ESVIgPSBJTlNUQUxMX0RJUiAvICJjb25maWciCllUVU5FUl9JTkkgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXIuaW5pIgpBVlJfSU5JID0gQ09ORklHX0RJUiAvICJhdnIuaW5pIgpTVEFUSU9OU19JTkkgPSBDT05GSUdfRElSIC8gInN0YXRpb25zLmluaSIKUFJPWFlfRU5WID0gUGF0aCgiL2V0Yy9kZWZhdWx0L3l0dW5lci1zdHJlYW0tcHJveHkiKQpQUk9YWV9TQ1JJUFQgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXItc3RyZWFtLXByb3h5LnB5IgpBRE1JTl9TQ1JJUFQgPSBJTlNUQUxMX0RJUiAvICJ5dHVuZXItYWRtaW4ucHkiClNFUlZJQ0VTID0gWyJ5dHVuZXIiLCAieXR1bmVyLXN0cmVhbS1wcm94eSIsICJ5dHVuZXItYWRtaW4iXQoKCmRlZiBydW5fY21kKGNtZDogbGlzdFtzdHJdLCB0aW1lb3V0OiBmbG9hdCA9IDIwLjApIC0+IGRpY3Q6CiAgICB0cnk6CiAgICAgICAgcHJvYyA9IHN1YnByb2Nlc3MucnVuKGNtZCwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PXRpbWVvdXQsIGNoZWNrPUZhbHNlKQogICAgICAgIHJldHVybiB7Im9rIjogcHJvYy5yZXR1cm5jb2RlID09IDAsICJyYyI6IHByb2MucmV0dXJuY29kZSwgInN0ZG91dCI6IHByb2Muc3Rkb3V0Wy00MDAwOl0sICJzdGRlcnIiOiBwcm9jLnN0ZGVyclstNDAwMDpdLCAiY21kIjogY21kfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7Im9rIjogRmFsc2UsICJyYyI6IC0xLCAic3Rkb3V0IjogIiIsICJzdGRlcnIiOiBzdHIoZXhjKSwgImNtZCI6IGNtZH0KCgpkZWYgcmVhZF90ZXh0KHBhdGg6IFBhdGgpIC0+IHN0cjoKICAgIHJldHVybiBwYXRoLnJlYWRfdGV4dChlbmNvZGluZz0idXRmLTgiLCBlcnJvcnM9InJlcGxhY2UiKSBpZiBwYXRoLmV4aXN0cygpIGVsc2UgIiIKCgpkZWYgaW5pX2dldChjb250ZW50OiBzdHIsIHNlY3Rpb246IHN0ciwga2V5OiBzdHIsIGRlZmF1bHQ6IHN0ciA9ICIiKSAtPiBzdHI6CiAgICBpbl9zZWN0aW9uID0gRmFsc2UKICAgIHNlY19yZSA9IHJlLmNvbXBpbGUociJeXHMqXFsoLis/KVxdXHMqJCIpCiAgICBrdl9yZSA9IHJlLmNvbXBpbGUociJeXHMqKFteOyM9XHNdW149XSo/KVxzKj1ccyooLio/KVxzKiQiKQogICAgZm9yIGxpbmUgaW4gY29udGVudC5zcGxpdGxpbmVzKCk6CiAgICAgICAgbSA9IHNlY19yZS5tYXRjaChsaW5lKQogICAgICAgIGlmIG06CiAgICAgICAgICAgIGluX3NlY3Rpb24gPSBtLmdyb3VwKDEpLnN0cmlwKCkubG93ZXIoKSA9PSBzZWN0aW9uLmxvd2VyKCkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiBpbl9zZWN0aW9uOgogICAgICAgICAgICBrbSA9IGt2X3JlLm1hdGNoKGxpbmUpCiAgICAgICAgICAgIGlmIGttIGFuZCBrbS5ncm91cCgxKS5zdHJpcCgpLmxvd2VyKCkgPT0ga2V5Lmxvd2VyKCk6CiAgICAgICAgICAgICAgICByZXR1cm4ga20uZ3JvdXAoMikKICAgIHJldHVybiBkZWZhdWx0CgoKZGVmIGVudl9wYXJzZShjb250ZW50OiBzdHIpIC0+IGRpY3Rbc3RyLCBzdHJdOgogICAgb3V0ID0ge30KICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICBpZiBub3QgbGluZSBvciBsaW5lLnN0YXJ0c3dpdGgoIiMiKSBvciAiPSIgbm90IGluIGxpbmU6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaywgdiA9IGxpbmUuc3BsaXQoIj0iLCAxKQogICAgICAgIG91dFtrLnN0cmlwKCldID0gdi5zdHJpcCgpLnN0cmlwKCciJykuc3RyaXAoIiciKQogICAgcmV0dXJuIG91dAoKCmRlZiBzZXJ2aWNlX3N0YXR1cyhuYW1lOiBzdHIpIC0+IGRpY3Q6CiAgICBpZiBzaHV0aWwud2hpY2goInN5c3RlbWN0bCIpIGlzIE5vbmU6CiAgICAgICAgcmV0dXJuIHsibmFtZSI6IG5hbWUsICJhY3RpdmUiOiAidW5rbm93biIsICJlbmFibGVkIjogInVua25vd24ifQogICAgYWN0aXZlID0gcnVuX2NtZChbInN5c3RlbWN0bCIsICJpcy1hY3RpdmUiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIGVuYWJsZWQgPSBydW5fY21kKFsic3lzdGVtY3RsIiwgImlzLWVuYWJsZWQiLCBuYW1lXSwgdGltZW91dD0xMCkKICAgIHJldHVybiB7Im5hbWUiOiBuYW1lLCAiYWN0aXZlIjogYWN0aXZlWyJzdGRvdXQiXS5zdHJpcCgpLCAiZW5hYmxlZCI6IGVuYWJsZWRbInN0ZG91dCJdLnN0cmlwKCl9CgoKZGVmIHBvcnRfY2hlY2socG9ydDogaW50LCBob3N0OiBzdHIgPSAiMTI3LjAuMC4xIikgLT4gZGljdDoKICAgIHMgPSBzb2NrZXQuc29ja2V0KCkKICAgIHMuc2V0dGltZW91dCgxLjUpCiAgICB0cnk6CiAgICAgICAgcy5jb25uZWN0KChob3N0LCBwb3J0KSkKICAgICAgICByZXR1cm4geyJwb3J0IjogcG9ydCwgIm9wZW4iOiBUcnVlfQogICAgZXhjZXB0IEV4Y2VwdGlvbiBhcyBleGM6ICAjIG5vcWE6IEJMRTAwMQogICAgICAgIHJldHVybiB7InBvcnQiOiBwb3J0LCAib3BlbiI6IEZhbHNlLCAiZXJyb3IiOiBzdHIoZXhjKX0KICAgIGZpbmFsbHk6CiAgICAgICAgdHJ5OgogICAgICAgICAgICBzLmNsb3NlKCkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCgoKZGVmIGh0dHBfY2hlY2sodXJsOiBzdHIsIHRpbWVvdXQ6IGZsb2F0ID0gNS4wKSAtPiBkaWN0OgogICAgcmVxID0gUmVxdWVzdCh1cmwsIGhlYWRlcnM9eyJVc2VyLUFnZW50IjogInl0dW5lci1hdXRvdGVzdC8wLjEifSkKICAgIHQwID0gdGltZS50aW1lKCkKICAgIHRyeToKICAgICAgICB3aXRoIHVybG9wZW4ocmVxLCB0aW1lb3V0PXRpbWVvdXQpIGFzIHJlc3A6CiAgICAgICAgICAgIGJvZHkgPSByZXNwLnJlYWQoNTEyKQogICAgICAgICAgICByZXR1cm4geyJ1cmwiOiB1cmwsICJvayI6IDIwMCA8PSBnZXRhdHRyKHJlc3AsICJzdGF0dXMiLCAyMDApIDwgNTAwLCAic3RhdHVzIjogZ2V0YXR0cihyZXNwLCAic3RhdHVzIiwgMjAwKSwgIm1zIjogaW50KCh0aW1lLnRpbWUoKSAtIHQwKSAqIDEwMDApLCAiYnl0ZXMiOiBsZW4oYm9keSl9CiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzogICMgbm9xYTogQkxFMDAxCiAgICAgICAgcmV0dXJuIHsidXJsIjogdXJsLCAib2siOiBGYWxzZSwgImVycm9yIjogc3RyKGV4YyksICJtcyI6IGludCgodGltZS50aW1lKCkgLSB0MCkgKiAxMDAwKX0KCgpkZWYgbWFpbigpIC0+IGludDoKICAgIGFwID0gYXJncGFyc2UuQXJndW1lbnRQYXJzZXIoZGVzY3JpcHRpb249IllUdW5lciBhdXRvdGVzdCBydW5uZXIiKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWpzb24iLCBhY3Rpb249InN0b3JlX3RydWUiLCBoZWxwPSJKU09OIG91dHB1dCIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0taW5jbHVkZS1hZG1pbiIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIsIGhlbHA9IkluY2x1ZGUgeXR1bmVyLWFkbWluIGNoZWNrcyIpCiAgICBhcmdzID0gYXAucGFyc2VfYXJncygpCgogICAgeXR1bmVyID0gcmVhZF90ZXh0KFlUVU5FUl9JTkkpCiAgICBwcm94eV9lbnYgPSBlbnZfcGFyc2UocmVhZF90ZXh0KFBST1hZX0VOVikpCiAgICB5dHVuZXJfcG9ydCA9IGludChpbmlfZ2V0KHl0dW5lciwgIldlYlNlcnZlciIsICJXZWJTZXJ2ZXJQb3J0IiwgIjgwIikgb3IgIjgwIikKICAgIGRuc19wb3J0ID0gaW50KGluaV9nZXQoeXR1bmVyLCAiRE5TU2VydmVyIiwgIkROU1NlcnZlclBvcnQiLCAiNTMiKSBvciAiNTMiKQogICAgcHJveHlfcG9ydCA9IGludChwcm94eV9lbnYuZ2V0KCJTVFJFQU1fUFJPWFlfUE9SVCIsICI4MDkwIikgb3IgIjgwOTAiKQogICAgYWRtaW5fZW52ID0gZW52X3BhcnNlKHJlYWRfdGV4dChQYXRoKCIvZXRjL2RlZmF1bHQveXR1bmVyLWFkbWluIikpKQogICAgYWRtaW5fcG9ydCA9IGludChhZG1pbl9lbnYuZ2V0KCJZVFVORVJfQURNSU5fUE9SVCIsICI4MDkxIikgb3IgIjgwOTEiKQoKICAgIHJlc3VsdHMgPSBbXQogICAgZGVmIGFkZChuYW1lLCBvaywgZGV0YWlsKToKICAgICAgICByZXN1bHRzLmFwcGVuZCh7Im5hbWUiOiBuYW1lLCAib2siOiBib29sKG9rKSwgImRldGFpbCI6IGRldGFpbH0pCgogICAgc2VydmljZXMgPSBTRVJWSUNFUyBpZiBhcmdzLmluY2x1ZGVfYWRtaW4gZWxzZSBbInl0dW5lciIsICJ5dHVuZXItc3RyZWFtLXByb3h5Il0KICAgIGZvciBzdmMgaW4gc2VydmljZXM6CiAgICAgICAgc3QgPSBzZXJ2aWNlX3N0YXR1cyhzdmMpCiAgICAgICAgYWRkKGYic2VydmljZTp7c3ZjfSIsIHN0LmdldCgiYWN0aXZlIikgaW4geyJhY3RpdmUiLCAidW5rbm93biJ9LCBzdCkKCiAgICBmb3IgcCBpbiBbeXR1bmVyX3BvcnQsIGRuc19wb3J0LCBwcm94eV9wb3J0XSArIChbYWRtaW5fcG9ydF0gaWYgYXJncy5pbmNsdWRlX2FkbWluIGVsc2UgW10pOgogICAgICAgIHBjID0gcG9ydF9jaGVjayhwKQogICAgICAgIGFkZChmInBvcnQ6e3B9IiwgcGNbIm9wZW4iXSwgcGMpCgogICAgZm9yIHAgaW4gW1lUVU5FUl9JTkksIEFWUl9JTkksIFNUQVRJT05TX0lOSSwgUFJPWFlfRU5WLCBQUk9YWV9TQ1JJUFRdICsgKFtBRE1JTl9TQ1JJUFRdIGlmIGFyZ3MuaW5jbHVkZV9hZG1pbiBlbHNlIFtdKToKICAgICAgICBhZGQoZiJmaWxlOntwfSIsIHAuZXhpc3RzKCksIHsicGF0aCI6IHN0cihwKSwgImV4aXN0cyI6IHAuZXhpc3RzKCksICJzaXplIjogcC5zdGF0KCkuc3Rfc2l6ZSBpZiBwLmV4aXN0cygpIGVsc2UgMH0pCgogICAgYWRkKCJodHRwOnl0dW5lciIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt5dHVuZXJfcG9ydH0vIilbIm9rIl0sIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnt5dHVuZXJfcG9ydH0vIikpCiAgICBhZGQoImh0dHA6cHJveHktaGVhbHRoIiwgaHR0cF9jaGVjayhmImh0dHA6Ly8xMjcuMC4wLjE6e3Byb3h5X3BvcnR9L2hlYWx0aCIpWyJvayJdLCBodHRwX2NoZWNrKGYiaHR0cDovLzEyNy4wLjAuMTp7cHJveHlfcG9ydH0vaGVhbHRoIikpCiAgICBpZiBhcmdzLmluY2x1ZGVfYWRtaW46CiAgICAgICAgYWRkKCJodHRwOmFkbWluLWhlYWx0aCIsIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnthZG1pbl9wb3J0fS9hcGkvaGVhbHRoIilbIm9rIl0sIGh0dHBfY2hlY2soZiJodHRwOi8vMTI3LjAuMC4xOnthZG1pbl9wb3J0fS9hcGkvaGVhbHRoIikpCgogICAgcHljID0gcnVuX2NtZChbInB5dGhvbjMiLCAiLW0iLCAicHlfY29tcGlsZSIsIHN0cihQUk9YWV9TQ1JJUFQpXSwgdGltZW91dD0yMCkKICAgIGFkZCgicHl0aG9uOnByb3h5LWNvbXBpbGUiLCBweWNbIm9rIl0sIHB5YykKICAgIGlmIGFyZ3MuaW5jbHVkZV9hZG1pbiBhbmQgQURNSU5fU0NSSVBULmV4aXN0cygpOgogICAgICAgIHB5YzIgPSBydW5fY21kKFsicHl0aG9uMyIsICItbSIsICJweV9jb21waWxlIiwgc3RyKEFETUlOX1NDUklQVCldLCB0aW1lb3V0PTIwKQogICAgICAgIGFkZCgicHl0aG9uOmFkbWluLWNvbXBpbGUiLCBweWMyWyJvayJdLCBweWMyKQoKICAgIHBhc3NlZCA9IHN1bSgxIGZvciByIGluIHJlc3VsdHMgaWYgclsib2siXSkKICAgIHJlcG9ydCA9IHsib2siOiBwYXNzZWQgPT0gbGVuKHJlc3VsdHMpLCAidG90YWwiOiBsZW4ocmVzdWx0cyksICJwYXNzZWQiOiBwYXNzZWQsICJmYWlsZWQiOiBsZW4ocmVzdWx0cyktcGFzc2VkLCAicmVzdWx0cyI6IHJlc3VsdHMsICJ0cyI6IGludCh0aW1lLnRpbWUoKSl9CiAgICBpZiBhcmdzLmpzb246CiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyhyZXBvcnQsIGVuc3VyZV9hc2NpaT1GYWxzZSkpCiAgICBlbHNlOgogICAgICAgIHByaW50KGYieydQQVNTJyBpZiByZXBvcnRbJ29rJ10gZWxzZSAnRkFJTCd9IHtwYXNzZWR9L3tsZW4ocmVzdWx0cyl9IikKICAgICAgICBmb3IgciBpbiByZXN1bHRzOgogICAgICAgICAgICBwcmludChmIlt7J09LJyBpZiByWydvayddIGVsc2UgJ0ZBSUwnfV0ge3JbJ25hbWUnXX0iKQogICAgICAgICAgICBpZiBub3Qgclsib2siXToKICAgICAgICAgICAgICAgIHByaW50KCIgICIgKyBqc29uLmR1bXBzKHJbImRldGFpbCJdLCBlbnN1cmVfYXNjaWk9RmFsc2UpWzozMDBdKQogICAgcmV0dXJuIDAgaWYgcmVwb3J0WyJvayJdIGVsc2UgMQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICByYWlzZSBTeXN0ZW1FeGl0KG1haW4oKSkK'
WEB_INDEX_B64='PCFkb2N0eXBlIGh0bWw+CjxodG1sIGxhbmc9ImRlIj4KPGhlYWQ+CiAgPG1ldGEgY2hhcnNldD0idXRmLTgiPgogIDxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsIGluaXRpYWwtc2NhbGU9MSI+CiAgPHRpdGxlPllUdW5lciBBZG1pbjwvdGl0bGU+CiAgPGxpbmsgcmVsPSJzdHlsZXNoZWV0IiBocmVmPSIvc3R5bGVzLmNzcyI+CjwvaGVhZD4KPGJvZHk+CiAgPGhlYWRlciBjbGFzcz0idG9wYmFyIj4KICAgIDxkaXY+CiAgICAgIDxoMT5ZVHVuZXIgQWRtaW48L2gxPgogICAgICA8cCBjbGFzcz0ibXV0ZWQiPldlYm9iZXJmbMOkY2hlIGbDvHIgWVR1bmVyLCBTdHJlYW0tUHJveHkgdW5kIERpYWdub3NlPC9wPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhY3Rpb25zIj4KICAgICAgPGJ1dHRvbiBpZD0icmVmcmVzaEJ0biI+QWt0dWFsaXNpZXJlbjwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9oZWFkZXI+CgogIDxuYXYgY2xhc3M9Im1haW4tdGFicyI+CiAgICA8YnV0dG9uIGNsYXNzPSJtYWluLXRhYiBhY3RpdmUiIGRhdGEtdGFiPSJzdGF0aW9ucyI+MS4gUmFkaW9zZW5kZXIgcGZsZWdlbjwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0ibWFpbi10YWIiIGRhdGEtdGFiPSJhZG1pbiI+Mi4gQWRtaW5pc3RyYXRpb24gLyBUZXN0czwvYnV0dG9uPgogIDwvbmF2PgoKICA8bWFpbj4KICAgIDwhLS0gVEFCIDE6IFJhZGlvc2VuZGVyIHBmbGVnZW4gLS0+CiAgICA8c2VjdGlvbiBpZD0idGFiLXN0YXRpb25zIiBjbGFzcz0idGFiLXBhbmVsIGFjdGl2ZSI+CiAgICAgIDxkaXYgY2xhc3M9ImdyaWQiPgogICAgICAgIDxzZWN0aW9uIGNsYXNzPSJjYXJkIHdpZGUiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VjdGlvbi1oZWFkIj4KICAgICAgICAgICAgPGRpdj4KICAgICAgICAgICAgICA8aDI+U2VuZGVybGlzdGUgKHN0YXRpb25zLmluaSk8L2gyPgogICAgICAgICAgICAgIDxwIGNsYXNzPSJtdXRlZCBzbWFsbCI+U2VuZGVyIGbDvHIgIk15IFN0YXRpb25zIiBwZmxlZ2VuLiBOYWNoIGRlbSBTcGVpY2hlcm4gbGllc3QgWVR1bmVyIGRpZSBEYXRlaSBqZSBuYWNoIEVpbnN0ZWxsdW5nIG5ldSBlaW4gKGdnZi4gU2VydmljZSBuZXUgc3RhcnRlbiBvZGVyIEF1dG8tUmVmcmVzaCBudXR6ZW4pLjwvcD4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImFjdGlvbnMiPgogICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0iY2hlY2tBbGxTdGF0aW9uc0J0biI+QWxsZSBwcsO8ZmVuPC9idXR0b24+CiAgICAgICAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGlkPSJhZGRTdGF0aW9uQnRuIj5TZW5kZXIgaGluenVmw7xnZW48L2J1dHRvbj4KICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InJlbG9hZFN0YXRpb25zQnRuIj5OZXUgbGFkZW48L2J1dHRvbj4KICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgaWQ9InNhdmVTdGF0aW9uc0J0biIgY2xhc3M9InByaW1hcnkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBpZD0ic3RhdGlvbnNFZGl0b3IiIGNsYXNzPSJzdGF0aW9ucy1lZGl0b3IiPjwvZGl2PgogICAgICAgICAgPGRldGFpbHMgc3R5bGU9Im1hcmdpbi10b3A6MTJweCI+CiAgICAgICAgICAgIDxzdW1tYXJ5PlJhdyBzdGF0aW9ucy5pbmkgYmVhcmJlaXRlbjwvc3VtbWFyeT4KICAgICAgICAgICAgPHRleHRhcmVhIGlkPSJzdGF0aW9uc1JhdyIgY2xhc3M9InJhdy1lZGl0b3IiIHNwZWxsY2hlY2s9ImZhbHNlIj48L3RleHRhcmVhPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWFjdGlvbnMiPjxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0ic2F2ZVN0YXRpb25zUmF3QnRuIj5SYXcgc3BlaWNoZXJuPC9idXR0b24+PC9kaXY+CiAgICAgICAgICA8L2RldGFpbHM+CiAgICAgICAgICA8cHJlIGlkPSJzdGF0aW9uc1NhdmVSZXN1bHQiIGNsYXNzPSJyZXN1bHQgbXV0ZWQiPjwvcHJlPgogICAgICAgIDwvc2VjdGlvbj4KICAgICAgPC9kaXY+CiAgICA8L3NlY3Rpb24+CgogICAgPCEtLSBUQUIgMjogQWRtaW5pc3RyYXRpb24gLyBUZXN0cyAtLT4KICAgIDxzZWN0aW9uIGlkPSJ0YWItYWRtaW4iIGNsYXNzPSJ0YWItcGFuZWwiPgogICAgICA8ZGl2IGNsYXNzPSJncmlkIj4KICAgICAgICA8c2VjdGlvbiBjbGFzcz0iY2FyZCI+CiAgICAgICAgICA8aDI+U3RhdHVzPC9oMj4KICAgICAgICAgIDxkaXYgaWQ9InN0YXR1c1N1bW1hcnkiIGNsYXNzPSJtdXRlZCI+TGFkZS4uLjwvZGl2PgogICAgICAgICAgPGRpdiBpZD0ic2VydmljZXMiIGNsYXNzPSJsaXN0Ij48L2Rpdj4KICAgICAgICAgIDxkaXYgaWQ9InBvcnRzIiBjbGFzcz0ibGlzdCI+PC9kaXY+CiAgICAgICAgPC9zZWN0aW9uPgoKICAgICAgICA8c2VjdGlvbiBjbGFzcz0iY2FyZCI+CiAgICAgICAgICA8aDI+U3RyZWFtLVByb3h5IEVpbnN0ZWxsdW5nZW48L2gyPgogICAgICAgICAgPGZvcm0gaWQ9InByb3h5Rm9ybSIgY2xhc3M9ImZvcm0iPgogICAgICAgICAgICA8bGFiZWw+SG9zdDxpbnB1dCBuYW1lPSJTVFJFQU1fUFJPWFlfSE9TVCIgcGxhY2Vob2xkZXI9IjAuMC4wLjAiPjwvbGFiZWw+CiAgICAgICAgICAgIDxsYWJlbD5Qb3J0PGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9QT1JUIiB0eXBlPSJudW1iZXIiIG1pbj0iMSIgbWF4PSI2NTUzNSI+PC9sYWJlbD4KICAgICAgICAgICAgPGxhYmVsPlRpbWVvdXQgKHMpPGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9USU1FT1VUIiB0eXBlPSJudW1iZXIiIG1pbj0iMSIgbWF4PSIxMjAiPjwvbGFiZWw+CiAgICAgICAgICAgIDxsYWJlbD5NYXggUmVkaXJlY3RzPGlucHV0IG5hbWU9IlNUUkVBTV9QUk9YWV9NQVhfUkVESVJFQ1RTIiB0eXBlPSJudW1iZXIiIG1pbj0iMCIgbWF4PSIyMCI+PC9sYWJlbD4KICAgICAgICAgICAgPGxhYmVsPkxvZyBMZXZlbAogICAgICAgICAgICAgIDxzZWxlY3QgbmFtZT0iU1RSRUFNX1BST1hZX0xPR19MRVZFTCI+CiAgICAgICAgICAgICAgICA8b3B0aW9uPkRFQlVHPC9vcHRpb24+PG9wdGlvbj5JTkZPPC9vcHRpb24+PG9wdGlvbj5XQVJOSU5HPC9vcHRpb24+PG9wdGlvbj5FUlJPUjwvb3B0aW9uPgogICAgICAgICAgICAgIDwvc2VsZWN0PgogICAgICAgICAgICA8L2xhYmVsPgogICAgICAgICAgICA8bGFiZWw+VXNlciBBZ2VudDxpbnB1dCBuYW1lPSJTVFJFQU1fUFJPWFlfVVNFUl9BR0VOVCIgcGxhY2Vob2xkZXI9Ik1vemlsbGEvNS4wIC4uLiI+PC9sYWJlbD4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1hY3Rpb25zIj4KICAgICAgICAgICAgICA8YnV0dG9uIHR5cGU9InN1Ym1pdCIgY2xhc3M9InByaW1hcnkiPlNwZWljaGVybjwvYnV0dG9uPgogICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBpZD0icmVzdGFydFByb3h5QnRuIj5Qcm94eSBuZXVzdGFydGVuPC9idXR0b24+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPC9mb3JtPgogICAgICAgICAgPHByZSBpZD0icHJveHlTYXZlUmVzdWx0IiBjbGFzcz0icmVzdWx0IG11dGVkIj48L3ByZT4KICAgICAgICA8L3NlY3Rpb24+CgogICAgICAgIDxzZWN0aW9uIGNsYXNzPSJjYXJkIj4KICAgICAgICAgIDxoMj5ZVHVuZXIgS29uZmlndXJhdGlvbiAocmVhZC1vbmx5IMOcYmVyYmxpY2spPC9oMj4KICAgICAgICAgIDxkaXYgaWQ9ImNvbmZpZ1ZpZXciIGNsYXNzPSJrdiI+PC9kaXY+CiAgICAgICAgICA8cCBjbGFzcz0ibXV0ZWQgc21hbGwiPkRhdGVpYmFzaWVydGUgS2VybmtvbmZpZ3VyYXRpb25lbiB3ZXJkZW4gYW5nZXplaWd0OyBCZWFyYmVpdHVuZyBlcmZvbGd0IMO8YmVyIElOSS9FbnYtRGF0ZWllbiBhbSBTZXJ2ZXIuPC9wPgogICAgICAgIDwvc2VjdGlvbj4KCiAgICAgICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQgd2lkZSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWN0aW9uLWhlYWQiPgogICAgICAgICAgICA8aDI+QXV0b3Rlc3QgLyBEaWFnbm9zZTwvaDI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImFjdGlvbnMiPjxidXR0b24gaWQ9InJ1blRlc3RzQnRuIiBjbGFzcz0icHJpbWFyeSI+VGVzdHMgYXVzZsO8aHJlbjwvYnV0dG9uPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGlkPSJ0ZXN0U3VtbWFyeSIgY2xhc3M9Im11dGVkIj5Ob2NoIGtlaW5lIFRlc3RzIGF1c2dlZsO8aHJ0LjwvZGl2PgogICAgICAgICAgPGRpdiBpZD0idGVzdFJlc3VsdHMiIGNsYXNzPSJ0ZXN0LXJlc3VsdHMiPjwvZGl2PgogICAgICAgIDwvc2VjdGlvbj4KCiAgICAgICAgPHNlY3Rpb24gY2xhc3M9ImNhcmQgd2lkZSI+CiAgICAgICAgICA8aDI+TG9nczwvaDI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ0YWJzIj4KICAgICAgICAgICAgPGJ1dHRvbiBkYXRhLWxvZz0ieXR1bmVyIiBjbGFzcz0idGFiIGFjdGl2ZSI+eXR1bmVyLmxvZzwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIGRhdGEtbG9nPSJwcm94eSIgY2xhc3M9InRhYiI+c3RyZWFtLXByb3h5LmxvZzwvYnV0dG9uPgogICAgICAgICAgICA8YnV0dG9uIGRhdGEtbG9nPSJhZG1pbiIgY2xhc3M9InRhYiI+YWRtaW4ubG9nPC9idXR0b24+CiAgICAgICAgICAgIDxidXR0b24gaWQ9InJlZnJlc2hMb2dzQnRuIj5Mb2dzIGxhZGVuPC9idXR0b24+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxwcmUgaWQ9ImxvZ1ZpZXciIGNsYXNzPSJsb2ciPkxhZGUuLi48L3ByZT4KICAgICAgICA8L3NlY3Rpb24+CiAgICAgIDwvZGl2PgogICAgPC9zZWN0aW9uPgogIDwvbWFpbj4KCiAgPHNjcmlwdCBzcmM9Ii9hcHAuanMiPjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K'
WEB_CSS_B64='OnJvb3R7LS1iZzojZjRmNmYxOy0tY2FyZDojZmZmZWY5Oy0taW5rOiMxZDJhMWY7LS1tdXRlZDojNWY2ZTYxOy0tbGluZTojZDdkZGQyOy0tYWNjZW50OiMxZjdhNGQ7LS1hY2NlbnQyOiNjNzViMmM7LS1iYWQ6I2IzMjYxZTstLW9rOiMxYjdmM2E7LS13YXJuOiM4YTVhMDA7LS1tb25vOnVpLW1vbm9zcGFjZSxTRk1vbm8tUmVndWxhcixNZW5sbyxtb25vc3BhY2U7LS1zYW5zOiJJQk0gUGxleCBTYW5zIiwiQXZlbmlyIE5leHQiLCJTZWdvZSBVSSIsc2Fucy1zZXJpZn0KKntib3gtc2l6aW5nOmJvcmRlci1ib3h9Ym9keXttYXJnaW46MDtmb250LWZhbWlseTp2YXIoLS1zYW5zKTtjb2xvcjp2YXIoLS1pbmspO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE4MGRlZywjZWVmNGVhIDAlLHZhcigtLWJnKSAxODBweCl9Ci50b3BiYXJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxNnB4O3BhZGRpbmc6MjRweCAyNHB4IDhweDthbGlnbi1pdGVtczpmbGV4LWVuZH0KaDF7bWFyZ2luOjA7Zm9udC1zaXplOjJyZW07bGV0dGVyLXNwYWNpbmc6LS4wMmVtfWgye21hcmdpbjowIDAgMTJweDtmb250LXNpemU6MS4wNXJlbX0KLm11dGVke2NvbG9yOnZhcigtLW11dGVkKX0uc21hbGx7Zm9udC1zaXplOi44OHJlbX0KLm1haW4tdGFic3tkaXNwbGF5OmZsZXg7Z2FwOjhweDtwYWRkaW5nOjAgMjRweCAxNnB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWxpbmUpfQoubWFpbi10YWJ7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7YmFja2dyb3VuZDojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQ6aW5oZXJpdDtmb250LXdlaWdodDo2MDB9Ci5tYWluLXRhYi5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1hY2NlbnQpO2NvbG9yOiNmZmY7Ym9yZGVyLWNvbG9yOnZhcigtLWFjY2VudCl9Ci50YWItcGFuZWx7ZGlzcGxheTpub25lfS50YWItcGFuZWwuYWN0aXZle2Rpc3BsYXk6YmxvY2t9Ci5ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsbWlubWF4KDAsMWZyKSk7Z2FwOjE2cHg7cGFkZGluZzoxNnB4IDI0cHggMzJweH0KLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWxpbmUpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7Ym94LXNoYWRvdzowIDFweCAwIHJnYmEoMCwwLDAsLjAyKX0KLmNhcmQud2lkZXtncmlkLWNvbHVtbjoxLy0xfQouc2VjdGlvbi1oZWFke2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O21hcmdpbi1ib3R0b206MTJweH0KLnNlY3Rpb24taGVhZCBoMnttYXJnaW4tYm90dG9tOjRweH0KLmFjdGlvbnMsLmZvcm0tYWN0aW9ucywudGFic3tkaXNwbGF5OmZsZXg7Z2FwOjhweDtmbGV4LXdyYXA6d3JhcH0KYnV0dG9ue2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7YmFja2dyb3VuZDojZmZmO2NvbG9yOnZhcigtLWluayk7cGFkZGluZzo4cHggMTJweDtib3JkZXItcmFkaXVzOjEwcHg7Y3Vyc29yOnBvaW50ZXI7Zm9udDppbmhlcml0fQpidXR0b24ucHJpbWFyeXtiYWNrZ3JvdW5kOnZhcigtLWFjY2VudCk7Y29sb3I6I2ZmZjtib3JkZXItY29sb3I6dmFyKC0tYWNjZW50KX0KYnV0dG9uOmhvdmVye2ZpbHRlcjpicmlnaHRuZXNzKC45OCl9IGJ1dHRvbjpkaXNhYmxlZHtvcGFjaXR5Oi42O2N1cnNvcjp3YWl0fQoubGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4fQouaXRlbXtkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6I2ZmZn0KLmJhZGdle3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjk5OXB4O2ZvbnQtc2l6ZTouNzhyZW07Zm9udC13ZWlnaHQ6NjAwO3doaXRlLXNwYWNlOm5vd3JhcH0ub2t7YmFja2dyb3VuZDojZThmNWViO2NvbG9yOnZhcigtLW9rKX0uYmFke2JhY2tncm91bmQ6I2ZkZWNlYjtjb2xvcjp2YXIoLS1iYWQpfS53YXJue2JhY2tncm91bmQ6I2ZmZjRkZDtjb2xvcjp2YXIoLS13YXJuKX0KLmZvcm17ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczpyZXBlYXQoMixtaW5tYXgoMCwxZnIpKTtnYXA6MTBweH0KbGFiZWx7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6NHB4O2ZvbnQtc2l6ZTouOXJlbX0KaW5wdXQsc2VsZWN0LHRleHRhcmVhe3BhZGRpbmc6OHB4IDEwcHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1saW5lKTtib3JkZXItcmFkaXVzOjhweDtmb250OmluaGVyaXQ7YmFja2dyb3VuZDojZmZmfQouZm9ybS1hY3Rpb25ze2dyaWQtY29sdW1uOjEvLTE7bWFyZ2luLXRvcDo0cHh9Ci5rdntkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjE4MHB4IDFmcjtnYXA6NnB4IDEycHg7Zm9udC1zaXplOi45MnJlbX0KLmt2IC5re2NvbG9yOnZhcigtLW11dGVkKX0ua3YgLnZ7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7d29yZC1icmVhazpicmVhay13b3JkfQoucmVzdWx0LC5sb2d7YmFja2dyb3VuZDojMWEyMTFiO2NvbG9yOiNkY2U3ZGM7cGFkZGluZzoxMnB4O2JvcmRlci1yYWRpdXM6MTBweDtvdmVyZmxvdzphdXRvO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZTouODVyZW07bGluZS1oZWlnaHQ6MS40NX0KLmxvZ3ttaW4taGVpZ2h0OjI2MHB4O21heC1oZWlnaHQ6NDIwcHh9LnJlc3VsdHttaW4taGVpZ2h0OjQ0cHg7bWFyZ2luLXRvcDoxMHB4fQoudGVzdC1yZXN1bHRze2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhweDttYXJnaW4tdG9wOjEwcHh9Ci50ZXN0e2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDtiYWNrZ3JvdW5kOiNmZmZ9Ci50ZXN0IC5oZWFke2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTBweDtmb250LXdlaWdodDo2MDB9Ci50ZXN0IHByZXttYXJnaW46OHB4IDAgMDtiYWNrZ3JvdW5kOiNmNmY4ZjQ7Y29sb3I6IzIxMztwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtvdmVyZmxvdzphdXRvO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZTouOHJlbX0KLnRhYi5hY3RpdmV7YmFja2dyb3VuZDojZThmNWViO2JvcmRlci1jb2xvcjojYjlkN2MzfQouc3RhdGlvbnMtZWRpdG9ye2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjEycHh9Ci5zdGF0aW9uLWdyb3Vwe2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTJweDtiYWNrZ3JvdW5kOiNmZmZ9Ci5zdGF0aW9uLWdyb3VwIC5ncm91cC1oZWFke2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlcjttYXJnaW4tYm90dG9tOjEwcHg7ZmxleC13cmFwOndyYXB9Ci5zdGF0aW9uLWdyb3VwIC5ncm91cC1oZWFkIGlucHV0e2ZsZXg6MTttaW4td2lkdGg6MTgwcHg7Zm9udC13ZWlnaHQ6NjAwfQouc3RhdGlvbi1yb3d7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxLjJmciAyZnIgMS4yZnIgYXV0byBhdXRvO2dhcDo4cHg7bWFyZ2luLWJvdHRvbTo4cHg7YWxpZ24taXRlbXM6c3RhcnR9Ci5zdGF0aW9uLXJvdyBpbnB1dHt3aWR0aDoxMDAlfQouc3RhdGlvbi1zdGF0dXN7Zm9udC1zaXplOi43OHJlbTtwYWRkaW5nOjZweCA4cHg7Ym9yZGVyLXJhZGl1czo4cHg7YmFja2dyb3VuZDojZjNmNWYxO2NvbG9yOnZhcigtLW11dGVkKTttaW4td2lkdGg6MTQwcHg7bWF4LXdpZHRoOjI2MHB4O292ZXJmbG93OmhpZGRlbjt0ZXh0LW92ZXJmbG93OmVsbGlwc2lzfQouc3RhdGlvbi1zdGF0dXMub2t7YmFja2dyb3VuZDojZThmNWViO2NvbG9yOnZhcigtLW9rKX0KLnN0YXRpb24tc3RhdHVzLmJhZHtiYWNrZ3JvdW5kOiNmZGVjZWI7Y29sb3I6dmFyKC0tYmFkKX0KLnN0YXRpb24tc3RhdHVzLndhcm57YmFja2dyb3VuZDojZmZmNGRkO2NvbG9yOnZhcigtLXdhcm4pfQoucmF3LWVkaXRvcnt3aWR0aDoxMDAlO21pbi1oZWlnaHQ6MjIwcHg7bWFyZ2luLXRvcDo4cHg7cGFkZGluZzoxMHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tbGluZSk7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Zm9udC1zaXplOi44NXJlbX0KQG1lZGlhIChtYXgtd2lkdGg6MTEwMHB4KXsuc3RhdGlvbi1yb3d7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnJ9fQpAbWVkaWEgKG1heC13aWR0aDo5MDBweCl7LmdyaWR7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmcn0uZm9ybXtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS50b3BiYXJ7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOnN0cmV0Y2h9LnN0YXRpb24tcm93e2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fQo='
WEB_JS_B64='YXN5bmMgZnVuY3Rpb24gYXBpKHBhdGgsIG9wdHM9e30pIHsKICBjb25zdCByZXMgPSBhd2FpdCBmZXRjaChwYXRoLCB7aGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nLCAuLi4ob3B0cy5oZWFkZXJzfHx7fSl9LCAuLi5vcHRzfSk7CiAgY29uc3QgdGV4dCA9IGF3YWl0IHJlcy50ZXh0KCk7CiAgbGV0IGRhdGE7IHRyeSB7IGRhdGEgPSBKU09OLnBhcnNlKHRleHQpOyB9IGNhdGNoIHsgZGF0YSA9IHtyYXc6dGV4dH07IH0KICBpZiAoIXJlcy5vaykgdGhyb3cgT2JqZWN0LmFzc2lnbihuZXcgRXJyb3IoZGF0YS5lcnJvciB8fCByZXMuc3RhdHVzVGV4dCksIHtkYXRhLCBzdGF0dXM6cmVzLnN0YXR1c30pOwogIHJldHVybiBkYXRhOwp9CmNvbnN0ICQgPSAocyk9PmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3Iocyk7CmNvbnN0ICQkID0gKHMpPT5BcnJheS5mcm9tKGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwocykpOwpjb25zdCBlc2MgPSAocyk9PlN0cmluZyhzPz8nJykucmVwbGFjZSgvWyY8PiInXS9nLGM9Pih7JyYnOicmYW1wOycsJzwnOicmbHQ7JywnPic6JyZndDsnLCciJzonJnF1b3Q7JywiJyI6JyYjMzk7J31bY10pKTsKZnVuY3Rpb24gYmFkZ2Uob2ssIHRleHQpeyBjb25zdCBjbHMgPSBvaz09PXRydWU/J29rJzpvaz09PWZhbHNlPydiYWQnOid3YXJuJzsgcmV0dXJuIGA8c3BhbiBjbGFzcz0iYmFkZ2UgJHtjbHN9Ij4ke2VzYyh0ZXh0KX08L3NwYW4+YDsgfQoKLyogLS0tLSBUYWJzIC0tLS0gKi8KJCQoJy5tYWluLXRhYicpLmZvckVhY2goYnRuPT5idG4uYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoKT0+ewogICQkKCcubWFpbi10YWInKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogICQkKCcudGFiLXBhbmVsJykuZm9yRWFjaChwPT5wLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgJCgnI3RhYi0nICsgYnRuLmRhdGFzZXQudGFiKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKfSkpOwoKLyogLS0tLSBTdGF0dXMgLyBDb25maWcgLS0tLSAqLwphc3luYyBmdW5jdGlvbiBsb2FkU3RhdHVzKCl7CiAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9zdGF0dXMnKTsKICBjb25zdCBzdmMgPSBkLnNlcnZpY2VzfHxbXTsKICBjb25zdCBwb3J0cyA9IGQucG9ydHN8fFtdOwogICQoJyNzdGF0dXNTdW1tYXJ5JykuaW5uZXJIVE1MID0gYEFrdHVhbGlzaWVydDogJHtuZXcgRGF0ZSgpLnRvTG9jYWxlU3RyaW5nKCl9IHwgQVBJIG9rYDsKICAkKCcjc2VydmljZXMnKS5pbm5lckhUTUwgPSBzdmMubWFwKHM9PmA8ZGl2IGNsYXNzPSJpdGVtIj48ZGl2PjxzdHJvbmc+JHtlc2Mocy5uYW1lKX08L3N0cm9uZz48ZGl2IGNsYXNzPSJtdXRlZCBzbWFsbCI+JHtlc2MoSlNPTi5zdHJpbmdpZnkocy5wcm9wc3x8e30pKX08L2Rpdj48L2Rpdj48ZGl2PiR7YmFkZ2Uocy5hY3RpdmU9PT0nYWN0aXZlJywgcy5hY3RpdmUpfSAke2JhZGdlKHMuZW5hYmxlZD09PSdlbmFibGVkJ3x8cy5lbmFibGVkPT09J3N0YXRpYyd8fHMuZW5hYmxlZD09PSd1bmtub3duJywgcy5lbmFibGVkKX08L2Rpdj48L2Rpdj5gKS5qb2luKCcnKTsKICAkKCcjcG9ydHMnKS5pbm5lckhUTUwgPSBwb3J0cy5tYXAocD0+YDxkaXYgY2xhc3M9Iml0ZW0iPjxkaXY+PHN0cm9uZz5Qb3J0ICR7ZXNjKHAucG9ydCl9PC9zdHJvbmc+PC9kaXY+JHtiYWRnZShwLm9wZW4sIHAub3Blbj8nb3Blbic6J2Nsb3NlZCcpfTwvZGl2PmApLmpvaW4oJycpOwogIHJlbmRlckNvbmZpZyhkLmNvbmZpZ3x8e30pOwogIGZpbGxQcm94eUZvcm0oKGQuY29uZmlnfHx7fSkucHJveHl8fHt9KTsKfQpmdW5jdGlvbiByZW5kZXJDb25maWcoY2ZnKXsKICBjb25zdCByb3dzPVtdOwogIGNvbnN0IGFkZD0oayx2KT0+cm93cy5wdXNoKGA8ZGl2IGNsYXNzPSJrIj4ke2VzYyhrKX08L2Rpdj48ZGl2IGNsYXNzPSJ2Ij4ke2VzYyh0eXBlb2Ygdj09PSdvYmplY3QnP0pTT04uc3RyaW5naWZ5KHYpOnYpfTwvZGl2PmApOwogIGFkZCgnaW5zdGFsbF9kaXInLCBjZmcucGF0aHM/Lmluc3RhbGxfZGlyKTsKICBhZGQoJ3l0dW5lci5pbmknLCBjZmcucGF0aHM/Lnl0dW5lcl9pbmkpOwogIGFkZCgnYXZyLmluaScsIGNmZy5wYXRocz8uYXZyX2luaSk7CiAgYWRkKCdzdGF0aW9ucy5pbmknLCBjZmcucGF0aHM/LnN0YXRpb25zX2luaSk7CiAgYWRkKCdwcm94eV9lbnYnLCBjZmcucGF0aHM/LnByb3h5X2Vudik7CiAgYWRkKCd5dHVuZXIud2ViX3BvcnQnLCBjZmcueXR1bmVyPy53ZWJfcG9ydCk7CiAgYWRkKCd5dHVuZXIuZG5zX3BvcnQnLCBjZmcueXR1bmVyPy5kbnNfcG9ydCk7CiAgYWRkKCd5dHVuZXIuaW50ZXJjZXB0X2RucycsIGNmZy55dHVuZXI/LmludGVyY2VwdF9kbnMpOwogIGFkZCgneXR1bmVyLnJiX2NhY2hlX3R5cGUnLCBjZmcueXR1bmVyPy5yYl9jYWNoZV90eXBlKTsKICBhZGQoJ2F2ci5wcm90b2NvbCcsIGNmZy5hdnI/LnByb3RvY29sKTsKICAkKCcjY29uZmlnVmlldycpLmlubmVySFRNTCA9IHJvd3Muam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsbFByb3h5Rm9ybShwcm94eSl7CiAgY29uc3QgZiA9ICQoJyNwcm94eUZvcm0nKTsKICBmb3IgKGNvbnN0IFtrLHZdIG9mIE9iamVjdC5lbnRyaWVzKHByb3h5fHx7fSkpewogICAgY29uc3Qga2V5ID0gJ1NUUkVBTV9QUk9YWV8nICsgay50b1VwcGVyQ2FzZSgpOwogICAgY29uc3QgZWwgPSBmLmVsZW1lbnRzLm5hbWVkSXRlbShrZXkpOwogICAgaWYgKGVsKSBlbC52YWx1ZSA9IHY7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIHNhdmVQcm94eShldil7CiAgZXYucHJldmVudERlZmF1bHQoKTsKICBjb25zdCBmZCA9IG5ldyBGb3JtRGF0YShldi50YXJnZXQpOwogIGNvbnN0IHBheWxvYWQgPSBPYmplY3QuZnJvbUVudHJpZXMoZmQuZW50cmllcygpKTsKICAkKCcjcHJveHlTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSAnU3BlaWNoZXJlLi4uJzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9jb25maWcvcHJveHknLCB7bWV0aG9kOidQT1NUJywgYm9keTpKU09OLnN0cmluZ2lmeShwYXlsb2FkKX0pOwogICAgJCgnI3Byb3h5U2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gSlNPTi5zdHJpbmdpZnkoZCwgbnVsbCwgMik7CiAgICBhd2FpdCBsb2FkU3RhdHVzKCk7CiAgfSBjYXRjaChlKXsgJCgnI3Byb3h5U2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gSlNPTi5zdHJpbmdpZnkoZS5kYXRhfHx7ZXJyb3I6ZS5tZXNzYWdlfSwgbnVsbCwgMik7IH0KfQphc3luYyBmdW5jdGlvbiByZXN0YXJ0UHJveHkoKXsKICAkKCcjcHJveHlTYXZlUmVzdWx0JykudGV4dENvbnRlbnQgPSAnU3RhcnRlIFByb3h5IG5ldS4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBhcGkoJy9hcGkvc2VydmljZS9yZXN0YXJ0Jywge21ldGhvZDonUE9TVCcsIGJvZHk6SlNPTi5zdHJpbmdpZnkoe25hbWU6J3l0dW5lci1zdHJlYW0tcHJveHknfSl9KTsKICAgICQoJyNwcm94eVNhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IEpTT04uc3RyaW5naWZ5KGQsIG51bGwsIDIpOwogICAgYXdhaXQgbG9hZFN0YXR1cygpOwogIH0gY2F0Y2goZSl7ICQoJyNwcm94eVNhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9IEpTT04uc3RyaW5naWZ5KGUuZGF0YXx8e2Vycm9yOmUubWVzc2FnZX0sIG51bGwsIDIpOyB9Cn0KCi8qIC0tLS0gVGVzdHMgLS0tLSAqLwphc3luYyBmdW5jdGlvbiBydW5UZXN0cygpewogICQoJyN0ZXN0U3VtbWFyeScpLnRleHRDb250ZW50ID0gJ1Rlc3RzIGxhdWZlbi4uLic7CiAgJCgnI3Rlc3RSZXN1bHRzJykuaW5uZXJIVE1MID0gJyc7CiAgdHJ5IHsgcmVuZGVyVGVzdHMoYXdhaXQgYXBpKCcvYXBpL3Rlc3RzL3J1bicsIHttZXRob2Q6J1BPU1QnfSkpOyB9CiAgY2F0Y2goZSl7ICQoJyN0ZXN0U3VtbWFyeScpLnRleHRDb250ZW50ID0gJ0ZlaGxlcjogJyArIGUubWVzc2FnZTsgfQp9CmZ1bmN0aW9uIHJlbmRlclRlc3RzKGQpewogICQoJyN0ZXN0U3VtbWFyeScpLmlubmVySFRNTCA9IGAke2JhZGdlKGQub2ssIGQub2s/J1BBU1MnOidGQUlMJyl9ICR7ZC5wYXNzZWR9LyR7ZC50b3RhbH0gYmVzdGFuZGVuLCAke2QuZmFpbGVkfSBmZWhsZ2VzY2hsYWdlbmA7CiAgJCgnI3Rlc3RSZXN1bHRzJykuaW5uZXJIVE1MID0gKGQucmVzdWx0c3x8W10pLm1hcChyPT5gPGRpdiBjbGFzcz0idGVzdCI+PGRpdiBjbGFzcz0iaGVhZCI+PHNwYW4+JHtlc2Moci5uYW1lKX08L3NwYW4+JHtiYWRnZShyLm9rLHIub2s/J29rJzonZmFpbCcpfTwvZGl2PjxwcmU+JHtlc2MoSlNPTi5zdHJpbmdpZnkoci5kZXRhaWwsIG51bGwsIDIpKX08L3ByZT48L2Rpdj5gKS5qb2luKCcnKTsKfQoKLyogLS0tLSBTdGF0aW9ucyAtLS0tICovCmxldCBzdGF0aW9uc01vZGVsID0gW107CmZ1bmN0aW9uIG5vcm1hbGl6ZVN0YXRpb25zKGdyb3Vwcyl7CiAgaWYgKCFBcnJheS5pc0FycmF5KGdyb3VwcykgfHwgIWdyb3Vwcy5sZW5ndGgpIHJldHVybiBbe25hbWU6J015IFN0YXRpb25zJywgc3RhdGlvbnM6W119XTsKICByZXR1cm4gZ3JvdXBzLm1hcChnPT4oe25hbWU6IFN0cmluZyhnPy5uYW1lfHwnVW5ncm91cGVkJyksIHN0YXRpb25zOiBBcnJheS5pc0FycmF5KGc/LnN0YXRpb25zKT9nLnN0YXRpb25zLm1hcChzPT4oe25hbWU6U3RyaW5nKHM/Lm5hbWV8fCcnKSwgdXJsOlN0cmluZyhzPy51cmx8fCcnKSwgbG9nbzpTdHJpbmcocz8ubG9nb3x8JycpLCBfc3RhdHVzOnMuX3N0YXR1c3x8bnVsbH0pKTpbXX0pKTsKfQpmdW5jdGlvbiBzdGF0dXNIdG1sKHN0KXsKICBpZiAoIXN0IHx8ICFzdC51cmwpIHJldHVybiAnPHNwYW4gY2xhc3M9InN0YXRpb24tc3RhdHVzIHdhcm4iPmtlaW5lIFVSTDwvc3Bhbj4nOwogIGlmICghc3QuX3N0YXR1cykgcmV0dXJuICc8c3BhbiBjbGFzcz0ic3RhdGlvbi1zdGF0dXMiPm5pY2h0IGdlcHLDvGZ0PC9zcGFuPic7CiAgY29uc3QgcyA9IHN0Ll9zdGF0dXM7CiAgaWYgKHMuY2hlY2tpbmcpIHJldHVybiAnPHNwYW4gY2xhc3M9InN0YXRpb24tc3RhdHVzIHdhcm4iPnByw7xmZS4uLjwvc3Bhbj4nOwogIGlmIChzLnJlYWNoYWJsZSkgcmV0dXJuIGA8c3BhbiBjbGFzcz0ic3RhdGlvbi1zdGF0dXMgb2siPk9LICR7ZXNjKHMuc3RhdHVzPz8nJyl9ICR7ZXNjKHMuY29udGVudF90eXBlfHwnJyl9ICR7ZXNjKHMubXM/PycnKX1tczwvc3Bhbj5gOwogIHJldHVybiBgPHNwYW4gY2xhc3M9InN0YXRpb24tc3RhdHVzIGJhZCI+RkFJTCAke2VzYyhzLnN0YXR1cz8/JycpfSAke2VzYyhzLmVycm9yfHwnJyl9PC9zcGFuPmA7Cn0KZnVuY3Rpb24gcmVuZGVyU3RhdGlvbnNFZGl0b3IoKXsKICBjb25zdCByb290ID0gJCgnI3N0YXRpb25zRWRpdG9yJyk7CiAgcm9vdC5pbm5lckhUTUwgPSBzdGF0aW9uc01vZGVsLm1hcCgoZyxnaSk9PmAKICAgIDxkaXYgY2xhc3M9InN0YXRpb24tZ3JvdXAiIGRhdGEtZ2k9IiR7Z2l9Ij4KICAgICAgPGRpdiBjbGFzcz0iZ3JvdXAtaGVhZCI+CiAgICAgICAgPGlucHV0IHZhbHVlPSIke2VzYyhnLm5hbWUpfSIgcGxhY2Vob2xkZXI9IkdydXBwZW5uYW1lIiBkYXRhLWZpZWxkPSJncm91cC1uYW1lIj4KICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Rpb249ImFkZC1zdGF0aW9uIj4rIFNlbmRlcjwvYnV0dG9uPgogICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdGlvbj0iY2hlY2stZ3JvdXAiPkdydXBwZSBwcsO8ZmVuPC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGRhdGEtYWN0aW9uPSJyZW1vdmUtZ3JvdXAiPkdydXBwZSBsw7ZzY2hlbjwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgJHsoZy5zdGF0aW9uc3x8W10pLm1hcCgocyxzaSk9PmAKICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0aW9uLXJvdyIgZGF0YS1zaT0iJHtzaX0iPgogICAgICAgICAgPGlucHV0IHZhbHVlPSIke2VzYyhzLm5hbWUpfSIgcGxhY2Vob2xkZXI9IlNlbmRlcm5hbWUiIGRhdGEtZmllbGQ9Im5hbWUiPgogICAgICAgICAgPGlucHV0IHZhbHVlPSIke2VzYyhzLnVybCl9IiBwbGFjZWhvbGRlcj0iU3RyZWFtIFVSTCAoaHR0cC9odHRwcykiIGRhdGEtZmllbGQ9InVybCI+CiAgICAgICAgICA8aW5wdXQgdmFsdWU9IiR7ZXNjKHMubG9nbyl9IiBwbGFjZWhvbGRlcj0iTG9nbyBVUkwgKG9wdGlvbmFsKSIgZGF0YS1maWVsZD0ibG9nbyI+CiAgICAgICAgICA8YnV0dG9uIHR5cGU9ImJ1dHRvbiIgZGF0YS1hY3Rpb249ImNoZWNrLXN0YXRpb24iPlByw7xmZW48L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBkYXRhLWFjdGlvbj0icmVtb3ZlLXN0YXRpb24iPkVudGZlcm5lbjwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9Im1hcmdpbjotNHB4IDAgMTBweCAwIj4ke3N0YXR1c0h0bWwocyl9PC9kaXY+YCkuam9pbignJyl9CiAgICA8L2Rpdj5gKS5qb2luKCcnKTsKfQpmdW5jdGlvbiBjb2xsZWN0U3RhdGlvbnNGcm9tRWRpdG9yKCl7CiAgY29uc3QgZ3JvdXBzPVtdOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zdGF0aW9uLWdyb3VwJykuZm9yRWFjaChnRWw9PnsKICAgIGNvbnN0IGdpID0gTnVtYmVyKGdFbC5kYXRhc2V0LmdpKTsKICAgIGNvbnN0IG9sZCA9IHN0YXRpb25zTW9kZWxbZ2ldIHx8IHtzdGF0aW9uczpbXX07CiAgICBjb25zdCBuYW1lID0gZ0VsLnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWZpZWxkPSJncm91cC1uYW1lIl0nKS52YWx1ZS50cmltKCkgfHwgJ1VuZ3JvdXBlZCc7CiAgICBjb25zdCBzdGF0aW9ucz1bXTsKICAgIGdFbC5xdWVyeVNlbGVjdG9yQWxsKCcuc3RhdGlvbi1yb3cnKS5mb3JFYWNoKHJFbD0+ewogICAgICBjb25zdCBzaSA9IE51bWJlcihyRWwuZGF0YXNldC5zaSk7CiAgICAgIGNvbnN0IHByZXYgPSAob2xkLnN0YXRpb25zfHxbXSlbc2ldIHx8IHt9OwogICAgICBjb25zdCBzdD17bmFtZTpyRWwucXVlcnlTZWxlY3RvcignW2RhdGEtZmllbGQ9Im5hbWUiXScpLnZhbHVlLnRyaW0oKSwgdXJsOnJFbC5xdWVyeVNlbGVjdG9yKCdbZGF0YS1maWVsZD0idXJsIl0nKS52YWx1ZS50cmltKCksIGxvZ286ckVsLnF1ZXJ5U2VsZWN0b3IoJ1tkYXRhLWZpZWxkPSJsb2dvIl0nKS52YWx1ZS50cmltKCksIF9zdGF0dXM6cHJldi5fc3RhdHVzfHxudWxsfTsKICAgICAgLy8gaW52YWxpZGF0ZSBzdGF0dXMgaWYgdXJsIGNoYW5nZWQKICAgICAgaWYgKHByZXYudXJsICE9PSBzdC51cmwpIHN0Ll9zdGF0dXMgPSBudWxsOwogICAgICBpZiAoc3QubmFtZSB8fCBzdC51cmwgfHwgc3QubG9nbykgc3RhdGlvbnMucHVzaChzdCk7CiAgICB9KTsKICAgIGdyb3Vwcy5wdXNoKHtuYW1lLCBzdGF0aW9uc30pOwogIH0pOwogIHN0YXRpb25zTW9kZWwgPSBub3JtYWxpemVTdGF0aW9ucyhncm91cHMpOwogIHJldHVybiBzdGF0aW9uc01vZGVsOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRTdGF0aW9ucygpewogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgYXBpKCcvYXBpL3N0YXRpb25zJyk7CiAgICBzdGF0aW9uc01vZGVsID0gbm9ybWFsaXplU3RhdGlvbnMoZC5ncm91cHN8fFtdKTsKICAgICQoJyNzdGF0aW9uc1JhdycpLnZhbHVlID0gZC5yYXcgfHwgJyc7CiAgICByZW5kZXJTdGF0aW9uc0VkaXRvcigpOwogICAgJCgnI3N0YXRpb25zU2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gYEdlbGFkZW46ICR7ZC5wYXRofWA7CiAgfSBjYXRjaChlKXsgJCgnI3N0YXRpb25zU2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gJ0ZlaGxlcjogJysoZS5kYXRhPy5lcnJvcnx8ZS5tZXNzYWdlKTsgfQp9CmFzeW5jIGZ1bmN0aW9uIHNhdmVTdGF0aW9ucyhncm91cHMpewogICQoJyNzdGF0aW9uc1NhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9ICdTcGVpY2hlcmUgc3RhdGlvbnMuaW5pLi4uJzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9zdGF0aW9ucycsIHttZXRob2Q6J1BPU1QnLCBib2R5OiBKU09OLnN0cmluZ2lmeShncm91cHMgPyB7Z3JvdXBzfSA6IHtyYXc6ICQoJyNzdGF0aW9uc1JhdycpLnZhbHVlfSl9KTsKICAgIC8vIHByZXNlcnZlIHN0YXR1cyBieSBVUkwKICAgIGNvbnN0IG9sZFN0YXR1cyA9IG5ldyBNYXAoKTsKICAgIHN0YXRpb25zTW9kZWwuZmxhdE1hcChnPT5nLnN0YXRpb25zfHxbXSkuZm9yRWFjaChzPT57IGlmKHMudXJsICYmIHMuX3N0YXR1cykgb2xkU3RhdHVzLnNldChzLnVybCwgcy5fc3RhdHVzKTsgfSk7CiAgICBzdGF0aW9uc01vZGVsID0gbm9ybWFsaXplU3RhdGlvbnMoZC5ncm91cHN8fFtdKS5tYXAoZz0+KHsuLi5nLCBzdGF0aW9uczpnLnN0YXRpb25zLm1hcChzPT4oey4uLnMsIF9zdGF0dXM6b2xkU3RhdHVzLmdldChzLnVybCl8fG51bGx9KSl9KSk7CiAgICAkKCcjc3RhdGlvbnNSYXcnKS52YWx1ZSA9IGQucmF3IHx8ICcnOwogICAgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsKICAgICQoJyNzdGF0aW9uc1NhdmVSZXN1bHQnKS50ZXh0Q29udGVudCA9ICdHZXNwZWljaGVydDogJytkLnBhdGg7CiAgfSBjYXRjaChlKXsgJCgnI3N0YXRpb25zU2F2ZVJlc3VsdCcpLnRleHRDb250ZW50ID0gJ0ZlaGxlcjogJytKU09OLnN0cmluZ2lmeShlLmRhdGF8fHtlcnJvcjplLm1lc3NhZ2V9KTsgfQp9CmFzeW5jIGZ1bmN0aW9uIGNoZWNrU3RhdGlvbihnaSwgc2kpewogIGNvbGxlY3RTdGF0aW9uc0Zyb21FZGl0b3IoKTsKICBjb25zdCBzdCA9IHN0YXRpb25zTW9kZWw/LltnaV0/LnN0YXRpb25zPy5bc2ldOwogIGlmICghc3QgfHwgIXN0LnVybCkgcmV0dXJuOwogIHN0Ll9zdGF0dXMgPSB7Y2hlY2tpbmc6dHJ1ZX07CiAgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGFwaSgnL2FwaS9zdGF0aW9ucy9jaGVjaz91cmw9JyArIGVuY29kZVVSSUNvbXBvbmVudChzdC51cmwpKTsKICAgIHN0Ll9zdGF0dXMgPSBkOwogIH0gY2F0Y2goZSl7IHN0Ll9zdGF0dXMgPSB7cmVhY2hhYmxlOmZhbHNlLCBlcnJvcjplLm1lc3NhZ2V9OyB9CiAgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsKfQphc3luYyBmdW5jdGlvbiBjaGVja0FsbFN0YXRpb25zKCl7CiAgY29sbGVjdFN0YXRpb25zRnJvbUVkaXRvcigpOwogIGNvbnN0IGpvYnM9W107CiAgc3RhdGlvbnNNb2RlbC5mb3JFYWNoKChnLGdpKT0+IChnLnN0YXRpb25zfHxbXSkuZm9yRWFjaCgocyxzaSk9PnsgaWYocy51cmwpIGpvYnMucHVzaChbZ2ksc2ldKTsgfSkpOwogIGZvciAoY29uc3QgW2dpLHNpXSBvZiBqb2JzKSB7IGF3YWl0IGNoZWNrU3RhdGlvbihnaSxzaSk7IH0KfQoKJCgnI3N0YXRpb25zRWRpdG9yJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCAoZXYpPT57CiAgY29uc3QgYnRuID0gZXYudGFyZ2V0LmNsb3Nlc3QoJ2J1dHRvbltkYXRhLWFjdGlvbl0nKTsgaWYoIWJ0bikgcmV0dXJuOwogIGNvbnN0IGdFbCA9IGJ0bi5jbG9zZXN0KCcuc3RhdGlvbi1ncm91cCcpOyBjb25zdCBnaSA9IE51bWJlcihnRWwuZGF0YXNldC5naSk7CiAgY29sbGVjdFN0YXRpb25zRnJvbUVkaXRvcigpOwogIGlmIChidG4uZGF0YXNldC5hY3Rpb249PT0nYWRkLXN0YXRpb24nKSBzdGF0aW9uc01vZGVsW2dpXS5zdGF0aW9ucy5wdXNoKHtuYW1lOicnLHVybDonJyxsb2dvOicnLF9zdGF0dXM6bnVsbH0pOwogIGlmIChidG4uZGF0YXNldC5hY3Rpb249PT0ncmVtb3ZlLWdyb3VwJykgc3RhdGlvbnNNb2RlbC5zcGxpY2UoZ2ksMSk7CiAgaWYgKGJ0bi5kYXRhc2V0LmFjdGlvbj09PSdyZW1vdmUtc3RhdGlvbicpIHsgY29uc3Qgc2k9TnVtYmVyKGJ0bi5jbG9zZXN0KCcuc3RhdGlvbi1yb3cnKS5kYXRhc2V0LnNpKTsgc3RhdGlvbnNNb2RlbFtnaV0uc3RhdGlvbnMuc3BsaWNlKHNpLDEpOyB9CiAgaWYgKGJ0bi5kYXRhc2V0LmFjdGlvbj09PSdjaGVjay1zdGF0aW9uJykgeyBjb25zdCBzaT1OdW1iZXIoYnRuLmNsb3Nlc3QoJy5zdGF0aW9uLXJvdycpLmRhdGFzZXQuc2kpOyBjaGVja1N0YXRpb24oZ2ksc2kpOyByZXR1cm47IH0KICBpZiAoYnRuLmRhdGFzZXQuYWN0aW9uPT09J2NoZWNrLWdyb3VwJykgeyAoc3RhdGlvbnNNb2RlbFtnaV0uc3RhdGlvbnN8fFtdKS5mb3JFYWNoKChfLHNpKT0+e30pOyByZW5kZXJTdGF0aW9uc0VkaXRvcigpOyAoYXN5bmMoKT0+eyBmb3IobGV0IHNpPTA7IHNpPChzdGF0aW9uc01vZGVsW2dpXT8uc3RhdGlvbnN8fFtdKS5sZW5ndGg7IHNpKyspIGF3YWl0IGNoZWNrU3RhdGlvbihnaSxzaSk7IH0pKCk7IHJldHVybjsgfQogIHN0YXRpb25zTW9kZWwgPSBub3JtYWxpemVTdGF0aW9ucyhzdGF0aW9uc01vZGVsKTsKICByZW5kZXJTdGF0aW9uc0VkaXRvcigpOwp9KTsKJCgnI2FkZFN0YXRpb25CdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT57IGNvbGxlY3RTdGF0aW9uc0Zyb21FZGl0b3IoKTsgaWYoIXN0YXRpb25zTW9kZWwubGVuZ3RoKSBzdGF0aW9uc01vZGVsPVt7bmFtZTonTXkgU3RhdGlvbnMnLHN0YXRpb25zOltdfV07IHN0YXRpb25zTW9kZWxbMF0uc3RhdGlvbnMucHVzaCh7bmFtZTonJyx1cmw6JycsbG9nbzonJyxfc3RhdHVzOm51bGx9KTsgcmVuZGVyU3RhdGlvbnNFZGl0b3IoKTsgfSk7CiQoJyNzYXZlU3RhdGlvbnNCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT5zYXZlU3RhdGlvbnMoY29sbGVjdFN0YXRpb25zRnJvbUVkaXRvcigpKSk7CiQoJyNzYXZlU3RhdGlvbnNSYXdCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT5zYXZlU3RhdGlvbnMobnVsbCkpOwokKCcjcmVsb2FkU3RhdGlvbnNCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGxvYWRTdGF0aW9ucyk7CiQoJyNjaGVja0FsbFN0YXRpb25zQnRuJykuYWRkRXZlbnRMaXN0ZW5lcignY2xpY2snLCBjaGVja0FsbFN0YXRpb25zKTsKCi8qIC0tLS0gTG9ncyAtLS0tICovCmxldCBjdXJyZW50TG9nPSd5dHVuZXInOwphc3luYyBmdW5jdGlvbiBsb2FkTG9ncyhuYW1lPWN1cnJlbnRMb2cpewogIGN1cnJlbnRMb2c9bmFtZTsKICAkJCgnLnRhYltkYXRhLWxvZ10nKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgYi5kYXRhc2V0LmxvZz09PW5hbWUpKTsKICAkKCcjbG9nVmlldycpLnRleHRDb250ZW50ID0gJ0xhZGUuLi4nOwogIHRyeSB7IGNvbnN0IGQgPSBhd2FpdCBhcGkoYC9hcGkvbG9ncz9uYW1lPSR7ZW5jb2RlVVJJQ29tcG9uZW50KG5hbWUpfSZsaW5lcz0yMDBgKTsgJCgnI2xvZ1ZpZXcnKS50ZXh0Q29udGVudCA9IGQuY29udGVudCB8fCAnKGxlZXIpJzsgfQogIGNhdGNoKGUpeyAkKCcjbG9nVmlldycpLnRleHRDb250ZW50ID0gJ0ZlaGxlcjogJytlLm1lc3NhZ2U7IH0KfQoKLyogLS0tLSBXaXJlIHVwIC0tLS0gKi8KJCgnI3JlZnJlc2hCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsICgpPT57IGxvYWRTdGF0dXMoKS5jYXRjaChlPT4kKCcjc3RhdHVzU3VtbWFyeScpLnRleHRDb250ZW50PWUubWVzc2FnZSk7IGxvYWRTdGF0aW9ucygpLmNhdGNoKCgpPT57fSk7IH0pOwokKCcjcnVuVGVzdHNCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIHJ1blRlc3RzKTsKJCgnI3Byb3h5Rm9ybScpLmFkZEV2ZW50TGlzdGVuZXIoJ3N1Ym1pdCcsIHNhdmVQcm94eSk7CiQoJyNyZXN0YXJ0UHJveHlCdG4nKS5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIHJlc3RhcnRQcm94eSk7CiQoJyNyZWZyZXNoTG9nc0J0bicpLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCk9PmxvYWRMb2dzKGN1cnJlbnRMb2cpKTsKJCQoJy50YWJbZGF0YS1sb2ddJykuZm9yRWFjaChiPT5iLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgKCk9PmxvYWRMb2dzKGIuZGF0YXNldC5sb2cpKSk7Cgpsb2FkU3RhdHVzKCkuY2F0Y2goZT0+JCgnI3N0YXR1c1N1bW1hcnknKS50ZXh0Q29udGVudD0nRmVobGVyOiAnK2UubWVzc2FnZSk7CmxvYWRTdGF0aW9ucygpLmNhdGNoKCgpPT57fSk7CmxvYWRMb2dzKCd5dHVuZXInKS5jYXRjaCgoKT0+e30pOwo='

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
