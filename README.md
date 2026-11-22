# YTuner Proxmox LXC Rollout

Dieses Repository enthält ein vollständiges, praxisnahes Rollout-Paket, um [YTuner](https://github.com/coffeegreg/YTuner) als **vTuner-Ersatz** in einem **Proxmox VE LXC-Container** zu betreiben. Ziel ist ein reproduzierbarer Setup-Weg: Container anlegen, YTuner installieren, AVR-DNS umstellen, Betrieb prüfen.

## Inhaltsverzeichnis

- [Überblick](#überblick)
- [Wie YTuner funktioniert](#wie-ytuner-funktioniert)
- [Voraussetzungen](#voraussetzungen)
- [Repository-Struktur](#repository-struktur)
- [Schnellstart](#schnellstart)
- [Detaillierte Installation](#detaillierte-installation)
- [Konfiguration](#konfiguration)
- [Betrieb, Update und Backup](#betrieb-update-und-backup)
- [Validierung und Troubleshooting](#validierung-und-troubleshooting)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Referenzen](#referenzen)

## Überblick

**YTuner** ist eine schlanke, eigenständige Anwendung (Free Pascal), die den früheren vTuner-Dienst für viele Internet-Radio-fähige AVRs ersetzt. Statt auf den externen vTuner-Dienst zuzugreifen, fragt der AVR den lokalen YTuner-Dienst ab.

Dieses Rollout stellt bereit:

- **LXC-Erstellung** auf dem Proxmox-Host (`scripts/create-lxc.sh`)
- **Automatische Installation** im Container (`scripts/install-ytuner.sh`)
- **Update-Skript** mit Binary-Backup (`scripts/update-ytuner.sh`)
- **Backup-Skript** für Config/DB/Cache/Logs (`scripts/backup-config.sh`)
- **systemd-Service** (`systemd/ytuner.service`)
- **Konfigurationsvorlagen** (`config/ytuner.ini`, `config/avr.ini`, `config/stations.ini`)
- **AVR-/Netzwerk-Anleitung** (`docs/AVR-SETUP.md`)

## Wie YTuner funktioniert

YTuner stellt zwei zentrale Dienste bereit:

- **Webservice (TCP/80):** Endpunkte, die AVRs für Stationslisten/Bookmarks/Streams erwarten.
- **DNS-Intercept (UDP/53):** fängt vTuner-bezogene Domains ab und beantwortet sie mit der IP des YTuner-Hosts.

Typischer Ablauf:

1. AVR hat als DNS den YTuner-Container eingetragen.
2. AVR fragt z. B. `*.vtuner.com` auf.
3. YTuner-DNS liefert die lokale YTuner-IP.
4. AVR verbindet sich per HTTP auf Port 80 mit YTuner.
5. YTuner liefert Stationsdaten (My Stations, Radio-browser, Bookmarks) und Stream-URLs.

> Wichtig: YTuner ist **kein Router/Gateway** für den AVR. Das Standard-Gateway des AVR bleibt der normale Router.

## Voraussetzungen

### Proxmox / Infrastruktur

- Proxmox VE Host mit LXC-Unterstützung
- Debian-12-LXC-Template verfügbar (wird vom Create-Skript bei Bedarf erkannt/heruntergeladen)
- Netzwerkbridge (Standard: `vmbr0`)
- Feste IP oder DHCP-Reservierung für den YTuner-Container (empfohlen)

### Container / Betriebssystem im LXC

- Debian/Ubuntu-basiertes Linux (Skripte sind für Debian LXC ausgelegt)
- Root-Zugriff im Container (`sudo`/root)
- Internetzugang für Paketinstallation und Download der YTuner-Binaries

### Netzwerk / Firewall

- **TCP 80** und **UDP 53** müssen vom LAN zum YTuner-Container erreichbar sein
- Falls Proxmox-Firewall oder Firewall im LXC aktiv ist: entsprechende Regeln setzen
- Port 53 darf nicht bereits durch anderen DNS-Dienst belegt sein (`systemd-resolved`, `dnsmasq` etc.)

## Repository-Struktur

```text
.
├── README.md                  # Diese ausführliche Anleitung
├── install.sh                 # One-Shot Installer (wget/curl -> bash)
├── .gitignore                 # Ignoriert Logs/Archive/temporäre Dateien
├── config/
│   ├── avr.ini                # AVR-Menü/Filter/Sortierung (Template)
│   ├── stations.ini           # Beispiel für "My Stations"
│   └── ytuner.ini             # Hauptkonfiguration für YTuner
├── docs/
│   └── AVR-SETUP.md           # AVR-DNS/Netzwerk-Checkliste & Troubleshooting
├── scripts/
│   ├── backup-config.sh       # Backup von Config/DB/Cache/Log/Service
│   ├── create-lxc.sh          # Proxmox-Host: LXC anlegen
│   ├── install-ytuner.sh      # Im LXC: Installation + systemd + Verifikation
│   └── update-ytuner.sh       # Im LXC: Binary-Update mit Backup
└── systemd/
    └── ytuner.service         # systemd-Unit für /opt/ytuner/ytuner
```

## Schnellstart (One-Shot Installation)

### Option A: Ein einziges Skript (empfohlen)

Wenn der LXC-Container bereits läuft (Debian/Ubuntu), reicht dieses eine Skript:

```bash
wget -O install.sh http://192.168.50.88:3000/alex/ytuner-lxc/raw/branch/main/install.sh
sudo bash install.sh
```

Alternativ mit `curl`:

```bash
curl -fsSL http://192.168.50.88:3000/alex/ytuner-lxc/raw/branch/main/install.sh | sudo bash
```

Das Skript installiert automatisch:

- benötigte Pakete (`wget`, `unzip`, `sqlite3`, `libsqlite3-0`, `ca-certificates`, etc.)
- die passende offizielle YTuner-Binary (architekturabhängig)
- Default-Konfigurationsdateien unter `/opt/ytuner/` (falls nicht vorhanden)
- die `systemd`-Unit und aktiviert/startet den Dienst
- behandelt Port-53-Konflikte mit `systemd-resolved`

Nützliche Optionen:

```bash
sudo bash install.sh --help
sudo bash install.sh --version 1.2.6
sudo bash install.sh --force-config     # überschreibt ytuner.ini/avr.ini/stations.ini
sudo bash install.sh --no-start         # nur installieren, nicht starten
```

### Option B: Manuelles Rollout mit Repo-Skripten

#### 1) LXC auf dem Proxmox-Host erstellen

Auf dem **Proxmox VE Host** ausführen:

```bash
bash scripts/create-lxc.sh --help
sudo bash scripts/create-lxc.sh --ctid 120 --hostname ytuner --start
```

#### 2) Projektdateien in den Container kopieren

```bash
pct push 120 /home/Exchange/ytuner-lxc /root/ytuner-lxc -r
pct enter 120
```

#### 3) Im LXC installieren

```bash
cd /root/ytuner-lxc
sudo bash scripts/install-ytuner.sh
```

### 4) AVR auf YTuner-DNS umstellen

Am AVR den DNS-Server auf die **IP des YTuner-Containers** setzen. Details: [docs/AVR-SETUP.md](docs/AVR-SETUP.md).

## Detaillierte Installation

### Was `scripts/create-lxc.sh` macht (Proxmox-Host)

- prüft Eingaben und vorhandene `pct`/`pveam`/`pvesm` Kommandos
- erkennt optional das neueste Debian-12-Standard-Template
- lädt Template bei Bedarf herunter
- erstellt den LXC mit konfigurierbaren Ressourcen/Netzwerkoptionen
- optional: Container direkt starten (`--start`)

Wichtige Optionen:

- `--ctid` (Pflicht), `--hostname`, `--storage`, `--template-storage`, `--template`
- `--disk`, `--memory`, `--swap`, `--cores`
- `--bridge`, `--ip`, `--gateway`, `--dns`
- `--ssh-pubkey`, `--password`, `--unprivileged`, `--features`, `--onboot`
- `--start`, `--dry-run`

### Was `scripts/install-ytuner.sh` macht (im LXC)

- erkennt Architektur und wählt das passende offizielle YTuner-Release-Asset
- installiert Abhängigkeiten via `apt-get` (u. a. `wget`, `unzip`, `sqlite3`, `libsqlite3-0`, `ca-certificates`)
- behandelt Port-53-Konflikte: stoppt/deaktiviert `systemd-resolved` (falls aktiv) und ersetzt Stub-`resolv.conf` durch statische DNS
- lädt Release-ZIP von GitHub, entpackt und installiert Binary nach `/opt/ytuner/ytuner`
- legt Verzeichnisse an: `/opt/ytuner/config`, `/opt/ytuner/cache`, `/opt/ytuner/db`
- kopiert Templates aus `config/` **nur wenn Ziel fehlt** (außer bei `--force-config`)
- installiert systemd-Unit, lädt Daemon neu, aktiviert/startet Service (außer `--no-start`)
- prüft, ob Ports 80/tcp und 53/udp lauschen

Wichtige Optionen:

```bash
sudo bash scripts/install-ytuner.sh --help
```

- `--version 1.2.6` — YTuner-Version (Default: `1.2.6`)
- `--install-dir /opt/ytuner` — Zielverzeichnis
- `--force-config` — bestehende `ytuner.ini`/`avr.ini`/`stations.ini` überschreiben
- `--no-start` — nur installieren, Service nicht starten
- `--skip-dns-check` — Port-53/systemd-resolved-Handling überspringen (nicht empfohlen)
- `--dry-run` — Aktionen nur anzeigen

### Unterstützte Architekturen (Installer/Updater)

Die Skripte mappen die Systemarchitektur auf offizielle YTuner-Release-Pakete:

- `x86_64/amd64`
- `aarch64/arm64`
- `armv7l/armv7hl`
- `armv6l/armhf`
- `i386/i686`

Andere Architekturen müssen manuell geprüft werden (Upstream-Releases).

## Konfiguration

### Dateien und Pfade

Nach der Installation liegen die produktiven Dateien unter `/opt/ytuner`:

| Pfad | Zweck |
|---|---|
| `/opt/ytuner/ytuner` | YTuner-Binary |
| `/opt/ytuner/ytuner.ini` | Hauptkonfiguration (Ports, DNS, Cache, Logging etc.) |
| `/opt/ytuner/config/avr.ini` | AVR-Menü, Filter, Sortierung, Übersetzeroptionen |
| `/opt/ytuner/config/stations.ini` | Eigene Stationsliste ("My Stations") |
| `/opt/ytuner/config/bookmark.xml` | Bookmarks (zur Laufzeit/je nach AVR-Nutzung) |
| `/opt/ytuner/db/rb.db` | Radio-browser SQLite-Cache (bei DB-Cache-Typen) |
| `/opt/ytuner/cache/` | Icon-/UUID-/Stationscache (je nach Einstellung) |
| `/var/log/ytuner.log` | Service-Log (stdout/stderr der Unit) |

Die Dateien im Repo unter `config/` sind **Templates**. Sie werden beim Erstinstall kopiert; bestehende Dateien bleiben erhalten, außer `--force-config` wird gesetzt.

### Wichtige Einstellungen in `ytuner.ini` (Template-Defaults)

- `IPAddress=default` / `ActAsHost=default` — für normale LXC-Setups passend
- `MessageInfoLevel=1` — sinnvolles Basis-Logging
- `MyStations.Enable=1`, `MyStationsFile=stations.ini`
- `Radiobrowser.Enable=1`
- `RBCacheType=catPermMemDB` — gute UX bei vorhandenem SQLite; benötigt etwas RAM
- `WebServerPort=80`
- `DNSServer.Enable=1`, `DNSServerPort=53`
- `InterceptDNs=*.vtuner.com,*.radiosetup.com,*.my-noxon.net,*.radiomarantz.com`
- `DNSServers=8.8.8.8,9.9.9.9` (Upstream-DNS für nicht abgefangene Domains)
- `MaintenanceServer.Enable=0` (sicherer Default)

### Anpassungen nach Bedarf

1. Datei bearbeiten, z. B. `/opt/ytuner/ytuner.ini`
2. Syntax/Werte prüfen (YTuner ist tolerant, aber falsche Werte können Verhalten ändern)
3. Service neu starten:

```bash
sudo systemctl restart ytuner
sudo systemctl status ytuner --no-pager
sudo tail -f /var/log/ytuner.log
```

### Eigene Sender (`stations.ini`)

Format:

```ini
[Group Name]
Station Name=http://stream.url/example.mp3|http://logo.url/logo.png
```

- Logo-URL ist optional.
- Alternativ unterstützt YTuner auch `stations.yaml`/`.yml` (siehe Upstream-Doku). Template dieses Repos verwendet `stations.ini`.

## Betrieb, Update und Backup

### systemd-Betrieb

```bash
# Status
sudo systemctl status ytuner --no-pager

# Neustart / Stopp / Start
sudo systemctl restart ytuner
sudo systemctl stop ytuner
sudo systemctl start ytuner

# Logs
sudo journalctl -u ytuner -n 100 --no-pager
sudo tail -f /var/log/ytuner.log
```

Die mitgelieferte Unit startet ` /opt/ytuner/ytuner` als `root` im WorkingDirectory `/opt/ytuner`, mit `Restart=always` und Logging nach `/var/log/ytuner.log`.

### Update

```bash
cd /root/ytuner-lxc
sudo bash scripts/update-ytuner.sh            # Default-Version aus Skript
sudo bash scripts/update-ytuner.sh --version 1.2.6
```

Das Update-Skript:

- lädt das Zielrelease für die erkannte Architektur
- sichert das vorhandene Binary als `ytuner.bak.<timestamp>`
- ersetzt das Binary atomar per `install`
- startet den Service neu (außer `--no-restart`)

### Backup

```bash
cd /root/ytuner-lxc
sudo bash scripts/backup-config.sh
# optional:
sudo bash scripts/backup-config.sh --output /root/ytuner-backup.tar.gz
```

Gesichert werden (falls vorhanden):

- `/opt/ytuner/ytuner.ini`
- `/opt/ytuner/config/`
- `/opt/ytuner/db/`
- `/opt/ytuner/cache/`
- `/etc/systemd/system/ytuner.service`
- `/var/log/ytuner.log`

## Validierung und Troubleshooting

### Schnellchecks

```bash
# Service aktiv?
sudo systemctl status ytuner --no-pager

# Ports offen?
sudo ss -lntup | grep -E ':80 |:53 '

# DNS-Intercept funktioniert? (von anderem LAN-Client)
dig @<YTUNER_IP> pioneer.vtuner.com +short

# HTTP antwortet?
curl -I http://<YTUNER_IP>/
```

### Typische Probleme

| Symptom | Wahrscheinliche Ursache | Prüfung / Lösung |
|---|---|---|
| YTuner startet, aber Port 53 fehlt | `systemd-resolved`/DNS-Dienst belegt Port 53 | `ss -lntup \| grep ':53'`, konfligierenden Dienst stoppen/deaktivieren; Installer ohne `--skip-dns-check` ausführen |
| AVR findet kein Internetradio | AVR-DNS nicht auf YTuner gesetzt / falsche IP | AVR-Netzwerkeinstellungen prüfen, YTuner-IP fix/reserviert setzen |
| Stationen laden langsam / Abbruch beim ersten Start | Radio-browser DB initialer Aufbau, wenig RAM | LXC auf 1024MB RAM erhöhen; Log prüfen (`/var/log/ytuner.log`) |
| Senderlisten leer/gefiltert | Zu restriktive Filter in `avr.ini` | Filter in `/opt/ytuner/config/avr.ini` lockern, Service neustarten |
| AVR kann browsen, aber Streams schlagen fehl | Netzwerk/Codec/HTTPS/AVR-spezifisches Verhalten | Log prüfen, `Protocol`/Cache/SSL-Einstellungen testen, Upstream-Issues zum AVR-Modell prüfen |
| Nach Reboot kein Dienst | Service nicht enabled oder Container nicht gestartet | `systemctl is-enabled ytuner`, `pct config <CTID>` (`onboot`) prüfen |

Weitere AVR-spezifische Schritte: [docs/AVR-SETUP.md](docs/AVR-SETUP.md).

## Sicherheitshinweise

- **DNS-Intercept ist wirkungsvoll:** Stelle sicher, dass nur intended Clients (AVRs) den YTuner als DNS nutzen.
- **Port 53/80 im LAN exponiert:** Firewalling auf Proxmox/LXC/Netzwerkebene empfehlenswert (nur LAN erlauben).
- **Service läuft als root:** Upstream-YTuner benötigt privilegierte Ports; Betrieb in isoliertem LXC reduziert Risiko.
- **Keine Secrets im Repo:** Dieses Repo enthält keine API-Keys; halte lokale Credentials/Token außerhalb von Git.
- **Config-Backups:** Vor Updates/Änderungen `scripts/backup-config.sh` nutzen.

## Referenzen

- Upstream-Projekt: https://github.com/coffeegreg/YTuner
- Releases (Binaries): https://github.com/coffeegreg/YTuner/releases
- Upstream README / Konfiguration: https://github.com/coffeegreg/YTuner/blob/master/README.md
- Upstream Docker-Doku: https://github.com/coffeegreg/YTuner/blob/master/doc/DOCKER.md
- Community-Hinweis Proxmox LXC: https://github.com/coffeegreg/YTuner/discussions/127

---

## Lizenz / Upstream

Dieses Repository enthält Rollout-Skripte, Templates und Dokumentation für den Betrieb von YTuner. YTuner selbst ist ein Upstream-Projekt von **coffeegreg** unter MIT-Lizenz. Prüfe die Upstream-Lizenz/Release-Hinweise vor produktivem Einsatz.
