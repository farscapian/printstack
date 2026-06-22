# printstack -- AI Development Notes (index)

Immutable USB/IP proxy + CUPS print server stack. **Load topic files from `ai-guidance/` instead of reading this index repeatedly.**

## Quick rules

- Branding: always lowercase `printstack` (never Print Stack / PrintStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in Sync: Grok -> `~/.grok/worktrees/mini-projects-printstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/mini-projects-printstack/<session-id>/`; bootstrap scripts run from `~/Sync/mini_projects/printstack`
- Claude Code: NEVER edit files under `~/Sync/mini_projects/printstack` -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (session sync + agent tips; see `ai-guidance/workflow.md`)
- After changes: commit in session clone; human runs `nut` then `push` (or `nut push`). NEVER `git push origin` from agents (see `ai-guidance/nut.md`)
- CLI runs from `~/Sync/mini_projects/printstack` via `printstack.sh` (or `~/.local/bin/printstack`)
- Never `git pull` on Sync or run `printstack` while the human has an active session (see `workflow.md`)
- Secrets live in `*.env` files (gitignored) -- never commit or echo them
- Integrated terminal (Cursor/Codium): put copy-pasteable commands in chat; see `ai-guidance/terminal.md`

## Topic index

| File | Load when |
|------|-----------|
| [ai-guidance/conventions.md](ai-guidance/conventions.md) | Naming, ASCII-only text, script output tags |
| [ai-guidance/workflow.md](ai-guidance/workflow.md) | Repos, agent session clones (Grok + Claude Code), git sync, active bootstrap sessions |
| [ai-guidance/nut.md](ai-guidance/nut.md) | `nut` command -- Newest commit Until Transferred (human Sync handoff) |
| [ai-guidance/configuration.md](ai-guidance/configuration.md) | `shared.env`, `pi-bootstrap.env`, `printserver-bootstrap.env` |
| [ai-guidance/architecture.md](ai-guidance/architecture.md) | Two-node USB/IP + CUPS design, nightly reprovisioning, firewall |
| [ai-guidance/terminal.md](ai-guidance/terminal.md) | Copy/paste in Cursor/Codium integrated terminal |
| [ai-guidance/cli.md](ai-guidance/cli.md) | `printstack.sh` commands, global flags, session logs |
| [ai-guidance/bootstrap.md](ai-guidance/bootstrap.md) | `pi-bootstrap.sh`, `printserver-bootstrap.sh`, `printserver-image-build.sh` (wrapped by CLI) |
| [ai-guidance/cloud-init.md](ai-guidance/cloud-init.md) | Cloud-init generation, firstboot vs nightly, lpadmin baking |
| [ai-guidance/features.md](ai-guidance/features.md) | TLS/Let's Encrypt, virtual printers, MACVLAN, CUPS discovery |
| [ai-guidance/implementation.md](ai-guidance/implementation.md) | Env loading, heredocs, YAML indent variables, trap/cleanup |
| [ai-guidance/gotchas.md](ai-guidance/gotchas.md) | usbip timing, brcmfmac NVRAM, cloud-init instance-id, package pre-bake |
| [ai-guidance/pitfalls.md](ai-guidance/pitfalls.md) | Symptom -> cause -> fix lookup table |
| [ai-guidance/security.md](ai-guidance/security.md) | Never print secrets; `.env` permissions; API keys |
| [ai-guidance/testing.md](ai-guidance/testing.md) | Pre-handoff validation checklist |
| [ai-guidance/code-quality.md](ai-guidance/code-quality.md) | shellcheck rules and examples |
| [ai-guidance/references.md](ai-guidance/references.md) | External docs and key source files |

Full catalog and review notes: [ai-guidance/README.md](ai-guidance/README.md).