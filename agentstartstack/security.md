# Security (printstack-specific)

> Generic rules (never echo secrets, env hygiene): see `.agentstartstack/agentstartstack/security.md`.

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
| `SSH_PUBKEYS` | `shared.env` | SSH access on all nodes |
| `NAMECHEAP_API_KEY` | `printserver-bootstrap.env` | DNS-01 TLS challenge |
| `NAMECHEAP_API_USER` | `printserver-bootstrap.env` | Namecheap API auth |

## TLS / API keys

Namecheap API requires whitelisting `NAMECHEAP_CLIENT_IP` (management machine's public IP). The API key grants DNS record modification for domains in the account -- protect it like a password.

## Firewall defaults

- SSH: restricted to `SSH_CIDRS` when set; otherwise open to any
- Print services: always restricted to `PRINT_CIDRS`
- TLS mode: port 443 open to any (required for HTTPS printing from outside LAN if desired)

When tightening SSH, ensure your management machine's IP is in `SSH_CIDRS`.