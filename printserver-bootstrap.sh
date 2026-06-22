#!/usr/bin/env bash
# =============================================================================
# printserver-bootstrap.sh
#
# Provisions the printserver LXC container via the Incus remote API.
# Runs from the management machine (pangolin).
#
# Usage:
#   cp printserver-bootstrap.env.example printserver-bootstrap.env
#   $EDITOR printserver-bootstrap.env
#   chmod 600 printserver-bootstrap.env
#   ./printserver-bootstrap.sh [--reprovision] [--help]
#
# Options:
#   --reprovision   Destroy existing container and reprovision from scratch.
#                   Default behaviour if container exists is to abort safely.
#   --help          Show this help and exit
#
# Prerequisites (management machine):
#   incus CLI installed locally with a remote named $INCUS_REMOTE:
#     incus remote add <name> https://<host>:8443 --accept-certificate
#   SSH config entry matching $INCUS_REMOTE for host-level operations
#   (installing the nightly systemd timer)
#
# What this script does:
#   1. Validate INCUS_REMOTE exists; switch to it if not already current
#   2. Create MACVLAN network (macvlan-eno1) if not present
#   3. Create/update Incus profile (printserver)
#   4. Generate cloud-init user-data from .env values
#   5. Launch LXC container with cloud-init user-data via Incus API
#   6. Wait for cloud-init to finish
#   7. Wait for usbip-attach to succeed
#   8. Auto-register all discovered USB printers in CUPS via lpadmin
#   9. Bake registered lpadmin commands back into cloud-init for nightly
#      reprovisioning
#  10. Push cloud-init to Incus host for nightly timer consumption
#  11. Install nightly reprovision systemd timer on Incus host
# =============================================================================

set -euo pipefail
set -x  # debug — remove when stable

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REMOTE_CLOUD_INIT_DIR="/var/local/printserver-bootstrap/cloud-init"
readonly CONTAINER_NAME="printserver"
readonly NETWORK_NAME="macvlan-eno1"
readonly PROFILE_NAME="printserver"

# ── Option defaults ───────────────────────────────────────────────────────────
ENV_FILE="${SCRIPT_DIR}/printserver-bootstrap.env"
REPROVISION=false

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  sed -n '/^# ={10}/,/^# ={10}/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reprovision) REPROVISION=true; shift ;;
    --env)         ENV_FILE="$2";    shift 2 ;;
    --help|-h)     usage ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Load shared.env ───────────────────────────────────────────────────────────
SHARED_ENV="${SCRIPT_DIR}/shared.env"
[[ -f "$SHARED_ENV" ]] || {
  echo "ERROR: shared.env not found: $SHARED_ENV" >&2
  echo "       Copy shared.env.example to shared.env and fill it in." >&2
  exit 1
}
SHARED_PERMS=$(stat -c '%a' "$SHARED_ENV")
if [[ "$SHARED_PERMS" != "600" && "$SHARED_PERMS" != "400" ]]; then
  echo "WARNING: $SHARED_ENV has permissions ${SHARED_PERMS}. Recommend: chmod 600 $SHARED_ENV" >&2
fi
set +u
# shellcheck source=/dev/null
source "$SHARED_ENV"
set -u

# ── Load .env ─────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: .env file not found: $ENV_FILE" >&2
  echo "       Copy printserver-bootstrap.env.example and fill it in." >&2
  exit 1
}

ENV_PERMS=$(stat -c '%a' "$ENV_FILE")
if [[ "$ENV_PERMS" != "600" && "$ENV_PERMS" != "400" ]]; then
  echo "WARNING: $ENV_FILE has permissions ${ENV_PERMS}. Recommend: chmod 600 $ENV_FILE" >&2
fi

set +u
# shellcheck source=/dev/null
source "$ENV_FILE"
set -u

# Apply defaults for optional vars
CONTAINER_HOSTNAME="${CONTAINER_HOSTNAME:-printserver}"
CONTAINER_FQDN="${CONTAINER_FQDN:-printserver.ancapistan.io}"
INCUS_STORAGE_POOL="${INCUS_STORAGE_POOL:-incus-pool}"
PARENT_IFACE="${PARENT_IFACE:-eno1}"
MAC_ADDRESS="${MAC_ADDRESS:-3e:db:83:86:db:24}"
# Shared vars — defaults applied here so printserver-bootstrap.env can override
SSH_PUBKEYS="${SSH_PUBKEYS:-}"
LAN_SUBNET="${LAN_SUBNET:-192.168.4.0/22}"
USBPROXY_HOST="${USBPROXY_HOST:-usbproxy.ancapistan.io}"
IMAGE="${INCUS_IMAGE:-local:printserver-base}"
ENABLE_LETSENCRYPT="${ENABLE_LETSENCRYPT:-false}"
LE_EMAIL="${LE_EMAIL:-}"
NAMECHEAP_API_USER="${NAMECHEAP_API_USER:-}"
NAMECHEAP_API_KEY="${NAMECHEAP_API_KEY:-}"
NAMECHEAP_CLIENT_IP="${NAMECHEAP_CLIENT_IP:-}"
LE_VOLUME_NAME="printserver-letsencrypt"
SSH_CIDRS="${SSH_CIDRS:-}"
PRINT_CIDRS="${PRINT_CIDRS:-${LAN_SUBNET}}"

# Build YAML-formatted pubkey list for cloud-init (6-space indent)
SSH_PUBKEYS_YAML=""
while IFS= read -r key; do
  [[ -z "${key// }" ]] && continue
  SSH_PUBKEYS_YAML+="      - ${key}"$'\n'
done <<< "$SSH_PUBKEYS"
SSH_PUBKEYS_YAML="${SSH_PUBKEYS_YAML%$'\n'}"

# Build CUPS Allow from lines — two indent levels needed:
#   CUPS_ALLOW_LOCATION: 8-space indent for <Location> blocks
#   CUPS_ALLOW_LIMIT:   10-space indent for <Limit> blocks inside <Policy>
# Both are referenced at column 0 in the heredoc so bash expands all lines
# with the correct indent already embedded in the variable content.
CUPS_ALLOW_LOCATION=""
CUPS_ALLOW_LIMIT=""
for _cidr in $PRINT_CIDRS; do
  CUPS_ALLOW_LOCATION+="        Allow from ${_cidr}"$'\n'
  CUPS_ALLOW_LIMIT+="          Allow from ${_cidr}"$'\n'
done
CUPS_ALLOW_LOCATION="${CUPS_ALLOW_LOCATION%$'\n'}"
CUPS_ALLOW_LIMIT="${CUPS_ALLOW_LIMIT%$'\n'}"

# Build UFW rules for cloud-init from CIDR lists
UFW_PRINT_RULES=""
for _cidr in $PRINT_CIDRS; do
  UFW_PRINT_RULES+="  - ufw allow from '${_cidr}' to any port 631 proto tcp"$'\n'
done
if [[ -z "$SSH_CIDRS" ]]; then
  UFW_SSH_RULES="  - ufw allow OpenSSH"$'\n'
else
  UFW_SSH_RULES=""
  for _cidr in $SSH_CIDRS; do
    UFW_SSH_RULES+="  - ufw allow from '${_cidr}' to any port 22 proto tcp"$'\n'
  done
fi
UFW_PRINT_RULES="${UFW_PRINT_RULES%$'\n'}"
UFW_SSH_RULES="${UFW_SSH_RULES%$'\n'}"

# ── Validation ────────────────────────────────────────────────────────────────
[[ -z "$SSH_PUBKEYS" ]] && { echo "ERROR: SSH_PUBKEYS is not set in $SHARED_ENV" >&2; exit 1; }

if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then
  [[ -z "$LE_EMAIL" ]]             && { echo "ERROR: LE_EMAIL must be set in $ENV_FILE when ENABLE_LETSENCRYPT=true" >&2; exit 1; }
  [[ -z "$NAMECHEAP_API_USER" ]]  && { echo "ERROR: NAMECHEAP_API_USER must be set in $ENV_FILE when ENABLE_LETSENCRYPT=true" >&2; exit 1; }
  [[ -z "$NAMECHEAP_API_KEY" ]]   && { echo "ERROR: NAMECHEAP_API_KEY must be set in $ENV_FILE when ENABLE_LETSENCRYPT=true" >&2; exit 1; }
  [[ -z "$NAMECHEAP_CLIENT_IP" ]] && { echo "ERROR: NAMECHEAP_CLIENT_IP must be set in $ENV_FILE when ENABLE_LETSENCRYPT=true" >&2; exit 1; }
fi

if [[ -z "${INCUS_REMOTE:-}" ]]; then
  echo "ERROR: INCUS_REMOTE is not set in $ENV_FILE" >&2
  echo "       Add: INCUS_REMOTE=<name>  (must exist in: incus remote list)" >&2
  exit 1
fi

if ! incus remote list --format=csv | cut -d, -f1 | sed 's/ (current)$//' | grep -qx "$INCUS_REMOTE"; then
  echo "ERROR: Incus remote '${INCUS_REMOTE}' not found." >&2
  echo "       Add it with: incus remote add ${INCUS_REMOTE} https://<host>:8443" >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Run a command on the Incus host via SSH (host-level operations only)
remote() { ssh "$INCUS_REMOTE" "$@"; }

# Push a local file to the Incus host via SSH
push_file() {
  local local_path="$1" remote_path="$2"
  ssh "$INCUS_REMOTE" mkdir -p -- "$(dirname "$remote_path")"
  scp -q "$local_path" "${INCUS_REMOTE}:${remote_path}"
}

# ── Phase 1: Validate and switch to Incus remote ─────────────────────────────

# Ensure the ubuntu: image remote exists (Canonical cloud images, includes cloud-init)
if ! incus remote list --format=csv | cut -d, -f1 | sed 's/ (current)$//' | grep -qx "ubuntu"; then
  log "Adding ubuntu image remote (Canonical cloud images)..."
  incus remote add ubuntu https://cloud-images.ubuntu.com/releases \
    --protocol=simplestreams --public
fi

log "Validating Incus remote ${INCUS_REMOTE}..."
PREV_REMOTE=$(incus remote get-default)
if [[ "$PREV_REMOTE" != "$INCUS_REMOTE" ]]; then
  log "Switching Incus remote from '${PREV_REMOTE}' to '${INCUS_REMOTE}'..."
  incus remote switch "$INCUS_REMOTE"
fi
log "Using Incus remote: ${INCUS_REMOTE}"

# Verify the base image exists; if not, build it automatically.
if ! incus image info "$IMAGE" &>/dev/null; then
  log "Base image '${IMAGE}' not found — invoking printserver-image-build.sh..."
  if [[ -x "${SCRIPT_DIR}/printserver-image-build.sh" ]]; then
    "${SCRIPT_DIR}/printserver-image-build.sh"
  else
    die "Base image '${IMAGE}' not found and ${SCRIPT_DIR}/printserver-image-build.sh is missing or not executable."
  fi
fi

# ── Phase 2: Stop nightly timer and delete existing container (reprovision) ───
# Stop the nightly reprovision timer on the Incus host before touching the
# container. Without this, the timer could fire between the delete and the
# new launch, claim the same MAC address, and race us to the container name.
# Phase 11 re-enables the timer unconditionally once the new container is up.
log "Stopping nightly reprovision timer on ${INCUS_REMOTE} (if present)..."
ssh "$INCUS_REMOTE" systemctl stop printserver-reprovision.timer 2>/dev/null || true

if [[ "$REPROVISION" == true ]]; then
  if incus info "$CONTAINER_NAME" &>/dev/null; then
    log "Destroying existing container ${CONTAINER_NAME}..."
    incus delete --force "$CONTAINER_NAME"
    log "Container destroyed."
  fi
  if incus profile show "$PROFILE_NAME" &>/dev/null; then
    log "Deleting existing profile ${PROFILE_NAME}..."
    incus profile delete "$PROFILE_NAME"
    log "Profile deleted."
  fi
else
  if incus info "$CONTAINER_NAME" &>/dev/null; then
    die "Container ${CONTAINER_NAME} already exists. Use --reprovision to destroy and recreate."
  fi
fi

# ── Phase 3: Create MACVLAN network ──────────────────────────────────────────
log "Checking MACVLAN network ${NETWORK_NAME}..."
if incus network show "$NETWORK_NAME" &>/dev/null; then
  if [[ "$REPROVISION" == true ]]; then
    log "Deleting existing network ${NETWORK_NAME} for reprovision..."
    incus network delete "$NETWORK_NAME"
    log "Network deleted."
  else
    log "Network ${NETWORK_NAME} already exists — skipping creation."
  fi
fi

if ! incus network show "$NETWORK_NAME" &>/dev/null; then
  log "Creating network ${NETWORK_NAME}..."
  incus network create "$NETWORK_NAME" --type=macvlan "parent=$PARENT_IFACE"
  log "Network created."
fi

# ── Phase 3.5: Ensure persistent Let's Encrypt certificate volume ─────────────
# The volume outlives individual container runs so certs survive nightly
# reprovisioning. Created once; never deleted on --reprovision.
if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then
  if incus storage volume show "$INCUS_STORAGE_POOL" "$LE_VOLUME_NAME" &>/dev/null; then
    log "Certificate volume '${LE_VOLUME_NAME}' already exists — certs will be reused."
  else
    log "Creating persistent Let's Encrypt certificate volume '${LE_VOLUME_NAME}'..."
    incus storage volume create "$INCUS_STORAGE_POOL" "$LE_VOLUME_NAME"
    log "Certificate volume created."
  fi
fi

# ── Phase 4: Create/update Incus profile ─────────────────────────────────────
log "Applying Incus profile ${PROFILE_NAME}..."
PROFILE_YAML=$(cat <<EOF
config:
  limits.cpu: "2"
  limits.memory: 2GiB
  security.privileged: "true"
description: Print server container profile
devices:
  eth0:
    type: nic
    network: ${NETWORK_NAME}
    hwaddr: ${MAC_ADDRESS}
  kmsg:
    type: unix-char
    path: /dev/kmsg
    source: /dev/kmsg
$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
  letsencrypt:
    type: disk
    pool: ${INCUS_STORAGE_POOL}
    source: ${LE_VOLUME_NAME}
    path: /etc/letsencrypt
LEEOF
fi)
  root:
    type: disk
    path: /
    pool: ${INCUS_STORAGE_POOL}
    size: 10GiB
name: ${PROFILE_NAME}
EOF
)

if incus profile show "$PROFILE_NAME" &>/dev/null; then
  log "Profile ${PROFILE_NAME} exists — updating..."
else
  log "Creating profile ${PROFILE_NAME}..."
  incus profile create "$PROFILE_NAME"
fi
echo "$PROFILE_YAML" | incus profile edit "$PROFILE_NAME"
log "Profile applied."

# ── Phase 5: Generate cloud-init user-data ────────────────────────────────────
log "Generating cloud-init user-data..."

INSTANCE_ID="${CONTAINER_NAME}-$(date +%Y%m%d%H%M%S)"
log "Instance ID: ${INSTANCE_ID}"

CLOUD_INIT=$(cat <<EOF
#cloud-config

network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true

hostname: ${CONTAINER_HOSTNAME}
fqdn: ${CONTAINER_FQDN}
manage_etc_hosts: true

# avahi-daemon is pre-installed in the base image and starts on container boot
# with Ubuntu's default config. Stop it before write_files so it doesn't run
# with use-ipv6=yes even briefly; runcmd restarts it with our custom config.
bootcmd:
  - systemctl stop avahi-daemon.service avahi-daemon.socket || true
$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
  # /etc/letsencrypt is a persistent ZFS volume — may be empty on first run.
  - mkdir -p /etc/letsencrypt/renewal-hooks/deploy
LEEOF
fi)

users:
  - name: ubuntu
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
${SSH_PUBKEYS_YAML}

ssh_pwauth: false

write_files:
  # USB/IP client kernel modules
  - path: /etc/modules-load.d/usbip.conf
    content: |
      usbip-core
      vhci-hcd
    owner: root:root
    permissions: '0644'

  # Load USB/IP modules before attach
  - path: /etc/systemd/system/usbip-load-modules.service
    content: |
      [Unit]
      Description=Load USB/IP client kernel modules
      After=local-fs.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/sh -c 'lsmod | grep -q usbip_core || modprobe usbip-core'
      ExecStart=/bin/sh -c 'lsmod | grep -q vhci_hcd || modprobe vhci-hcd'

      [Install]
      WantedBy=multi-user.target
    owner: root:root
    permissions: '0644'

  # Auto-attach all USB devices exported by the usbproxy Pi.
  # Discovers bus IDs at runtime via usbip list -r — no hardcoded config needed.
  - path: /usr/local/bin/usbip-attach-all
    content: |
      #!/bin/bash
      HOST="${USBPROXY_HOST}"
      busids=\$(usbip list -r "\$HOST" 2>/dev/null \
        | grep -E '^ +[0-9]+-[0-9.]+:' | awk '{print \$1}' | tr -d ':')
      if [ -z "\$busids" ]; then
        echo "usbip-attach-all: no devices exported by \$HOST — is usbipd running on the Pi?" \
          | systemd-cat -t usbip-attach -p warning
        exit 0
      fi
      for busid in \$busids; do
        usbip attach -r "\$HOST" -b "\$busid" || \
          echo "usbip-attach-all: failed to attach \$busid from \$HOST" \
            | systemd-cat -t usbip-attach -p warning
      done
    owner: root:root
    permissions: '0755'

  - path: /etc/systemd/system/usbip-attach.service
    content: |
      [Unit]
      Description=USB/IP Attach All Devices from usbproxy
      After=network.target usbip-load-modules.service
      Requires=usbip-load-modules.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/usbip-attach-all

      [Install]
      WantedBy=multi-user.target
    owner: root:root
    permissions: '0644'

  # CUPS configuration
  - path: /etc/cups/cupsd.conf
    content: |
      LogLevel warn
      PageLogFormat
      MaxLogSize 0
      ErrorPolicy retry-job

$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
      ServerName ${CONTAINER_FQDN}
      Listen /run/cups/cups.sock
      Listen 127.0.0.1:631
LEEOF
else cat <<LEEOF
      Listen /run/cups/cups.sock
      Listen 0.0.0.0:631
LEEOF
fi)

      Browsing On
      BrowseLocalProtocols dnssd

      DefaultAuthType Basic
      WebInterface Yes

      <Location />
        Order allow,deny
        Allow from 127.0.0.1
${CUPS_ALLOW_LOCATION}
      </Location>

      <Location /admin>
        Order allow,deny
        Allow from 127.0.0.1
${CUPS_ALLOW_LOCATION}
      </Location>

      <Location /admin/conf>
        AuthType Default
        Require user @SYSTEM
        Order allow,deny
        Allow from 127.0.0.1
${CUPS_ALLOW_LOCATION}
      </Location>

      <Policy default>
        JobPrivateAccess default
        JobPrivateValues default
        SubscriptionPrivateAccess default
        SubscriptionPrivateValues default
        <Limit Create-Job Print-Job Print-URI Validate-Job>
          Order allow,deny
${CUPS_ALLOW_LIMIT}
        </Limit>
        <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscriptions Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
          Require user @OWNER @SYSTEM
          Order allow,deny
${CUPS_ALLOW_LIMIT}
        </Limit>
        <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
          AuthType Default
          Require user @SYSTEM
          Order allow,deny
${CUPS_ALLOW_LIMIT}
        </Limit>
        <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After CUPS-Accept-Jobs CUPS-Reject-Jobs>
          AuthType Default
          Require user @SYSTEM
          Order allow,deny
${CUPS_ALLOW_LIMIT}
        </Limit>
        <Limit Cancel-Job CUPS-Authenticate-Job>
          Require user @OWNER @SYSTEM
          Order allow,deny
${CUPS_ALLOW_LIMIT}
        </Limit>
        <Limit All>
          Order allow,deny
${CUPS_ALLOW_LIMIT}
        </Limit>
      </Policy>
    owner: root:root
    permissions: '0640'

$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
  # Namecheap DNS-01 credentials for certbot (DNS-01 requires no open ports)
  - path: /etc/ssl/certbot-namecheap.ini
    content: |
      certbot_dns_namecheap:dns_namecheap_username = ${NAMECHEAP_API_USER}
      certbot_dns_namecheap:dns_namecheap_api_key = ${NAMECHEAP_API_KEY}
      certbot_dns_namecheap:dns_namecheap_client_ip = ${NAMECHEAP_CLIENT_IP}
    owner: root:root
    permissions: '0600'

  # nginx: HTTPS — TLS termination + reverse proxy to CUPS on localhost
  - path: /etc/nginx/sites-available/cups-ssl
    content: |
      server {
          listen 443 ssl;
          server_name ${CONTAINER_FQDN};
          ssl_certificate     /etc/letsencrypt/live/${CONTAINER_FQDN}/fullchain.pem;
          ssl_certificate_key /etc/letsencrypt/live/${CONTAINER_FQDN}/privkey.pem;
          ssl_protocols       TLSv1.2 TLSv1.3;
          ssl_prefer_server_ciphers off;
          location / {
              proxy_pass         http://127.0.0.1:631;
              proxy_set_header   Host              \$host;
              proxy_set_header   X-Real-IP         \$remote_addr;
              proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
              proxy_set_header   X-Forwarded-Proto \$scheme;
          }
      }
    owner: root:root
    permissions: '0644'

  # certbot deploy hook — reloads nginx after each successful cert renewal
  - path: /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
    content: |
      #!/bin/bash
      systemctl reload nginx
    owner: root:root
    permissions: '0755'

LEEOF
fi)
  # Avahi configuration
  - path: /etc/avahi/avahi-daemon.conf
    content: |
      [server]
      host-name=${CONTAINER_HOSTNAME}
      domain-name=ancapistan.io
      use-ipv4=yes
      use-ipv6=no
      allow-interfaces=eth0
      ratelimit-interval-usec=1000000
      ratelimit-burst=1000

      [wide-area]
      enable-wide-area=yes

      [publish]
      publish-addresses=yes
      publish-hinfo=yes
      publish-workstation=no
      publish-domain=yes

      [reflector]
      enable-reflector=no

      [rlimits]
    owner: root:root
    permissions: '0644'

  # Printer auto-registration script — run at end of runcmd and on nightly
  # reprovision. Waits for USB devices to appear then registers all found
  # USB printers in CUPS using driverless IPP (lpadmin -m everywhere).
  - path: /usr/local/bin/register-printers
    content: |
      #!/bin/bash
      set -euo pipefail
      set -x  # debug — remove when stable
      log() { echo "[\$(date '+%H:%M:%S')] register-printers: \$*"; }

      log "Waiting for USB printer devices..."
      WAIT=0
      until lpinfo -v 2>/dev/null | grep -q "^direct usb://" || [ "\$WAIT" -ge 60 ]; do
        sleep 3
        WAIT=\$((WAIT + 3))
      done

      if ! lpinfo -v 2>/dev/null | grep -q "^direct usb://"; then
        log "WARNING: No USB printers found after \${WAIT}s — skipping registration."
        exit 0
      fi

      log "Removing existing USB printer registrations..."
      for p in \$(lpstat -p 2>/dev/null | awk '/^printer/{print \$2}'); do
        URI=\$(lpstat -v "\$p" 2>/dev/null | awk '{print \$3}' | tr -d ':')
        if [[ "\$URI" == usb://* ]]; then
          log "Removing \$p"
          lpadmin -x "\$p" 2>/dev/null || true
        fi
      done

      log "Registering discovered USB printers..."
      FIRST=""
      INDEX=1
      while IFS= read -r line; do
        URI=\$(echo "\$line" | awk '{print \$2}')
        # Derive a clean printer name from the URI
        # e.g. usb://Canon/PIXMA%20MX490?serial=XXX -> Canon_PIXMA_MX490
        NAME=\$(echo "\$URI" | sed 's|usb://||;s|/|_|g;s|?.*||;s|%20|_|g;s|[^A-Za-z0-9_]||g')
        NAME="Printer_\${INDEX}_\${NAME}"
        log "Registering \$NAME -> \$URI"
        lpadmin -p "\$NAME" -E \
          -v "\$URI" \
          -m everywhere \
          -o printer-is-shared=true \
          2>/dev/null || log "WARNING: lpadmin failed for \$NAME"
        [[ -z "\$FIRST" ]] && FIRST="\$NAME"
        INDEX=\$((INDEX + 1))
      done < <(lpinfo -v 2>/dev/null | grep "^direct usb://")

      if [[ -n "\$FIRST" ]]; then
        log "Setting default printer: \$FIRST"
        lpoptions -d "\$FIRST"
      fi

      log "Registration complete. Registered \$((INDEX - 1)) printer(s)."
    owner: root:root
    permissions: '0755'

runcmd:
  - systemctl mask systemd-udev-trigger systemd-udevd
  - sh -c 'lsmod | grep -q usbip_core || modprobe usbip-core'
  - sh -c 'lsmod | grep -q vhci_hcd || modprobe vhci-hcd'
  # Resolve kernel-versioned usbip binary
  - |
    USBIP=\$(find /usr/lib/linux-tools-* -name usbip 2>/dev/null | head -1)
    if [ -n "\$USBIP" ]; then
      ln -sf "\$USBIP" /usr/local/bin/usbip
    else
      echo "WARNING: usbip not found" >&2
    fi
  - systemctl daemon-reload
  - systemctl enable usbip-load-modules
  - systemctl enable usbip-attach
  - systemctl enable avahi-daemon
  - systemctl enable cups
  - systemctl start usbip-load-modules
  - systemctl start usbip-attach || true
  - systemctl restart avahi-daemon
  - systemctl start cups
  - usermod -aG lpadmin ubuntu
  - systemctl restart cups
$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
  # ── nginx + Let's Encrypt (DNS-01 / Namecheap) ─────────────────────────────
  # DNS-01 validates via the Namecheap XML API — no open inbound ports needed.
  - rm -f /etc/nginx/sites-enabled/default
  # Issue cert if not already present on the persistent certificate volume
  - |
    if [[ ! -f /etc/letsencrypt/live/${CONTAINER_FQDN}/fullchain.pem ]]; then
      certbot certonly --dns-namecheap \
        --dns-namecheap-credentials /etc/ssl/certbot-namecheap.ini \
        -d ${CONTAINER_FQDN} --email ${LE_EMAIL} --agree-tos --non-interactive
    fi
  - ln -sf /etc/nginx/sites-available/cups-ssl /etc/nginx/sites-enabled/cups-ssl
  - systemctl enable nginx
  - systemctl start nginx
  - ufw allow 443/tcp
LEEOF
fi)
  # Firewall — idempotent; safe to re-run on every reprovision
${UFW_PRINT_RULES}
${UFW_SSH_RULES}
  - ufw --force enable

  # Auto-register USB printers — best-effort; succeeds even if Pi isn't connected yet
  - /usr/local/bin/register-printers || true

final_message: |
  printserver provisioning complete.
$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
  CUPS web UI: https://${CONTAINER_FQDN}/
LEEOF
else cat <<LEEOF
  CUPS web UI: http://${CONTAINER_FQDN}:631
LEEOF
fi)
  mDNS: ${CONTAINER_FQDN}
  Provisioned at: \$TIMESTAMP
EOF
)

mkdir -p "${SCRIPT_DIR}/cloud-init/printserver-bootstrap"
echo "$CLOUD_INIT" > "${SCRIPT_DIR}/cloud-init/printserver-bootstrap/cloud-init.yaml"
log "Cloud-init written to cloud-init/printserver-bootstrap/cloud-init.yaml"

cat > "${SCRIPT_DIR}/cloud-init/printserver-bootstrap/meta-data.yaml" <<METAEOF
instance-id: ${INSTANCE_ID}
local-hostname: ${CONTAINER_HOSTNAME}
METAEOF

# ── Phase 6: Ensure usbip kernel modules are available on Incus host ─────────
# Modules must be present before the container launches — cloud-init runs
# modprobe during first boot and /lib/modules is a bind mount from the host.
log "Ensuring usbip kernel modules are installed on ${INCUS_REMOTE}..."
ssh "$INCUS_REMOTE" sudo bash <<'USBIP_EOF'
set -euo pipefail
depmod -a
modprobe usbip-core
modprobe vhci-hcd
echo "usbip-core" >  /etc/modules-load.d/usbip.conf
echo "vhci-hcd"   >> /etc/modules-load.d/usbip.conf
echo "usbip modules loaded and configured for persistent load."
USBIP_EOF
log "usbip modules ready on host."

# ── Phase 7: Launch container ─────────────────────────────────────────────────
log "Launching container ${CONTAINER_NAME}..."
incus launch "$IMAGE" "$CONTAINER_NAME" \
  --profile "$PROFILE_NAME" \
  --config "user.user-data=$(cat "${SCRIPT_DIR}/cloud-init/printserver-bootstrap/cloud-init.yaml")"
log "Container launched."

# ── Phase 7: Wait for cloud-init ──────────────────────────────────────────────
log "Waiting for cloud-init to complete (this may take several minutes)..."

# Stream the container journal so cloud-init progress is visible.
# Retry briefly — journald may not be ready immediately after launch.
JOURNAL_PID=""
for _i in {1..10}; do
  if incus exec "$CONTAINER_NAME" -- journalctl -f --no-hostname --no-pager \
      -o short-monotonic 2>/dev/null &
  then
    JOURNAL_PID=$!
    break
  fi
  sleep 2
done
[[ -z "$JOURNAL_PID" ]] && log "WARNING: could not attach journal stream — polling only."

WAIT=0
until incus exec "$CONTAINER_NAME" -- \
    cloud-init status 2>/dev/null | grep -qE "status: (done|error)"; do
  sleep 10
  WAIT=$((WAIT + 10))
  if (( WAIT % 60 == 0 )); then
    log "Still waiting for cloud-init... (${WAIT}s elapsed — package install + upgrade can take 15-20 min)"
  fi
  if [[ $WAIT -ge 1800 ]]; then
    [[ -n "$JOURNAL_PID" ]] && kill "$JOURNAL_PID" 2>/dev/null || true
    die "cloud-init did not complete after 1800s. Check: incus exec ${CONTAINER_NAME} -- cloud-init status --long"
  fi
done

[[ -n "$JOURNAL_PID" ]] && kill "$JOURNAL_PID" 2>/dev/null || true
wait "$JOURNAL_PID" 2>/dev/null || true

CI_STATUS=$(incus exec "$CONTAINER_NAME" -- cloud-init status 2>/dev/null | grep -oE 'status: \S+' || true)
if [[ "$CI_STATUS" == "status: error" ]]; then
  log "WARNING: cloud-init finished with errors — check: incus exec ${CONTAINER_NAME} -- cloud-init status --long"
else
  log "cloud-init complete."
fi

# ── Phase 8: Wait for USB printers ───────────────────────────────────────────
log "Waiting for USB printers to appear in container..."
{
  WAIT=0
  until incus exec "$CONTAINER_NAME" -- \
      lpinfo -v 2>/dev/null | grep -q "^direct usb://"; do
    sleep 5
    WAIT=$((WAIT + 5))
    log "  ...${WAIT}s elapsed"
    if [[ $WAIT -ge 120 ]]; then
      log "WARNING: USB printers not found after 120s — skipping auto-registration."
      log "         Connect printers to usbproxy and run:"
      log "         incus exec ${CONTAINER_NAME} -- /usr/local/bin/register-printers"
      break
    fi
  done

  # ── Phase 9: Bake lpadmin commands into cloud-init for nightly reprovision ───
  if incus exec "$CONTAINER_NAME" -- \
      lpinfo -v 2>/dev/null | grep -q "^direct usb://"; then
    log "Printers found — baking lpadmin commands into cloud-init for nightly reprovision..."

    LPADMIN_CMDS=$(incus exec "$CONTAINER_NAME" -- bash <<'LPADMIN_EOF'
INDEX=1
while IFS= read -r line; do
  URI=$(echo "$line" | awk '{print $2}')
  NAME=$(echo "$URI" | sed 's|usb://||;s|/|_|g;s|?.*||;s|%20|_|g;s|[^A-Za-z0-9_]||g')
  NAME="Printer_${INDEX}_${NAME}"
  echo "  - lpadmin -p ${NAME} -E -v ${URI} -m everywhere -o printer-is-shared=true"
  INDEX=$((INDEX + 1))
done < <(lpinfo -v 2>/dev/null | grep '^direct usb://')
FIRST=$(lpstat -d 2>/dev/null | awk '{print $NF}')
[ -n "$FIRST" ] && echo "  - lpoptions -d ${FIRST}"
LPADMIN_EOF
)

    register_block=$'  # Auto-register USB printers — best-effort; succeeds even if Pi isn'\''t connected yet\n  - /usr/local/bin/register-printers || true'
    baked_block=$'  # Auto-register USB printers (baked lpadmin from first provision)\n'"${LPADMIN_CMDS}"
    UPDATED_CLOUD_INIT="${CLOUD_INIT//$register_block/$baked_block}"

    echo "$UPDATED_CLOUD_INIT" > "${SCRIPT_DIR}/cloud-init/printserver-bootstrap/cloud-init.yaml"
    log "Cloud-init updated with printer registration."
  fi
}

# ── Phase 10: Push cloud-init to Incus host (for nightly timer) ───────────────
log "Pushing cloud-init to ${INCUS_REMOTE}:${REMOTE_CLOUD_INIT_DIR}..."
push_file \
  "${SCRIPT_DIR}/cloud-init/printserver-bootstrap/cloud-init.yaml" \
  "${REMOTE_CLOUD_INIT_DIR}/cloud-init.yaml"
log "Cloud-init pushed."

# ── Phase 11: Install nightly reprovision timer on Incus host ─────────────────
log "Installing nightly reprovision timer on ${INCUS_REMOTE}..."

read -r -d '' launch_script <<'LAUNCH_EOF' || true
#!/bin/bash
set -euo pipefail
set -x  # debug -- remove when stable

CONTAINER_NAME="__CONTAINER_NAME__"
PROFILE_NAME="__PROFILE_NAME__"
IMAGE="__IMAGE__"
CLOUD_INIT_PATH="__CLOUD_INIT_PATH__"
PI_HOST="__PI_HOST__"
PI_PORT="3240"
PI_TIMEOUT=10

echo "[$(date)] Checking Pi USB/IP health at ${PI_HOST}:${PI_PORT}..."
if ! timeout "$PI_TIMEOUT" bash -c \
    ">/dev/tcp/${PI_HOST}/${PI_PORT}" 2>/dev/null; then
  echo "[$(date)] ERROR: Pi not reachable -- aborting reprovision." >&2
  echo "printserver-launch: Pi health check failed; reprovision skipped." \
    | systemd-cat -t printserver-launch -p warning
  exit 1
fi

echo "[$(date)] Pi healthy. Destroying ${CONTAINER_NAME}..."
incus delete --force "$CONTAINER_NAME" 2>/dev/null || true

echo "[$(date)] Launching ${CONTAINER_NAME}..."
incus launch "$IMAGE" "$CONTAINER_NAME" \
  --profile "$PROFILE_NAME" \
  --config "user.user-data=$(cat "$CLOUD_INIT_PATH")"

echo "[$(date)] ${CONTAINER_NAME} launched."
LAUNCH_EOF

launch_script="${launch_script//__CONTAINER_NAME__/${CONTAINER_NAME}}"
launch_script="${launch_script//__PROFILE_NAME__/${PROFILE_NAME}}"
launch_script="${launch_script//__IMAGE__/${IMAGE}}"
launch_script="${launch_script//__CLOUD_INIT_PATH__/${REMOTE_CLOUD_INIT_DIR}/cloud-init.yaml}"
launch_script="${launch_script//__PI_HOST__/${USBPROXY_HOST}}"

printf '%s' "$launch_script" | ssh "$INCUS_REMOTE" \
  'cat > /usr/local/bin/printserver-launch && chmod +x /usr/local/bin/printserver-launch'

ssh "$INCUS_REMOTE" 'cat > /etc/systemd/system/printserver-reprovision.service' <<SVC_EOF
[Unit]
Description=Nightly printserver container reprovision

[Service]
Type=oneshot
ExecStart=/usr/local/bin/printserver-launch
SVC_EOF

ssh "$INCUS_REMOTE" 'cat > /etc/systemd/system/printserver-reprovision.timer' <<TIMER_EOF
[Unit]
Description=Nightly printserver reprovision at 02:30

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

ssh "$INCUS_REMOTE" systemctl daemon-reload
ssh "$INCUS_REMOTE" systemctl enable --now printserver-reprovision.timer
log "Nightly reprovision timer installed and active."

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════════"
echo "  printserver-bootstrap complete."
echo "  Container    : ${CONTAINER_NAME} on ${INCUS_REMOTE}"
echo "  Image        : ${IMAGE}"
echo "  Profile      : ${PROFILE_NAME}"
echo "  Network      : ${NETWORK_NAME} (MACVLAN on ${PARENT_IFACE})"
echo "  MAC          : ${MAC_ADDRESS}"
if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then
  echo "  CUPS UI      : https://${CONTAINER_FQDN}/"
  echo "  TLS          : Let's Encrypt cert (volume: ${LE_VOLUME_NAME})"
else
  echo "  CUPS UI      : http://${CONTAINER_FQDN}:631"
fi
echo
echo "  Nightly reprovision timer: 02:30 on ${INCUS_REMOTE}"
echo "  Launch script: ${INCUS_REMOTE}:/usr/local/bin/printserver-launch"
echo "  Cloud-init   : ${INCUS_REMOTE}:${REMOTE_CLOUD_INIT_DIR}/cloud-init.yaml"
echo
echo "  USB printers are attached automatically — connect them to the Pi and"
echo "  usbip-bind-all (Pi) + usbip-attach-all (printserver) do the rest."
echo "══════════════════════════════════════════════════════════════════"
