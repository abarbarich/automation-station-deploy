#!/usr/bin/env bash
# Automation Station — Proxmox LXC (CT) installer.
#
# Run this ON THE PROXMOX VE HOST (as root). It creates a Debian 12 unprivileged
# container, installs Docker, and deploys the prebuilt Automation Station image. When it
# finishes it prints the URL — open it, create your admin account, done.
#
# Canonical copy (public, so the one-liner works while the app repo stays private):
#   https://github.com/abarbarich/automation-station-deploy
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/abarbarich/automation-station-deploy/main/proxmox-ct.sh)"
#
# Override any default with an env var, e.g.:
#   CTID=210 CORES=4 RAM=4096 DISK=12 BRIDGE=vmbr0 STORAGE=local-lvm bash proxmox-ct.sh
set -euo pipefail

# ---- config (env-overridable) -----------------------------------------------
# NB: not HOSTNAME — that's a bash built-in already set to the *host's* name, so a
# ${HOSTNAME:-default} would inherit "proxmox" and never use our default.
CT_HOSTNAME="${CT_HOSTNAME:-automationstation}"
CORES="${CORES:-2}"
RAM="${RAM:-2048}"           # MB
DISK="${DISK:-10}"           # GB
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"             # "dhcp" or "192.168.1.50/24,gw=192.168.1.1"
STORAGE="${STORAGE:-local-lvm}"      # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # where CT templates live
IMAGE="${IMAGE:-ghcr.io/abarbarich/automationstation:latest}"
# Opt-in scheduled auto-update: a systemd timer in the CT that runs
# `docker compose pull && up -d` on a schedule (no extra container, no Watchtower).
AUTO_UPDATE="${AUTO_UPDATE:-no}"                       # "yes" to enable
AUTO_UPDATE_SCHEDULE="${AUTO_UPDATE_SCHEDULE:-daily}"  # systemd OnCalendar (e.g. daily, weekly, *-*-* 04:00)

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c '1;36' "→ $*"; }
ok()   { c '1;32' "✓ $*"; }
die()  { c '1;31' "✗ $*"; exit 1; }

# ---- preflight --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null   || die "pct not found — run this on a Proxmox VE host"
command -v pveam >/dev/null || die "pveam not found — run this on a Proxmox VE host"

CTID="${CTID:-$(pvesh get /cluster/nextid)}"
pct status "$CTID" >/dev/null 2>&1 && die "CT $CTID already exists — set CTID=<free id>"

c '1;35' "Automation Station — Proxmox CT installer"
echo "  CTID=$CTID  host=$CT_HOSTNAME  cores=$CORES  ram=${RAM}MB  disk=${DISK}GB"
echo "  net: bridge=$BRIDGE ip=$IP   rootfs: $STORAGE   image: $IMAGE"
case "$AUTO_UPDATE" in [yY]*|1|true) echo "  auto-update: ON ($AUTO_UPDATE_SCHEDULE)";; *) echo "  auto-update: off (set AUTO_UPDATE=yes to enable)";; esac

# ---- template ---------------------------------------------------------------
info "ensuring a Debian 12 template is available"
pveam update >/dev/null 2>&1 || true
TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/{print $2}' | sort -V | tail -1)"
[ -n "$TEMPLATE" ] || die "no debian-12-standard template found in 'pveam available'"
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  info "downloading $TEMPLATE to $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi
TEMPLATE_REF="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"

# ---- create the container ---------------------------------------------------
info "creating CT $CTID"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$CT_HOSTNAME" \
  --cores "$CORES" --memory "$RAM" --swap 512 \
  --rootfs "$STORAGE:$DISK" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IP" \
  --features "nesting=1,keyctl=1" \
  --unprivileged 1 --onboot 1 \
  --description "Automation Station — home automation platform"

info "starting CT $CTID"
pct start "$CTID"
sleep 5

# wait for network
info "waiting for network in the container"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts ghcr.io >/dev/null 2>&1 && break
  sleep 2
done

# ---- install Docker + Automation Station inside the CT ----------------------
info "installing Docker inside the container"
pct exec "$CTID" -- bash -lc '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl >/dev/null
  curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker >/dev/null 2>&1 || true
'

info "deploying Automation Station ($IMAGE)"
pct exec "$CTID" -- bash -lc "
  set -e
  mkdir -p /opt/automationstation
  cat > /opt/automationstation/docker-compose.yml <<YML
services:
  automationstation:
    image: $IMAGE
    container_name: automationstation
    restart: unless-stopped
    network_mode: host   # Matter/HomeKit + mDNS need the LAN's multicast
    cgroup: host         # so the Monitor reports the CT's RAM limit, not the host's
    volumes:
      - as-data:/data
    environment:
      - AS_LISTEN=:8123
volumes:
  as-data:
YML
  cd /opt/automationstation && docker compose up -d
"

# ---- optional: scheduled auto-update ----------------------------------------
# A plain systemd timer that pulls the new image and recreates the container on a
# schedule — no Watchtower/extra container, no extra privilege (Docker is already
# local to the CT). Data lives in the as-data volume, so it survives the recreate.
case "$AUTO_UPDATE" in
  [yY]*|1|true)
    info "enabling scheduled auto-update ($AUTO_UPDATE_SCHEDULE)"
    pct exec "$CTID" -- bash -lc "
      set -e
      cat > /etc/systemd/system/automationstation-update.service <<'UNIT'
[Unit]
Description=Automation Station auto-update (pull + recreate)
Wants=network-online.target
After=network-online.target docker.service
[Service]
Type=oneshot
WorkingDirectory=/opt/automationstation
ExecStart=/usr/bin/docker compose pull
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStartPost=-/usr/bin/docker image prune -f
UNIT
      cat > /etc/systemd/system/automationstation-update.timer <<UNIT
[Unit]
Description=Automation Station auto-update schedule
[Timer]
OnCalendar=$AUTO_UPDATE_SCHEDULE
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
UNIT
      systemctl daemon-reload
      systemctl enable --now automationstation-update.timer >/dev/null 2>&1
    "
    ;;
esac

# ---- done -------------------------------------------------------------------
CTIP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
ok "Automation Station is running in CT $CTID"
echo
c '1;32' "  Open:  http://${CTIP:-<container-ip>}:8123      (or http://$CT_HOSTNAME.local:8123)"
echo "  Then create your admin account and add your devices."
echo
echo "  Manage:   pct enter $CTID     # shell into the container"
echo "  Update:   pct exec $CTID -- bash -lc 'cd /opt/automationstation && docker compose pull && docker compose up -d'"
echo "  Logs:     pct exec $CTID -- docker logs -f automationstation"
case "$AUTO_UPDATE" in
  [yY]*|1|true) echo "  Auto-update: ON — runs '$AUTO_UPDATE_SCHEDULE' (disable: pct exec $CTID -- systemctl disable --now automationstation-update.timer)";;
  *)            echo "  Auto-update: off — re-run with AUTO_UPDATE=yes (+ optional AUTO_UPDATE_SCHEDULE=...) to enable a scheduled pull";;
esac
