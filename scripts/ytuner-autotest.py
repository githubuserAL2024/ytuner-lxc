#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen


INSTALL_DIR = Path(os.environ.get("YTUNER_INSTALL_DIR", "/opt/ytuner"))
CONFIG_DIR = INSTALL_DIR / "config"
YTUNER_INI = INSTALL_DIR / "ytuner.ini"
AVR_INI = CONFIG_DIR / "avr.ini"
STATIONS_INI = CONFIG_DIR / "stations.ini"
PROXY_ENV = Path("/etc/default/ytuner-stream-proxy")
PROXY_SCRIPT = INSTALL_DIR / "ytuner-stream-proxy.py"
ADMIN_SCRIPT = INSTALL_DIR / "ytuner-admin.py"
SERVICES = ["ytuner", "ytuner-stream-proxy", "ytuner-admin"]


def run_cmd(cmd: list[str], timeout: float = 20.0) -> dict:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return {"ok": proc.returncode == 0, "rc": proc.returncode, "stdout": proc.stdout[-4000:], "stderr": proc.stderr[-4000:], "cmd": cmd}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "rc": -1, "stdout": "", "stderr": str(exc), "cmd": cmd}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def ini_get(content: str, section: str, key: str, default: str = "") -> str:
    in_section = False
    sec_re = re.compile(r"^\s*\[(.+?)\]\s*$")
    kv_re = re.compile(r"^\s*([^;#=\s][^=]*?)\s*=\s*(.*?)\s*$")
    for line in content.splitlines():
        m = sec_re.match(line)
        if m:
            in_section = m.group(1).strip().lower() == section.lower()
            continue
        if in_section:
            km = kv_re.match(line)
            if km and km.group(1).strip().lower() == key.lower():
                return km.group(2)
    return default


def env_parse(content: str) -> dict[str, str]:
    out = {}
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def service_status(name: str) -> dict:
    if shutil.which("systemctl") is None:
        return {"name": name, "active": "unknown", "enabled": "unknown"}
    active = run_cmd(["systemctl", "is-active", name], timeout=10)
    enabled = run_cmd(["systemctl", "is-enabled", name], timeout=10)
    return {"name": name, "active": active["stdout"].strip(), "enabled": enabled["stdout"].strip()}


def port_check(port: int, host: str = "127.0.0.1") -> dict:
    s = socket.socket()
    s.settimeout(1.5)
    try:
        s.connect((host, port))
        return {"port": port, "open": True}
    except Exception as exc:  # noqa: BLE001
        return {"port": port, "open": False, "error": str(exc)}
    finally:
        try:
            s.close()
        except Exception:
            pass


def http_check(url: str, timeout: float = 5.0) -> dict:
    req = Request(url, headers={"User-Agent": "ytuner-autotest/0.1"})
    t0 = time.time()
    try:
        with urlopen(req, timeout=timeout) as resp:
            body = resp.read(512)
            return {"url": url, "ok": 200 <= getattr(resp, "status", 200) < 500, "status": getattr(resp, "status", 200), "ms": int((time.time() - t0) * 1000), "bytes": len(body)}
    except Exception as exc:  # noqa: BLE001
        return {"url": url, "ok": False, "error": str(exc), "ms": int((time.time() - t0) * 1000)}


def main() -> int:
    ap = argparse.ArgumentParser(description="YTuner autotest runner")
    ap.add_argument("--json", action="store_true", help="JSON output")
    ap.add_argument("--include-admin", action="store_true", help="Include ytuner-admin checks")
    args = ap.parse_args()

    ytuner = read_text(YTUNER_INI)
    proxy_env = env_parse(read_text(PROXY_ENV))
    ytuner_port = int(ini_get(ytuner, "WebServer", "WebServerPort", "80") or "80")
    dns_port = int(ini_get(ytuner, "DNSServer", "DNSServerPort", "53") or "53")
    proxy_port = int(proxy_env.get("STREAM_PROXY_PORT", "8090") or "8090")
    admin_env = env_parse(read_text(Path("/etc/default/ytuner-admin")))
    admin_port = int(admin_env.get("YTUNER_ADMIN_PORT", "8091") or "8091")

    results = []
    def add(name, ok, detail):
        results.append({"name": name, "ok": bool(ok), "detail": detail})

    services = SERVICES if args.include_admin else ["ytuner", "ytuner-stream-proxy"]
    for svc in services:
        st = service_status(svc)
        add(f"service:{svc}", st.get("active") in {"active", "unknown"}, st)

    for p in [ytuner_port, dns_port, proxy_port] + ([admin_port] if args.include_admin else []):
        pc = port_check(p)
        add(f"port:{p}", pc["open"], pc)

    for p in [YTUNER_INI, AVR_INI, STATIONS_INI, PROXY_ENV, PROXY_SCRIPT] + ([ADMIN_SCRIPT] if args.include_admin else []):
        add(f"file:{p}", p.exists(), {"path": str(p), "exists": p.exists(), "size": p.stat().st_size if p.exists() else 0})

    add("http:ytuner", http_check(f"http://127.0.0.1:{ytuner_port}/")["ok"], http_check(f"http://127.0.0.1:{ytuner_port}/"))
    add("http:proxy-health", http_check(f"http://127.0.0.1:{proxy_port}/health")["ok"], http_check(f"http://127.0.0.1:{proxy_port}/health"))
    if args.include_admin:
        add("http:admin-health", http_check(f"http://127.0.0.1:{admin_port}/api/health")["ok"], http_check(f"http://127.0.0.1:{admin_port}/api/health"))

    pyc = run_cmd(["python3", "-m", "py_compile", str(PROXY_SCRIPT)], timeout=20)
    add("python:proxy-compile", pyc["ok"], pyc)
    if args.include_admin and ADMIN_SCRIPT.exists():
        pyc2 = run_cmd(["python3", "-m", "py_compile", str(ADMIN_SCRIPT)], timeout=20)
        add("python:admin-compile", pyc2["ok"], pyc2)

    passed = sum(1 for r in results if r["ok"])
    report = {"ok": passed == len(results), "total": len(results), "passed": passed, "failed": len(results)-passed, "results": results, "ts": int(time.time())}
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        print(f"{'PASS' if report['ok'] else 'FAIL'} {passed}/{len(results)}")
        for r in results:
            print(f"[{'OK' if r['ok'] else 'FAIL'}] {r['name']}")
            if not r["ok"]:
                print("  " + json.dumps(r["detail"], ensure_ascii=False)[:300])
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
