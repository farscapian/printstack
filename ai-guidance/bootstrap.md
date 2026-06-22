# Bootstrap Scripts

Three scripts provision the stack from a management machine. All load `shared.env` first, then their node-specific `.env` file.

**Preferred entry point:** `printstack flash` and `printstack refresh` (see [cli.md](cli.md)). The scripts below can still be run directly.

## pi-bootstrap.sh

Flashes Ubuntu 26.04 arm64 to an SD card and writes cloud-init for the USB/IP proxy Pi.

**Requires root:** `sudo ./pi-bootstrap.sh`

### Typical usage

```bash
# First flash (or re-flash with confirmation)
sudo ./pi-bootstrap.sh --flash

# Automated re-flash (no prompt)
sudo ./pi-bootstrap.sh --flash --force

# Update cloud-init only (card already has Ubuntu)
sudo ./pi-bootstrap.sh
```

### Phases (summary)

1. Safety checks (block device, not root disk, size limits)
2. Download/verify/decompress Ubuntu image (SHA256 checked)
3. `dd` flash with `pv` progress
4. Mount ext4 root partition; `systemd-nspawn` chroot to pre-install packages
5. Extract `usbip`/`usbipd` from `linux-raspi-tools` via `dpkg-deb -x` (avoids flash-kernel hooks)
6. Patch brcmfmac NVRAM with `ccode=US` (enables 5GHz WiFi)
7. Mount FAT32 boot partition; write `meta-data`, `vendor-data`, patch cmdline
8. Write `user-data` (firstboot) and `user-data.nightly` (internet-free reprovision)
9. Copy rendered files to `cloud-init/pi-bootstrap/` for local inspection
10. Unmount, sync, eject

### Virtual printers (dev/test)

Set `ENABLE_VIRTUAL_PRINTERS=3` in `pi-bootstrap.env` to create virtual USB printers via `dummy_hcd` + USB gadget configfs.

## printserver-image-build.sh

Builds the `printserver-base` Incus image with CUPS, usbip tools, nginx, certbot, and printer drivers pre-installed.

```bash
./printserver-image-build.sh          # skip if image exists
./printserver-image-build.sh --force  # rebuild
```

Run once before first deployment. The builder container runs `apt-get` on first boot -- wait for cloud-init before installing packages.

## printserver-bootstrap.sh

Provisions the CUPS LXC container via Incus API.

```bash
./printserver-bootstrap.sh                    # safe abort if container exists
./printserver-bootstrap.sh --reprovision      # destroy and recreate
```

### Phases (summary)

1. Validate Incus remote; switch to it
2. Stop nightly timer; delete container if `--reprovision`
3. Create MACVLAN network (`macvlan-eno1`) if missing
4. Ensure Let's Encrypt persistent volume (if TLS enabled)
5. Create/update Incus profile (`printserver`)
6. Generate cloud-init user-data from `.env` values (heredoc)
7. Ensure usbip kernel modules on Incus host
8. Launch container with cloud-init config
9. Wait for cloud-init (up to 1800s; package install can take 15-20 min)
10. Wait for usbip attach and printer discovery
11. Bake `lpadmin` commands into cloud-init for nightly reprovision
12. Push cloud-init to Incus host (`/var/local/printserver-bootstrap/cloud-init/`)
13. Install nightly reprovision systemd timer on Incus host (02:00)

### Idempotency

Without `--reprovision`, the script aborts safely if the `printserver` container already exists. Re-running discovery/registration without destroying is the non-destructive path for fixing offline printers.

### Debug mode

`printserver-bootstrap.sh` currently has `set -x` in several places (marked "remove when stable"). Do not remove unless asked -- it aids provisioning diagnostics.

## Recommended deployment order

1. Configure all `.env` files
2. `sudo ./pi-bootstrap.sh --flash` -- insert SD into Pi, power on
3. `./printserver-image-build.sh` -- once per Incus host
4. `./printserver-bootstrap.sh` -- Pi must be up and usbipd listening