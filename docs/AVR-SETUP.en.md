# AVR Setup for YTuner (English)

> Deutsch: [AVR-SETUP.md](AVR-SETUP.md)

This guide covers network/AVR setup after YTuner is running in the LXC.

## 0. Know the ports

This rollout exposes:

- **TCP 80** - YTuner web/API endpoint for AVR
- **UDP 53** - YTuner DNS intercept
- **TCP 8090** - HTTPS→HTTP stream proxy (for HTTPS-only stations)
- **TCP 8091** - Admin WebUI/API (settings, logs, autotests; optional, restrict to admin LAN)

## 1. Give YTuner a stable IP

Use either a **static IP** in LXC/Proxmox config, or a **DHCP reservation** on your router/DHCP server.

The AVR uses this IP as its DNS server. If it changes, AVR internet radio breaks.

## 2. Verify YTuner is healthy

On the YTuner container:

```bash
sudo systemctl status ytuner --no-pager
sudo systemctl status ytuner-stream-proxy --no-pager
sudo systemctl status ytuner-admin --no-pager
sudo ss -lntup | grep -E ':80 |:53 |:8090 |:8091 '
sudo tail -n 50 /var/log/ytuner.log
```

From another LAN machine:

```bash
dig @<YTUNER_IP> pioneer.vtuner.com +short
# should return <YTUNER_IP> (or configured ActAsHost/IP)
```

## 3. Configure the AVR

On the AVR network settings:

1. Set **DNS server** to `<YTUNER_IP>` (primary). If secondary DNS is required, same IP or leave blank if allowed.
2. Disable AVR **proxy** settings if present.
3. Keep AVR **gateway** pointed at your normal router (YTuner is DNS/web endpoint, not a router).
4. Save and reboot the AVR if needed.

> Exact menu names vary by brand/model (e.g. Yamaha: *Setup > Network > Network Setup > IP Address/DNS*).

## 4. DNS domains intercepted by default

Default `ytuner.ini` template intercepts:

- `*.vtuner.com`
- `*.radiosetup.com`
- `*.my-noxon.net`
- `*.radiomarantz.com`

If your AVR uses a different vTuner-related domain, observe DNS queries and add it to `InterceptDNs` in `/opt/ytuner/ytuner.ini`, then restart ytuner.

## 5. Troubleshooting

### AVR shows "Please check network" / no internet radio

- Confirm AVR can reach LAN and gateway.
- Confirm AVR DNS is set to YTuner IP.
- Confirm YTuner ports 80/53 are listening.
- Confirm no firewall blocks LAN -> YTuner 80/tcp, 53/udp.

### YTuner not listening on port 53

Another DNS service is likely bound to 53 (`systemd-resolved`, `dnsmasq`, etc.):

```bash
sudo ss -lntup | grep ':53 '
```

Disable conflicting service or reconfigure. The installer handles `systemd-resolved` on Debian.

### Stations browse but won't play

- Check `ytuner.ini` cache settings; `RBCacheType=catPermMemDB` or `catDB` with SQLite3 recommended.
- Ensure SQLite3 installed (`sqlite3 --version`).
- Check `/var/log/ytuner.log`.
- Some AVRs need specific icon/protocol settings; see upstream issues/discussions.

### HTTPS-only station won't play on old AVR

Many AVRs cannot open TLS connections. Use the included stream proxy:

```text
http://<YTUNER_IP>:8090/stream?url=https://original-stream-url
```

Add that URL to `stations.ini` (My Stations) or test directly:

```bash
curl -I http://<YTUNER_IP>:8090/health
curl -v "http://<YTUNER_IP>:8090/stream?url=https://example.com/stream.mp3" | head
sudo tail -f /var/log/ytuner-stream-proxy.log
```

If proxy works but AVR still fails, the station may use an unsupported codec/container for that AVR.

### Admin WebUI / API / Autotests

- Open: `http://<YTUNER_IP>:8091/`
- Health: `curl -I http://<YTUNER_IP>:8091/api/health`
- Stations: `GET/POST /api/stations`
- Radio-Browser: `GET /api/radiobrowser/search?q=...&limit=...`
- Run tests via API: `curl -X POST http://<YTUNER_IP>:8091/api/tests/run`
- Run tests via CLI: `/usr/bin/python3 /opt/ytuner/ytuner-autotest.py --json --include-admin`
- Config: `/etc/default/ytuner-admin` (optional `YTUNER_ADMIN_TOKEN`, `YTUNER_ADMIN_ALLOW_SYSTEMCTL`)

### Radio-browser DB build killed / slow

First DB build can use noticeable RAM/CPU. Increase LXC memory to 1024MB temporarily or permanently. See upstream discussion #127.

### Verify from container

```bash
sudo systemctl status ytuner --no-pager
sudo ss -lntup | grep -E ':80 |:53 |:8090 |:8091 '
sudo tail -f /var/log/ytuner.log
```

## 6. Optional: Pi-hole / dnsmasq integration

If you already run Pi-hole/dnsmasq, you can redirect vTuner domains there instead of using YTuner's DNS server. In that case, disable YTuner DNS (`[DNSServer] Enable=0`) and add DNS records in your DNS server pointing vTuner domains to the YTuner IP. Simpler path: let YTuner handle DNS for the AVR only.
