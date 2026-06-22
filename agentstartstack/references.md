# References

## ShellCheck

- https://www.shellcheck.net/
- https://www.shellcheck.net/wiki/

## External docs

- USB/IP: Linux `usbip` man pages (`usbip`, `usbipd`)
- cloud-init: https://cloudinit.readthedocs.io/
- Incus: https://linuxcontainers.org/incus/docs/main/
- CUPS: https://www.cups.org/doc/
- Ubuntu Pi images: https://cdimage.ubuntu.com/releases/26.04/release/
- Let's Encrypt DNS-01: https://letsencrypt.org/docs/challenge-types/
- Namecheap API: https://www.namecheap.com/support/api/intro/

## Key source files

| File | Purpose |
|------|---------|
| `printstack.sh` | CLI entrypoint (`flash`, `refresh`; global flags) |
| `pi-bootstrap.sh` | SD flash, nspawn chroot pre-bake, Pi cloud-init |
| `printserver-bootstrap.sh` | Incus provision, CUPS setup, lpadmin baking, nightly timer |
| `printserver-image-build.sh` | `printserver-base` Incus image builder |
| `shared.env.example` | Shared config template |
| `pi-bootstrap.env.example` | Pi-specific config template |
| `printserver-bootstrap.env.example` | Printserver-specific config template |
| `scripts/init_grok_session.sh` | Grok session sync + agent tips |
| `scripts/init_claude_session.sh` | Claude Code session sync + agent tips |
| `.agentstartstack/agentstartstack/nut.md` | `nut` command source + backronym (`~/.bash_aliases`) |
| `README.md` | Human-facing project overview |
| `CLAUDE.md` | AI agent index |

## Generated output (inspect after runs)

| Path | Written by |
|------|------------|
| `cloud-init/pi-bootstrap/` | `pi-bootstrap.sh` |
| `cloud-init/printserver-bootstrap/` | `printserver-bootstrap.sh` |