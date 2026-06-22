# Common Pitfalls

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Pi won't connect to WiFi | Wrong `WIFI_PASSWORD` or missing 5GHz regulatory domain | Fix `pi-bootstrap.env`; re-flash; verify brcmfmac NVRAM patch ran |
| cloud-init didn't run (Pi) | Missing `ds=nocloud` or unchanged instance-id | Check `cmdline.txt` and `meta-data` on boot partition |
| usbip attach fails | Pi down, usbipd not listening, or no printers connected | `nc -zv $USBPROXY_HOST 3240`; connect printers before Pi boot |
| CUPS shows printers offline | Stale baked lpadmin or failed usbip attach | Re-run `printserver-bootstrap.sh`; check container journal |
| cloud-init timeout (printserver) | First boot package install on upstream image | Wait up to 30 min; or use pre-built `printserver-base` image |
| Container has no LAN IP | Wrong `PARENT_IFACE` or MACVLAN misconfigured | Verify `eno1` (or configured parent) on Incus host |
| TLS cert issuance fails | Namecheap API IP not whitelisted or wrong FQDN | Check `NAMECHEAP_CLIENT_IP`; verify DNS resolves |
| Nightly reprovision loses printers | Baked cloud-init not pushed to Incus host | Check `/var/local/printserver-bootstrap/cloud-init/` on host |
| Script appears to hang on prompt | stdout redirected or stdin not a TTY | Use `>&2` for prompts, `</dev/tty` for input (`implementation.md`) |
| Stale behavior after agent fix | Testing against unpulled Sync tree | `git pull origin main` on `~/Sync/mini_projects/printstack` |
| Agent sync disrupted human flash | `nut` during active `printstack` run | `pgrep -af 'printstack\.sh'` first |
| `--reprovision` deleted working container | Flag destroys container before recreate | Use without flag for non-destructive printer re-discovery |
| SD card flash to wrong device | `DEVICE` misidentified | `lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS` before every flash |
| Image too large for SD card | Card smaller than Ubuntu image | Script pre-checks size; use >= 8 GB card |
| Secrets committed to git | `.env` not gitignored or force-added | Only commit `*.env.example`; chmod 600 real env files |