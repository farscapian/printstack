# Implementation Details

### Env file loading pattern

Both bootstrap scripts use the same sequence:

```bash
# 1. Load shared.env (required)
set +u
source "$SHARED_ENV"
set -u

# 2. Load node-specific .env (required)
set +u
source "$ENV_FILE"
set -u

# 3. Apply defaults for optional vars
LAN_SUBNET="${LAN_SUBNET:-192.168.4.0/22}"
```

`set +u` before `source` prevents abort on unset optional variables. Required vars are validated explicitly after sourcing.

### YAML indent builder variables

Cloud-init heredocs need correctly indented interpolated blocks. Build these in loops **before** the heredoc:

```bash
SSH_PUBKEYS_YAML=""
while IFS= read -r key; do
  [[ -z "${key// }" ]] && continue
  SSH_PUBKEYS_YAML+="      - ${key}"$'\n'
done <<< "$SSH_PUBKEYS"
```

Reference at column 0 inside the heredoc: `${SSH_PUBKEYS_YAML}`. The variable content carries its own indentation.

### Nested heredocs for conditional cloud-init blocks

`printserver-bootstrap.sh` uses nested heredocs for TLS-conditional sections:

```bash
$(if [[ "$ENABLE_LETSENCRYPT" == "true" ]]; then cat <<LEEOF
  # TLS-specific cloud-init lines
LEEOF
fi)
```

When adding conditional blocks, keep the inner heredoc delimiter unique (e.g. `LEEOF`, `METAEOF`).

### Stdout/Stderr and user prompts

If a script ever redirects stdout to a log file, user prompts break:

```bash
exec > >(tee -a "$LOG_FILE") 2>&1
```

**Solution for prompts after redirect:**
```bash
echo "Continue?" >&2
read -r -p "Continue? [y/N] " confirm </dev/tty
```

`pi-bootstrap.sh` uses `read -r -p` for the destructive flash confirmation -- ensure any future logging redirect preserves `</dev/tty` for prompts.

### Mount cleanup (pi-bootstrap.sh)

```bash
cleanup() {
  if mountpoint -q "$ROOT_MOUNT" 2>/dev/null; then umount "$ROOT_MOUNT" 2>/dev/null || true; fi
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then umount "$MOUNT_POINT" 2>/dev/null || true; fi
}
trap cleanup EXIT
```

Always unmount before exit -- SD card corruption otherwise.

### Partition path derivation

```bash
if [[ "$DEVICE" == *mmcblk* || "$DEVICE" == *nvme* ]]; then
  BOOT_PART="${DEVICE}p1"
else
  BOOT_PART="${DEVICE}1"
fi
```

### Generated cloud-init inspection

After every bootstrap run, inspect gitignored output:

```
cloud-init/pi-bootstrap/
cloud-init/printserver-bootstrap/
```

Useful for verifying interpolation without booting hardware.

### Incus remote switching

`printserver-bootstrap.sh` and `printserver-image-build.sh` save the previous default remote and switch to `INCUS_REMOTE` for operations. Be aware other Incus CLI sessions on the same machine may be affected.

### lpadmin bake-back flow

After printer discovery, the script:
1. Captures `lpadmin` commands from the discovery phase
2. Splices them into the `CLOUD_INIT` heredoc content (or rebuilds the YAML)
3. Writes to local `cloud-init/printserver-bootstrap/cloud-init.yaml`
4. `scp`/`rsync` to Incus host for nightly timer consumption

Do not break this chain when modifying the discovery or runcmd sections.