#!/usr/bin/env bash
# =============================================================================
# printserver-image-build.sh
#
# Builds a custom Incus image with all printer drivers, CUPS, avahi, usbip
# tools, and nginx/certbot pre-installed. The resulting image is used by
# printserver-bootstrap.sh as the base, so cloud-init only handles config
# (no package installation at reprovision time).
#
# Run once before first deployment, or with --force to rebuild:
#   ./printserver-image-build.sh
#   ./printserver-image-build.sh --force   # rebuild even if image exists
#
# After building, set in printserver-bootstrap.env:
#   INCUS_IMAGE=local:printserver-base
# (this is already the default)
#
# Prerequisites: same as printserver-bootstrap.sh (incus CLI, remote configured)
# =============================================================================

set -exuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load envs ─────────────────────────────────────────────────────────────────
SHARED_ENV="${SCRIPT_DIR}/shared.env"
ENV_FILE="${SCRIPT_DIR}/printserver-bootstrap.env"

[[ -f "$SHARED_ENV" ]] || { echo "ERROR: shared.env not found: $SHARED_ENV" >&2; exit 1; }
[[ -f "$ENV_FILE"   ]] || { echo "ERROR: printserver-bootstrap.env not found: $ENV_FILE" >&2; exit 1; }

set +u
source "$SHARED_ENV"
source "$ENV_FILE"
set -u

# ── Config ────────────────────────────────────────────────────────────────────
INCUS_STORAGE_POOL="${INCUS_STORAGE_POOL:-incus-pool}"
SOURCE_IMAGE="${SOURCE_IMAGE:-images:ubuntu/26.04/cloud}"
IMAGE_ALIAS="printserver-base"
BUILDER_NAME="printserver-image-builder"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# ── Validate ──────────────────────────────────────────────────────────────────
[[ -z "${INCUS_REMOTE:-}" ]] && die "INCUS_REMOTE is not set in $ENV_FILE"

if ! incus remote list --format=csv | cut -d, -f1 | sed 's/ (current)$//' | grep -qx "$INCUS_REMOTE"; then
  die "Incus remote '${INCUS_REMOTE}' not found. Add with: incus remote add ${INCUS_REMOTE} https://<host>:8443"
fi

# ── Switch remote ─────────────────────────────────────────────────────────────
PREV_REMOTE=$(incus remote get-default)
if [[ "$PREV_REMOTE" != "$INCUS_REMOTE" ]]; then
  log "Switching Incus remote to ${INCUS_REMOTE}..."
  incus remote switch "$INCUS_REMOTE"
fi

# ── Check for existing image ──────────────────────────────────────────────────
if incus image info "$IMAGE_ALIAS" &>/dev/null; then
  if [[ "$FORCE" == true ]]; then
    log "Deleting existing image '${IMAGE_ALIAS}' (--force)..."
    incus image delete "$IMAGE_ALIAS"
  else
    log "Image '${IMAGE_ALIAS}' already exists. Use --force to rebuild."
    log "Built: $(incus image info "$IMAGE_ALIAS" | grep '^Created:' || true)"
    exit 0
  fi
fi

# ── Clean up any stale builder from a previous failed run ─────────────────────
if incus info "$BUILDER_NAME" &>/dev/null; then
  log "Removing stale builder container from a previous run..."
  incus delete --force "$BUILDER_NAME"
fi

# ── Launch builder container ──────────────────────────────────────────────────
log "Launching builder container from ${SOURCE_IMAGE}..."
incus launch "$SOURCE_IMAGE" "$BUILDER_NAME" \
  --storage "$INCUS_STORAGE_POOL"

# Wait for cloud-init on the builder. The ubuntu cloud image runs a default
# package update on first boot, which can take several minutes.
# We must wait before running apt-get to avoid a dpkg lock conflict.
log "Waiting for builder cloud-init (default image may run package update — be patient)..."
WAIT=0
until incus exec "$BUILDER_NAME" -- cloud-init status 2>/dev/null \
    | grep -qE "status: (done|error)"; do
  sleep 5
  WAIT=$((WAIT + 5))
  (( WAIT % 30 == 0 )) && log "  ...${WAIT}s elapsed"
  [[ $WAIT -ge 300 ]] && die "Builder container cloud-init did not complete after 300s"
done
log "Builder ready."

# ── Install packages ──────────────────────────────────────────────────────────
log "Running apt-get update + upgrade + install (this takes a few minutes)..."
incus exec "$BUILDER_NAME" -- bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get upgrade -y -q
  apt-get install -y -q \
    cups \
    cups-client \
    cups-filters \
    printer-driver-all \
    avahi-daemon \
    libnss-mdns \
    usbutils \
    linux-tools-common \
    linux-tools-generic \
    nginx \
    certbot \
    python3-certbot-nginx
  apt-get clean
  rm -rf /var/lib/apt/lists/*
'
log "Packages installed."

# ── Stop builder and publish image ────────────────────────────────────────────
log "Stopping builder container..."
incus stop "$BUILDER_NAME"

log "Publishing image as '${IMAGE_ALIAS}'..."
incus publish "$BUILDER_NAME" \
  --alias "$IMAGE_ALIAS" \
  -p "description=printserver base (ubuntu 26.04 + cups + printer-driver-all + nginx)" \
  -p "os=ubuntu" \
  -p "release=26.04"

log "Deleting builder container..."
incus delete "$BUILDER_NAME"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════════"
echo "  Image built: ${IMAGE_ALIAS}"
echo "  Remote     : ${INCUS_REMOTE}"
echo "  Based on   : ${SOURCE_IMAGE}"
echo
echo "  printserver-bootstrap.sh will use this image automatically."
echo "  To use a different image, set INCUS_IMAGE in printserver-bootstrap.env."
echo "══════════════════════════════════════════════════════════════════"
