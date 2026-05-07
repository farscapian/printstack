#!/usr/bin/env bash
# =============================================================================
# pi-bootstrap.sh
#
# Flash Ubuntu Server 26.04 LTS (Resolute Raccoon) to an SD card and write
# all cloud-init files for the USB/IP proxy node (Raspberry Pi 4B).
#
# Configuration is read from a .env file to keep secrets off the command line
# and out of shell history.
#
# Usage:
#   cp pi-bootstrap.env.example pi-bootstrap.env
#   $EDITOR pi-bootstrap.env          # fill in values
#   chmod 600 pi-bootstrap.env        # protect the password
#   sudo ./pi-bootstrap.sh [--env pi-bootstrap.env] [--flash] [--force] [--help]
#
# Options:
#   --env    <file>   Path to .env file (default: pi-bootstrap.env in the
#                     same directory as the script)
#   --flash           Force a full OS flash even if the device already appears
#                     to have Ubuntu on it. By default the script only flashes
#                     if the Ubuntu image is present but the boot partition is
#                     not yet written (i.e. the SD card is blank or foreign).
#   --force           Skip the "all data will be destroyed" confirmation prompt.
#                     Useful for scripted/automated runs. Implies --flash.
#   --help            Show this help and exit
#
# .env variables (see pi-bootstrap.env.example):
#   DEVICE          /dev/sdX    SD card block device (required)
#   WIFI_PASSWORD   <pass>      HomeNet WPA3/WPA2 passphrase (required)
#   PI_HOSTNAME     <fqdn>      Pi hostname (default: usbproxy.ancapistan.io)
#
# Image file:
#   The script looks for ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz
#   in the same directory as pi-bootstrap.sh. If found (and checksum passes),
#   it is used directly. If not found, it is downloaded and saved there.
#
# What this script does:
#   1. Decompress the .xz image to a cached .img file (skipped if .img exists)
#   2. Verify SHA256 checksum of the .xz against hardcoded hash
#   3. Flash the .img to --device via dd (progress via pv)
#   4. Mount the ext4 writable partition (partition 2)
#   5. Chroot into the image (via systemd-nspawn) and pre-install packages
#      that have NO kernel dependency chain: linux-tools-common, usbutils,
#      hwdata, ufw, wireless-regdb, zstd, iw.
#      usbip/usbipd are extracted from linux-raspi-tools via dpkg-deb -x
#      (not installed) to avoid triggering flash-kernel/dracut postinst hooks.
#      Also patches the brcmfmac NVRAM with ccode=US inside the chroot.
#   6. Unmount writable partition
#   7. Mount the FAT32 system-boot partition (partition 1)
#   8. Write meta-data, vendor-data, patch cmdline with ds=nocloud + cfg80211.ieee80211_regdom=US
#   9. Write pi-firstboot-user-data.yaml  →  user-data
#      (runs once: configures WiFi, sets regulatory domain, swaps user-data)
#  10. Write pi-nightly-user-data.yaml    →  user-data.nightly
#      (internet-free; used for all subsequent nightly reprovisioning)
#  11. Unmount, sync, eject
#
# CAUTION: Step 3 will DESTROY ALL DATA on --device.
#          Verify the device path carefully before running.
#
# Requirements: curl, xz-utils, pv, coreutils, util-linux, qemu-user-static,
#               binfmt-support — missing packages installed automatically.
# =============================================================================

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly IMAGE_NAME="ubuntu-26.04-preinstalled-server-arm64+raspi.img"
readonly IMAGE_XZ="${IMAGE_NAME}.xz"

readonly IMAGE_URL="https://cdimage.ubuntu.com/releases/26.04/release/${IMAGE_XZ}"
# SHA256 of ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz
# Source: https://cdimage.ubuntu.com/releases/26.04/release/SHA256SUMS
readonly IMAGE_SHA256="10604098a0c4eeb7359e58e12b01badbce8c74b0d53b414e633ba0b047b512cd"

readonly MOUNT_POINT="/mnt/pi-boot"
readonly ROOT_MOUNT="/mnt/pi-root"
readonly CI_DIR="${SCRIPT_DIR}/cloud-init/pi-bootstrap"  # local copies of all files written to the SD card

# ── Script flag defaults ──────────────────────────────────────────────────────
# These are script-level flags only. All configuration values (DEVICE,
# WIFI_PASSWORD, etc.) come exclusively from the .env file — never the CLI.
ENV_FILE="${SCRIPT_DIR}/pi-bootstrap.env"
FLASH=false    # set to true by --flash or --force, or auto-detected
FORCE=false    # skip confirmation prompt; implies FLASH=true

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  sed -n '/^# ={10}/,/^# ={10}/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
  exit 0
}

# ── Argument parsing (flags only — no secrets on the CLI) ────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)      ENV_FILE="$2"; shift 2 ;;
    --flash)    FLASH=true;    shift   ;;
    --force)    FORCE=true; FLASH=true; shift ;;
    --help|-h)  usage ;;
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

# ── Load .env file ─────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: .env file not found: $ENV_FILE" >&2
  echo "       Copy pi-bootstrap.env.example to pi-bootstrap.env and fill it in." >&2
  exit 1
}

# Warn if .env is world-readable before we source it
ENV_PERMS=$(stat -c '%a' "$ENV_FILE")
if [[ "$ENV_PERMS" != "600" && "$ENV_PERMS" != "400" ]]; then
  echo "WARNING: $ENV_FILE has permissions ${ENV_PERMS}. Recommend: chmod 600 $ENV_FILE" >&2
fi

# Source with -u relaxed so missing optional vars don't abort before validation
set +u
# shellcheck source=/dev/null
source "$ENV_FILE"
set -u

# Apply shared.env defaults
SSH_PUBKEYS="${SSH_PUBKEYS:-}"
LAN_SUBNET="${LAN_SUBNET:-192.168.4.0/22}"
USBPROXY_HOST="${USBPROXY_HOST:-usbproxy.ancapistan.io}"
ENABLE_VIRTUAL_PRINTERS="${ENABLE_VIRTUAL_PRINTERS:-0}"
SSH_CIDRS="${SSH_CIDRS:-}"
PRINT_CIDRS="${PRINT_CIDRS:-${LAN_SUBNET}}"

# PI_HOSTNAME defaults to USBPROXY_HOST (they're the same node)
PI_HOSTNAME="${PI_HOSTNAME:-${USBPROXY_HOST}}"

# Build YAML-formatted pubkey list for cloud-init (6-space indent)
SSH_PUBKEYS_YAML=""
while IFS= read -r key; do
  [[ -z "${key// }" ]] && continue
  SSH_PUBKEYS_YAML+="      - ${key}"$'\n'
done <<< "$SSH_PUBKEYS"
SSH_PUBKEYS_YAML="${SSH_PUBKEYS_YAML%$'\n'}"

# Build UFW rules for cloud-init from CIDR lists
UFW_PRINT_RULES=""
for _cidr in $PRINT_CIDRS; do
  UFW_PRINT_RULES+="  - ufw allow from '${_cidr}' to any port 3240 proto tcp"$'\n'
done
if [[ -z "$SSH_CIDRS" ]]; then
  UFW_SSH_RULES="  - ufw allow OpenSSH"$'\n'
else
  UFW_SSH_RULES=""
  for _cidr in $SSH_CIDRS; do
    UFW_SSH_RULES+="  - ufw allow from '${_cidr}' to any port 22 proto tcp"$'\n'
  done
fi
# Strip trailing newlines
UFW_PRINT_RULES="${UFW_PRINT_RULES%$'\n'}"
UFW_SSH_RULES="${UFW_SSH_RULES%$'\n'}"

# ── Validation ─────────────────────────────────────────────────────────────────
[[ -z "$SSH_PUBKEYS" ]]       && { echo "ERROR: SSH_PUBKEYS is not set in $SHARED_ENV."  >&2; exit 1; }
[[ -z "${DEVICE:-}" ]]        && { echo "ERROR: DEVICE is not set in $ENV_FILE."         >&2; exit 1; }
[[ -z "${WIFI_PASSWORD:-}" ]] && { echo "ERROR: WIFI_PASSWORD is not set in $ENV_FILE."  >&2; exit 1; }
# WLAN_MAC is optional — if set, overrides wlan0 MAC in netplan
WLAN_MAC="${WLAN_MAC:-}"


if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo $0 ...)." >&2
  exit 1
fi

# Derive the short hostname (everything before the first dot)
PI_SHORT="${PI_HOSTNAME%%.*}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
  if mountpoint -q "$ROOT_MOUNT" 2>/dev/null; then
    log "Unmounting $ROOT_MOUNT..."
    umount "$ROOT_MOUNT" 2>/dev/null || true
  fi
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    log "Unmounting $MOUNT_POINT..."
    umount "$MOUNT_POINT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

ensure_deps() {
  local -a needed=()
  command -v curl               &>/dev/null || needed+=(curl)
  command -v xz                 &>/dev/null || needed+=(xz-utils)
  command -v pv                 &>/dev/null || needed+=(pv)
  command -v sha256sum          &>/dev/null || needed+=(coreutils)
  command -v lsblk              &>/dev/null || needed+=(util-linux)
  command -v partprobe      &>/dev/null || needed+=(parted)
  command -v systemd-nspawn &>/dev/null || needed+=(systemd-container)

  if [[ ${#needed[@]} -gt 0 ]]; then
    log "Installing missing dependencies: ${needed[*]}"
    apt-get install -y "${needed[@]}"
  fi
}

# ── Phase 1: Safety checks and flash auto-detection ───────────────────────────
ensure_deps

[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device. Check the path."

# Refuse if device looks like a system disk (> 512 GB)
DEVICE_SIZE_GB=$(lsblk -bno SIZE "$DEVICE" 2>/dev/null | head -1 \
  | awk '{printf "%.0f", $1/1024/1024/1024}')
if [[ "$DEVICE_SIZE_GB" -gt 512 ]]; then
  die "$DEVICE appears to be ${DEVICE_SIZE_GB} GB — too large for an SD card. Aborting."
fi

# Refuse if device is the root disk
ROOT_DISK=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
if [[ "$(realpath "$DEVICE")" == "$(realpath "$ROOT_DISK")" ]]; then
  die "$DEVICE is your root disk. Aborting."
fi

# Derive boot partition path (handles both /dev/sdX and /dev/mmcblkX styles)
if [[ "$DEVICE" == *mmcblk* || "$DEVICE" == *nvme* ]]; then
  BOOT_PART="${DEVICE}p1"
else
  BOOT_PART="${DEVICE}1"
fi

# Auto-detect whether flashing is needed:
# If --flash or --force were not given, check whether the device already has
# a Ubuntu system-boot FAT32 partition. If it does, skip flashing. If it
# doesn't (blank, foreign FS, or unpartitioned), enable flashing automatically.
if [[ "$FLASH" == false ]]; then
  EXISTING_LABEL=$(lsblk -no LABEL "$BOOT_PART" 2>/dev/null | head -1 || true)
  if [[ "$EXISTING_LABEL" == "system-boot" ]]; then
    log "Detected existing Ubuntu system-boot partition on $BOOT_PART — skipping flash."
    log "(Use --flash to force a full reflash.)"
  else
    log "No Ubuntu system-boot partition detected on $BOOT_PART — flashing required."
    FLASH=true
  fi
fi

log "Target device : $DEVICE  (${DEVICE_SIZE_GB} GB)"
log "Hostname      : $PI_HOSTNAME"
log "Image dir     : $SCRIPT_DIR"
log "Flash OS      : $FLASH"

# ── Pre-flash size check ──────────────────────────────────────────────────────
if [[ "$FLASH" == true ]]; then
  DEVICE_SIZE_BYTES=$(lsblk -bno SIZE "$DEVICE" | head -1)

  # Determine required bytes from the best available source:
  #   1. Decompressed .img (exact)
  #   2. .xz header via xz --list (exact, no decompression needed)
  #   3. Hardcoded minimum (conservative fallback when neither exists yet)
  if [[ -f "${SCRIPT_DIR}/${IMAGE_NAME}" ]]; then
    REQUIRED_BYTES=$(stat -c%s "${SCRIPT_DIR}/${IMAGE_NAME}")
    REQUIRED_SOURCE="decompressed image"
  elif [[ -f "${SCRIPT_DIR}/${IMAGE_XZ}" ]]; then
    REQUIRED_BYTES=$(xz --robot --list "${SCRIPT_DIR}/${IMAGE_XZ}" 2>/dev/null \
      | awk '/^file\t/{print $5}')
    REQUIRED_SOURCE=".xz header"
  else
    REQUIRED_BYTES=$(( 8 * 1024 * 1024 * 1024 ))
    REQUIRED_SOURCE="minimum estimate (image not yet downloaded)"
  fi

  if [[ -n "$REQUIRED_BYTES" && "$DEVICE_SIZE_BYTES" -lt "$REQUIRED_BYTES" ]]; then
    DEVICE_GB=$(awk "BEGIN {printf \"%.1f\", ${DEVICE_SIZE_BYTES}/1073741824}")
    REQUIRED_GB=$(awk "BEGIN {printf \"%.1f\", ${REQUIRED_BYTES}/1073741824}")
    die "$DEVICE is ${DEVICE_GB} GB but the image requires ${REQUIRED_GB} GB (source: ${REQUIRED_SOURCE}). Insert a larger SD card."
  fi
fi

if [[ "$FLASH" == true ]]; then
  if [[ "$FORCE" == false ]]; then
    echo
    read -r -p "WARNING: ALL DATA ON $DEVICE WILL BE DESTROYED. Type 'yes' to continue: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { log "Aborted."; exit 0; }
  else
    log "(--force: skipping confirmation)"
  fi
fi

# ── Phase 2: Locate, verify, or download .xz; decompress to cached .img ──────
if [[ "$FLASH" == true ]]; then
  XZ_PATH="${SCRIPT_DIR}/${IMAGE_XZ}"
  IMG_PATH="${SCRIPT_DIR}/${IMAGE_NAME}"

  verify_xz_checksum() {
    local actual
    actual=$(sha256sum "$XZ_PATH" | awk '{print $1}')
    if [[ "$actual" == "$IMAGE_SHA256" ]]; then
      return 0
    else
      log "Expected : $IMAGE_SHA256"
      log "Actual   : $actual"
      return 1
    fi
  }

  # If decompressed .img already exists, use it directly — skip .xz entirely
  if [[ -f "$IMG_PATH" ]]; then
    log "Decompressed image found: $IMG_PATH"
    log "Skipping .xz download and decompression."
  else
    # Ensure we have a valid .xz to decompress
    if [[ -f "$XZ_PATH" ]]; then
      log "Found .xz: $XZ_PATH — verifying checksum..."
      if verify_xz_checksum; then
        log "Checksum OK."
      else
        log "Checksum mismatch — re-downloading."
        rm -f "$XZ_PATH"
      fi
    fi

    if [[ ! -f "$XZ_PATH" ]]; then
      log "Downloading $IMAGE_XZ to $SCRIPT_DIR ..."
      log "(URL: $IMAGE_URL)"
      curl -fL --progress-bar "$IMAGE_URL" -o "$XZ_PATH"
      log "Verifying checksum..."
      verify_xz_checksum || die "Checksum verification failed. Aborting."
      log "Checksum OK."
    fi

    log "Decompressing $IMAGE_XZ → $IMAGE_NAME (this may take a minute)..."
    xz -dk "$XZ_PATH"
    log "Decompression complete. Cached at: $IMG_PATH"
  fi

  # ── Phase 3: Flash .img to SD card ───────────────────────────────────────
  log "Unmounting any existing partitions on $DEVICE..."
  for part in "${DEVICE}"?* "${DEVICE}p"?*; do
    [[ -b "$part" ]] && umount "$part" 2>/dev/null || true
  done

  IMG_SIZE=$(stat -c%s "$IMG_PATH")
  log "Flashing $IMAGE_NAME to $DEVICE (${IMG_SIZE} bytes)..."
  pv --size "$IMG_SIZE" "$IMG_PATH"     | dd of="$DEVICE" bs=4M conv=fsync status=none
  sync
  log "Flash complete."

  # Re-read partition table and wait for udev
  log "Re-reading partition table..."
  partprobe "$DEVICE" 2>/dev/null     || blockdev --rereadpt "$DEVICE" 2>/dev/null     || true
  sleep 3

  # ── Phase 3b: Pre-install packages via chroot ─────────────────────────────
  # Derive root partition path
  if [[ "$DEVICE" == *mmcblk* || "$DEVICE" == *nvme* ]]; then
    ROOT_PART="${DEVICE}p2"
  else
    ROOT_PART="${DEVICE}2"
  fi

  log "Waiting for $ROOT_PART..."
  for i in {1..15}; do
    [[ -b "$ROOT_PART" ]] && break
    sleep 1
  done
  [[ -b "$ROOT_PART" ]] || die "Root partition $ROOT_PART not found after flash."

  log "Mounting $ROOT_PART at $ROOT_MOUNT..."
  mkdir -p "$ROOT_MOUNT"
  mount "$ROOT_PART" "$ROOT_MOUNT"

  # systemd-nspawn handles bind mounts and binfmt transparently — no need
  # to manually mount proc/sys/dev or copy a qemu binary into the rootfs.
  # It detects the arm64 rootfs and uses the host binfmt registration
  # (/usr/bin/qemu-aarch64 via qemu-user-binfmt) automatically.

  # Write correct apt sources before running apt
  cat > "$ROOT_MOUNT/etc/apt/sources.list.d/ubuntu.sources" <<APTEOF
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: resolute resolute-updates resolute-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: resolute-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
APTEOF

  # Copy host resolv.conf into rootfs so DNS works inside nspawn.
  # The image has resolv.conf as a dangling symlink to the systemd stub
  # resolver which doesn't exist yet — remove it and write a real file.
  # The symlink is restored after nspawn exits.
  RESOLV_TARGET=$(readlink "$ROOT_MOUNT/etc/resolv.conf" 2>/dev/null || true)
  rm -f "$ROOT_MOUNT/etc/resolv.conf"
  cp /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf"

  # Single nspawn invocation for both apt install and NVRAM patch.
  log "Pre-installing packages and patching NVRAM via systemd-nspawn..."
  systemd-nspawn \
      --directory="$ROOT_MOUNT" \
      --timezone=off \
      --suppress-sync=yes \
      /bin/bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq

      # Install packages that have no kernel dependency chain.
      # linux-tools-raspi is intentionally excluded: it depends on
      # linux-raspi-tools-<kver> which depends on linux-modules-<kver>
      # which depends on linux-image-<kver>. That triggers a kernel upgrade
      # and a dracut initramfs rebuild — which fails inside nspawn because
      # nspawn's seccomp filter blocks the mknod/mknodat syscalls dracut needs.
      # The usbip/usbipd binaries are extracted below instead.
      apt-get install -y --no-install-recommends \
        linux-tools-common \
        usbutils \
        hwdata \
        ufw \
        wireless-regdb \
        zstd \
        iw

      # Extract usbip/usbipd from the linux-raspi-tools deb without
      # installing it (and without pulling in its kernel deps).
      # apt-get download fetches the deb; dpkg-deb -x unpacks it to /.
      # cloud-init's runcmd finds the binary via:
      #   find /usr/lib/linux-raspi-tools-* -type d | sort -V | tail -1
      TOOLS_PKG=\$(apt-cache pkgnames 'linux-raspi-tools-' 2>/dev/null \
        | sort -V | tail -1)
      if [ -n \"\$TOOLS_PKG\" ]; then
        echo \"Extracting usbip/usbipd from \$TOOLS_PKG...\"
        mkdir -p /tmp/raspi-tools
        ( cd /tmp/raspi-tools && apt-get download \"\$TOOLS_PKG\" )
        dpkg-deb -x /tmp/raspi-tools/*.deb /
        rm -rf /tmp/raspi-tools
        echo \"Extracted: \$(ls /usr/lib/linux-raspi-tools-*/usbip* 2>/dev/null | tr '\n' ' ')\"
      else
        echo 'WARNING: No linux-raspi-tools-* package found in apt cache' >&2
      fi

      apt-get clean
      rm -rf /var/lib/apt/lists/*

      # Patch brcmfmac NVRAM with ccode=US
      GENERIC=\$(readlink -f /usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt.zst 2>/dev/null)
      if [ -n "\$GENERIC" ]; then
        zstd -d "\$GENERIC" -o /tmp/nvram-pi4b.txt
        printf '
ccode=US
regrev=0
' >> /tmp/nvram-pi4b.txt
        zstd -19 -f /tmp/nvram-pi4b.txt \
          -o /usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt.zst
        echo 'brcmfmac NVRAM patched with ccode=US'
      else
        echo 'WARNING: could not find brcmfmac NVRAM to patch' >&2
      fi
    "

  # Restore original resolv.conf symlink
  rm -f "$ROOT_MOUNT/etc/resolv.conf"
  if [[ -n "$RESOLV_TARGET" ]]; then
    ln -sf "$RESOLV_TARGET" "$ROOT_MOUNT/etc/resolv.conf"
  fi

  umount "$ROOT_MOUNT"
  log "nspawn complete — packages pre-installed."
fi

# ── Phase 4: Mount boot partition ────────────────────────────────────────────
log "Waiting for $BOOT_PART..."
for i in {1..15}; do
  [[ -b "$BOOT_PART" ]] && break
  sleep 1
done
[[ -b "$BOOT_PART" ]] || die "Boot partition $BOOT_PART not found. Try --no-flash and mount manually."

log "Mounting $BOOT_PART at $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT"
mount "$BOOT_PART" "$MOUNT_POINT"

# Create local cloud-init output directory
mkdir -p "$CI_DIR"

# ── Phase 5: Write meta-data and seed support files ──────────────────────────
log "Writing meta-data..."
# instance-id must be unique on every flash — cloud-init uses it to determine
# whether this is a new instance. If it matches a cached value, runcmd and
# other once-per-instance modules are skipped entirely.
INSTANCE_ID="${PI_SHORT}-$(date +%Y%m%d%H%M%S)"
log "Instance ID: $INSTANCE_ID"
cat > "$CI_DIR/meta-data" <<EOF
instance-id: ${INSTANCE_ID}
local-hostname: ${PI_SHORT}
EOF
cp "$CI_DIR/meta-data" "$MOUNT_POINT/meta-data"

# vendor-data must exist (even if empty) for NoCloud seed detection on
# some cloud-init versions.
touch "$CI_DIR/vendor-data"
cp "$CI_DIR/vendor-data" "$MOUNT_POINT/vendor-data"

# Patch the kernel cmdline file with ds=nocloud to force the local filesystem
# datasource. Without this, Ubuntu 26.04 cloud-init uses DataSourceNoCloudNet
# (network variant), ignores seed files on system-boot, and falls back to
# DataSourceNone — silently skipping all write_files and runcmd directives.
#
# Ubuntu Pi images use nobtcmd.txt (referenced via cmdline=nobtcmd.txt in
# config.txt) rather than the traditional cmdline.txt. We try both names and
# also check config.txt to find whichever filename is actually in use.
log "Patching kernel cmdline file with ds=nocloud..."

# Determine which cmdline file is active by reading config.txt.
# Ubuntu 26.04 Pi images use os_prefix=current/ in config.txt, meaning
# the kernel, initrd, and cmdline.txt all live under current/ on the
# boot partition rather than at the root.
CMDLINE_FILE=""
OS_PREFIX=""

if [[ -f "$MOUNT_POINT/config.txt" ]]; then
  # Extract os_prefix (may be empty or e.g. "current/")
  OS_PREFIX=$(grep -i "^os_prefix=" "$MOUNT_POINT/config.txt"     | head -1 | cut -d= -f2 | tr -d '[:space:]')
  # Extract cmdline filename (default: cmdline.txt)
  CMDLINE_NAME=$(grep -i "^cmdline=" "$MOUNT_POINT/config.txt"     | head -1 | cut -d= -f2 | tr -d '[:space:]')
  CMDLINE_NAME="${CMDLINE_NAME:-cmdline.txt}"
  CMDLINE_FILE="${OS_PREFIX}${CMDLINE_NAME}"
fi

# Verify the resolved path exists; if not, scan common locations
if [[ -z "$CMDLINE_FILE" || ! -f "$MOUNT_POINT/$CMDLINE_FILE" ]]; then
  [[ -n "$CMDLINE_FILE" ]] &&     log "WARNING: config.txt references $CMDLINE_FILE but file not found."
  log "Scanning for cmdline file..."
  CMDLINE_FILE=""
  for candidate in       current/cmdline.txt current/nobtcmd.txt       nobtcmd.txt cmdline.txt autoboot.txt btcmd.txt; do
    if [[ -f "$MOUNT_POINT/$candidate" ]]; then
      CMDLINE_FILE="$candidate"
      log "Found: $candidate"
      break
    fi
  done
fi

if [[ -z "$CMDLINE_FILE" ]]; then
  log "WARNING: No kernel cmdline file found on boot partition."
  log "         Files present: $(ls "$MOUNT_POINT")"
  log "         ds=nocloud not added — cloud-init datasource detection may fail."
else
  log "Kernel cmdline file: $CMDLINE_FILE"
  if grep -q "ds=nocloud" "$MOUNT_POINT/$CMDLINE_FILE" && \
     grep -q "cfg80211.ieee80211_regdom=US" "$MOUNT_POINT/$CMDLINE_FILE"; then
    log "$CMDLINE_FILE already patched — skipping."
  elif [[ "$CMDLINE_FILE" == "autoboot.txt" ]]; then
    # autoboot.txt format: [all]\nbootcmd=<cmdline>
    sed -i 's/^\(bootcmd=.*\)$/\1 ds=nocloud cfg80211.ieee80211_regdom=US/' \
      "$MOUNT_POINT/$CMDLINE_FILE"
    log "$CMDLINE_FILE patched: ds=nocloud cfg80211.ieee80211_regdom=US appended to bootcmd."
  else
    # Traditional single-line cmdline files — append inline
    sed -i 's/$/ ds=nocloud cfg80211.ieee80211_regdom=US/' "$MOUNT_POINT/$CMDLINE_FILE"
    log "$CMDLINE_FILE patched: ds=nocloud cfg80211.ieee80211_regdom=US added."
  fi
fi

# ── Phase 6: Write user-data (first-boot) ────────────────────────────────────
log "Writing first-boot user-data → user-data..."
cat > "$CI_DIR/user-data.yaml" <<EOF
#cloud-config
# pi-firstboot-user-data.yaml
#
# Runs ONCE on initial boot.
#
# Responsibilities:
#   1. Set hostname, user, SSH key
#   2. Write netplan (eth0 + wlan0), CRDA regulatory domain
#   3. Set regulatory domain at runtime (iw reg set)
#   4. Create usbip/usbipd symlinks from pre-installed raspi tools
#   5. Apply netplan so WiFi comes up
#   6. Swap user-data → nightly config for all future reprovisioning
#
# NO package installation — all packages are pre-installed into the image
# by pi-bootstrap.sh via chroot before the SD card is flashed. First boot
# is fully internet-free.
#
# Deliberately does NOT call cloud-init clean/reboot inline — that caused
# an infinite boot loop. The nightly reprovision.timer (02:00) handles all
# subsequent provisioning runs via the internet-free nightly config.

hostname: ${PI_SHORT}
fqdn: ${PI_HOSTNAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
${SSH_PUBKEYS_YAML}

ssh_pwauth: false

# Network config — written to root filesystem; persists across nightly
# reprovisioning (cloud-init clean does not wipe rootfs).
#
# eth0: DHCP, primary interface (route-metric 100). Optional so absent cable
#        never stalls boot; when present it is preferred over wlan0.
# wlan0: DHCP, secondary interface (route-metric 200). Reserve DHCP by MAC.
#        DNS: ${PI_HOSTNAME} → wlan0 IP.
#
# WPA3-SAE requested; falls back to WPA2-PSK on transition-mode APs.
#
# Regulatory domain set at three layers to silence brcmfmac warnings:
#   1. netplan (cfg80211 / wpa_supplicant)
#   2. /etc/default/crda (CRDA kernel regulatory daemon)
#   3. config.txt country= (Pi firmware — most authoritative for brcmfmac)
write_files:
  - path: /etc/netplan/60-network.yaml
    content: |
      network:
        version: 2
        ethernets:
          eth0:
            dhcp4: true
            optional: true
            dhcp4-overrides:
              route-metric: 100
        wifis:
          wlan0:
            dhcp4: true
            optional: true
            dhcp4-overrides:
              route-metric: 200
$(if [[ -n "${WLAN_MAC}" ]]; then echo "            macaddress: ${WLAN_MAC}"; fi)
            access-points:
              "HomeNet":
                auth:
                  key-management: psk
                  password: "${WIFI_PASSWORD}"
                band: 2.4GHz
            regulatory-domain: US
    owner: root:root
    permissions: '0600'

  - path: /etc/default/crda
    content: |
      REGDOMAIN=US
    owner: root:root
    permissions: '0644'

# bootcmd runs before everything on every boot. Detect if the instance-id
# on the boot partition differs from the cached one and clear the cloud-init
# instance cache if so. This ensures a reflash always triggers a full
# cloud-init run (including runcmd) without needing to mount the root
# partition from the bootstrap script.
bootcmd:
  - |
    BOOT_IID=\$(grep "^instance-id:" /boot/firmware/meta-data 2>/dev/null | awk '{print \$2}')
    CACHE_IID=\$(cat /var/lib/cloud/data/instance-id 2>/dev/null)
    if [ -n "\$BOOT_IID" ] && [ "\$BOOT_IID" != "\$CACHE_IID" ]; then
      echo "cloud-init: instance-id changed (\$CACHE_IID -> \$BOOT_IID), clearing cache"
      cloud-init clean --logs
    fi

# No package installation — all packages are pre-installed into the image
# by the bootstrap script via chroot before flashing. First boot is fully
# internet-free.

runcmd:
  # Set regulatory domain at runtime. The brcmfmac NVRAM was patched with
  # ccode=US during image preparation so 5GHz channels work after reboot.
  # iw reg set covers the current boot session immediately.
  - iw reg set US
  - |
    if grep -q "^country=" /boot/firmware/config.txt 2>/dev/null; then
      sed -i "s/^country=.*/country=US/" /boot/firmware/config.txt
    else
      echo "country=US" >> /boot/firmware/config.txt
    fi

  # Create symlinks for usbip/usbipd from the pre-installed raspi tools.
  - |
    TOOLS=\$(find /usr/lib/linux-raspi-tools-* -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
    if [ -n "\$TOOLS" ]; then
      ln -sf "\$TOOLS/usbipd" /usr/local/bin/usbipd
      ln -sf "\$TOOLS/usbip"  /usr/local/bin/usbip
    else
      echo "WARNING: linux-raspi-tools-* not found" | systemd-cat -t usbip-setup -p warning
    fi

  # Apply netplan so WiFi comes up.
  - netplan apply

  # Swap user-data → nightly config so all future cloud-init runs are
  # internet-free. This must be the LAST step.
  - |
    if [ -f /boot/firmware/user-data.nightly ]; then
      cp /boot/firmware/user-data.nightly /boot/firmware/user-data
      echo "cloud-init-swap: nightly user-data now active." \
        | systemd-cat -t cloud-init-swap
    else
      echo "cloud-init-swap: WARNING: user-data.nightly not found." \
        | systemd-cat -t cloud-init-swap -p warning
    fi

final_message: |
  usbproxy first-boot complete (no internet required).
  All packages were pre-installed. WiFi configured. Nightly user-data now active.
  The system will come up normally. Nightly reprovision timer runs at 02:00.
  Provisioned at: \$TIMESTAMP
EOF
cp "$CI_DIR/user-data.yaml" "$MOUNT_POINT/user-data"

# ── Phase 7: Write user-data.nightly ─────────────────────────────────────────
log "Writing nightly user-data → user-data.nightly..."
cat > "$CI_DIR/user-data.nightly.yaml" <<EOF
#cloud-config
# pi-nightly-user-data.yaml
#
# Used for ALL nightly reprovisioning runs (and immediately after first boot).
# No package_update / package_upgrade / packages directives — entirely
# internet-free. Will succeed during a connectivity outage.
# All packages were pre-installed during first boot.

hostname: ${PI_SHORT}
fqdn: ${PI_HOSTNAME}
manage_etc_hosts: true

users:
  - name: ubuntu
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
${SSH_PUBKEYS_YAML}

ssh_pwauth: false

write_files:
  # Network config — eth0 is primary (route-metric 100, optional), wlan0
  # is secondary (route-metric 200). When both are up, traffic prefers eth0.
  # This file is NOT written on first boot (the firstboot config handles it);
  # it IS written on every nightly reprovision to ensure it stays correct.
  - path: /etc/netplan/60-network.yaml
    content: |
      network:
        version: 2
        ethernets:
          eth0:
            dhcp4: true
            optional: true
            dhcp4-overrides:
              route-metric: 100
        wifis:
          wlan0:
            dhcp4: true
            optional: true
            dhcp4-overrides:
              route-metric: 200
$(if [[ -n "${WLAN_MAC}" ]]; then echo "            macaddress: ${WLAN_MAC}"; fi)
            access-points:
              "HomeNet":
                auth:
                  key-management: psk
                  password: "PLACEHOLDER_WIFI_PASSWORD"
                band: 2.4GHz
            regulatory-domain: US
    owner: root:root
    permissions: '0600'

  # USB/IP kernel modules — load at boot
  - path: /etc/modules-load.d/usbip.conf
    content: |
      usbip_core
      usbip_host
    owner: root:root
    permissions: '0644'

  # usbipd systemd service
  - path: /etc/systemd/system/usbipd.service
    content: |
      [Unit]
      Description=USB/IP Daemon
      After=network.target

      [Service]
      Type=simple
      ExecStart=/usr/local/bin/usbipd
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target
    owner: root:root
    permissions: '0644'

  # Auto-bind all USB devices so usbipd exports everything connected to the Pi.
  # Bus IDs are discovered at runtime — no hardcoded config needed.
  - path: /usr/local/bin/usbip-bind-all
    content: |
      #!/bin/bash
      for busid in \$(usbip list -l 2>/dev/null | awk '/busid/{print \$3}'); do
        usbip bind -b "\$busid" || true
      done
    owner: root:root
    permissions: '0755'

  - path: /usr/local/bin/usbip-unbind-all
    content: |
      #!/bin/bash
      for busid in \$(usbip list -l 2>/dev/null | awk '/busid/{print \$3}'); do
        usbip unbind -b "\$busid" || true
      done
    owner: root:root
    permissions: '0755'

  - path: /etc/systemd/system/usbip-bind.service
    content: |
      [Unit]
      Description=USB/IP Bind All USB Devices
      After=usbipd.service virtual-printers.service
      Requires=usbipd.service
      Wants=virtual-printers.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/usbip-bind-all
      ExecStop=/usr/local/bin/usbip-unbind-all

      [Install]
      WantedBy=multi-user.target
    owner: root:root
    permissions: '0644'

$(if [[ "${ENABLE_VIRTUAL_PRINTERS}" -gt 0 ]]; then cat <<VEOF
  # ── Virtual USB printers (dev/test only) ─────────────────────────────────────
  - path: /usr/local/bin/setup-virtual-printers
    content: |
      #!/bin/bash
      set -euo pipefail
      COUNT=\${1:-1}
      modprobe dummy_hcd num_hcs="\$COUNT" || {
        echo "ERROR: dummy_hcd unavailable" | systemd-cat -t virtual-printers -p err; exit 1; }
      modprobe libcomposite || {
        echo "ERROR: libcomposite unavailable" | systemd-cat -t virtual-printers -p err; exit 1; }
      mountpoint -q /sys/kernel/config 2>/dev/null || mount -t configfs none /sys/kernel/config
      VIDS=(04a9 04b8 03f0)
      PIDS=(176d 0401 2504)
      MFGS=(Canon Epson HP)
      MDLS=("Canon MF4410" "Epson WF-2850" "HP LaserJet M404n")
      for i in \$(seq 0 \$(( COUNT - 1 ))); do
        IDX=\$(( i % 3 ))
        G="/sys/kernel/config/usb_gadget/vprinter\${i}"
        rm -rf "\$G" 2>/dev/null; mkdir -p "\$G"
        echo "0x\${VIDS[\$IDX]}" > "\$G/idVendor"
        echo "0x\${PIDS[\$IDX]}" > "\$G/idProduct"
        printf '0x0200\n'        > "\$G/bcdUSB"
        printf '0x0100\n'        > "\$G/bcdDevice"
        mkdir -p "\$G/strings/0x409"
        echo "\${MFGS[\$IDX]}"          > "\$G/strings/0x409/manufacturer"
        echo "\${MDLS[\$IDX]}"          > "\$G/strings/0x409/product"
        printf 'VIRT%08d\n' "\$i"       > "\$G/strings/0x409/serialnumber"
        mkdir -p "\$G/configs/c.1/strings/0x409"
        echo "Printer"                  > "\$G/configs/c.1/strings/0x409/configuration"
        FUNC="\$G/functions/printer.usb0"
        if mkdir -p "\$FUNC" 2>/dev/null; then
          MFG="\${MFGS[\$IDX]}"; MDL="\${MDLS[\$IDX]}"
          echo "MFG:\${MFG};MDL:\${MDL};CMD:PDF;CLS:PRINTER;DES:\${MDL};" \
            > "\$FUNC/pnp_string" 2>/dev/null || true
          ln -sf "\$FUNC" "\$G/configs/c.1/"
        else
          mkdir -p "\$G/functions/Loopback.0"
          ln -sf "\$G/functions/Loopback.0" "\$G/configs/c.1/"
          echo "WARNING: printer gadget function unavailable; using loopback for vprinter\${i}" \
            | systemd-cat -t virtual-printers -p warning
        fi
        UDC="dummy_udc.\${i}"
        if [ -d "/sys/class/udc/\$UDC" ]; then
          echo "\$UDC" > "\$G/UDC"
          echo "vprinter\${i}: bound to \$UDC (\${MDLS[\$IDX]})" \
            | systemd-cat -t virtual-printers -p info
        else
          echo "ERROR: UDC \$UDC not available" | systemd-cat -t virtual-printers -p err
        fi
      done
    owner: root:root
    permissions: '0755'

  - path: /usr/local/bin/teardown-virtual-printers
    content: |
      #!/bin/bash
      for g in /sys/kernel/config/usb_gadget/vprinter*; do
        [ -d "\$g" ] || continue
        echo "" > "\$g/UDC" 2>/dev/null || true
        find "\$g/configs" -maxdepth 2 -type l -delete 2>/dev/null || true
        rmdir "\$g"/configs/*/strings/* "\$g"/configs/* \
              "\$g/strings/0x409" "\$g"/functions/* "\$g" 2>/dev/null || true
      done
      modprobe -r dummy_hcd 2>/dev/null || true
    owner: root:root
    permissions: '0755'

  - path: /etc/systemd/system/virtual-printers.service
    content: |
      [Unit]
      Description=Virtual USB Printers (dev/test)
      Before=usbip-bind.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/setup-virtual-printers ${ENABLE_VIRTUAL_PRINTERS}
      ExecStop=/usr/local/bin/teardown-virtual-printers

      [Install]
      WantedBy=multi-user.target
    owner: root:root
    permissions: '0644'
VEOF
fi)

  # Nightly reprovision service (triggered by timer below)
  - path: /etc/systemd/system/reprovision.service
    content: |
      [Unit]
      Description=Nightly cloud-init reprovision
      After=network.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/cloud-init clean --logs --reboot
    owner: root:root
    permissions: '0644'

  # Nightly reprovision timer — 02:00 daily
  - path: /etc/systemd/system/reprovision.timer
    content: |
      [Unit]
      Description=Nightly reprovision at 02:00

      [Timer]
      OnCalendar=*-*-* 02:00:00
      Persistent=true

      [Install]
      WantedBy=timers.target
    owner: root:root
    permissions: '0644'

runcmd:
  # Set regulatory domain before netplan apply so brcmfmac firmware
  # sees it before attempting to scan/associate on any channel.
  - iw reg set US
  # Apply network config so wlan0 is up before services start.
  # On nightly reprovision this reconnects WiFi early in the boot sequence.
  - netplan apply
  - sleep 3

  # Load modules immediately (no reboot needed)
  - modprobe usbip_core
  - modprobe usbip_host

  # Resolve usbipd/usbip binaries from linux-raspi-tools-* and symlink to
  # stable paths. Uses the newest version found. Re-runs on every
  # reprovision so it survives kernel upgrades automatically.
  - |
    TOOLS=\$(find /usr/lib/linux-raspi-tools-* -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
    if [ -n "\$TOOLS" ]; then
      ln -sf "\$TOOLS/usbipd" /usr/local/bin/usbipd
      ln -sf "\$TOOLS/usbip"  /usr/local/bin/usbip
    else
      echo "WARNING: linux-raspi-tools-* not found — is linux-tools-raspi installed?" \
        | systemd-cat -t usbip-setup -p warning
    fi

  - systemctl daemon-reload
  - systemctl enable usbipd
  - systemctl enable usbip-bind
  - systemctl enable reprovision.timer
$(if [[ "${ENABLE_VIRTUAL_PRINTERS}" -gt 0 ]]; then cat <<VEOF
  - systemctl enable virtual-printers
  - systemctl start virtual-printers
VEOF
fi)
  - systemctl start usbipd
  - systemctl start usbip-bind
  - systemctl start reprovision.timer

  # Firewall — idempotent; safe to re-run on every reprovision
${UFW_PRINT_RULES}
${UFW_SSH_RULES}
  - ufw --force enable

final_message: |
  usbproxy nightly reprovision complete (internet-free).
  Host: ${PI_HOSTNAME}
  usbipd listening on TCP 3240
  Nightly reprovision timer active at 02:00
  Provisioned at: \$TIMESTAMP
EOF
cp "$CI_DIR/user-data.nightly.yaml" "$MOUNT_POINT/user-data.nightly"

# ── Phase 8: Unmount and eject ────────────────────────────────────────────────
log "Syncing and unmounting..."
sync
umount "$MOUNT_POINT"
trap - EXIT   # cleanup already done; suppress exit handler

log "Ejecting $DEVICE — safe to remove SD card."
# Flush all pending writes and tell the kernel to drop the device.
# udisksctl is the cleanest method; fall back to eject, then blockdev.
if command -v udisksctl &>/dev/null; then
  udisksctl power-off -b "$DEVICE" 2>/dev/null     || udisksctl unmount  -b "$DEVICE" 2>/dev/null     || true
elif command -v eject &>/dev/null; then
  eject "$DEVICE" 2>/dev/null || true
else
  blockdev --flushbufs "$DEVICE" 2>/dev/null || true
fi
log "SD card ejected."

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════════"
echo "  Bootstrap complete."
echo "  Device        : $DEVICE"
echo "  Hostname      : $PI_HOSTNAME"
echo "  Boot partition: $BOOT_PART"
echo
echo "  Packages pre-installed into image (no internet needed on first boot):"
echo "    usbutils, ufw, wireless-regdb, zstd, iw, linux-tools-common"
echo "    usbip/usbipd extracted from linux-raspi-tools (no kernel upgrade)"
echo "    brcmfmac NVRAM patched with ccode=US (5GHz fix)"
echo
echo "  Files written to system-boot:"
echo "    user-data         ← first-boot config (internet-free)"
echo "    user-data.nightly ← nightly config (internet-free)"
echo "    meta-data"
echo
echo "  Local copies for inspection/editing:"
echo "    ${CI_DIR}/user-data.yaml"
echo "    ${CI_DIR}/user-data.nightly.yaml"
echo "    ${CI_DIR}/meta-data"
echo
echo "  Next steps:"
echo "    1. Insert the SD card into the Raspberry Pi 4B."
echo "    2. Power on — cloud-init runs automatically."
echo "    3. Connect USB printers to the Pi — usbip-bind-all exports them automatically."
echo "══════════════════════════════════════════════════════════════════"