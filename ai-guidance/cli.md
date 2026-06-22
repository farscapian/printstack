# CLI (printstack.sh)

Entry point for the `printstack` command (symlink `~/.local/bin/printstack` -> `printstack.sh` in the Sync repo).

## Global flags

Valid anywhere on the command line (before or after the subcommand):

| Flag | Effect |
|------|--------|
| `-v`, `--verbose` | Verbose output |
| `-q`, `--quiet` | Suppress non-error output |
| `--create-log` | Session log with GUID under `~/.printstack/logs/`; implies `--timestamp` and `-v` |
| `--timestamp` | Prefix subprocess lines with ISO timestamps |
| `-env=<file>` | Load `~/.printstack/<file>` instead of default `.env` |

Every invocation appends one line to `~/.printstack/logs/sessions.watch` (TSV: ts, pid, log_id, session_log, command).

## Commands

### `printstack flash [--force]`

Flashes the Pi SD card via `pi-bootstrap.sh --flash`. Uses `sudo` when not root.

| Flag | Passes to pi-bootstrap |
|------|----------------------|
| `--force` | `--force` (skip confirmation; implies `--flash`) |

Requires `shared.env` and `pi-bootstrap.env` configured.

### `printstack refresh`

Immutable print server redeploy:

1. `printserver-image-build.sh --force` -- rebuild `printserver-base` Incus image
2. `printserver-bootstrap.sh --reprovision` -- destroy and recreate the container

Requires `shared.env` and `printserver-bootstrap.env` configured.

## Examples

```bash
printstack help
printstack --create-log flash --force
printstack --timestamp refresh
```

## Agents

When the human runs `printstack` from Sync, tail `~/.printstack/logs/sessions.watch` for new runs, then the session log path from that line. See [workflow.md](workflow.md).

Do not `nut` or `git pull` on Sync while `printstack` is running (`pgrep -af 'printstack\.sh'`).