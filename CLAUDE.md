# printstack -- AI Development Notes (index)

Immutable USB/IP proxy + CUPS print server stack. **Load topic files from `agentstartstack/` instead of reading this index repeatedly.**

## Quick rules

- Branding: always lowercase `printstack` (never Print Stack / PrintStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in Sync: Grok -> `~/.grok/worktrees/mini-projects-printstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/mini-projects-printstack/<session-id>/`; bootstrap scripts run from `~/Sync/mini_projects/printstack`
- Claude Code: NEVER edit files under `~/Sync/mini_projects/printstack` -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (session sync + agent tips; see `agentstartstack/workflow.md`)
- After changes: commit in session clone; human runs `nut` then `push` (or `nut push`). NEVER `git push origin` from agents (see `agentstartstack/nut.md`)
- CLI runs from `~/Sync/mini_projects/printstack` via `printstack.sh` (or `~/.local/bin/printstack`)
- Never `git pull` on Sync or run `printstack` while the human has an active session (see `workflow.md`)
- Secrets live in `*.env` files (gitignored) -- never commit or echo them
- Integrated terminal (Cursor/Codium): put copy-pasteable commands in chat; see `agentstartstack/terminal.md`

## Topic index

| File | Load when |
|------|-----------|
| [agentstartstack/conventions.md](agentstartstack/conventions.md) | Naming, ASCII-only text, script output tags |
| [agentstartstack/workflow.md](agentstartstack/workflow.md) | Repos, agent session clones (Grok + Claude Code), git sync, active bootstrap sessions |
| [agentstartstack/nut.md](agentstartstack/nut.md) | `nut` command -- Newest commit Until Transferred (human Sync handoff) |
| [agentstartstack/configuration.md](agentstartstack/configuration.md) | `shared.env`, `pi-bootstrap.env`, `printserver-bootstrap.env` |
| [agentstartstack/architecture.md](agentstartstack/architecture.md) | Two-node USB/IP + CUPS design, nightly reprovisioning, firewall |
| [agentstartstack/terminal.md](agentstartstack/terminal.md) | Copy/paste in Cursor/Codium integrated terminal |
| [agentstartstack/cli.md](agentstartstack/cli.md) | `printstack.sh` commands, global flags, session logs |
| [agentstartstack/bootstrap.md](agentstartstack/bootstrap.md) | `pi-bootstrap.sh`, `printserver-bootstrap.sh`, `printserver-image-build.sh` (wrapped by CLI) |
| [agentstartstack/cloud-init.md](agentstartstack/cloud-init.md) | Cloud-init generation, firstboot vs nightly, lpadmin baking |
| [agentstartstack/features.md](agentstartstack/features.md) | TLS/Let's Encrypt, virtual printers, MACVLAN, CUPS discovery |
| [agentstartstack/implementation.md](agentstartstack/implementation.md) | Env loading, heredocs, YAML indent variables, trap/cleanup |
| [agentstartstack/gotchas.md](agentstartstack/gotchas.md) | usbip timing, brcmfmac NVRAM, cloud-init instance-id, package pre-bake |
| [agentstartstack/pitfalls.md](agentstartstack/pitfalls.md) | Symptom -> cause -> fix lookup table |
| [agentstartstack/security.md](agentstartstack/security.md) | Never print secrets; `.env` permissions; API keys |
| [agentstartstack/testing.md](agentstartstack/testing.md) | Pre-handoff validation checklist |
| [agentstartstack/code-quality.md](agentstartstack/code-quality.md) | shellcheck rules and examples |
| [agentstartstack/references.md](agentstartstack/references.md) | External docs and key source files |

Full catalog and review notes: [agentstartstack/README.md](agentstartstack/README.md).