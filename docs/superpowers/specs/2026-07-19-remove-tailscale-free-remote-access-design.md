# Design: Remove Tailscale — free self-hosted public remote access

Date: 2026-07-19
Status: Approved (brainstorming)
Supersedes access design in: `docs/superpowers/specs/2026-07-18-family-photo-backup-design.md`

## Problem

The current setup uses [Tailscale](https://tailscale.com) to give family
iPhones a private path to the self-hosted Immich server. Tailscale's free tier
caps seats, so a 4–8 person family may be pushed onto a paid plan. The owner
wants a **zero-subscription** solution and accepts running the server on the
public internet to get it.

## What Tailscale was actually doing

Tailscale performed two distinct jobs:

1. **Network path** — an encrypted route from any family iPhone to the home
   server, with a valid HTTPS URL, without exposing the home network.
2. **Gatekeeping** — because only devices on the tailnet could reach the
   server, the server was implicitly invisible to the public internet.

Removing Tailscale removes **both**. Immich already has its own per-user login
(email + password, separate libraries), so we are not adding login *per se* —
we are replacing the **network path** and the **gatekeeping** that Tailscale
provided.

## Decision

- **Network path** → **DuckDNS** (free dynamic DNS) + home-router **port
  forward** (443) + **Caddy** reverse proxy with automatic Let's Encrypt TLS.
- **Gatekeeping** (now gone) → a **hardened Immich login layer**: strong
  per-person passwords, self-registration disabled, **TOTP two-factor
  required**, plus **fail2ban** and Immich's built-in rate limiting at the edge.

Rejected alternatives (recorded for context):
- **Cloudflare Tunnel + Access** — strongest free option (home stays invisible,
  email-code gate), but the owner chose direct public exposure.
- **Self-hosted WireGuard** — free but still a per-phone VPN app and needs a
  public IP / port-forward; more admin burden.

## Security posture (explicit)

Public exposure means the login layer is the entire security story. This design
therefore over-invests in that layer. The owner has accepted this trade-off
knowingly. The threat-model note in `README.md` is updated to say the server is
now reachable from the public internet and what compensating controls exist.

**Hard prerequisite:** the home ISP must provide a real public IP. Under CGNAT,
inbound port-forwarding cannot work and this design is not viable without a
relay. The setup doc includes a one-command CGNAT check to run *first*.

## Architecture

```
iPhone (Immich app, anywhere, no VPN)
        │  https://<name>.duckdns.org
        ▼
Home router  ── port-forward 443 ──►  Caddy  ──►  Immich (127.0.0.1:2283)
        ▲                              │
   DuckDNS updater keeps               ├─ Let's Encrypt TLS + security headers
   the dynamic IP current             └─ JSON access log
                                                 │
                                        fail2ban bans brute-forcing IPs
```

## Components

### New
- **`caddy/` service in the compose stack** — terminates HTTPS for the DuckDNS
  hostname, reverse-proxies to Immich, emits a JSON access log to a shared
  volume for fail2ban. Immich's port is no longer published to the host; it is
  reachable only over the internal compose network.
- **`scripts/duckdns-update.sh`** + systemd timer (cron fallback documented) —
  keeps the DuckDNS record pointed at the current home IP. Reads token/domain
  from env. Logs success/failure; exits non-zero on API failure.
- **fail2ban jail** (`docs/` + config snippet) — watches Caddy's access log,
  bans IPs after repeated failed Immich logins.
- **`docs/remote-access-setup.md`** — replaces `docs/tailscale-setup.md`.
  Sections: DuckDNS signup, **CGNAT check (run first)**, router port-forward,
  Caddy config, fail2ban, and the account-hardening checklist.
- **`tests/test_duckdns-update.sh`** — mocks `curl`; asserts the updater calls
  the DuckDNS API with the right domain + token and handles an API failure
  (KO / non-zero) correctly. Follows the existing mocked-harness style.

### Changed
- **`immich/docker-compose.yml`** — add Caddy; stop publishing Immich's port to
  the host; add a shared log volume; ensure public registration is disabled.
- **`immich/example.env`** — add `DUCKDNS_DOMAIN`, `DUCKDNS_TOKEN`,
  `PUBLIC_HOSTNAME`; note the registration-disabled setting.
- **`docs/family-onboarding.md`** — remove the entire Tailscale/VPN part; server
  URL becomes `https://<name>.duckdns.org`; add a TOTP-enrollment step; update
  the "can't reach the server" troubleshooting (no VPN toggle anymore).
- **`README.md`** — retitle away from Tailscale; update the layout table,
  order-of-operations, and the threat-model/backup-honesty note to reflect
  public exposure.

### Removed
- **`docs/tailscale-setup.md`**.

## The new auth layer (detail)

1. **HTTPS everywhere** — Caddy + Let's Encrypt; valid cert the iOS Immich app
   trusts. Immich never served plaintext or on a raw exposed port.
2. **Per-person accounts, strong unique passwords, self-registration OFF** —
   admin provisions each account; nobody can self-register.
3. **TOTP 2FA required** — enrolled during onboarding. A leaked password alone
   is insufficient. Documented opt-out for anyone who genuinely can't manage an
   authenticator app, with the risk called out.
4. **fail2ban + Immich rate limiting** — brute-force defense that the VPN
   previously made unnecessary.

## Testing

- **New:** `tests/test_duckdns-update.sh` (mocked `curl`; success + failure
  paths).
- **Unchanged and must still pass:** `tests/test_backup.sh`,
  `tests/test_update.sh`. Backup/restore scripts are untouched — this change is
  about access, not storage.
- **Manual verification** (checklist in the setup doc): TLS cert valid from an
  external network; Immich's raw port not reachable from the LAN host; a
  deliberate failed-login burst actually produces a fail2ban ban.

## Out of scope (YAGNI)

Cloudflare, WireGuard, VLAN segmentation, off-site backup changes, Immich
version bumps. No changes to `scripts/backup.sh`, `scripts/update.sh`, or
`scripts/restore.md`.
