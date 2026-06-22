# Configuration

All secrets and environment-specific values live in `.env` files sourced by bootstrap scripts. **Never commit real `.env` files** -- only `*.env.example` templates are tracked.

## Setup

```bash
cp shared.env.example shared.env
cp pi-bootstrap.env.example pi-bootstrap.env
cp printserver-bootstrap.env.example printserver-bootstrap.env

chmod 600 shared.env pi-bootstrap.env printserver-bootstrap.env
$EDITOR shared.env
$EDITOR pi-bootstrap.env
$EDITOR printserver-bootstrap.env
```

## shared.env (both nodes)

Loaded by `pi-bootstrap.sh` and `printserver-bootstrap.sh` before their node-specific env file.

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `SSH_PUBKEYS` | yes | -- | One or more SSH public keys (multiline string); added to all nodes |
| `LAN_SUBNET` | no | `192.168.4.0/22` | Legacy/fallback CIDR for services |
| `SSH_CIDRS` | no | (empty = allow any) | Space-separated CIDRs for SSH (port 22) in UFW |
| `PRINT_CIDRS` | no | `$LAN_SUBNET` | Space-separated CIDRs for CUPS (631) and USB/IP (3240) |
| `USBPROXY_HOST` | no | `usbproxy.ancapistan.io` | Pi FQDN; used by printserver for `usbip attach` |

**Permissions:** script warns if not `600` or `400`.

## pi-bootstrap.env (Pi node)

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `DEVICE` | yes | -- | SD card block device (e.g. `/dev/sdb`) |
| `WIFI_PASSWORD` | yes | -- | HomeNet WPA3/WPA2 passphrase |
| `PI_HOSTNAME` | no | `$USBPROXY_HOST` | Pi FQDN |
| `ENABLE_VIRTUAL_PRINTERS` | no | `0` | Number of virtual USB printers for dev/test |
| `WLAN_MAC` | no | -- | Override wlan0 MAC in netplan |

**Script flags** (not in .env): `--flash`, `--force`, `--env <file>`, `--help`

- `--flash` -- force full OS flash even if Ubuntu already on card
- `--force` -- skip confirmation prompt; implies `--flash`
- Without `--flash`: auto-detects whether card needs flashing (checks for `system-boot` label)

## printserver-bootstrap.env (Incus container)

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `INCUS_REMOTE` | yes | -- | Incus remote name (must match SSH config entry) |
| `MAC_ADDRESS` | yes | -- | Container eth0 MAC (for DHCP reservation) |
| `INCUS_IMAGE` | no | `local:printserver-base` | Base image (build with `printserver-image-build.sh`) |
| `CONTAINER_HOSTNAME` | no | `printserver` | Short hostname |
| `CONTAINER_FQDN` | no | `printserver.ancapistan.io` | FQDN for CUPS/TLS |
| `INCUS_STORAGE_POOL` | no | `incus-pool` | Storage pool name |
| `PARENT_IFACE` | no | `eno1` | Parent NIC for MACVLAN |

### TLS / Let's Encrypt (optional)

| Variable | Required when TLS | Purpose |
|----------|-------------------|---------|
| `ENABLE_LETSENCRYPT` | -- | `true` to enable nginx + certbot |
| `LE_EMAIL` | yes | Certbot registration email |
| `NAMECHEAP_API_USER` | yes | Namecheap account username |
| `NAMECHEAP_API_KEY` | yes | Namecheap API key |
| `NAMECHEAP_CLIENT_IP` | yes | Management machine IP whitelisted in Namecheap API |

Certificates use **DNS-01** via Namecheap XML API -- no inbound ports 80/443 required. Stored in persistent Incus volume `printserver-letsencrypt`.

**Script flags:** `--reprovision`, `--env <file>`, `--help`

- `--reprovision` -- destroy existing container and reprovision from scratch

## Image files (Pi)

`pi-bootstrap.sh` looks for `ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz` in the repo root. If present and checksum passes, uses it directly. Otherwise downloads from Ubuntu CD image releases. Decompressed `.img` is cached alongside the `.xz`.

SHA256 is hardcoded in `pi-bootstrap.sh` -- update when changing Ubuntu image version.

## Incus remote setup

```bash
incus remote add <name> https://<host>:8443 --accept-certificate
```

The remote name must match `INCUS_REMOTE` in `printserver-bootstrap.env` and your SSH config for host-level operations (nightly timer install).