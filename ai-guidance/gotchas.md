# Architecture Decisions and Gotchas

### usbip extracted, not installed (Pi chroot)

`usbip` and `usbipd` are extracted from `linux-raspi-tools` via `dpkg-deb -x`, not installed with `apt`. Installing the full package triggers `flash-kernel`/`dracut` postinst hooks that break the chroot pre-bake workflow.

### brcmfmac NVRAM patch (5GHz WiFi)

The Pi's brcmfmac driver NVRAM is patched with `ccode=US` inside the chroot. Without this, 5GHz channels may be unavailable. Look for `brcmfmac NVRAM patched with ccode=US` in bootstrap output.

### Pi firstboot swaps user-data

First-boot cloud-init writes `user-data` that configures WiFi, then arranges for subsequent boots to use `user-data.nightly`. Nightly config must be fully internet-free -- no `apt` or `package_upgrade`.

### cloud-init instance-id must change

Cloud-init only re-runs when the instance ID changes. Nightly reprovision on the Pi updates `meta-data`; printserver uses timestamped instance IDs (`printserver-YYYYMMDDHHMMSS`).

### usbip attach timing

Printserver provisioning waits for:
1. Container cloud-init complete (can take 15-20 min on first run with package install)
2. Pi reachable and `usbipd` listening on port 3240
3. USB printers physically connected to Pi **before** attach

If attach runs before the Pi exports devices, the script retries but may complete with zero printers.

### lpadmin baking is one-way until re-run

Nightly reprovision uses the **baked** `lpadmin` commands from the last successful `printserver-bootstrap.sh` run. Adding or removing physical printers requires re-running bootstrap (non-destructive) to refresh the baked config.

### MACVLAN parent interface

`PARENT_IFACE` must be the Incus host's physical LAN interface (default `eno1`). Wrong interface = container gets no LAN connectivity.

### Let's Encrypt volume before first cert

When TLS is enabled, `/etc/letsencrypt` is a persistent ZFS/Incus volume. First run creates the volume; `bootcmd` ensures renewal-hooks directory exists before certbot runs.

### avahi stopped during cloud-init write_files

Printserver cloud-init stops `avahi-daemon` in `bootcmd` before `write_files`, then restarts it in `runcmd` with custom config. Prevents brief window with wrong IPv6 settings.

### printserver-bootstrap debug tracing

`set -x` is intentionally enabled in places (marked "remove when stable"). Expect verbose shell tracing during provision -- not a bug.

### CUPS offline after nightly reprovision

If printers show offline after nightly reprovision, the baked `lpadmin` commands may be stale or usbip attach failed silently. Re-run `printserver-bootstrap.sh` and check `journalctl -t usbip-attach` in the container.

### Pi auto-flash detection

Without `--flash`, `pi-bootstrap.sh` skips OS flash if boot partition label is `system-boot`. Use `--flash` to force full reflash. Use `--force` to skip the destructive confirmation prompt.

### SD card safety checks

Script refuses devices > 512 GB and refuses the system root disk. Always verify `DEVICE` with `lsblk` before flashing.