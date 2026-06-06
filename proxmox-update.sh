#!/usr/bin/env bash
# Automation Station — Proxmox CT updater.
#
# Run this ON THE PROXMOX VE HOST (as root). It finds the Automation Station
# container, pulls the latest image, and recreates it. Your data is preserved
# (the `as-data` volume is never touched).
#
# Canonical copy (public):
#   https://github.com/abarbarich/automation-station-deploy
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/abarbarich/automation-station-deploy/main/proxmox-update.sh)"
#
# Options (env vars):
#   CTID=210   bash ...   # target a specific container instead of auto-detecting
#   IMAGE=ghcr.io/abarbarich/homeautomation:0.1.4 bash ...   # switch to a specific tag
set -euo pipefail

APP_DIR="/opt/automationstation"

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { c '1;36' "→ $*"; }
ok()   { c '1;32' "✓ $*"; }
die()  { c '1;31' "✗ $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found — run this on a Proxmox VE host"

c '1;35' "Automation Station — Proxmox CT updater"

# ---- locate the container ---------------------------------------------------
if [ -z "${CTID:-}" ]; then
  info "looking for the Automation Station container"
  for id in $(pct list | awk 'NR>1{print $1}'); do
    if pct exec "$id" -- test -f "$APP_DIR/docker-compose.yml" 2>/dev/null; then
      CTID="$id"; break
    fi
  done
fi
[ -n "${CTID:-}" ] || die "couldn't find the container — set CTID=<id> (see 'pct list')"
pct config "$CTID" >/dev/null 2>&1 || die "CT $CTID doesn't exist"
echo "  container: CT $CTID"

# Make sure it's running.
if ! pct status "$CTID" | grep -q running; then
  info "starting CT $CTID"
  pct start "$CTID"; sleep 3
fi

# ---- optionally pin a specific image tag ------------------------------------
if [ -n "${IMAGE:-}" ]; then
  info "switching image to $IMAGE"
  pct exec "$CTID" -- bash -lc "sed -i 's#image: .*#image: ${IMAGE}#' '$APP_DIR/docker-compose.yml'"
fi

# ---- pull + recreate --------------------------------------------------------
info "pulling the new image and recreating the container (data is preserved)"
pct exec "$CTID" -- bash -lc "
  set -e
  cd '$APP_DIR'
  docker compose pull
  docker compose up -d
  docker image prune -f >/dev/null 2>&1 || true
"

# ---- report -----------------------------------------------------------------
CTIP="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '[:space:]')"
VER="$(pct exec "$CTID" -- bash -lc "curl -fsS http://localhost:8123/api/v1/system/status 2>/dev/null | sed -n 's/.*\"version\":\"\\([^\"]*\\)\".*/\\1/p'" 2>/dev/null || true)"
ok "Updated CT $CTID${VER:+ to v$VER}"
echo "  Open:  http://${CTIP:-<container-ip>}:8123"
echo "  Logs:  pct exec $CTID -- docker logs -f automationstation"
