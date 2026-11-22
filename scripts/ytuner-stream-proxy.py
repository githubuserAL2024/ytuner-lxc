#!/usr/bin/env python3
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
  STREAM_PROXY_USER_AGENT User-Agent sent upstream (default: Mozilla/5.0 ...)
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

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "proxy-connection",
}


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
            # Preserve UA on redirects
            new_req.add_unredirected_header("User-Agent", USER_AGENT)
        return new_req


def build_url_opener() -> object:
    redirect_handler = LimitedRedirectHandler(MAX_REDIRECTS)
    return build_opener(HTTPHandler(), HTTPSHandler(), redirect_handler)


def sanitize_upstream_url(raw: str) -> str:
    raw = (raw or "").strip()
    if not raw:
        raise ValueError("Missing upstream URL")

    # Allow /https://... shorthand
    if raw.startswith("https://") or raw.startswith("http://"):
        candidate = raw
    else:
        # tolerate missing scheme in ?url=host/path
        candidate = "http://" + raw

    parts = urlsplit(candidate)
    scheme = parts.scheme.lower()
    if scheme not in ("http", "https"):
        raise ValueError(f"Unsupported URL scheme: {parts.scheme}")
    if not parts.netloc:
        raise ValueError("Upstream URL missing host")

    # Block obvious local/private abuse targets? We keep it simple but block
    # non-http(s) already; the proxy is intended for LAN use.
    # Normalize path
    path = parts.path or "/"
    normalized = urlunsplit((scheme, parts.netloc, path, parts.query, ""))
    return normalized


def extract_target_url(path: str) -> str:
    # Forms supported:
    #  /stream?url=https://...
    #  /proxy?url=https://...
    #  /https://...
    #  /http://...
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

    # Allow /<anything>?url=...
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
        # Pass through Range if AVR/player sends it (rare, but harmless)
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
            body = f"Upstream HTTP error: {exc.code} {exc.reason}\nURL: {upstream_url}\n"
            self._send_text(502, body)
            return
        except URLError as exc:
            body = f"Upstream connection error: {exc.reason}\nURL: {upstream_url}\n"
            self._send_text(502, body)
            return
        except Exception as exc:  # noqa: BLE001
            body = f"Proxy error: {exc}\nURL: {upstream_url}\n"
            self._send_text(502, body)
            return

        with resp:
            status = getattr(resp, "status", 200)
            try:
                self.send_response(status)
            except (BrokenPipeError, ConnectionResetError):
                return

            # Forward selected headers
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

            # Pass through ICY headers useful for internet radio
            for key, value in resp.headers.items():
                lk = key.lower()
                if lk.startswith("icy-"):
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
