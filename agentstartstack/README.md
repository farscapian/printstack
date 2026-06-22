# agentstartstack (printstack)

Project-specific agent guidance. Generic workflow, nut, conventions, and security live in the **.agentstartstack** submodule.

## Session startup

1. Run `scripts/init_grok_session.sh` or `scripts/init_claude_session.sh`
2. Read root `CLAUDE.md`; load 1-3 files from this directory for the task

## Suggested load patterns

| Task type | Files |
|-----------|-------|
| Pi SD flash / WiFi | `cli.md`, `workflow.md`, `bootstrap.md`, `gotchas.md` |
| Printserver provision / reprovision | `cli.md`, `workflow.md`, `bootstrap.md`, `cloud-init.md` |
| Incus image rebuild | `bootstrap.md`, `architecture.md` |
| Cloud-init / nightly reprovision | `cloud-init.md`, `features.md`, `gotchas.md` |
| TLS / Let's Encrypt | `features.md`, `configuration.md`, `security.md` |
| New shell script | `.agentstartstack/agentstartstack/conventions.md`, `code-quality.md`, `implementation.md` |
| Firewall / network / MACVLAN | `architecture.md`, `configuration.md` |
| CI / commit hygiene | `.agentstartstack/agentstartstack/workflow.md`, `code-quality.md`, `testing.md` |
| Human Sync handoff | `.agentstartstack/agentstartstack/nut.md`, `workflow.md` |

Append to the smallest applicable file. Update `CLAUDE.md` when adding a new file.