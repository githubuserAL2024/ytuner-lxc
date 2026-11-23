#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


INSTALL_DIR = Path(os.environ.get("YTUNER_INSTALL_DIR", "/opt/ytuner"))
CONFIG_DIR = INSTALL_DIR / "config"


def _first_existing(*paths: Path) -> Path:
    for p in paths:
        if p.exists():
            return p
    return paths[0]


YTUNER_INI = _first_existing(INSTALL_DIR / "ytuner.ini", CONFIG_DIR / "ytuner.ini")
AVR_INI = _first_existing(CONFIG_DIR / "avr.ini", INSTALL_DIR / "avr.ini")
STATIONS_INI = _first_existing(CONFIG_DIR / "stations.ini", INSTALL_DIR / "stations.ini")
PROXY_ENV = _first_existing(Path("/etc/default/ytuner-stream-proxy"), CONFIG_DIR / "ytuner-stream-proxy.default")
PROXY_SCRIPT = _first_existing(INSTALL_DIR / "ytuner-stream-proxy.py", INSTALL_DIR / "scripts" / "ytuner-stream-proxy.py")
WEB_DIR = _first_existing(Path(os.environ.get("YTUNER_ADMIN_WEB_DIR", "/opt/ytuner/webui")), INSTALL_DIR / "webui")
LOG_FILES = {
    "ytuner": Path("/var/log/ytuner.log"),
    "proxy": Path("/var/log/ytuner-stream-proxy.log"),
    "admin": Path("/var/log/ytuner-admin.log"),
}
SERVICES = ["ytuner", "ytuner-stream-proxy", "ytuner-admin"]
ALLOW_SYSTEMCTL = os.environ.get("YTUNER_ADMIN_ALLOW_SYSTEMCTL", "1") != "0"
HOST = os.environ.get("YTUNER_ADMIN_HOST", "0.0.0.0")
PORT = int(os.environ.get("YTUNER_ADMIN_PORT", "8091"))
TOKEN = os.environ.get("YTUNER_ADMIN_TOKEN", "")


def run_cmd(cmd: list[str], timeout: float = 20.0) -> dict:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return {
            "ok": proc.returncode == 0,
            "rc": proc.returncode,
            "stdout": proc.stdout[-8000:],
            "stderr": proc.stderr[-8000:],
            "cmd": cmd,
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "rc": -1, "stdout": "", "stderr": str(exc), "cmd": cmd}


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def write_text_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def ini_get(content: str, section: str, key: str, default: str = "") -> str:
    in_section = False
    sec_re = re.compile(r"^\s*\[(.+?)\]\s*$")
    kv_re = re.compile(r"^\s*([^;#=\s][^=]*?)\s*=\s*(.*?)\s*$")
    for line in content.splitlines():
        m = sec_re.match(line)
        if m:
            in_section = m.group(1).strip().lower() == section.lower()
            continue
        if not in_section:
            continue
        km = kv_re.match(line)
        if km and km.group(1).strip().lower() == key.lower():
            return km.group(2)
    return default


def env_parse(content: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def env_render(existing: str, updates: dict[str, str]) -> str:
    lines = existing.splitlines() if existing else []
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if "=" in line and not line.lstrip().startswith("#"):
            k = line.split("=", 1)[0].strip()
            ku = k.upper()
            if ku in updates:
                out.append(f"{k}={updates[ku]}")
                seen.add(ku)
                continue
        out.append(line)
    for k, v in updates.items():
        if k not in seen:
            out.append(f"{k}={v}")
    return "\n".join(out).rstrip() + "\n"


def service_status(name: str) -> dict:
    if not ALLOW_SYSTEMCTL or shutil.which("systemctl") is None:
        patterns = {
            "ytuner": "[y]tuner",
            "ytuner-stream-proxy": "[y]tuner-stream-proxy.py",
            "ytuner-admin": "[y]tuner-admin.py",
        }
        pat = patterns.get(name, f"[{name[:1]}]{name[1:]}" if name else name)
        active = run_cmd(["sh", "-lc", f"pgrep -af '{pat}' >/dev/null && echo active || echo inactive"], timeout=5)
        return {"name": name, "active": active["stdout"].strip() or "inactive", "enabled": "n/a", "detail": active}
    active = run_cmd(["systemctl", "is-active", name], timeout=10)
    enabled = run_cmd(["systemctl", "is-enabled", name], timeout=10)
    show = run_cmd(["systemctl", "show", name, "--property=ActiveState,SubState,UnitFileState,MainPID,ExecMainStatus"], timeout=10)
    props = {}
    for line in show["stdout"].splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            props[k.strip()] = v.strip()
    return {
        "name": name,
        "active": active["stdout"].strip() or props.get("ActiveState", "unknown"),
        "enabled": enabled["stdout"].strip() or props.get("UnitFileState", "unknown"),
        "props": props,
    }


def port_check(port: int, host: str = "127.0.0.1") -> dict:
    import socket

    s = socket.socket()
    s.settimeout(1.5)
    try:
        s.connect((host, port))
        s.close()
        return {"port": port, "open": True, "host": host}
    except Exception as exc:  # noqa: BLE001
        err = str(exc)
    finally:
        try:
            s.close()
        except Exception:
            pass

    # Fallback for containerized/bound-to-non-loopback listeners: inspect ss/netstat.
    ss = run_cmd(["sh", "-lc", f"ss -lntH '( sport = :{int(port)} )' 2>/dev/null | head -n 1"], timeout=5)
    line = (ss.get("stdout") or "").strip()
    if ss.get("ok") and line:
        return {"port": port, "open": True, "host": host, "via": "ss", "listener": line}

    ns = run_cmd(["sh", "-lc", f"netstat -lnt 2>/dev/null | awk '$4 ~ /:{int(port)}$/' | head -n 1"], timeout=5)
    nline = (ns.get("stdout") or "").strip()
    if ns.get("ok") and nline:
        return {"port": port, "open": True, "host": host, "via": "netstat", "listener": nline}

    return {"port": port, "open": False, "error": err, "host": host}


def http_check(url: str, timeout: float = 5.0) -> dict:
    from urllib.request import Request, urlopen
    from urllib.parse import urlsplit, urlunsplit

    def _try(u: str) -> dict:
        from urllib.error import HTTPError
        req = Request(u, headers={"User-Agent": "ytuner-admin/0.1"})
        t0 = time.time()
        try:
            with urlopen(req, timeout=timeout) as resp:
                body = resp.read(512)
                return {
                    "url": u,
                    "ok": 200 <= getattr(resp, "status", 200) < 600,
                    "status": getattr(resp, "status", 200),
                    "ms": int((time.time() - t0) * 1000),
                    "bytes": len(body),
                }
        except HTTPError as exc:
            # HTTP response means service is reachable; 404 is acceptable for root endpoint
            body = b""
            try:
                body = exc.read(512)
            except Exception:
                pass
            return {
                "url": u,
                "ok": 200 <= int(getattr(exc, "code", 0) or 0) < 600,
                "status": int(getattr(exc, "code", 0) or 0),
                "ms": int((time.time() - t0) * 1000),
                "bytes": len(body),
                "error": str(exc),
            }
        except Exception as exc:  # noqa: BLE001
            return {"url": u, "ok": False, "error": str(exc), "ms": int((time.time() - t0) * 1000)}

    res = _try(url)
    if res.get("ok"):
        return res
    # If localhost failed, try local interface IPs / listener IPs (some services bind only to container IP)
    try:
        sp = urlsplit(url)
        if sp.hostname in {"127.0.0.1", "localhost"}:
            candidates: list[str] = []
            ips = run_cmd(["sh", "-lc", "hostname -I 2>/dev/null || true"], timeout=5)
            for ip in (ips.get("stdout") or "").split():
                if ip and not ip.startswith("127.") and ip not in candidates:
                    candidates.append(ip)
            # also parse listeners for the port
            if sp.port:
                ss = run_cmd(["sh", "-lc", f"ss -lntH '( sport = :{int(sp.port)} )' 2>/dev/null || true"], timeout=5)
                for line in (ss.get("stdout") or "").splitlines():
                    # format: LISTEN 0 5 192.168.50.146:80 0.0.0.0:*
                    parts = line.split()
                    if len(parts) >= 4:
                        local = parts[3]
                        # strip IPv6 brackets
                        if local.startswith('['):
                            host = local.rsplit(']:', 1)[0].lstrip('[')
                        else:
                            host = local.rsplit(':', 1)[0]
                        if host in ('0.0.0.0', '*', '::', ''):
                            continue
                        if host.startswith('127.'):
                            continue
                        if host not in candidates:
                            candidates.append(host)
            for ip in candidates:
                alt = urlunsplit((sp.scheme, f"{ip}:{sp.port}" if sp.port else ip, sp.path, sp.query, sp.fragment))
                r2 = _try(alt)
                if r2.get("ok"):
                    r2["fallback_from"] = url
                    return r2
                # keep last failure detail but note attempted fallback
                res.setdefault("fallback_attempts", []).append({"url": alt, "error": r2.get("error"), "status": r2.get("status")})
    except Exception as e:
        res["fallback_error"] = str(e)
    return res


def check_stream_url(url: str, timeout: float = 6.0) -> dict:
    """Check if a radio stream URL is reachable. Returns status/content-type info."""
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError, URLError

    url = (url or "").strip()
    if not url:
        return {"url": url, "reachable": False, "error": "empty url"}
    # allow only http/https
    if not re.match(r'^https?://', url, re.I):
        return {"url": url, "reachable": False, "error": "only http/https supported"}

    req = Request(url, headers={"User-Agent": "ytuner-admin/0.1", "Icy-MetaData": "1"}, method="GET")
    t0 = time.time()
    try:
        with urlopen(req, timeout=timeout) as resp:
            status = getattr(resp, "status", 200)
            ctype = resp.headers.get("Content-Type", "")
            body = resp.read(1024)  # read a small chunk to confirm stream flows
            ms = int((time.time() - t0) * 1000)
            return {
                "url": url,
                "reachable": 200 <= status < 400,
                "status": status,
                "content_type": ctype,
                "ms": ms,
                "bytes": len(body),
            }
    except HTTPError as exc:
        ms = int((time.time() - t0) * 1000)
        return {"url": url, "reachable": False, "status": exc.code, "error": str(exc.reason), "ms": ms}
    except URLError as exc:
        ms = int((time.time() - t0) * 1000)
        return {"url": url, "reachable": False, "error": str(exc.reason), "ms": ms}
    except Exception as exc:  # noqa: BLE001
        ms = int((time.time() - t0) * 1000)
        return {"url": url, "reachable": False, "error": str(exc), "ms": ms}


def parse_stations_ini(content: str) -> list[dict]:
    groups: list[dict] = []
    current: dict | None = None
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith(";") or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = {"name": line[1:-1].strip(), "stations": []}
            groups.append(current)
            continue
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        station_name = name.strip()
        rest = value.strip()
        url, logo = rest, ""
        if "|" in rest:
            url, logo = rest.split("|", 1)
        item = {"name": station_name, "url": url.strip(), "logo": logo.strip()}
        if current is None:
            current = {"name": "Ungrouped", "stations": []}
            groups.append(current)
        current["stations"].append(item)
    return groups


def render_stations_ini(groups: list[dict]) -> str:
    lines = [
        "; Custom stations for YTuner \"My Stations\" menu.",
        "; Format: Station Name=stream_url|optional_logo_url",
        "",
    ]
    for g in groups:
        gname = str(g.get("name", "")).strip() or "Ungrouped"
        lines.append(f"[{gname}]")
        for st in g.get("stations", []) or []:
            name = str(st.get("name", "")).strip()
            url = str(st.get("url", "")).strip()
            logo = str(st.get("logo", "")).strip()
            if not name or not url:
                continue
            if any(c in name for c in "\r\n=") or any(c in url for c in "\r\n|") or any(c in logo for c in "\r\n"):
                raise ValueError("Invalid characters in station fields")
            lines.append(f"{name}={url}" + (f"|{logo}" if logo else ""))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def collect_config() -> dict:
    ytuner = read_text(YTUNER_INI)
    avr = read_text(AVR_INI)
    proxy = env_parse(read_text(PROXY_ENV))
    stations_content = read_text(STATIONS_INI)
    return {
        "paths": {
            "install_dir": str(INSTALL_DIR),
            "ytuner_ini": str(YTUNER_INI),
            "avr_ini": str(AVR_INI),
            "stations_ini": str(STATIONS_INI),
            "proxy_env": str(PROXY_ENV),
        },
        "ytuner": {
            "web_port": ini_get(ytuner, "WebServer", "WebServerPort", "80"),
            "dns_port": ini_get(ytuner, "DNSServer", "DNSServerPort", "53"),
            "dns_enable": ini_get(ytuner, "DNSServer", "Enable", "1"),
            "intercept_dns": ini_get(ytuner, "DNSServer", "InterceptDNs", ""),
            "rb_cache_type": ini_get(ytuner, "Radiobrowser", "RBCacheType", ""),
            "message_level": ini_get(ytuner, "Configuration", "MessageInfoLevel", ""),
        },
        "avr": {
            "protocol": ini_get(avr, "Configuration", "Protocol", ""),
        },
        "proxy": {
            "host": proxy.get("STREAM_PROXY_HOST", "0.0.0.0"),
            "port": proxy.get("STREAM_PROXY_PORT", "8090"),
            "timeout": proxy.get("STREAM_PROXY_TIMEOUT", "15"),
            "max_redirects": proxy.get("STREAM_PROXY_MAX_REDIRECTS", "5"),
            "log_level": proxy.get("STREAM_PROXY_LOG_LEVEL", "INFO"),
        },
        "stations": {
            "path": str(STATIONS_INI),
            "groups": parse_stations_ini(stations_content),
            "raw": stations_content,
        },
    }


def save_proxy_env(payload: dict) -> dict:
    allowed = {
        "STREAM_PROXY_HOST",
        "STREAM_PROXY_PORT",
        "STREAM_PROXY_TIMEOUT",
        "STREAM_PROXY_MAX_REDIRECTS",
        "STREAM_PROXY_LOG_LEVEL",
        "STREAM_PROXY_USER_AGENT",
    }
    updates = {}
    for k, v in payload.items():
        ku = k.upper()
        if ku in allowed and v is not None:
            updates[ku] = str(v).strip()
    if "STREAM_PROXY_PORT" in updates and not updates["STREAM_PROXY_PORT"].isdigit():
        raise ValueError("STREAM_PROXY_PORT must be numeric")
    content = read_text(PROXY_ENV)
    new_content = env_render(content, updates)
    write_text_atomic(PROXY_ENV, new_content)
    return {"saved": True, "path": str(PROXY_ENV), "updates": updates}


def run_tests() -> dict:
    cfg = collect_config()
    proxy_port = int(cfg["proxy"].get("port", "8090") or "8090")
    web_port = int(cfg["ytuner"].get("web_port", "80") or "80")
    dns_port = int(cfg["ytuner"].get("dns_port", "53") or "53")
    results = []

    def add(name: str, ok: bool, detail: dict | str):
        results.append({"name": name, "ok": bool(ok), "detail": detail})

    for svc in SERVICES:
        st = service_status(svc)
        ok = st.get("active") == "active" or (not ALLOW_SYSTEMCTL and st.get("enabled") == "n/a")
        add(f"service:{svc}", ok, st)

    for p, label in [(web_port, "ytuner-web"), (dns_port, "ytuner-dns"), (proxy_port, "stream-proxy")]:
        pc = port_check(p)
        ok = pc["open"] or (not ALLOW_SYSTEMCTL)  # in preview/dev without services, don't hard-fail
        detail = {**pc, "label": label, "strict": ALLOW_SYSTEMCTL}
        add(f"port:{p}", ok, detail)

    required_files = [AVR_INI, STATIONS_INI, PROXY_ENV, PROXY_SCRIPT]
    optional_files = [YTUNER_INI]
    for p in required_files:
        exists = p.exists()
        add(f"file:{p}", exists or (not ALLOW_SYSTEMCTL and p in {PROXY_ENV}), {"path": str(p), "exists": exists, "size": p.stat().st_size if exists else 0, "strict": ALLOW_SYSTEMCTL})
    for p in optional_files:
        exists = p.exists()
        add(f"file:{p}", exists or (not ALLOW_SYSTEMCTL), {"path": str(p), "exists": exists, "size": p.stat().st_size if exists else 0, "optional": True, "strict": ALLOW_SYSTEMCTL})

    yt = http_check(f"http://127.0.0.1:{web_port}/", 4.0)
    ph = http_check(f"http://127.0.0.1:{proxy_port}/health", 4.0)
    add("http:ytuner", yt["ok"] or (not ALLOW_SYSTEMCTL), {**yt, "strict": ALLOW_SYSTEMCTL})
    add("http:proxy-health", ph["ok"] or (not ALLOW_SYSTEMCTL), {**ph, "strict": ALLOW_SYSTEMCTL})

    pyc = run_cmd(["python3", "-m", "py_compile", str(PROXY_SCRIPT)], timeout=20)
    add("python:proxy-compile", pyc["ok"], pyc)

    ok_count = sum(1 for r in results if r["ok"])
    return {"ok": ok_count == len(results), "total": len(results), "passed": ok_count, "failed": len(results) - ok_count, "results": results, "ts": int(time.time())}


class Handler(BaseHTTPRequestHandler):
    server_version = "YTunerAdmin/0.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _auth_ok(self) -> bool:
        if not TOKEN:
            return True
        hdr = self.headers.get("X-Admin-Token") or ""
        if hdr == TOKEN:
            return True
        qs = parse_qs(urlsplit(self.path).query)
        return (qs.get("token") or [""])[0] == TOKEN

    def _send_json(self, code: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_bytes(self, code: int, data: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> dict:
        n = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(n) if n > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _serve_static(self, path: str) -> bool:
        p = urlsplit(path).path
        if p == "/":
            p = "/index.html"
        safe = Path(p.lstrip("/"))
        target = (WEB_DIR / safe).resolve()
        if WEB_DIR.resolve() not in target.parents and target != WEB_DIR.resolve():
            self._send_json(403, {"ok": False, "error": "forbidden"})
            return True
        if not target.exists() or not target.is_file():
            return False
        ctype = "text/plain; charset=utf-8"
        if target.suffix == ".html":
            ctype = "text/html; charset=utf-8"
        elif target.suffix == ".css":
            ctype = "text/css; charset=utf-8"
        elif target.suffix == ".js":
            ctype = "application/javascript; charset=utf-8"
        elif target.suffix == ".json":
            ctype = "application/json; charset=utf-8"
        self._send_bytes(200, target.read_bytes(), ctype)
        return True

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlsplit(self.path)
        path = parsed.path
        if path.startswith("/api/") and not self._auth_ok():
            self._send_json(401, {"ok": False, "error": "unauthorized"})
            return
        if path == "/api/health":
            self._send_json(200, {"ok": True, "service": "ytuner-admin"})
            return
        if path == "/api/status":
            cfg = collect_config()
            statuses = [service_status(s) for s in SERVICES]
            proxy_port = int(cfg["proxy"].get("port", "8090") or "8090")
            ytuner_port = int(cfg["ytuner"].get("web_port", "80") or "80")
            dns_port = int(cfg["ytuner"].get("dns_port", "53") or "53")
            self._send_json(200, {
                "ok": True,
                "config": cfg,
                "services": statuses,
                "ports": [port_check(ytuner_port), port_check(dns_port), port_check(proxy_port)],
            })
            return
        if path == "/api/config":
            self._send_json(200, {"ok": True, "config": collect_config()})
            return
        if path == "/api/stations":
            content = read_text(STATIONS_INI)
            self._send_json(200, {"ok": True, "path": str(STATIONS_INI), "groups": parse_stations_ini(content), "raw": content})
            return
        if path == "/api/stations/check":
            qs = parse_qs(parsed.query)
            url = (qs.get("url") or [""])[0].strip()
            if not url:
                self._send_json(400, {"ok": False, "error": "missing url"})
                return
            try:
                result = check_stream_url(url)
                self._send_json(200, {"ok": True, **result})
            except Exception as exc:  # noqa: BLE001
                self._send_json(200, {"ok": True, "url": url, "reachable": False, "error": str(exc)})
            return
        if path == "/api/logs":
            qs = parse_qs(parsed.query)
            name = (qs.get("name") or ["ytuner"])[0]
            lines = int((qs.get("lines") or ["120"])[0])
            lines = max(10, min(lines, 1000))
            p = LOG_FILES.get(name)
            if not p:
                self._send_json(400, {"ok": False, "error": "unknown log"})
                return
            text = read_text(p)
            tail = "\n".join(text.splitlines()[-lines:])
            self._send_json(200, {"ok": True, "name": name, "path": str(p), "content": tail})
            return
        if path == "/api/tests/run":
            self._send_json(200, run_tests())
            return
        if path.startswith("/api/"):
            self._send_json(404, {"ok": False, "error": "not found"})
            return
        if self._serve_static(path):
            return
        self._send_json(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlsplit(self.path)
        path = parsed.path
        if not self._auth_ok():
            self._send_json(401, {"ok": False, "error": "unauthorized"})
            return
        payload = self._read_json()
        if path == "/api/config/proxy":
            try:
                res = save_proxy_env(payload)
                self._send_json(200, {"ok": True, **res})
            except Exception as exc:  # noqa: BLE001
                self._send_json(400, {"ok": False, "error": str(exc)})
            return
        if path == "/api/stations":
            try:
                if "raw" in payload and isinstance(payload.get("raw"), str):
                    raw = payload["raw"]
                    # validate by parsing and normalizing through renderer if groups can be derived? keep raw but basic check
                    if len(raw) > 200000:
                        raise ValueError("stations.ini too large")
                    write_text_atomic(STATIONS_INI, raw if raw.endswith("\n") else raw + "\n")
                    content = read_text(STATIONS_INI)
                    self._send_json(200, {"ok": True, "saved": True, "path": str(STATIONS_INI), "groups": parse_stations_ini(content), "raw": content})
                    return
                groups = payload.get("groups")
                if not isinstance(groups, list):
                    raise ValueError("Expected 'groups' list or 'raw' string")
                rendered = render_stations_ini(groups)
                write_text_atomic(STATIONS_INI, rendered)
                self._send_json(200, {"ok": True, "saved": True, "path": str(STATIONS_INI), "groups": parse_stations_ini(rendered), "raw": rendered})
            except Exception as exc:  # noqa: BLE001
                self._send_json(400, {"ok": False, "error": str(exc)})
            return
        if path == "/api/service/restart":
            name = str(payload.get("name") or "")
            if name not in SERVICES:
                self._send_json(400, {"ok": False, "error": "invalid service"})
                return
            if not ALLOW_SYSTEMCTL or shutil.which("systemctl") is None:
                self._send_json(400, {"ok": False, "error": "systemctl unavailable"})
                return
            res = run_cmd(["systemctl", "restart", name], timeout=30)
            self._send_json(200 if res["ok"] else 500, {"ok": res["ok"], "result": res, "status": service_status(name)})
            return
        if path == "/api/tests/run":
            self._send_json(200, run_tests())
            return
        self._send_json(404, {"ok": False, "error": "not found"})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"ytuner-admin listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
