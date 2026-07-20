# Family Photo Backup Server

Self-hosted [Immich](https://immich.app) so the whole family's iPhones back
up automatically to a box at home — no Apple developer account, no cloud
subscription, no VPN subscription. Reached over HTTPS from anywhere via free
[DuckDNS](https://www.duckdns.org) dynamic DNS and a [Caddy](https://caddyserver.com)
reverse proxy.

## Why this design

iOS won't let a web page back up the camera roll in the background, and we
can't ship a native app. Immich's official iOS app (free, App Store) does
automatic background backup; we only host the server. Instead of a paid VPN,
family phones reach the server directly over HTTPS at a DuckDNS address, and
the login layer is hardened (no public sign-up, per-person accounts, required
TOTP two-factor, fail2ban) since the server is now internet-facing.

## Layout

| Path | What |
|---|---|
| `immich/` | Pinned Docker Compose stack + env template |
| `immich/Caddyfile` | Caddy reverse proxy (HTTPS termination) config |
| `immich/fail2ban/` | fail2ban filter + jail for failed-login bans |
| `scripts/duckdns-update.sh` | Keeps the DuckDNS record on your home IP |
| `scripts/backup.sh` | Nightly DB dump + library rsync to external drive |
| `scripts/update.sh` | Version bump with mandatory release-notes check |
| `scripts/restore.md` | Disaster recovery, with a yearly verification drill |
| `docs/server-setup.md` | Blank Linux box → running server |
| `docs/remote-access-setup.md` | Free public HTTPS access + login hardening |
| `docs/family-onboarding.md` | 10-minute per-iPhone setup |
| `tests/` | Test harnesses for the scripts (mocked docker/rsync) |

## Order of operations

1. `docs/server-setup.md`
2. `docs/remote-access-setup.md`
3. `docs/family-onboarding.md` for each person

## Keeping backups honest

Backups fail silently if nobody looks: once a month, check that the last line
of `/var/log/immich-backup.log` says "backup completed OK". Off-site copies
(e.g. a Backblaze B2 sync of `/mnt/backup`) are a good later upgrade once this
is routine; note that the backup drive itself is unencrypted — anyone holding
it can read the photos, and since the drive also carries `immich.env`, they
can read the server's database password too.

**Security note (internet-facing):** unlike the old VPN setup, the server is
now reachable from the public internet at your DuckDNS address. Your defense
is the login layer — keep public registration OFF, use strong unique
passwords, keep TOTP two-factor on for every account, and keep fail2ban
running. See `docs/remote-access-setup.md`.

Design spec: `docs/superpowers/specs/2026-07-19-remove-tailscale-free-remote-access-design.md`
