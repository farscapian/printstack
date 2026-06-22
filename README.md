# Immutable USB/IP Proxy + Print Server

Two-node print server stack with nightly cloud-init reprovisioning. USB printers plug into a Raspberry Pi 4B, which exports them over the network via USB/IP. An Incus LXC container on a separate host picks them up and serves them via CUPS.

```
USB Printers ──► Raspberry Pi 4B          LAN
                 (usbipd, TCP 3240)  ────────────► Incus LXC container
                 [pi-bootstrap.sh]                 (CUPS + nginx/TLS)
                                                   [printserver-bootstrap.sh]
```

Both nodes reprovision nightly from cloud-init: the container is destroyed and recreated; the Pi reboots and re-applies config. Neither node accumulates state.

---

## Architecture

### Node 1 — USB/IP Proxy (Raspberry Pi 4B)

- Runs Ubuntu 26.04 Server (arm64)
- `usbipd` listens on TCP 3240 and exports all attached USB devices
- `usbip-bind-all` automatically binds every connected printer at boot
- Ethernet (`eth0`) is the primary interface (lower route-metric); WiFi (`wlan0`) is secondary and optional
- All packages pre-installed into the SD card image before first boot — first boot requires no internet
- Nightly `reprovision.timer` runs `cloud-init clean --logs --reboot` at 02:00

### Node 2 — Print Server (Incus LXC)

- Ubuntu 26.04 LXC container on an Incus host
- CUPS serves IPP/LPD/Bonjour to the LAN
- Optional nginx + Let's Encrypt TLS proxy on port 443
- USB printers attached via `usbip attach` at provisioning time; auto-discovered and registered with `lpadmin`
- Printer `lpadmin` commands baked back into cloud-init after first discovery — nightly reprovisioning re-registers all printers without re-running discovery
- Based on a pre-built Incus image (`printserver-base`) with all packages installed — container reprovisioning requires no internet

---

## Repository Layout

```
.
├── printstack.sh                    # CLI entrypoint (flash, refresh)
├── shared.env.example               # SSH keys, LAN subnet, Pi hostname (shared by both scripts)
├── pi-bootstrap.env.example         # SD card device, WiFi password
├── pi-bootstrap.sh                  # Flash SD card and write cloud-init for the Pi
├── printserver-bootstrap.env.example
├── printserver-bootstrap.sh         # Provision the CUPS LXC container via Incus
├── printserver-image-build.sh       # Build the pre-baked printserver-base Incus image
└── cloud-init/                      # Generated output (gitignored); inspect after a run
```

---

## Prerequisites

### Management machine

| Tool | Purpose |
|---|---|
| `bash`, `coreutils` | Scripts |
| `pv`, `xz-utils`, `curl` | SD card flashing |
| `systemd-container` (`systemd-nspawn`) | Chroot into arm64 image for pre-install |
| `incus` CLI | Container management |
| `gh` (optional) | GitHub operations |

Missing flash dependencies are installed automatically by `pi-bootstrap.sh`.

### Incus host

- Incus installed and listening on HTTPS (`incus remote add ...`)
- SSH access from the management machine (same name as the Incus remote)
- A storage pool available (default: `incus-pool`)
- `eno1` (or configured `PARENT_IFACE`) for MACVLAN

---

## Setup

### 1. Configure secrets

```bash
cp shared.env.example shared.env
cp pi-bootstrap.env.example pi-bootstrap.env
cp printserver-bootstrap.env.example printserver-bootstrap.env

chmod 600 shared.env pi-bootstrap.env printserver-bootstrap.env
$EDITOR shared.env                  # SSH keys, LAN subnet, Pi hostname
$EDITOR pi-bootstrap.env            # DEVICE=/dev/sdX, WIFI_PASSWORD=
$EDITOR printserver-bootstrap.env   # INCUS_REMOTE=, MAC_ADDRESS=
```

### 2. Flash the SD card (Raspberry Pi)

Insert the SD card, identify the device (`lsblk`), then:

```bash
printstack flash --force
# or: sudo ./pi-bootstrap.sh --flash --force
```

This will:
- Download Ubuntu 26.04 arm64 raspi image if not already present (SHA256 verified)
- Flash the image to the SD card
- Pre-install packages via `systemd-nspawn` (no internet needed on first boot):
  `usbutils`, `ufw`, `wireless-regdb`, `zstd`, `iw`, `linux-tools-common`,
  and `usbip`/`usbipd` extracted from `linux-raspi-tools`
- Patch the brcmfmac NVRAM with `ccode=US` (enables 5GHz channels)
- Write cloud-init `user-data`, `user-data.nightly`, and `meta-data` to the boot partition

Insert the SD card into the Pi and power on. Cloud-init runs automatically on first boot.

**Re-flashing** an already-configured card: `--flash` forces a full OS flash. Without it, the script only updates cloud-init files if the partition is already Ubuntu.

#### Virtual printers (dev/test)

Set `ENABLE_VIRTUAL_PRINTERS=3` in `pi-bootstrap.env` to create 3 virtual USB printers via `dummy_hcd` + USB gadget configfs. Useful for testing without physical hardware.

### 3. Build the printserver base image

Run once before first deployment. Creates a pre-baked Incus image named `printserver-base` with CUPS, usbip tools, nginx, certbot, and printer drivers installed:

```bash
./printserver-image-build.sh
# Rebuild: ./printserver-image-build.sh --force
```

### 4. Provision the print server

First deployment:

```bash
./printserver-image-build.sh
./printserver-bootstrap.sh
```

Immutable refresh (rebuild image + destroy/recreate container):

```bash
printstack refresh
```

This will:
- Create a MACVLAN network and Incus profile if not present
- Launch the `printserver` container from `local:printserver-base`
- Wait for cloud-init to finish
- Wait for `usbip attach` to succeed (Pi must be up and reachable)
- Discover all attached USB printers and register them in CUPS via `lpadmin`
- Bake the `lpadmin` commands back into the nightly cloud-init config
- Push the nightly cloud-init to the Incus host and install a systemd timer for 02:00 reprovisioning

**Re-provisioning** from scratch: `--reprovision` destroys the existing container first.

---

## Nightly Reprovisioning

| Node | Mechanism | Time |
|---|---|---|
| Pi | `reprovision.timer` → `cloud-init clean --logs --reboot` | 02:00 |
| Printserver | systemd timer on Incus host → destroy + recreate container | 02:00 |

The nightly configs are internet-free — all packages are pre-installed in the base images. Reprovisioning will succeed during a connectivity outage.

---

## Firewall

Both nodes use `ufw`. Allowed inbound:

| Node | Port | Protocol | Source |
|---|---|---|---|
| Pi | 3240 | TCP | LAN (`PRINT_CIDRS`) |
| Pi | 22 | TCP | `SSH_CIDRS` (or any if unset) |
| Printserver | 631 | TCP | LAN (`PRINT_CIDRS`) |
| Printserver | 22 | TCP | `SSH_CIDRS` (or any if unset) |
| Printserver | 443 | TCP | any (if TLS enabled) |

---

## TLS (optional)

Set in `printserver-bootstrap.env`:

```bash
ENABLE_LETSENCRYPT=true
LE_EMAIL=admin@example.com
CONTAINER_FQDN=printserver.example.com
NAMECHEAP_API_USER=myusername
NAMECHEAP_API_KEY=abc123...
NAMECHEAP_CLIENT_IP=203.0.113.10   # IP of the management machine, whitelisted in Namecheap API
```

Certificates are issued via **DNS-01 challenge** using the Namecheap XML API — no inbound ports 80 or 443 need to be open. nginx terminates TLS on port 443 and proxies to CUPS on `localhost:631`. Certificates are stored in a persistent Incus storage volume (`printserver-letsencrypt`) and survive nightly container reprovisioning.

`CONTAINER_FQDN` must resolve to the container's IP and its domain must be managed by Namecheap. Enable API access at namecheap.com → Profile → Tools → API Access and whitelist `NAMECHEAP_CLIENT_IP`.

---

## Troubleshooting

**Pi won't connect to WiFi**
- Confirm `WIFI_PASSWORD` in `pi-bootstrap.env` and re-flash.
- 5GHz band: verify the brcmfmac NVRAM patch ran (`brcmfmac NVRAM patched with ccode=US` in bootstrap output).

**cloud-init didn't run (Pi)**
- Check `ds=nocloud` is in the kernel cmdline: `cat /boot/firmware/current/cmdline.txt`
- Check instance-id changed: `cat /boot/firmware/meta-data`

**usbip attach fails**
- Pi must be up and `usbipd` listening: `nc -zv usbproxy.ancapistan.io 3240`
- USB printers must be connected to the Pi before boot.

**CUPS shows printers offline**
- Re-run `printserver-bootstrap.sh` (non-destructive unless `--reprovision`) to re-run discovery and re-register printers.
