# Cloud-init

Both nodes are configured entirely via cloud-init. Bootstrap scripts **generate** user-data at runtime from `.env` values and write copies to `cloud-init/` (gitignored) for inspection.

## Pi (SD card / nocloud)

### Boot partition files

Written to the FAT32 system-boot partition:

| File | Purpose |
|------|---------|
| `meta-data` | Instance ID (must change to trigger re-run) |
| `vendor-data` | Vendor metadata |
| `user-data` | Active config (firstboot or nightly) |
| `user-data.nightly` | Internet-free nightly reprovision config |

Kernel cmdline is patched with `ds=nocloud` and `cfg80211.ieee80211_regdom=US`.

### Firstboot vs nightly

| Config | When used | Internet |
|--------|-----------|----------|
| `user-data` (firstboot) | First boot only | May need WiFi setup |
| `user-data.nightly` | Nightly `reprovision.timer` at 02:00 | Not required |

Firstboot `user-data` configures WiFi, sets regulatory domain, and swaps itself to point at `user-data.nightly` for subsequent boots.

Nightly config runs `cloud-init clean --logs --reboot` via systemd timer. All packages are pre-baked in the SD image chroot -- no `apt` during nightly reprovision.

### Local copies

Rendered files land in `cloud-init/pi-bootstrap/`:
- `user-data.yaml`
- `user-data.nightly.yaml`
- `meta-data`
- `vendor-data`

### Troubleshooting Pi cloud-init

- `ds=nocloud` must be in cmdline: `cat /boot/firmware/current/cmdline.txt`
- Instance ID must change between reprovisions: `cat /boot/firmware/meta-data`
- If cloud-init did not run, check instance-id and kernel cmdline first

## Printserver (Incus LXC)

### Generation

`printserver-bootstrap.sh` builds a `#cloud-config` document via bash heredoc with interpolated values:

- Network: DHCP on eth0 (MACVLAN)
- Users: `ubuntu` with `SSH_PUBKEYS`
- `write_files`: usbip modules, systemd units, CUPS config, optional nginx/certbot
- `runcmd`: module load, usbip attach, CUPS enable, printer registration, optional TLS setup

Local copies:
- `cloud-init/printserver-bootstrap/cloud-init.yaml`
- `cloud-init/printserver-bootstrap/meta-data.yaml`

### Instance ID

Each provision uses a fresh instance ID: `printserver-YYYYMMDDHHMMSS`. Incus passes user-data at launch; changing instance ID on nightly reprovision forces cloud-init to re-run.

### lpadmin baking (critical)

On first successful provision:

1. Discovery script finds attached USB printers
2. Runs `lpadmin` to register each printer in CUPS
3. Bootstrap script extracts the `lpadmin` command lines
4. Injects them into the cloud-init `runcmd` section
5. Writes updated YAML to local `cloud-init/` and pushes to Incus host

Nightly reprovisioning then re-registers all known printers without re-running discovery. **If you add/remove physical printers, re-run `printserver-bootstrap.sh`** (non-destructive) to refresh the baked commands.

### Nightly timer (Incus host)

Cloud-init files are pushed to:
```
/var/local/printserver-bootstrap/cloud-init/
```

A systemd timer on the Incus host destroys and recreates the container at 02:00 using the pushed config. The timer is stopped during `--reprovision` to avoid races.

### Let's Encrypt volume

When TLS is enabled, certificates live in persistent Incus storage volume `printserver-letsencrypt`, mounted at `/etc/letsencrypt` in the container. Survives nightly container destroy/recreate.

## YAML indent variables

Several bash variables embed indentation for heredoc insertion:

| Variable | Indent | Used in |
|----------|--------|---------|
| `SSH_PUBKEYS_YAML` | 6 spaces | `ssh_authorized_keys` list |
| `CUPS_ALLOW_LOCATION` | 8 spaces | `<Location>` blocks |
| `CUPS_ALLOW_LIMIT` | 10 spaces | `<Limit>` inside `<Policy>` |
| `UFW_PRINT_RULES` | 2 spaces | `runcmd` ufw rules |

These are built in loops before the heredoc. When adding new interpolated YAML blocks, match the indent level of the surrounding cloud-config structure.