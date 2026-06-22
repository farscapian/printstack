#!/bin/bash
# init_claude_session.sh -- Claude Code session sync (AI git workflow step 1) and agent tips
#
# Usage:
#   scripts/init_claude_session.sh [session-clone-path]
#
# Run from inside a Claude Code session clone, or pass the clone path as the first argument.
# Sync source: ~/Sync/mini_projects/printstack (override with PRINTSTACK_SYNC_REPO).

set -euo pipefail

SYNC_REPO="${PRINTSTACK_SYNC_REPO:-${HOME}/Sync/mini_projects/printstack}"
CLAUDE_PARENT="${PRINTSTACK_CLAUDE_WORKTREES:-${HOME}/.claude/worktrees/mini-projects-printstack}"

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR]  %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: init_claude_session.sh [session-clone-path]

Session sync for the authorized AI git workflow: aligns a Claude Code session
clone with the canonical Sync repo and prints reminders for efficient agent use.

Examples:
  cd ~/.claude/worktrees/mini-projects-printstack/<session-id>
  /home/derek/Sync/mini_projects/printstack/scripts/init_claude_session.sh

  init_claude_session.sh ~/.claude/worktrees/mini-projects-printstack/<session-id>
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

resolve_repo_root() {
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then
    [[ -d "$arg" ]] || err "Session path not found: $arg"
    (cd "$arg" && pwd)
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || true
}

REPO_ROOT="$(resolve_repo_root "${1:-}")"
[[ -n "$REPO_ROOT" ]] || err "Not inside a git repo. Pass the session clone path as an argument."

SYNC_REPO="$(cd "$SYNC_REPO" 2>/dev/null && pwd)" || err "Sync repo not found: $SYNC_REPO"
[[ -d "${SYNC_REPO}/.git" ]] || err "Sync path is not a git repo: $SYNC_REPO"

if [[ "$(readlink -f "$REPO_ROOT")" == "$(readlink -f "$SYNC_REPO")" ]]; then
  warn "Current directory is the Sync canonical repo, not a Claude Code session clone."
  warn "Init is intended for ~/.claude/worktrees/mini-projects-printstack/<session-id>/"
  read -r -p "Continue anyway? [y/N] " confirm </dev/tty
  [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]] || exit 0
fi

cd "$REPO_ROOT"
git rev-parse --is-inside-work-tree &>/dev/null || err "Not a git work tree: $REPO_ROOT"

info "Session clone: $REPO_ROOT"
info "Sync source:   $SYNC_REPO"
echo ""

info "Session sync: fetching local-sync/main and resetting..."
if git remote get-url local-sync &>/dev/null; then
  git remote set-url local-sync "$SYNC_REPO"
else
  git remote add local-sync "$SYNC_REPO"
fi

git fetch local-sync main
git reset --hard local-sync/main
git clean -fd

COMMIT="$(git log -1 --oneline)"
BRANCH="$(git branch --show-current)"
ok "Synced to ${BRANCH} @ ${COMMIT}"
info "Workflow guide: ${REPO_ROOT}/ai-guidance/workflow.md"
echo ""

cat <<'EOF'
================================================================================
Using Claude Code agents efficiently (printstack)
================================================================================

AI GIT WORKFLOW (authorized)
  1. Session sync  -- init_claude_session.sh once per session (you just ran this)
  2. Sync          -- when human says "sync": git push local-sync main
                      (pushes to ~/Sync/mini_projects/printstack, NOT to origin)
                      Human reviews and pushes to origin -- NEVER the agent

IMPORTANT: Claude Code always edits files in the session clone (~/.claude/worktrees/...)
  using absolute paths. VS Code opens at ~/Sync/mini_projects/printstack for the
  human's reference only -- do NOT edit files under Sync.

FIRST MESSAGE (copy/paste template below)
  - Say you ran init_claude_session.sh (session sync complete).
  - State your task in one sentence.
  - Name 1-3 ai-guidance files to read (not all of them, not CLAUDE.md in full).

WHAT TO READ (pick 1-3 by task type)
  Pi SD flash / WiFi         -> workflow.md, bootstrap.md, gotchas.md
  Printserver provision      -> workflow.md, bootstrap.md, cloud-init.md
  Incus image rebuild        -> bootstrap.md, architecture.md
  Cloud-init / nightly       -> cloud-init.md, features.md, gotchas.md
  TLS / Let's Encrypt        -> features.md, configuration.md, security.md
  New shell script           -> conventions.md, code-quality.md, implementation.md
  Docs / workflow only       -> workflow.md, ai-guidance/README.md

  CLAUDE.md is an index only. Do not ask the agent to "read all of CLAUDE.md".

TOKEN TIPS
  - Session sync once per session (this script), not before every task.
  - Give concrete errors, hostnames, and file paths up front.
  - Let the agent read source files after guidance, not the whole repo.
  - End of session: commit, then sync to Sync on request (git push local-sync main).
    Human reviews and pushes to origin when satisfied.

WATCHING LIVE RUNS (when human runs bootstrap from Sync)
  - Watch terminal output for pi-bootstrap / printserver-bootstrap milestones
  - Inspect generated cloud-init under cloud-init/ (gitignored) after runs
  - See workflow.md § Watching live bootstrap runs

DO NOT
  - Start a session without session sync (stale clone -> wrong fixes).
  - Edit files under ~/Sync/mini_projects/printstack -- work only in the session clone.
  - Push to origin (git push origin main) -- HUMAN ONLY, never an AI agent.
  - Re-explain the AI git workflow every time (see ai-guidance/workflow.md).
  - nut while printstack is running: pgrep -af '(printstack\.sh|/printstack) '
  - Run printstack flash against an SD card the human is already flashing.

WHEN HUMAN SAYS "sync"
  nut push          # or: nut printstack push -- see ai-guidance/nut.md

================================================================================
Suggested first message to paste into the agent:
================================================================================
EOF

cat <<EOF
New session. init_claude_session.sh complete (session sync) -- on main at ${COMMIT}.

Task: <your task in one sentence>
Read: ai-guidance/workflow.md, ai-guidance/<pick-one-or-two-more>.md
Constraints: <Pi/Incus host, files not to touch>
EOF

echo ""
info "Claude Code session directories: ${CLAUDE_PARENT}/"
info "Canonical repo:                  ${SYNC_REPO}/"
info "Full workflow:                ${REPO_ROOT}/ai-guidance/workflow.md"