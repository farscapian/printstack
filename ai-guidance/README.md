# ai-guidance

Split from the monolithic project docs so agents load only the topics needed for a task.

## Session startup (Grok clone)

1. **Session sync** -- `scripts/init_grok_session.sh` (see `workflow.md`)
2. Read this index; load 1-3 topic files relevant to the task
3. Do not load all files unless doing a broad audit

## Publish (end of session)

1. Commit in the Grok/Claude session clone
2. **Publish** -- human runs `nut push` (or `nut` then `push`; see `nut.md`)

## Suggested load patterns

| Task type | Files |
|-----------|-------|
| Pi SD card flash / WiFi | `cli.md`, `workflow.md`, `bootstrap.md`, `gotchas.md` |
| Printserver provision / reprovision | `cli.md`, `workflow.md`, `bootstrap.md`, `cloud-init.md` |
| Incus image rebuild | `bootstrap.md`, `architecture.md` |
| Cloud-init / nightly reprovision | `cloud-init.md`, `features.md`, `gotchas.md` |
| TLS / Let's Encrypt | `features.md`, `configuration.md`, `security.md` |
| New shell script | `conventions.md`, `code-quality.md`, `implementation.md` |
| Firewall / network / MACVLAN | `architecture.md`, `configuration.md` |
| CI / commit hygiene | `workflow.md`, `code-quality.md`, `testing.md` |
| Human Sync handoff | `nut.md`, `workflow.md` |

## Maintenance

When adding guidance, append to the smallest applicable topic file. Update `CLAUDE.md` index table if adding a new file. Keep cross-references as relative `ai-guidance/*.md` links.