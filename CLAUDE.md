# printstack -- AI Development Notes (index)

Immutable USB/IP proxy + CUPS print server stack. **Load topic files on demand -- do not read this entire index repeatedly.**

## Quick rules

- Branding: always lowercase `printstack` (never Print Stack / PrintStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in Sync: Grok -> `~/.grok/worktrees/mini-projects-printstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/mini-projects-printstack/<session-id>/`; bootstrap scripts run from `~/Sync/mini_projects/printstack`
- Claude Code: NEVER edit files under `~/Sync/mini_projects/printstack` -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (see `.agentstartstack/agentstartstack/workflow.md`)
- After changes: commit in session clone; human runs `nut` then `git push origin main` (or `nutup`). NEVER `git push origin` from agents (see `.agentstartstack/agentstartstack/nut.md`)
- CLI runs from `~/Sync/mini_projects/printstack` via `printstack.sh` (or `~/.local/bin/printstack`)
- Never `nut` or `git pull` on Sync while `printstack` is running (see `agentstartstack/workflow.md`)
- Secrets live in `*.env` files (gitignored) -- never commit or echo them
- Integrated terminal: see `.agentstartstack/agentstartstack/terminal.md`

## Generic guidance (.agentstartstack submodule)

| File | Load when |
|------|-----------|
| [.agentstartstack/agentstartstack/workflow.md](.agentstartstack/agentstartstack/workflow.md) | Repos, session clones, git sync |
| [.agentstartstack/agentstartstack/nut.md](.agentstartstack/agentstartstack/nut.md) | `nut` / `nutup` handoff |
| [.agentstartstack/agentstartstack/conventions.md](.agentstartstack/agentstartstack/conventions.md) | Naming, ASCII-only, output tags |
| [.agentstartstack/agentstartstack/terminal.md](.agentstartstack/agentstartstack/terminal.md) | Copy/paste in Cursor/Codium integrated terminal |
| [.agentstartstack/agentstartstack/security.md](.agentstartstack/agentstartstack/security.md) | Never print secrets (generic) |
| [.agentstartstack/agentstartstack/code-quality.md](.agentstartstack/agentstartstack/code-quality.md) | shellcheck, git hooks |
| [.agentstartstack/agentstartstack/implementation.md](.agentstartstack/agentstartstack/implementation.md) | Common shell patterns |
| [.agentstartstack/agentstartstack/testing.md](.agentstartstack/agentstartstack/testing.md) | Generic pre-handoff checks |

## Project guidance

| File | Load when |
|------|-----------|
| [agentstartstack/workflow.md](agentstartstack/workflow.md) | Active bootstrap sessions, live-run milestones |
| [agentstartstack/configuration.md](agentstartstack/configuration.md) | `shared.env`, `pi-bootstrap.env`, `printserver-bootstrap.env` |
| [agentstartstack/architecture.md](agentstartstack/architecture.md) | Two-node USB/IP + CUPS design, nightly reprovisioning, firewall |
| [agentstartstack/cli.md](agentstartstack/cli.md) | `printstack.sh` commands, global flags, session logs |
| [agentstartstack/bootstrap.md](agentstartstack/bootstrap.md) | `pi-bootstrap.sh`, `printserver-bootstrap.sh`, image build |
| [agentstartstack/cloud-init.md](agentstartstack/cloud-init.md) | Cloud-init generation, firstboot vs nightly, lpadmin baking |
| [agentstartstack/features.md](agentstartstack/features.md) | TLS/Let's Encrypt, virtual printers, MACVLAN, CUPS discovery |
| [agentstartstack/implementation.md](agentstartstack/implementation.md) | Env loading, heredocs, YAML indent variables, trap/cleanup |
| [agentstartstack/gotchas.md](agentstartstack/gotchas.md) | usbip timing, brcmfmac NVRAM, cloud-init instance-id |
| [agentstartstack/pitfalls.md](agentstartstack/pitfalls.md) | Symptom -> cause -> fix lookup table |
| [agentstartstack/security.md](agentstartstack/security.md) | Project secrets, TLS, firewall |
| [agentstartstack/testing.md](agentstartstack/testing.md) | Pre-handoff validation checklist |
| [agentstartstack/references.md](agentstartstack/references.md) | External docs and key source files |

Full catalog: [agentstartstack/README.md](agentstartstack/README.md).

Origin: `git@github.com:farscapian/printstack.git`