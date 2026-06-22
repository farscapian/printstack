# Testing

Before requesting human approval or syncing to Sync:

## Shell script validation

```bash
# Syntax check all scripts
bash -n pi-bootstrap.sh printserver-bootstrap.sh printserver-image-build.sh

# ShellCheck (see .agentstartstack/agentstartstack/code-quality.md)
find . -name "*.sh" -type f ! -path "./.git/*" -print0 | xargs -0 shellcheck -x
```

## Pi bootstrap (when hardware available)

- [ ] `lsblk` confirms correct `DEVICE` before flash
- [ ] Image checksum verifies (or downloads cleanly)
- [ ] Flash completes without dd errors
- [ ] brcmfmac NVRAM patch message appears in output
- [ ] Cloud-init files written to `cloud-init/pi-bootstrap/`
- [ ] Pi boots and joins WiFi
- [ ] `usbipd` listening: `nc -zv $USBPROXY_HOST 3240`
- [ ] `usbip list -r $USBPROXY_HOST` shows connected printers

## Printserver bootstrap (when Incus host available)

- [ ] `printserver-base` image exists (or image build succeeds)
- [ ] Container launches and cloud-init reaches `status: done`
- [ ] usbip attach succeeds (printers visible in container)
- [ ] `lpadmin -p` lists registered printers
- [ ] CUPS web UI reachable from LAN (port 631)
- [ ] Test print succeeds
- [ ] Baked cloud-init updated in `cloud-init/printserver-bootstrap/`
- [ ] Nightly timer installed on Incus host

## TLS (if enabled)

- [ ] certbot obtains certificate via DNS-01
- [ ] nginx serves HTTPS on 443
- [ ] Certificate persists in `printserver-letsencrypt` volume
- [ ] Nightly reprovision retains valid cert

## Virtual printer path (no hardware)

- [ ] `ENABLE_VIRTUAL_PRINTERS=3` creates gadgets on Pi
- [ ] Virtual devices appear in `usbip list -r`
- [ ] Printserver discovers and registers them in CUPS

## Regression checks

- [ ] Re-running bootstrap without `--reprovision` aborts safely when container exists
- [ ] Nightly cloud-init configs contain no `apt`/`package_upgrade` (internet-free)
- [ ] No secrets in generated `cloud-init/` output files
- [ ] `.env` files not staged in `git status`

## Agent handoff notes

When committing before full hardware test, note in the commit message:
- Which nodes were tested (Pi / Incus / both)
- Which paths are untested (e.g. TLS, nightly reprovision, virtual printers)