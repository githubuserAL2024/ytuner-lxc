# YTuner Proxmox LXC Rollout

> Deutsch: [README.md](README.md)

This repository provides a complete, practical rollout package to run [YTuner](https://github.com/coffeegreg/YTuner) as a **vTuner replacement** in a **Proxmox VE LXC container**. Goal: reproducible setup - create container, install YTuner, point AVR DNS to YTuner, verify operation.

## Table of Contents

- [Overview](#overview)
- [How YTuner Works](#how-ytuner-works)
- [Prerequisites](#prerequisites)
- [Repository Structure](#repository-structure)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Admin WebUI / API / Autotests](#admin-webui--api--autotests)
- [Operation, Update, Backup](#operation-update-backup)
- [Validation and Troubleshooting](#validation-and-troubleshooting)
- [Security Notes](#security-notes)
- [References](#references)

## Overview

**YTuner** is a lightweight, standalone Free Pascal application replacing the former vTuner service for many internet-radio-capable AVRs. Instead of the external vTuner service, the AVR queries local YTuner.

This rollout provides:

- **LXC creation** on Proxmox host (`scripts/create-lxc.sh`)
- **Automated install** in container (`scripts/install-ytuner.sh`)
- **One-shot installer** (`install.sh`) for `wget ... | bash`
- **HTTPS→HTTP stream proxy** (`scripts/ytuner-stream-proxy.py`, systemd service)
- **Admin WebUI + API** (`scripts/ytuner-admin.py`, `webui/`) for status, settings, logs, station management, tests
- **Autotest tool** (`scripts/ytuner-autotest.py`) via CLI/WebUI/API
- **Update script** with binary backup (`scripts/update-ytuner.sh`)
- **Backup script** for config/DB/cache/logs (`scripts/backup-config.sh`)
- **systemd services** and **config templates**

## How YTuner Works

YTuner provides two core services:

- **Web service (TCP/80):** endpoints AVRs expect for station lists/bookmarks/streams.
- **DNS intercept (UDP/53):** intercepts vTuner-related domains and answers with YTuner host IP.

This rollout adds:

- **HTTPS→HTTP stream proxy (TCP/8090):** accepts HTTP from AVR, fetches upstream via HTTPS/HTTP, delivers HTTP to AVR. For old AVRs without TLS.
- **Admin WebUI/API (TCP/8091):** manage stations, Radio-Browser search/add, source toggles, status/logs, proxy settings, autotests, container reboot.

Typical flow:

1. AVR uses YTuner container as DNS.
2. AVR queries e.g. `*.vtuner.com`.
3. YTuner DNS returns local YTuner IP.
4. AVR connects via HTTP on port 80 to YTuner.
5. YTuner serves station data and stream URLs.

> Important: YTuner is **not a router/gateway** for the AVR. AVR default gateway stays your normal router.

## Prerequisites

### Proxmox / Infrastructure

- Proxmox VE host with LXC support
- Debian 12 LXC template available
- Network bridge (default: `vmbr0`)
- Fixed IP or DHCP reservation for YTuner container (recommended)

### Container / OS

- Debian/Ubuntu-based Linux (scripts designed for Debian LXC)
- Root access (`sudo`/root)
- Internet access for packages and YTuner binary download
- `python3` (installed automatically; required for proxy/admin)

### Network / Firewall

- **TCP 80, UDP 53, TCP 8090, TCP 8091** reachable from LAN to YTuner container (8091 optional/admin only)
- Port 53 must not be used by another DNS service (`systemd-resolved`, `dnsmasq`, etc.)

## Repository Structure

```text
.
├── README.md / README.en.md
├── install.sh                        # One-shot installer
├── config/
│   ├── avr.ini                       # AVR menu/filter/sorting template
│   ├── stations.ini                  # Example "My Stations"
│   ├── ytuner.ini                    # Main YTuner config
│   ├── ytuner-admin.default          # Admin env
│   └── ytuner-stream-proxy.default   # Proxy env
├── docs/
│   ├── AVR-SETUP.md / AVR-SETUP.en.md
├── scripts/
│   ├── backup-config.sh
│   ├── create-lxc.sh
│   ├── install-ytuner.sh
│   ├── update-ytuner.sh
│   ├── ytuner-admin.py
│   ├── ytuner-autotest.py
│   └── ytuner-stream-proxy.py
├── webui/                            # index.html, app.js, styles.css
└── systemd/                          # ytuner*.service
```

## Quick Start

### Option A: One-shot install (recommended)

In an existing Debian/Ubuntu LXC:

```bash
wget -O install.sh http://192.168.50.88:3000/alex/ytuner-lxc/raw/branch/main/install.sh
sudo bash install.sh
```

Or:

```bash
curl -fsSL http://192.168.50.88:3000/alex/ytuner-lxc/raw/branch/main/install.sh | sudo bash
```

Installs packages, official YTuner binary (arch-dependent), default configs (if missing), proxy/admin scripts + webui, systemd units, handles port 53 conflict, starts services.

Options:

```bash
sudo bash install.sh --help
sudo bash install.sh --version 1.2.6
sudo bash install.sh --force-config
sudo bash install.sh --no-start
```

### Option B: Manual rollout

On Proxmox host:

```bash
sudo bash scripts/create-lxc.sh --ctid 120 --hostname ytuner --start
pct push 120 /path/to/ytuner-lxc /root/ytuner-lxc -r
pct enter 120
cd /root/ytuner-lxc
sudo bash scripts/install-ytuner.sh
```

### AVR DNS

Set AVR DNS server to **YTuner container IP**. Keep AVR gateway as normal router. Details: [docs/AVR-SETUP.en.md](docs/AVR-SETUP.en.md).

### HTTPS-only streams via proxy

```text
http://<YTUNER_IP>:8090/stream?url=https://example.com/radio.mp3
```

Shorthand also supported: `http://<YTUNER_IP>:8090/https://example.com/radio.mp3`. Put into `stations.ini` as stream URL.

## Configuration

### Files and Paths

| Path | Purpose |
|---|---|
| `/opt/ytuner/ytuner` | YTuner binary |
| `/opt/ytuner/ytuner.ini` | Main config (ports, DNS, cache, logging) |
| `/opt/ytuner/config/avr.ini` | AVR menu/filters/sorting |
| `/opt/ytuner/config/stations.ini` | My Stations |
| `/opt/ytuner/config/bookmark.xml` | Bookmarks |
| `/opt/ytuner/db/rb.db` | Radio-browser SQLite cache |
| `/opt/ytuner/cache/` | Icon/UUID/station cache |
| `/opt/ytuner/ytuner-stream-proxy.py` | HTTPS→HTTP proxy |
| `/opt/ytuner/ytuner-admin.py` | Admin WebUI/API |
| `/opt/ytuner/webui/` | Static WebUI files |
| `/etc/default/ytuner-stream-proxy` | Proxy env |
| `/etc/default/ytuner-admin` | Admin env |
| `/var/log/ytuner*.log` | Service logs |

Repo `config/` files are templates; copied on first install, kept unless `--force-config`.

### Key `ytuner.ini` defaults

- `IPAddress=default`, `ActAsHost=default`
- `MyStations.Enable=1`, `Radiobrowser.Enable=1`, `Bookmark.Enable=1`
- `MyStationsAutoRefreshPeriod=1` — YTuner re-reads `stations.ini` (e.g. saved from the web UI) automatically within ~1 minute; with `0` the file is only read at service start
- `WebServerPort=80`, `DNSServer.Enable=1`, `DNSServerPort=53`
- `InterceptDNs=*.vtuner.com,*.radiosetup.com,*.my-noxon.net,*.radiomarantz.com`
- `DNSServers=8.8.8.8,9.9.9.9`
- `MaintenanceServer.Enable=0`

After config changes: `sudo systemctl restart ytuner`.

### Custom stations (`stations.ini`)

```ini
[Group Name]
Station Name=http://stream.url/example.mp3|http://logo.url/logo.png
```

Logo URL optional. YTuner also supports YAML; this repo uses `stations.ini`.

Edits only reach the AVR after YTuner re-reads the file: automatically within `MyStationsAutoRefreshPeriod` minutes (template default `1`), or at service start when set to `0`. The admin web UI reports which path applies after saving and offers "Restart YTuner" for an immediate reload.

## Admin WebUI / API / Autotests

Admin UI default: **port 8091** - `http://<YTUNER_IP>:8091/`

- **Tab 1: Manage radio stations** - edit `stations.ini` (groups/stations/raw), station reachability check, Radio-Browser search and add to selected My Stations folder.
- **Tab 2: Administration / Tests** - service/port status, config overview, YTuner source toggles, proxy env editing, service restart, container reboot, logs, autotests with clickable lamp matrix.

### Admin config

`/etc/default/ytuner-admin`:

```bash
YTUNER_ADMIN_HOST=0.0.0.0
YTUNER_ADMIN_PORT=8091
YTUNER_ADMIN_TOKEN=              # optional; X-Admin-Token or ?token=
YTUNER_ADMIN_ALLOW_SYSTEMCTL=1   # allows restart/reboot via API
```

### API endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/api/health` | Admin healthcheck |
| GET | `/api/status` | Services/ports/config overview |
| GET | `/api/config` | Read-only config overview |
| GET/POST | `/api/stations` | Read/save `stations.ini`; saving propagates to YTuner (no restart when auto-refresh is on, otherwise restarts `ytuner`) |
| GET | `/api/stations/check?url=...` | Check stream URL reachability |
| GET | `/api/radiobrowser/search?q=...&limit=...` | Search Radio-Browser |
| GET/POST | `/api/config/ytuner-sources` | Read/save YTuner source toggles; saving restarts `ytuner` (startup-only values) |
| POST | `/api/config/proxy` | Save proxy env values |
| POST | `/api/service/restart` | Restart allowed service |
| POST | `/api/system/reboot` | Reboot container/host (if allowed) |
| GET | `/api/logs?name=ytuner|proxy|admin&lines=200` | Log tail |
| GET/POST | `/api/tests/run` | Run autotests |

### Autotest CLI

```bash
/usr/bin/python3 /opt/ytuner/ytuner-autotest.py
/usr/bin/python3 /opt/ytuner/ytuner-autotest.py --json --include-admin
```

Checks services, ports, files, HTTP health, Python syntax of proxy/admin scripts.

## Operation, Update, Backup

```bash
sudo systemctl status ytuner ytuner-stream-proxy ytuner-admin --no-pager
sudo systemctl restart ytuner
sudo journalctl -u ytuner -n 100 --no-pager
sudo tail -f /var/log/ytuner.log
```

Update:

```bash
cd /root/ytuner-lxc
sudo bash scripts/update-ytuner.sh --version 1.2.6
```

Backup:

```bash
sudo bash scripts/backup-config.sh
sudo bash scripts/backup-config.sh --output /root/ytuner-backup.tar.gz
```

## Validation and Troubleshooting

```bash
sudo ss -lntup | grep -E ':80 |:53 |:8090 |:8091 '
dig @<YTUNER_IP> pioneer.vtuner.com +short
curl -I http://<YTUNER_IP>/
curl -I http://<YTUNER_IP>:8090/health
curl -I http://<YTUNER_IP>:8091/api/health
/usr/bin/python3 /opt/ytuner/ytuner-autotest.py --json --include-admin
```

| Symptom | Likely cause | Fix |
|---|---|---|
| Port 53 missing | `systemd-resolved`/other DNS bound | stop/disable conflicting service; rerun installer |
| AVR finds no internet radio | AVR DNS not set to YTuner IP | set AVR DNS to fixed YTuner IP |
| Slow/empty station lists | DB build / low RAM / filters | increase LXC RAM to 1024MB; check `avr.ini` filters |
| HTTPS-only station won't play | AVR cannot do TLS | use proxy URL `http://<YTUNER_IP>:8090/stream?url=https://...` |
| Station edits visible in web UI but not on the AVR | YTuner keeps the station list in RAM; without `MyStationsAutoRefreshPeriod>=1` `stations.ini` is only read at startup | click "Restart YTuner" or `systemctl restart ytuner`; set `MyStationsAutoRefreshPeriod=1` in `/opt/ytuner/ytuner.ini`; check `/var/log/ytuner.log` (`Refreshing..`, `loaded N my stations`); reopen the menu on the AVR (it may cache) |
| Admin API restart/reboot denied | `YTUNER_ADMIN_ALLOW_SYSTEMCTL=0` or no systemctl | set env and restart admin service |

More AVR/network details: [docs/AVR-SETUP.en.md](docs/AVR-SETUP.en.md).

## Security Notes

- **DNS intercept is powerful:** only intended clients (AVRs) should use YTuner as DNS.
- **Ports 53/80/8090/8091 exposed in LAN:** restrict via firewall; 8091 only for admin networks.
- **Stream proxy** fetches client-supplied URLs; restrict port 8090 in untrusted networks.
- **Admin API:** set `YTUNER_ADMIN_TOKEN`; reboot/restart gated by `YTUNER_ADMIN_ALLOW_SYSTEMCTL`.
- **Service runs as root** due to privileged ports; isolated LXC reduces risk.
- **No secrets in repo;** backup before updates.

## References

- Upstream: https://github.com/coffeegreg/YTuner
- Releases: https://github.com/coffeegreg/YTuner/releases
- Upstream README: https://github.com/coffeegreg/YTuner/blob/master/README.md
- Upstream Docker doc: https://github.com/coffeegreg/YTuner/blob/master/doc/DOCKER.md
- Community Proxmox LXC: https://github.com/coffeegreg/YTuner/discussions/127

---

This repo contains rollout scripts/templates/docs for operating YTuner. YTuner itself is upstream by **coffeegreg** under MIT license. Check upstream license/release notes before production use.
