# YTuner Proxmox LXC Rollout

This folder contains a ready-to-use rollout for [YTuner](https://github.com/coffeegreg/YTuner) on a Proxmox VE LXC container.

YTuner is a lightweight vTuner replacement for AVRs (Yamaha, Denon, Marantz, Pioneer, Onkyo, Harman Kardon, and others). It provides:

- **Web service** on TCP port `80` for AVR station browsing/streaming endpoints
- **DNS intercept** on UDP port `53` for `*.vtuner.com` and related domains
- **Radio-browser.info** integration with local caching
- **Custom stations** via `stations.ini` / `stations.yaml`
- **Bookmarks** support for compatible AVRs

## Repository layout

```text
.
├── README.md
├── .gitignore
├── config/
│   ├── avr.ini              # AVR/menu/filter template
│   ├── stations.ini         # Example custom stations
│   └── ytuner.ini           # Main YTuner config tuned for LXC
├── docs/
│   └── AVR-SETUP.md         # AVR DNS/network setup checklist
├── scripts/
│   ├── backup-config.sh     # Backup config/db/cache
│   ├── create-lxc.sh        # Run on Proxmox host to create container
│   ├── install-ytuner.sh    # Run inside LXC to install/configure YTuner
│   └── update-ytuner.sh     # Run inside LXC to update YTuner binary
└── systemd/
    └── ytuner.service       # systemd unit template
```

## Quick start

### 1) Create the LXC on the Proxmox host

Run on the **Proxmox VE host** (not inside the container):

```bash
# Review defaults first
bash scripts/create-lxc.sh --help

# Example: create CT 120 with DHCP
sudo bash scripts/create-lxc.sh --ctid 120 --hostname ytuner

# Example: static IP
sudo bash scripts/create-lxc.sh \
  --ctid 120 \
  --hostname ytuner \
  --ip 192.168.1.120/24 \
  --gateway 192.168.1.1 \
  --dns 192.168.1.1
```

The script creates an unprivileged Debian 12 LXC with sensible defaults for YTuner (`512MB RAM`, `1 core`, `8GB disk`, nesting enabled). It prints the next steps after creation.

### 2) Copy this project into the container

From the Proxmox host (or any machine with the files):

```bash
# Example: push folder into container
pct push 120 /home/Exchange/ytuner-lxc /root/ytuner-lxc -r
pct exec 120 -- bash -lc 'ls /root/ytuner-lxc'
```

Or clone/copy the folder by any method you prefer.

### 3) Install YTuner inside the container

Run **inside the LXC**:

```bash
cd /root/ytuner-lxc
sudo bash scripts/install-ytuner.sh
```

The installer will:

- install required packages (`wget`, `unzip`, `sqlite3`, `ca-certificates`, `net-tools`/`iproute2`)
- download the official YTuner release binary for the detected architecture
- install into `/opt/ytuner`
- copy config templates from `config/` (without overwriting existing configs unless `--force-config`)
- install and enable the `ytuner.service` systemd unit
- disable `systemd-resolved` if it is occupying port 53
- start YTuner and verify ports 80/tcp and 53/udp

### 4) Point your AVR DNS to the YTuner container

On your AVR/network device, set DNS to the **YTuner container IP**. See [docs/AVR-SETUP.md](docs/AVR-SETUP.md).

## Installer options

```bash
sudo bash scripts/install-ytuner.sh --help
```

Useful flags:

- `--version 1.2.6` — YTuner release version (default: `1.2.6`)
- `--install-dir /opt/ytuner` — install location
- `--force-config` — overwrite existing `ytuner.ini`/`avr.ini`/`stations.ini` with templates from `config/`
- `--no-start` — install but do not start/enable service
- `--skip-dns-check` — skip systemd-resolved/port 53 handling (not recommended)

## Updating

```bash
cd /root/ytuner-lxc
sudo bash scripts/update-ytuner.sh            # latest configured/default version
sudo bash scripts/update-ytuner.sh --version 1.2.6
```

The updater backs up the current binary before replacing it and restarts the service.

## Configuration

Primary files live in `/opt/ytuner` after install:

- `/opt/ytuner/ytuner.ini` — main service config
- `/opt/ytuner/config/avr.ini` — AVR/menu/filter config
- `/opt/ytuner/config/stations.ini` — custom stations
- `/opt/ytuner/db/rb.db` — Radio-browser SQLite cache (created at runtime when DB cache enabled)
- `/var/log/ytuner.log` — service log (systemd `StandardOutput`/`StandardError`)

Templates in this repo (`config/`) are copied on first install. Edit the installed files, then restart:

```bash
sudo systemctl restart ytuner
sudo systemctl status ytuner --no-pager
sudo tail -f /var/log/ytuner.log
```

## Operational checks

```bash
# Service status
sudo systemctl status ytuner --no-pager

# Listening ports
sudo ss -lntup | grep -E ':80 |:53 '

# DNS intercept sanity check (from another machine on LAN)
dig @<YTUNER_IP> pioneer.vtuner.com +short

# HTTP endpoint sanity check
curl -I http://<YTUNER_IP>/
```

## Notes / gotchas

- **Port 53 conflict**: `systemd-resolved` or other DNS services will block YTuner DNS. The installer disables `systemd-resolved` by default on Debian LXC.
- **Memory**: YTuner is lightweight, but Radio-browser DB build can spike memory. 512MB RAM is a practical minimum; 1GB is comfortable. If you see OOM kills, increase container RAM.
- **Static IP recommended**: AVRs point DNS at this container; use a DHCP reservation or static IP.
- **Firewall**: If you run firewalling inside LXC, allow `80/tcp` and `53/udp` from your LAN.
- **Proxmox firewall**: Also allow those ports if Datacenter/Node/CT firewall is enabled.
- **No Windows binaries**: Upstream v1.2.6 dropped Windows binaries; this rollout targets Linux LXC.

## References

- Upstream project: https://github.com/coffeegreg/YTuner
- Releases: https://github.com/coffeegreg/YTuner/releases
- Docker guide (upstream): https://github.com/coffeegreg/YTuner/blob/master/doc/DOCKER.md
- Community Proxmox LXC confirmation: https://github.com/coffeegreg/YTuner/discussions/127
