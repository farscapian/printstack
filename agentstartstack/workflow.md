# Development Workflow

## Canonical paths

- **Primary repo (daily use):** `~/Sync/mini_projects/printstack` on branch `main`
- **Grok/Cursor session clones:** `~/.grok/worktrees/mini-projects-printstack/<session-id>/` (isolated full git clones for agent sessions; not linked `git worktree` entries)
- **Claude Code session clones:** `~/.claude/worktrees/mini-projects-printstack/<session-id>/` (same isolation model; Claude Code edits here via absolute paths; VS Code stays open at Sync for human reference only)
- **Before testing fixes on Sync:** `git pull origin main` -- stale trees produce confusing output
- **Handoff between trees:** `origin/main` -- agents sync to Sync on request; humans push to origin; new sessions session-sync from Sync

## Who edits where

| Role | Edit here | Why |
|------|-----------|-----|
| Grok/Cursor agent (active session) | `~/.grok/worktrees/mini-projects-printstack/<session-id>/` | Isolated workspace; commits and sync without touching your daily tree |
| Claude Code agent (active session) | `~/.claude/worktrees/mini-projects-printstack/<session-id>/` | Same isolation; human never edits these clones; Claude Code uses absolute paths |
| Human (manual work) | `~/Sync/mini_projects/printstack` | Canonical repo; bootstrap scripts run from here |

**Rule of thumb:** agents write their session clone; humans write Sync. Do not edit an active session clone by hand.

**Agent write access:** treat the open session clone as agent-owned for the duration of the session. No special file permissions required -- avoid parallel human edits in that directory instead.

**Human manual edits:** use Sync. Edit, test with bootstrap scripts, commit, `git push origin main`. Then session-sync any active agent clone so the agent sees your commits:

Grok:
```bash
~/Sync/mini_projects/printstack/scripts/init_grok_session.sh \
  ~/.grok/worktrees/mini-projects-printstack/<session-id>
```

Claude Code:
```bash
~/Sync/mini_projects/printstack/scripts/init_claude_session.sh \
  ~/.claude/worktrees/mini-projects-printstack/<session-id>
```

**Mid-session human intervention:** prefer telling the agent what to change. If you must edit git-tracked files yourself, edit Sync, push, then session-sync the agent clone -- do not patch the clone directly.

**When editing a session clone by hand is acceptable:** throwaway experiments, a session that is already finished, or running the init script (expected).

**Testing agent changes:** bootstrap scripts always run from Sync. After the agent syncs to Sync, pull on Sync (or let the human pull), then test. Running against an unpulled Sync tree is a common source of false failures.

## AI git workflow

Authorized workflow for agent sessions (Grok/Cursor and Claude Code). Two steps: **session sync** at start, **sync to Sync** after commits when the human asks.

### 1. Session sync (start of session)

Align the session clone with the canonical Sync repo. Run once per session (or after the human edits Sync and pushes).

**Grok/Cursor:** `scripts/init_grok_session.sh` -- session sync, session-goal prompt, and agent usage reminders.

```bash
cd ~/.grok/worktrees/mini-projects-printstack/<session-id>
~/Sync/mini_projects/printstack/scripts/init_grok_session.sh
```

**Claude Code:** `scripts/init_claude_session.sh` -- same sync + Claude Code specific reminders.

```bash
cd ~/.claude/worktrees/mini-projects-printstack/<session-id>
~/Sync/mini_projects/printstack/scripts/init_claude_session.sh
```

Manual equivalent (either agent type):

```bash
cd <session-clone-path>

git remote add local-sync ~/Sync/mini_projects/printstack 2>/dev/null \
  || git remote set-url local-sync ~/Sync/mini_projects/printstack

git fetch local-sync main
git reset --hard local-sync/main
git clean -fd
```

### 2. Sync (when human asks)

Push the latest agent-worktree commit to the local Sync repo. The human then reviews and pushes to origin. **Agents never push to origin.**

**Human command:** `nut` (or `nut printstack`) -- see [nut.md](nut.md). Finds the newest commit in the matching agent worktree, runs guards, and `git push local-sync main`.

```bash
nut printstack
# equivalent manual path (nut runs this after picking the worktree):
# git -C <worktree> push local-sync main
```

`~/Sync/mini_projects/printstack` is configured with `receive.denyCurrentBranch = updateInstead`, so the push also updates Sync's working tree.

**Human after sync:** review in Sync, then `git push origin main` when satisfied.

**Humans editing Sync directly:** `git push origin main` from Sync, then session-sync any active agent clone.

### 3. Active bootstrap sessions (agents -- mandatory)

Do **not** disrupt a flash, provision, image build, or other long-running `printstack` command the human started on Sync.

#### Before sync (push to Sync)

Sync to Sync **if and only if** no `printstack` command is running:

```bash
# Any match means: do NOT git push local-sync yet
pgrep -af '(printstack\.sh|/printstack) ' || echo "no printstack sessions"
```

If anything is running: commit in the session clone, tell the human sync is pending, and push local-sync only after their session finishes.

#### Before hardware operations

Never run `printstack flash` against an SD card the human is already flashing. Check first:

```bash
pgrep -af '(printstack\.sh|/printstack) '
```

**Safe without hardware:** `bash -n`, shellcheck, editing cloud-init templates in the session clone, reviewing generated output under `cloud-init/` (gitignored).

**When in doubt:** ask the human or wait for their running command to finish.

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

## End-to-end (quick reference)

**Start a Grok session**
1. Open the session folder in Cursor/Grok
2. Run `scripts/init_grok_session.sh` (session sync + goal prompt + agent tips)
3. Paste the suggested first message into the agent (task + 1-3 `agentstartstack/` files to read)

**Start a Claude Code session**
1. Create a session clone: `git clone git@github.com:farscapian/immutable-usbproxy-and-printserver.git ~/.claude/worktrees/mini-projects-printstack/<session-id>`
2. Run `scripts/init_claude_session.sh` from the clone (session sync + agent tips)
3. VS Code stays open at Sync for your reference; Claude Code edits the clone via absolute paths

**During any agent session**
- Agent edits and commits only in the session clone; never in Sync
- Human does not edit the session clone by hand; use Sync for manual work (push + session-sync to refresh the agent)
- When the human runs bootstrap scripts on Sync, watch terminal output for milestones and errors

**After agent work**
- Human lands agent commits on Sync: `nut` (never `git push origin` from agents)
- Human reviews in `~/Sync/mini_projects/printstack`, then `git push origin main` when satisfied
- Human continues on Sync for bootstrap scripts and follow-up edits

**Human-only work (no agent)**
- Edit, commit, and push from Sync only
- Next agent session picks up your commits via `init_grok_session.sh` or `init_claude_session.sh`

## Agent session clones

Both Grok and Claude Code use full git clones, not linked `git worktree` entries (`git worktree list` shows only the current clone).

Grok session directories:
```bash
ls -la ~/.grok/worktrees/mini-projects-printstack/
```

Claude Code session directories:
```bash
ls -la ~/.claude/worktrees/mini-projects-printstack/
```

Create a new Claude Code session clone:
```bash
git clone git@github.com:farscapian/immutable-usbproxy-and-printserver.git \
  ~/.claude/worktrees/mini-projects-printstack/<session-id>
~/Sync/mini_projects/printstack/scripts/init_claude_session.sh \
  ~/.claude/worktrees/mini-projects-printstack/<session-id>
```

## Git hooks (shellcheck)

Install once per clone (Sync repo or session clone):

```bash
./scripts/install-githooks.sh
```

This sets `core.hooksPath` to `.githooks` and enables a **pre-commit** hook that runs `shellcheck -x -S error` on staged `.sh` files. Hard errors block the commit; run full `shellcheck -x` manually to catch warnings and style notes (see [code-quality.md](code-quality.md)).

Re-run `install-githooks.sh` after cloning a new session worktree.

## Git and commit policy

**Agent default:** commit when a task is complete. Human runs `nut` when ready (see [nut.md](nut.md)); `nut` refuses while bootstrap scripts are running (see [Active bootstrap sessions](#3-active-bootstrap-sessions-agents----mandatory)). Never push to origin -- that is human-only.

**Correctness bar:** end-to-end testing against real hardware (Pi + Incus host) remains the standard for functional validation. Commits can land before the human has tested every edge case; note untested areas in the commit message when relevant.

**Human override:** skip or defer commit/`nut` when the human requests it (e.g. experimental WIP).

### Commit workflow

**Agent (Grok or Claude Code session clone)**
1. Make code changes in the session clone (never in Sync)
2. `git add` and commit
3. Human: `nut` (never `git push origin` from agents)
4. Human reviews in Sync, then `git push origin main` when satisfied

**Human (Sync repo)**
1. Make code changes on Sync
2. `git add`, commit, `git push origin main`
3. Session-sync any active agent clone before resuming agent work:
   - Grok: `init_grok_session.sh`
   - Claude Code: `init_claude_session.sh`

## Research FIRST, then debug

**When encountering a persistent problem, do targeted internet research BEFORE systematic debugging.**

Example: USB/IP attach fails intermittently
- [FAIL] Bad: Retry attach 10 times with different bus IDs (hours of guessing)
- [OK] Good: Research "usbip attach vhci-hcd container" -> find module load ordering issue (minutes)

**When to research:**
- Problem seems common (cloud-init, usbip, CUPS, Incus MACVLAN)
- Infrastructure problem (existing best practices likely exist)
- Multiple attempts failing with similar symptoms

**When systematic debugging is still appropriate:**
- Project-specific cloud-init heredoc or env wiring
- After research has identified the likely cause (then test to confirm)