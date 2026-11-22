# AVR Setup for YTuner

This guide covers the network/AVR side after YTuner is running in the LXC.

## 0. Know the ports

This rollout exposes:

- **TCP 80** - YTuner web/API endpoint for AVR
- **UDP 53** - YTuner DNS intercept
- **TCP 8090** - HTTPS→HTTP stream proxy (for HTTPS-only stations)
- **TCP 8091** - Admin WebUI/API (settings, logs, autotests; optional, restrict to admin LAN)

## 1. Give YTuner a stable IP

Use either:

- a **static IP** in the LXC/Proxmox config, or
- a **DHCP reservation** on your router/DHCP server

The AVR will use this IP as its DNS server. If it changes, AVR internet radio breaks.

## 2. Verify YTuner is healthy

On the YTuner container:

```bash
sudo systemctl status ytuner --no-pager
sudo ss -lntup | grep -E ':80 |:53 '
sudo tail -n 50 /var/log/ytuner.log
```

Expected: `ytuner` listening on TCP 80 and UDP 53.

From another LAN machine:

```bash
dig @<YTUNER_IP> pioneer.vtuner.com +short
# should return <YTUNER_IP> (or the configured ActAsHost/IP)
```

## 3. Configure the AVR

On the AVR's network settings:

1. Set **DNS server** to `<YTUNER_IP>` (primary).  
   If the AVR requires secondary DNS, you can set the same IP or leave secondary blank if allowed.
2. Disable AVR **proxy** settings if present.
3. Keep AVR gateway pointed at your normal router (YTuner is DNS/web endpoint, not a router).
4. Save and reboot the AVR if needed.

> Exact menu names vary by brand/model (e.g., Yamaha: *Setup > Network > Network Setup > IP Address/DNS*).

## 4. DNS domains intercepted by default

The default `ytuner.ini` template intercepts common vTuner domains:

- `*.vtuner.com`
- `*.radiosetup.com`
- `*.my-noxon.net`
- `*.radiomarantz.com`

If your AVR uses a different vTuner-related domain, watch DNS queries (Pi-hole logs, tcpdump, or router DNS logs) and add it to `InterceptDNs` in `/opt/ytuner/ytuner.ini`.

## 5. Troubleshooting

### AVR shows "Please check network" / no internet radio

- Confirm AVR can reach LAN and gateway.
- Confirm AVR DNS is set to YTuner IP.
- Confirm YTuner ports 80/53 are listening.
- Confirm no firewall blocks LAN -> YTuner 80/tcp, 53/udp.

### YTuner not listening on port 53

Another DNS service is likely bound to 53 (`systemd-resolved`, `dnsmasq`, etc.). Check:

```bash
sudo ss -lntup | grep ':53 '
```

Disable the conflicting service or reconfigure. The installer handles `systemd-resolved` on Debian.

### Stations browse but won't play

- Check `ytuner.ini` cache settings; `RBCacheType=catPermMemDB` or `catDB` with SQLite3 is recommended.
- Ensure SQLite3 is installed (`sqlite3 --version`).
- Check `/var/log/ytuner.log` for errors.
- Some AVRs need specific icon/protocol settings; see upstream issues/discussions.

### HTTPS-only station won't play on old AVR

Many AVRs cannot open TLS connections. Use the included stream proxy:

```text
http://<YTUNER_IP>:8090/stream?url=https://original-stream-url
```

Add that URL to `stations.ini` (My Stations) or test it directly:

```bash
curl -I http://<YTUNER_IP>:8090/health
curl -v "http://<YTUNER_IP>:8090/stream?url=https://example.com/stream.mp3" | head
sudo tail -f /var/log/ytuner-stream-proxy.log
```

If the proxy works but the AVR still fails, the station may use an unsupported codec/container for that AVR.

### Admin WebUI / API / Autotests

- Open: `http://<YTUNER_IP>:8091/`
- Health: `curl -I http://<YTUNER_IP>:8091/api/health`
- Run tests via API: `curl -X POST http://<YTUNER_IP>:8091/api/tests/run`
- Run tests via CLI: `/usr/bin/python3 /opt/ytuner/ytuner-autotest.py --json --include-admin`
- Config: `/etc/default/ytuner-admin` (optional `YTUNER_ADMIN_TOKEN`)

### Radio-browser DB build killed / slow

First DB build can use noticeable RAM/CPU. Increase LXC memory to 1024MB temporarily or permanently. See upstream discussion #127.

### Verify from container

```bash
# Check ytuner process and ports
sudo systemctl status ytuner --no-pager
sudo ss -lntup | grep ytuner

# Watch logs
sudo tail -f /var/log/ytuner.log
```

## 6. Optional: Pi-hole / dnsmasq integration

If you already run Pi-hole/dnsmasq, you can redirect vTuner domains there instead of using YTuner's DNS server. In that case, disable YTuner DNS (`[DNSServer] Enable=0`) and add DNS records in your DNS server pointing vTuner domains to the YTuner IP. The simpler path is usually: let YTuner handle DNS for the AVR only.
