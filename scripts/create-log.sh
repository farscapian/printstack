#!/bin/bash
# create-log.sh -- Session logging helpers for printstack --create-log / --timestamp
#
# Requires config.sh (PRINTSTACK_HOME) and SCRIPT_DIR to be set.

[[ -n "${_CREATE_LOG_LOADED:-}" ]] && return 0
_CREATE_LOG_LOADED=1

PRINTSTACK_LOG_STAMP="${PRINTSTACK_LOG_STAMP:-${SCRIPTS_DIR}/log-stamp.py}"

PRINTSTACK_ARGV=()

printstack_parse_global_argv() {
  PRINTSTACK_ARGV=()
  VERBOSE=0
  QUIET=0
  unset PRINTSTACK_LOG_ID 2>/dev/null || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        ;;
      -q|--quiet)
        QUIET=1
        ;;
      --create-log)
        export PRINTSTACK_CREATE_LOG=1
        export PRINTSTACK_TIMESTAMP=1
        if [[ -z "${PRINTSTACK_LOG_ID:-}" ]]; then
          PRINTSTACK_LOG_ID=$(uuidgen 2>/dev/null \
            || python3 -c 'import uuid; print(uuid.uuid4())')
          export PRINTSTACK_LOG_ID
        fi
        ;;
      --timestamp)
        export PRINTSTACK_TIMESTAMP=1
        ;;
      -env=*)
        export ENV_FILE="${HOME}/.printstack/${1#-env=}"
        ;;
      *)
        PRINTSTACK_ARGV+=("$1")
        ;;
    esac
    shift
  done

  [[ "${PRINTSTACK_CREATE_LOG:-0}" -eq 1 ]] && VERBOSE=1

  if [[ $VERBOSE -eq 1 && $QUIET -eq 1 ]]; then
    echo "[ERROR] -v/--verbose and -q/--quiet are incompatible" >&2
    exit 1
  fi

  export VERBOSE QUIET
  if [[ $VERBOSE -eq 1 ]]; then
    export PRINTSTACK_VERBOSE=1
  else
    unset PRINTSTACK_VERBOSE 2>/dev/null || true
  fi
}

create_log_enabled() {
  [[ "${PRINTSTACK_CREATE_LOG:-0}" -eq 1 ]]
}

printstack_timestamp_enabled() {
  [[ "${PRINTSTACK_TIMESTAMP:-0}" -eq 1 ]]
}

create_log_child_output_piped() {
  create_log_enabled || printstack_timestamp_enabled
}

# VS Code / Cursor / Codium integrated terminals handle /dev/tty poorly for
# copy/paste; use plain tee (stdout only) in those environments.
printstack_integrated_terminal() {
  case "${TERM_PROGRAM:-}" in
    vscode|VSCode|cursor|Cursor|Windsurf|windsurf|Zed|zed|VSCodium|vscodium)
      return 0
      ;;
  esac
  [[ -n "${VSCODE_IPC_HOOK_CLI:-}" || -n "${VSCODE_INJECTION:-}" ]] && return 0
  return 1
}

create_log_stamp_line() {
  local source="$1"
  local line="$2"
  create_log_enabled || return 0
  [[ -n "${PRINTSTACK_LOG_FILE:-}" ]] || return 0
  local ts
  ts=$(date -Iseconds)
  mkdir -p "$(dirname "$PRINTSTACK_LOG_FILE")"
  printf '%s [%s] %s\n' "$ts" "$source" "$line" >> "$PRINTSTACK_LOG_FILE"
}

create_log_stamp_pipe() {
  local source="$1"
  if create_log_enabled && [[ -n "${PRINTSTACK_LOG_FILE:-}" && -f "$PRINTSTACK_LOG_STAMP" ]]; then
    stdbuf -oL -eL python3 -u "$PRINTSTACK_LOG_STAMP" \
      --source "$source" \
      --log-file "$PRINTSTACK_LOG_FILE" \
      --log-only
  else
    cat
  fi
}

create_log_subprocess_indent_env() {
  export PRINTSTACK_LOG_SUB_INDENT="  "
}

create_log_console_stamp_pipe() {
  local source="${1:-}"
  if [[ -f "$PRINTSTACK_LOG_STAMP" ]]; then
    local -a stamp_args=(--console-only)
    if create_log_enabled && [[ -n "${PRINTSTACK_LOG_FILE:-}" ]]; then
      stamp_args=(--console --source "$source" --log-file "$PRINTSTACK_LOG_FILE")
    fi
    create_log_subprocess_indent_env
    stdbuf -oL -eL env \
      PRINTSTACK_LOG_INDENT="${PRINTSTACK_LOG_INDENT:-}" \
      PRINTSTACK_LOG_SUB_INDENT="${PRINTSTACK_LOG_SUB_INDENT:-}" \
      python3 -u "$PRINTSTACK_LOG_STAMP" "${stamp_args[@]}"
  else
    cat
  fi
}

create_log_tee_console() {
  local source="$1"
  if create_log_enabled && printstack_timestamp_enabled; then
    create_log_console_stamp_pipe "$source"
  elif create_log_enabled; then
    if printstack_integrated_terminal; then
      stdbuf -oL -eL tee | create_log_stamp_pipe "$source"
    else
      stdbuf -oL -eL tee /dev/tty | create_log_stamp_pipe "$source"
    fi
  elif printstack_timestamp_enabled; then
    create_log_console_stamp_pipe "$source"
  else
    cat
  fi
}

create_log_run() {
  local source="$1"
  shift
  if create_log_child_output_piped; then
    create_log_subprocess_indent_env
    env PYTHONUNBUFFERED=1 stdbuf -oL -eL "$@" 2>&1 | create_log_tee_console "$source"
    return "${PIPESTATUS[0]}"
  fi
  "$@"
}

create_log_watch_append() {
  local invocation_cmd="$1"
  local watch_file="${PRINTSTACK_SESSION_WATCH:-${PRINTSTACK_HOME}/logs/sessions.watch}"
  local ts log_id session_log

  ts=$(date -Iseconds)
  mkdir -p "$(dirname "$watch_file")"

  if [[ ! -f "$watch_file" ]]; then
    printf '#%s\t%s\t%s\t%s\t%s\n' \
      ts pid log_id session_log command >"$watch_file"
  fi

  if [[ -n "${PRINTSTACK_LOG_ID:-}" ]]; then
    log_id="$PRINTSTACK_LOG_ID"
  else
    log_id="-"
  fi

  if [[ -n "${PRINTSTACK_LOG_FILE:-}" ]]; then
    session_log="$PRINTSTACK_LOG_FILE"
  else
    session_log="-"
  fi

  invocation_cmd="${invocation_cmd//$'\t'/ }"
  invocation_cmd="${invocation_cmd//$'\n'/ }"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$$" "$log_id" "$session_log" "$invocation_cmd" >>"$watch_file"
}

create_log_setup() {
  local command="$1"
  local log_name
  create_log_enabled || return 0

  export PYTHONUNBUFFERED=1
  if [[ -n "${PRINTSTACK_LOG_ID:-}" ]]; then
    log_name="printstack-${PRINTSTACK_LOG_ID}"
  else
    log_name="printstack-${command}"
  fi
  export PRINTSTACK_LOG_FILE="${PRINTSTACK_HOME}/logs/${log_name}.log"

  mkdir -p "$(dirname "$PRINTSTACK_LOG_FILE")"

  if [[ -n "${PRINTSTACK_LOG_ID:-}" && -f "$PRINTSTACK_LOG_FILE" ]]; then
    echo "" >> "$PRINTSTACK_LOG_FILE"
  else
    : > "$PRINTSTACK_LOG_FILE"
  fi
}

create_log_write_header() {
  create_log_enabled || return 0
  [[ -n "${PRINTSTACK_LOG_FILE:-}" ]] || return 0
  local session_cmd="printstack"
  [[ ${#PRINTSTACK_ARGV[@]} -gt 0 ]] && session_cmd+=" ${PRINTSTACK_ARGV[*]}"
  printf '%s === %s ===\n' "$(date -Iseconds)" "$session_cmd" >> "$PRINTSTACK_LOG_FILE"
}