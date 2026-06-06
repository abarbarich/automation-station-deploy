# Automation Station — deploy

Public deploy scripts for [Automation Station](https://github.com/abarbarich/HomeAutomation)
(the application repo is private; this repo holds only the installer so the one-liner
below works without exposing the source).

## Proxmox VE (LXC container)

Run **on the Proxmox VE host, as root**. Creates an unprivileged Debian 12 CT, installs
Docker, and runs the prebuilt image. Prints the URL when done.

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/abarbarich/automation-station-deploy/main/proxmox-ct.sh)"
```

Override any default with an env var:

```sh
CTID=210 CORES=4 RAM=4096 DISK=12 BRIDGE=vmbr0 STORAGE=local-lvm \
IMAGE=ghcr.io/abarbarich/homeautomation:latest \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/abarbarich/automation-station-deploy/main/proxmox-ct.sh)"
```

The container image is pulled from `ghcr.io/abarbarich/homeautomation` — that package must
be **public** for the anonymous pull to succeed.

### Update later

```sh
pct exec <CTID> -- bash -lc 'cd /opt/automationstation && docker compose pull && docker compose up -d'
```
