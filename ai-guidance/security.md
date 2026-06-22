# Security

## CRITICAL: Never print passwords or secrets

**Rule: NEVER echo passwords, API keys, or secrets to stdout/stderr**

Secrets printed to console can be captured in:
- Shell history (`~/.bash_history`, `~/.zsh_history`)
- Log files (CI logs, audit logs, syslog)
- Terminal session recordings
- Process monitoring tools (`ps`, `top`)
- `set -x` debug traces (bash prints expanded variables)

**Correct pattern:** secrets stay in `.env` files, sourced by scripts

```bash
# OK: password in env file, sourced by script
# pi-bootstrap.env:
WIFI_PASSWORD=actual_password

# FAIL: password on command line (visible in ps, history)
sudo ./pi-bootstrap.sh --wifi-password "actual_password"

# FAIL: password echoed in script output
echo "WiFi password: $WIFI_PASSWORD"
```

**In code:**
- OK: `echo "[OK] WiFi configured from pi-bootstrap.env"`
- FAIL: `echo "[OK] WiFi password: $WIFI_PASSWORD"`
- OK: `echo "[OK] Namecheap API key configured"`
- FAIL: `echo "[OK] API key: $NAMECHEAP_API_KEY"`

## .env file permissions

Bootstrap scripts warn if `.env` files are world-readable. Recommend `chmod 600`:

```bash
chmod 600 shared.env pi-bootstrap.env printserver-bootstrap.env
```

## Git hygiene

| Track in git | Never track |
|--------------|-------------|
| `*.env.example` | `shared.env`, `pi-bootstrap.env`, `printserver-bootstrap.env` |
| Scripts, cloud-init templates | Generated `cloud-init/*` output |
| | `*.img`, `*.img.xz` |

## Secrets in this project

| Secret | File | Used for |
|--------|------|----------|
| `WIFI_PASSWORD` | `pi-bootstrap.env` | Pi WiFi join |
| `SSH_PUBKEYS` | `shared.env` | SSH access on all nodes (public keys only -- still treat as sensitive config) |
| `NAMECHEAP_API_KEY` | `printserver-bootstrap.env` | DNS-01 TLS challenge |
| `NAMECHEAP_API_USER` | `printserver-bootstrap.env` | Namecheap API auth |

## TLS / API keys

Namecheap API requires whitelisting `NAMECHEAP_CLIENT_IP` (management machine's public IP). The API key grants DNS record modification for domains in the account -- protect it like a password.

## Firewall defaults

- SSH: restricted to `SSH_CIDRS` when set; otherwise open to any (convenient but less secure)
- Print services: always restricted to `PRINT_CIDRS`
- TLS mode: port 443 open to any (required for HTTPS printing from outside LAN if desired)

When tightening SSH, ensure your management machine's IP is in `SSH_CIDRS`.