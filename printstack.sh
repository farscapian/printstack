#!/bin/bash
# printstack.sh -- CLI for the immutable USB/IP proxy + print server stack

set -euo pipefail

_PRINTSTACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR="$_PRINTSTACK_DIR"

# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/scripts/config.sh"
# shellcheck source=scripts/create-log.sh
source "${SCRIPT_DIR}/scripts/create-log.sh"

VERBOSE=0
QUIET=0

RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[0;33m'
BLU=$'\033[0;34m'
DIM=$'\033[2m'
RST=$'\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { [[ $QUIET -eq 0 ]] && echo -e "${GRN}[OK]${RST} $*"; return 0; }
warn() { [[ $QUIET -eq 0 ]] && echo -e "${YLW}[WARN]${RST} $*"; return 0; }
debug() { [[ $VERBOSE -eq 1 && $QUIET -eq 0 ]] && echo -e "${DIM}[DEBUG]${RST} $*" >&2; return 0; }

info() {
  [[ $QUIET -eq 0 ]] || return 0
  if create_log_enabled; then
    create_log_stamp_line "printstack.sh" "$*"
  fi
  echo -e "${BLU}[INFO]${RST} $*"
}

usage() {
  cat <<'EOF'
printstack -- immutable USB/IP proxy + CUPS print server

Global flags (any position):
  -v, --verbose       Verbose output
  -q, --quiet         Suppress non-error output
  --create-log        Session log with GUID (implies --timestamp and -v)
  --timestamp         Prefix subprocess output with timestamps
  -env=<file>         Load ~/.printstack/<file> instead of default .env

Commands:
  flash [--force]     Flash Pi SD card (pi-bootstrap.sh --flash)
  refresh             Rebuild printserver image and reprovision container
  help [command]      Show help

Examples:
  printstack --create-log flash --force
  printstack --timestamp refresh
  printstack help flash

Logs: ~/.printstack/logs/  (with --create-log)
Session registry: ~/.printstack/logs/sessions.watch
EOF
}

help_flash() {
  cat <<'EOF'
printstack flash -- flash Ubuntu to the Pi SD card

Wraps pi-bootstrap.sh. Requires root (uses sudo when needed).

Options:
  --force   Skip SD card destruction confirmation (implies --flash)

Setup:
  cp shared.env.example shared.env
  cp pi-bootstrap.env.example pi-bootstrap.env
  chmod 600 shared.env pi-bootstrap.env

Examples:
  printstack flash
  printstack --create-log flash --force
EOF
}

help_refresh() {
  cat <<'EOF'
printstack refresh -- rebuild and redeploy the print server

Immutable refresh (no state preserved):
  1. printserver-image-build.sh --force   (rebuild printserver-base image)
  2. printserver-bootstrap.sh --reprovision (destroy + recreate container)

Setup:
  cp shared.env.example shared.env
  cp printserver-bootstrap.env.example printserver-bootstrap.env
  chmod 600 shared.env printserver-bootstrap.env
  ./printserver-image-build.sh   (first deploy only; refresh always rebuilds)

Examples:
  printstack refresh
  printstack --create-log --timestamp refresh
EOF
}

cmd_flash() {
  local force=false
  local arg

  for arg in "$@"; do
    case "$arg" in
      help) help_flash; return 0 ;;
      --force) force=true ;;
      *) err "Unknown flash argument: $arg (try: printstack help flash)" ;;
    esac
  done

  local pi_script="${PROJECT_ROOT}/pi-bootstrap.sh"
  [[ -x "$pi_script" || -f "$pi_script" ]] || err "pi-bootstrap.sh not found: $pi_script"

  local -a flash_args=(--flash)
  [[ "$force" == true ]] && flash_args+=(--force)

  info "Flash Pi SD card (${flash_args[*]})..."

  if [[ $EUID -ne 0 ]]; then
    create_log_run "pi-bootstrap" sudo -E "$pi_script" "${flash_args[@]}"
  else
    create_log_run "pi-bootstrap" "$pi_script" "${flash_args[@]}"
  fi

  ok "Pi flash complete."
}

cmd_refresh() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      help) help_refresh; return 0 ;;
      *) err "Unknown refresh argument: $arg (try: printstack help refresh)" ;;
    esac
  done

  local image_script="${PROJECT_ROOT}/printserver-image-build.sh"
  local bootstrap_script="${PROJECT_ROOT}/printserver-bootstrap.sh"

  [[ -f "$image_script" ]] || err "printserver-image-build.sh not found"
  [[ -f "$bootstrap_script" ]] || err "printserver-bootstrap.sh not found"

  info "Step 1/2: Rebuild printserver-base Incus image (--force)..."
  create_log_run "printserver-image-build" bash "$image_script" --force

  info "Step 2/2: Reprovision printserver container (--reprovision)..."
  create_log_run "printserver-bootstrap" bash "$bootstrap_script" --reprovision

  ok "Print server refresh complete."
}

main() {
  local invocation_cmd="printstack" arg
  for arg in "$@"; do
    invocation_cmd+=" $(printf '%q' "$arg")"
  done

  printstack_parse_global_argv "$@"
  set -- "${PRINTSTACK_ARGV[@]}"

  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift

  create_log_setup "$command"

  if create_log_enabled; then
    info "Session log: tail -f ${PRINTSTACK_LOG_FILE}"
  fi
  create_log_write_header
  create_log_watch_append "$invocation_cmd"

  if [[ -f "$ENV_FILE" ]]; then
    debug "Loading environment from: $ENV_FILE"
    set +u
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set -u
  fi

  case "$command" in
    flash)
      cmd_flash "$@"
      ;;
    refresh)
      cmd_refresh "$@"
      ;;
    help|-h|--help)
      if [[ $# -eq 0 ]]; then
        usage
      else
        case "$1" in
          flash)   help_flash ;;
          refresh) help_refresh ;;
          *)       err "Unknown help topic: $1" ;;
        esac
      fi
      ;;
    *)
      err "Unknown command: $command. Try 'printstack help'"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi