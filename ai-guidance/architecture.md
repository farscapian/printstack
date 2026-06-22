# Architecture

Two-node immutable print server stack. USB printers plug into a Raspberry Pi 4B; the Pi exports them over USB/IP. An Incus LXC container on a separate host attaches the printers and serves them via CUPS.

```
USB Printers --> Raspberry Pi 4B          LAN
                 (usbipd, TCP 3240)  ------------> Incus LXC container
                 [pi-bootstrap.sh]                 (CUPS + optional nginx/TLS)
                                                   [printserver-bootstrap.sh]
```

**Development process:** see [workflow.md](workflow.md) for Grok/Claude clones, commit/sync policy, and git handoff.

## Core design principles

### Immutable / stateless nodes

Both nodes reprovision nightly from cloud-init. Neither accumulates drift:

| Node | Mechanism | Time |
|------|-----------|------|
| Pi | `reprovision.timer` -> `cloud-init clean --logs --reboot` | 02:00 |
| Printserver | systemd timer on Incus host -> destroy + recreate container | 02:00 |

Nightly configs are **internet-free** -- all packages are pre-installed in base images (Pi SD card chroot, Incus `printserver-base` image). Reprovisioning succeeds during a connectivity outage.

### Node 1 -- USB/IP Proxy (Raspberry Pi 4B)

- Ubuntu 26.04 Server arm64 on SD card
- `usbipd` listens on TCP 3240 and exports all attached USB devices
- `usbip-bind-all` binds every connected printer at boot
- Ethernet (`eth0`) is primary (lower route-metric); WiFi (`wlan0`) is secondary and optional
- Packages pre-installed into the SD card image via `systemd-nspawn` chroot before first boot
- First boot uses `user-data` (internet may be needed for WiFi setup); nightly uses `user-data.nightly` (no internet)

### Node 2 -- Print Server (Incus LXC)

- Ubuntu 26.04 LXC container on an Incus host
- MACVLAN network (`macvlan-eno1`) gives the container a LAN IP
- CUPS serves IPP/LPD/Bonjour to the LAN (port 631)
- Optional nginx + Let's Encrypt TLS proxy on port 443
- USB printers attached via `usbip attach` at provisioning; auto-discovered and registered with `lpadmin`
- `lpadmin` commands baked back into cloud-init after first discovery -- nightly reprovisioning re-registers printers without re-running discovery
- Based on pre-built Incus image (`printserver-base`) from `printserver-image-build.sh`

## Network and firewall

Both nodes use `ufw`. CIDRs come from `shared.env`:

| Node | Port | Protocol | Source |
|------|------|----------|--------|
| Pi | 3240 | TCP | `PRINT_CIDRS` |
| Pi | 22 | TCP | `SSH_CIDRS` (or any if unset) |
| Printserver | 631 | TCP | `PRINT_CIDRS` |
| Printserver | 22 | TCP | `SSH_CIDRS` (or any if unset) |
| Printserver | 443 | TCP | any (if TLS enabled) |

## Repository layout

```
.
├── CLAUDE.md                        # AI index (load ai-guidance/ topics)
├── ai-guidance/                     # Topic-specific agent guidance
├── printstack.sh                    # CLI entrypoint (flash, refresh)
├── scripts/                         # config.sh, create-log.sh, session init
├── shared.env.example               # SSH keys, LAN subnet, Pi hostname
├── pi-bootstrap.env.example         # SD card device, WiFi password
├── pi-bootstrap.sh                  # Flash SD card and write cloud-init for the Pi
├── printserver-bootstrap.env.example
├── printserver-bootstrap.sh         # Provision the CUPS LXC container via Incus
├── printserver-image-build.sh       # Build the pre-baked printserver-base Incus image
├── scripts/                         # Session init scripts
└── cloud-init/                      # Generated output (gitignored); inspect after a run
```

## Management machine

Bootstrap scripts run from a management machine (e.g. pangolin) with:

| Tool | Purpose |
|------|---------|
| `bash`, `coreutils` | Scripts |
| `pv`, `xz-utils`, `curl` | SD card flashing (`pi-bootstrap.sh`) |
| `systemd-container` (`systemd-nspawn`) | Chroot into arm64 Pi image for pre-install |
| `incus` CLI | Container management (`printserver-bootstrap.sh`) |

Missing flash dependencies are installed automatically by `pi-bootstrap.sh`.

## Data flow: printer discovery to nightly reprovision

1. Human runs `printserver-bootstrap.sh` -- container launches with cloud-init
2. `usbip-attach-all` connects to `USBPROXY_HOST:3240` and attaches exported devices
3. Discovery script finds USB printers and runs `lpadmin` to register them in CUPS
4. Bootstrap script extracts the `lpadmin` commands and **bakes them** into the cloud-init user-data
5. Updated cloud-init is pushed to the Incus host at `/var/local/printserver-bootstrap/cloud-init/`
6. Nightly timer destroys and recreates the container using the baked config -- printers come back without manual steps