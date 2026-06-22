# Features

## USB/IP proxy (Pi)

- `usbipd` exports all attached USB devices on TCP 3240
- `usbip-bind-all` systemd unit binds printers at boot
- Clients discover devices via `usbip list -r <host>`
- Firewall restricts port 3240 to `PRINT_CIDRS`

## USB/IP client (printserver container)

- Kernel modules: `usbip-core`, `vhci-hcd` (loaded via systemd oneshot)
- `usbip-attach-all` discovers bus IDs at runtime from `USBPROXY_HOST` -- no hardcoded bus IDs
- Attach runs after network is up; failures log to systemd journal (`usbip-attach` tag)

## CUPS printing

- Listens on `0.0.0.0:631` (or localhost-only when TLS/nginx enabled)
- Bonjour/mDNS browsing enabled (`BrowseLocalProtocols dnssd`)
- Access restricted to `PRINT_CIDRS` in cupsd.conf
- Printers auto-registered via `lpadmin` on first provision; commands baked for nightly

## Virtual printers (dev/test)

Set `ENABLE_VIRTUAL_PRINTERS=N` in `pi-bootstrap.env` to create N virtual USB printers on the Pi without physical hardware. Uses `dummy_hcd` + USB gadget configfs.

Useful for testing `usbip attach` and CUPS discovery without real printers plugged in.

## MACVLAN networking

Printserver container gets a direct LAN IP via MACVLAN on `PARENT_IFACE` (default `eno1`):

- Network: `macvlan-eno1`
- Profile: `printserver`
- Static MAC from `MAC_ADDRESS` in env (set DHCP reservation on router)

Container hostname/FQDN from `CONTAINER_HOSTNAME` / `CONTAINER_FQDN`.

## TLS / Let's Encrypt (optional)

When `ENABLE_LETSENCRYPT=true`:

- nginx terminates TLS on port 443, proxies to CUPS on `localhost:631`
- CUPS binds localhost only (not exposed on 631 to LAN directly)
- certbot uses **DNS-01** challenge via Namecheap XML API
- No inbound ports 80/443 required on the container
- Certificates persist in Incus volume `printserver-letsencrypt`

Requirements:
- `CONTAINER_FQDN` resolves to container IP
- Domain managed by Namecheap with API access enabled
- `NAMECHEAP_CLIENT_IP` whitelisted in Namecheap API settings

## Nightly reprovisioning

| Node | Trigger | Effect |
|------|---------|--------|
| Pi | `reprovision.timer` (02:00) | `cloud-init clean --logs --reboot` |
| Printserver | Host systemd timer (02:00) | Destroy + recreate LXC from pushed cloud-init |

Both paths are internet-free after initial image bake. State does not accumulate across days.

## Pre-baked images (no internet at reprovision)

| Image | Built by | Contains |
|-------|----------|----------|
| Pi SD card | `pi-bootstrap.sh` chroot | usbip, ufw, wireless tools, brcmfmac patch |
| `printserver-base` | `printserver-image-build.sh` | CUPS, usbip client, nginx, certbot, printer drivers |