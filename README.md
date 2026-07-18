# Family Photo Backup Server

Self-hosted [Immich](https://immich.app) + [Tailscale](https://tailscale.com)
so the whole family's iPhones back up automatically to a box at home — no
Apple developer account, no cloud subscription, photos never leave machines
we control.

## Why this design

iOS won't let a web page back up the camera roll in the background, and we
can't ship a native app. Immich's official iOS app (free, App Store) does
automatic background backup; we only host the server. Tailscale gives every
family phone a private, encrypted path to the server from anywhere — nothing
is exposed to the public internet.

## Layout

| Path | What |
|---|---|
| `immich/` | Pinned Docker Compose stack + env template |
| `scripts/backup.sh` | Nightly DB dump + library rsync to external drive |
| `scripts/update.sh` | Version bump with mandatory release-notes check |
| `scripts/restore.md` | Disaster recovery, with a yearly verification drill |
| `docs/server-setup.md` | Blank Linux box → running server |
| `docs/tailscale-setup.md` | Private remote access |
| `docs/family-onboarding.md` | 10-minute per-iPhone setup |
| `tests/` | Test harnesses for the scripts (mocked docker/rsync) |

## Order of operations

1. `docs/server-setup.md`
2. `docs/tailscale-setup.md`
3. `docs/family-onboarding.md` for each person

## Keeping backups honest

Backups fail silently if nobody looks: once a month, check that the last line
of `/var/log/immich-backup.log` says "backup completed OK". Off-site copies
(e.g. a Backblaze B2 sync of `/mnt/backup`) are a good later upgrade once this
is routine; note that the backup drive itself is unencrypted — anyone holding
it can read the photos.

Design spec: `docs/superpowers/specs/2026-07-18-family-photo-backup-design.md`
