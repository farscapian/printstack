#!/bin/bash
# config.sh -- Centralized configuration for printstack scripts
#
# Users can override via environment variables or ~/.printstack/.env

[[ -n "${_PRINTSTACK_CONFIG_LOADED:-}" ]] && return 0
_PRINTSTACK_CONFIG_LOADED=1

_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS_DIR="${SCRIPTS_DIR:-$_CONFIG_DIR}"
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${_CONFIG_DIR}/.." && pwd)}"
export SCRIPT_DIR="${SCRIPT_DIR:-$PROJECT_ROOT}"

export PRINTSTACK_HOME="${PRINTSTACK_HOME:-${HOME}/.printstack}"
export LOGS_DIR="${LOGS_DIR:-${PRINTSTACK_HOME}/logs}"
export PRINTSTACK_SESSION_WATCH="${PRINTSTACK_SESSION_WATCH:-${LOGS_DIR}/sessions.watch}"
export ENV_FILE="${ENV_FILE:-${PRINTSTACK_HOME}/.env}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

mkdir -p "$PRINTSTACK_HOME" "$LOGS_DIR" 2>/dev/null || true