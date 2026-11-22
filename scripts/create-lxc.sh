#!/usr/bin/env bash
set -Eeuo pipefail

# create-lxc.sh - Run on the Proxmox VE host to create an LXC for YTuner.
# Creates an unprivileged Debian 12 container with defaults suitable for YTuner.

usage() {
  cat <<'USAGE'
Usage: create-lxc.sh --ctid <id> [options]

Required:
  --ctid <id>             Proxmox container ID (e.g. 120)

Options:
  --hostname <name>       Container hostname (default: ytuner)
  --storage <storage>     Storage for rootfs (default: local-lvm)
  --template-storage <s>  Storage containing templates (default: local)
  --template <tmpl>       Template file/name (default: auto-detect latest debian-12-standard)
  --disk <gb>             Rootfs size in GB (default: 8)
  --memory <mb>           RAM in MB (default: 512)
  --swap <mb>             Swap in MB (default: 256)
  --cores <n>             CPU cores (default: 1)
  --bridge <name>         Network bridge (default: vmbr0)
  --ip <cidr|dhcp>        IP config (default: dhcp). Example: 192.168.1.120/24
  --gateway <ip>          Gateway (required when --ip is static CIDR)
  --dns <ip>              DNS server for container (default: host/default)
  --password <pw>         Root password (optional; prompts/SSH keys recommended instead)
  --ssh-pubkey <file>     SSH public key file to install for root
  --unprivileged <0|1>    Unprivileged container (default: 1)
  --features <list>       LXC features (default: nesting=1,keyctl=1)
  --onboot <0|1>          Start on boot (default: 1)
  --start                 Start container after creation
  --dry-run               Print commands without executing
  -h, --help              Show this help

Examples:
  sudo bash scripts/create-lxc.sh --ctid 120 --hostname ytuner --start
  sudo bash scripts/create-lxc.sh --ctid 120 --ip 192.168.1.120/24 --gateway 192.168.1.1 --dns 192.168.1.1 --start
USAGE
}

log() { printf '[create-lxc] %s\n' "$*"; }
err() { printf '[create-lxc] ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

CTID=""
HOSTNAME="ytuner"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
TEMPLATE=""
DISK_GB="8"
MEMORY_MB="512"
SWAP_MB="256"
CORES="1"
BRIDGE="vmbr0"
IP_CONF="dhcp"
GATEWAY=""
DNS=""
PASSWORD=""
SSH_PUBKEY_FILE=""
UNPRIVILEGED="1"
FEATURES="nesting=1,keyctl=1"
ONBOOT="1"
START_AFTER="0"
DRY_RUN="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="${2:-}"; shift 2 ;;
    --hostname) HOSTNAME="${2:-}"; shift 2 ;;
    --storage) STORAGE="${2:-}"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="${2:-}"; shift 2 ;;
    --template) TEMPLATE="${2:-}"; shift 2 ;;
    --disk) DISK_GB="${2:-}"; shift 2 ;;
    --memory) MEMORY_MB="${2:-}"; shift 2 ;;
    --swap) SWAP_MB="${2:-}"; shift 2 ;;
    --cores) CORES="${2:-}"; shift 2 ;;
    --bridge) BRIDGE="${2:-}"; shift 2 ;;
    --ip) IP_CONF="${2:-}"; shift 2 ;;
    --gateway) GATEWAY="${2:-}"; shift 2 ;;
    --dns) DNS="${2:-}"; shift 2 ;;
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --ssh-pubkey) SSH_PUBKEY_FILE="${2:-}"; shift 2 ;;
    --unprivileged) UNPRIVILEGED="${2:-}"; shift 2 ;;
    --features) FEATURES="${2:-}"; shift 2 ;;
    --onboot) ONBOOT="${2:-}"; shift 2 ;;
    --start) START_AFTER="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

[[ -n "$CTID" ]] || { usage; die "--ctid is required"; }
[[ "$CTID" =~ ^[0-9]+$ ]] || die "--ctid must be numeric"
[[ "$UNPRIVILEGED" == "0" || "$UNPRIVILEGED" == "1" ]] || die "--unprivileged must be 0 or 1"
[[ "$ONBOOT" == "0" || "$ONBOOT" == "1" ]] || die "--onboot must be 0 or 1"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "--disk must be integer GB"
[[ "$MEMORY_MB" =~ ^[0-9]+$ ]] || die "--memory must be integer MB"
[[ "$SWAP_MB" =~ ^[0-9]+$ ]] || die "--swap must be integer MB"
[[ "$CORES" =~ ^[0-9]+$ ]] || die "--cores must be integer"

if [[ "$IP_CONF" != "dhcp" && -z "$GATEWAY" ]]; then
  die "--gateway is required when --ip is a static CIDR"
fi

if [[ -n "$SSH_PUBKEY_FILE" && ! -f "$SSH_PUBKEY_FILE" ]]; then
  die "SSH public key file not found: $SSH_PUBKEY_FILE"
fi

need_cmd pct
need_cmd pveam
need_cmd pvesm

if pct status "$CTID" >/dev/null 2>&1; then
  die "CTID $CTID already exists"
fi

if [[ -z "$TEMPLATE" ]]; then
  log "Detecting latest Debian 12 standard template in $TEMPLATE_STORAGE..."
  TEMPLATE_CANDIDATE=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep '^debian-12-standard_.*_amd64\.tar\.' | sort -V | tail -n1 || true)
  [[ -n "$TEMPLATE_CANDIDATE" ]] || die "Could not auto-detect Debian 12 template. Pass --template explicitly."
  TEMPLATE="$TEMPLATE_CANDIDATE"
fi

# Normalize template ref for pct (storage:vztmpl/file or just file)
if [[ "$TEMPLATE" != *:* ]]; then
  TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
else
  TEMPLATE_REF="$TEMPLATE"
fi

TEMPLATE_FILE="${TEMPLATE_REF#*:}"
TEMPLATE_FILE="${TEMPLATE_FILE#vztmpl/}"

log "Ensuring template is present: $TEMPLATE_FILE"
if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -Fxq "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  && ! pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -Fxq "$TEMPLATE_FILE"; then
  run pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE"
else
  log "Template already present in $TEMPLATE_STORAGE"
fi

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONF}"
if [[ "$IP_CONF" != "dhcp" ]]; then
  NET0+=",gw=${GATEWAY}"
fi

PCT_ARGS=(
  "$CTID" "$TEMPLATE_REF"
  --hostname "$HOSTNAME"
  --cores "$CORES"
  --memory "$MEMORY_MB"
  --swap "$SWAP_MB"
  --rootfs "${STORAGE}:${DISK_GB}"
  --net0 "$NET0"
  --unprivileged "$UNPRIVILEGED"
  --features "$FEATURES"
  --onboot "$ONBOOT"
  --ostype debian
  --timezone host
)

if [[ -n "$DNS" ]]; then
  PCT_ARGS+=(--nameserver "$DNS")
fi
if [[ -n "$PASSWORD" ]]; then
  PCT_ARGS+=(--password "$PASSWORD")
fi
if [[ -n "$SSH_PUBKEY_FILE" ]]; then
  PCT_ARGS+=(--ssh-public-keys "$SSH_PUBKEY_FILE")
fi

log "Creating container $CTID ($HOSTNAME)..."
run pct create "${PCT_ARGS[@]}"

if [[ "$START_AFTER" == "1" ]]; then
  log "Starting container $CTID..."
  run pct start "$CTID"
fi

cat <<EOF

[create-lxc] Done.

Container: $CTID ($HOSTNAME)
Template:  $TEMPLATE_REF
Rootfs:    ${STORAGE}:${DISK_GB}GB
Memory:    ${MEMORY_MB}MB (swap ${SWAP_MB}MB)
Network:   ${NET0}

Next steps:
  1) Push this repo into the container (from Proxmox host):
       pct push $CTID /home/Exchange/ytuner-lxc /root/ytuner-lxc -r
  2) Enter container and install YTuner:
       pct enter $CTID
       cd /root/ytuner-lxc && bash scripts/install-ytuner.sh
  3) Set your AVR DNS to the container IP. See docs/AVR-SETUP.md.

Notes:
  - For production, use a static IP or DHCP reservation.
  - If using Proxmox firewall, allow 80/tcp and 53/udp to this CT.
EOF
