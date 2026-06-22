# printstack Workflow (project-specific)

> Generic session clone / nut workflow: see `.agentstartstack/agentstartstack/workflow.md`.
> This file covers printstack-only guards and live-run monitoring.

## Active bootstrap sessions (agents -- mandatory)

Do **not** disrupt a flash, provision, image build, or other long-running `printstack` command the human started on Sync.

### Before nut / sync to Sync

```bash
# Any match means: do NOT nut yet
pgrep -af '(printstack\.sh|/printstack) ' || echo "no printstack sessions"
```

If anything is running: commit in the session clone, tell the human sync is pending, and wait.

### Before hardware operations

Never run `printstack flash` against an SD card the human is already flashing:

```bash
pgrep -af '(printstack\.sh|/printstack) '
```

**Safe without hardware:** `bash -n`, shellcheck, editing cloud-init templates in the session clone, reviewing generated output under `cloud-init/` (gitignored).

## Watching live bootstrap runs (agents)

When the human runs `printstack` from Sync, **watch logs proactively** -- do not wait for them to paste output.

| Command | Typical duration | What to watch |
|---------|------------------|---------------|
| `printstack flash` | 10-30 min | Image download/decompress, dd progress, nspawn chroot, cloud-init write |
| `printstack refresh` | 30-60 min | Image build, container reprovision, cloud-init, usbip attach, CUPS lpadmin |

With `--create-log`, tail `~/.printstack/logs/sessions.watch` then the session log path from that line. See [cli.md](cli.md).

Key milestones to report:
- Pi: checksum OK, flash complete, brcmfmac NVRAM patched, cloud-init files written
- Printserver: cloud-init status done, usbip attach succeeded, printers registered, nightly timer installed

**Safe while a run is active:** read terminal output, inspect `cloud-init/` generated files. **Unsafe:** `git pull` on Sync, `sudo ./pi-bootstrap.sh` on the same SD card, `printserver-bootstrap.sh --reprovision` unless asked.