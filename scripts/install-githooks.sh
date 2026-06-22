#!/usr/bin/env bash
# Install printstack git hooks (pre-commit: shellcheck staged .sh files).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not a git repository: $SCRIPT_DIR" >&2
  exit 1
fi

chmod +x \
  "${SCRIPT_DIR}/.githooks/pre-commit" \
  "${SCRIPT_DIR}/scripts/shellcheck-staged.sh"

git -C "$SCRIPT_DIR" config core.hooksPath .githooks
echo "Git hooks installed (pre-commit: shellcheck staged .sh files)"