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
    python3 iproute2 net-tools file
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
PROXY_PY='#!/usr/bin/env python3
"""
ytuner-stream-proxy - HTTPS->HTTP stream relay for old AVRs.

Listens on HTTP and proxies audio streams from HTTPS (or HTTP) upstreams.
Designed for YTuner/AVR setups where the AVR cannot speak TLS.

Usage examples:
  http://<host>:8090/stream?url=https://example.com/radio.mp3
  http://<host>:8090/https://example.com/radio.mp3

Environment variables:
  STREAM_PROXY_HOST       Bind address (default: 0.0.0.0)
  STREAM_PROXY_PORT       Bind port (default: 8090)
  STREAM_PROXY_TIMEOUT    Upstream connect/read timeout seconds (default: 15)
  STREAM_PROXY_MAX_REDIRECTS  Max redirects to follow (default: 5)
  STREAM_PROXY_USER_AGENT User-Agent sent upstream
  STREAM_PROXY_LOG_LEVEL  DEBUG, INFO, WARNING, ERROR (default: INFO)
"""

from __future__ import annotations

import logging
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit, urlunsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler, HTTPSHandler, HTTPHandler


HOST = os.environ.get("STREAM_PROXY_HOST", "0.0.0.0")
PORT = int(os.environ.get("STREAM_PROXY_PORT", "8090"))
TIMEOUT = float(os.environ.get("STREAM_PROXY_TIMEOUT", "15"))
MAX_REDIRECTS = int(os.environ.get("STREAM_PROXY_MAX_REDIRECTS", "5"))
USER_AGENT = os.environ.get(
    "STREAM_PROXY_USER_AGENT",
    "Mozilla/5.0 (compatible; YTuner-Stream-Proxy/0.1; +https://github.com/coffeegreg/YTuner)",
)
LOG_LEVEL = os.environ.get("STREAM_PROXY_LOG_LEVEL", "INFO").upper()


def setup_logging() -> logging.Logger:
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL, logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )
    return logging.getLogger("ytuner-stream-proxy")


LOG = setup_logging()


class LimitedRedirectHandler(HTTPRedirectHandler):
    def __init__(self, max_redirects: int) -> None:
        self.max_redirects = max_redirects
        self.redirect_count = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        self.redirect_count += 1
        if self.redirect_count > self.max_redirects:
            raise HTTPError(newurl, code, f"Too many redirects (>{self.max_redirects})", headers, fp)
        LOG.debug("Redirect %s -> %s", req.full_url, newurl)
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is not None:
            new_req.add_unredirected_header("User-Agent", USER_AGENT)
        return new_req


def build_url_opener() -> object:
    redirect_handler = LimitedRedirectHandler(MAX_REDIRECTS)
    return build_opener(HTTPHandler(), HTTPSHandler(), redirect_handler)


def sanitize_upstream_url(raw: str) -> str:
    raw = (raw or "").strip()
    if not raw:
        raise ValueError("Missing upstream URL")
    if raw.startswith("https://") or raw.startswith("http://"):
        candidate = raw
    else:
        candidate = "http://" + raw
    parts = urlsplit(candidate)
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https"):
        raise ValueError(f"Unsupported URL scheme: {parts.scheme}")
    if not parts.netloc:
        raise ValueError("Upstream URL missing host")
    path = parts.path or "/"
    return urlunsplit((scheme, parts.netloc, path, parts.query, ""))


def extract_target_url(path: str) -> str:
    if path.startswith("/http://") or path.startswith("/https://"):
        return sanitize_upstream_url(path[1:])
    parts = urlsplit(path)
    if parts.path in ("/stream", "/proxy", "/"):
        qs = parse_qs(parts.query)
        values = qs.get("url") or qs.get("u") or qs.get("stream")
        if not values:
            if parts.path == "/":
                raise ValueError("index")
            raise ValueError("Missing 'url' query parameter")
        return sanitize_upstream_url(values[0])
    qs = parse_qs(parts.query)
    values = qs.get("url") or qs.get("u") or qs.get("stream")
    if values:
        return sanitize_upstream_url(values[0])
    raise ValueError("Unsupported path. Use /stream?url=https://...")


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "YTunerStreamProxy/0.1"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        LOG.info("%s - %s", self.address_string(), fmt % args)

    def _send_text(self, code: int, body: str, content_type: str = "text/plain; charset=utf-8") -> None:
        data = body.encode("utf-8", errors="replace")
        try:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass

    def _send_index(self) -> None:
        host = self.headers.get("Host") or f"{HOST}:{PORT}"
        body = (
            "YTuner HTTPS->HTTP Stream Proxy\n\n"
            "Usage:\n"
            f"  http://{host}/stream?url=https://example.com/stream.mp3\n"
            f"  http://{host}/https://example.com/stream.mp3\n\n"
            "Health:\n"
            f"  http://{host}/health\n"
        )
        self._send_text(200, body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/health", "/healthz"):
            self._send_text(200, "ok\n")
            return
        try:
            upstream_url = extract_target_url(self.path)
        except ValueError as exc:
            if str(exc) == "index":
                self._send_index()
                return
            self._send_text(400, f"Bad request: {exc}\n")
            return
        self._proxy(upstream_url, head_only=False)

    def do_HEAD(self) -> None:  # noqa: N802
        if self.path in ("/health", "/healthz"):
            self._send_text(200, "ok\n")
            return
        try:
            upstream_url = extract_target_url(self.path)
        except ValueError as exc:
            self._send_text(400, f"Bad request: {exc}\n")
            return
        self._proxy(upstream_url, head_only=True)

    def _proxy(self, upstream_url: str, head_only: bool) -> None:
        req_headers = {
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
            "Connection": "close",
        }
        range_header = self.headers.get("Range")
        if range_header:
            req_headers["Range"] = range_header
        icy = self.headers.get("Icy-MetaData")
        if icy:
            req_headers["Icy-MetaData"] = icy

        request = Request(upstream_url, headers=req_headers, method="HEAD" if head_only else "GET")
        opener = build_url_opener()
        LOG.info("Proxying %s -> %s", self.command, upstream_url)
        try:
            resp = opener.open(request, timeout=TIMEOUT)
        except HTTPError as exc:
            self._send_text(502, f"Upstream HTTP error: {exc.code} {exc.reason}\nURL: {upstream_url}\n")
            return
        except URLError as exc:
            self._send_text(502, f"Upstream connection error: {exc.reason}\nURL: {upstream_url}\n")
            return
        except Exception as exc:  # noqa: BLE001
            self._send_text(502, f"Proxy error: {exc}\nURL: {upstream_url}\n")
            return

        with resp:
            status = getattr(resp, "status", 200)
            try:
                self.send_response(status)
            except (BrokenPipeError, ConnectionResetError):
                return
            content_type = resp.headers.get("Content-Type")
            if content_type:
                self.send_header("Content-Type", content_type)
            content_length = resp.headers.get("Content-Length")
            if content_length and not head_only:
                self.send_header("Content-Length", content_length)
            content_range = resp.headers.get("Content-Range")
            if content_range:
                self.send_header("Content-Range", content_range)
            accept_ranges = resp.headers.get("Accept-Ranges")
            if accept_ranges:
                self.send_header("Accept-Ranges", accept_ranges)
            for key, value in resp.headers.items():
                if key.lower().startswith("icy-"):
                    self.send_header(key, value)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            try:
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                return
            if head_only:
                return
            try:
                while True:
                    chunk = resp.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
                LOG.info("Client disconnected: %s", upstream_url)
            except Exception as exc:  # noqa: BLE001
                LOG.warning("Stream error for %s: %s", upstream_url, exc)


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address) -> None:  # noqa: ANN001
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout)):
            LOG.debug("Client connection error from %s: %s", client_address, exc)
            return
        super().handle_error(request, client_address)


def main() -> int:
    server = ProxyServer((HOST, PORT), ProxyHandler)
    LOG.info("Listening on http://%s:%s", HOST, PORT)
    LOG.info("Example: http://<host>:%s/stream?url=https://example.com/radio.mp3", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("Shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'

PROXY_DEFAULT='STREAM_PROXY_HOST=0.0.0.0
STREAM_PROXY_PORT=8090
STREAM_PROXY_TIMEOUT=15
STREAM_PROXY_MAX_REDIRECTS=5
STREAM_PROXY_LOG_LEVEL=INFO
'

PROXY_SERVICE_UNIT='[Unit]
Description=YTuner HTTPS->HTTP stream proxy
Documentation=https://github.com/coffeegreg/YTuner
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

log "Installing HTTPS->HTTP stream proxy..."
write_file "$INSTALL_DIR/ytuner-stream-proxy.py" "0755" "$PROXY_PY"
if [[ -f /etc/default/ytuner-stream-proxy && "$FORCE_CONFIG" != "1" ]]; then
  log "Keeping existing config: /etc/default/ytuner-stream-proxy"
else
  write_file "/etc/default/ytuner-stream-proxy" "0644" "$PROXY_DEFAULT"
fi
write_file "/etc/systemd/system/ytuner-stream-proxy.service" "0644" "$PROXY_SERVICE_UNIT"

# --- Enable & start -----------------------------------------------------------
if [[ "$NO_START" == "0" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    run systemctl daemon-reload
    run systemctl enable ytuner.service
    run systemctl enable ytuner-stream-proxy.service
    run systemctl restart ytuner.service
    run systemctl restart ytuner-stream-proxy.service
    sleep 2
    run systemctl --no-pager --full status ytuner.service || true
    run systemctl --no-pager --full status ytuner-stream-proxy.service || true
  else
    warn "systemctl not found. Start manually: $INSTALL_DIR/ytuner and /usr/bin/python3 $INSTALL_DIR/ytuner-stream-proxy.py"
  fi
else
  log "--no-start set; skipping service enable/start."
fi

# --- Verification -------------------------------------------------------------
log "Verifying listeners (80/tcp, 53/udp, 8090/tcp)..."
if command -v ss >/dev/null 2>&1; then
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ ss -lntup | grep -E ":80 |:53 |:8090 "\n'
  else
    ss -lntup | grep -E ':80\s|:53\s|:8090\s' || warn "Ports 80/53/8090 not visible yet. Check logs: journalctl -u ytuner -n 100 --no-pager; journalctl -u ytuner-stream-proxy -n 100 --no-pager"
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
Proxy cfg:    /etc/default/ytuner-stream-proxy
Logs:         /var/log/ytuner.log
              /var/log/ytuner-stream-proxy.log
Services:     systemctl status ytuner
              systemctl status ytuner-stream-proxy

Next steps:
  1) Ensure this container has a stable IP (DHCP reservation or static).
  2) On your AVR, set DNS server to: $IP_HINT
  3) Disable AVR proxy if configured.
  4) For HTTPS-only stations, use:
     http://${IP_HINT}:8090/stream?url=https://STREAM-URL
  5) Reboot/open Internet Radio on the AVR.

Checks:
  ss -lntup | grep -E ':80 |:53 |:8090 '
  dig @${IP_HINT} pioneer.vtuner.com +short
  curl -I "http://${IP_HINT}:8090/health"
  tail -f /var/log/ytuner.log

Docs: https://github.com/coffeegreg/YTuner
EOF
