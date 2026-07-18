# Family Photo Backup Server — Design Spec

**Date:** 2026-07-18
**Status:** Approved

## Problem

The family (4–8 people, all iPhone users) needs automatic photo backup and
shared viewing. Building a native iOS app is off the table (no Apple developer
account), and a plain web page cannot back up an iPhone camera roll in the
background — iOS does not allow it.

## Decision

Self-host **Immich** (open-source Google Photos replacement) on a home Linux
mini-PC. Immich's official iOS app is on the App Store, so family members get
automatic background backup with no developer account needed. Remote access is
via **Tailscale** (private mesh VPN) — the server is never exposed to the
public internet.

This repo is a **curated deployment repo**: everything needed to build,
operate, back up, and rebuild the server from scratch lives here in git.

## Constraints and sizing

- Server: Linux PC / mini-PC / spare laptop running Docker.
- Scale: 4–8 users, 500 GB – 2 TB of photos and videos.
- Access: family iPhones, at home and remote (Wi-Fi and cellular).
- Cost: hardware already owned; no recurring cloud costs required.

## Architecture

```
iPhone (Immich app + Tailscale app)
        │  HTTPS over tailnet
        ▼
Home Linux box ── Tailscale (host, `tailscale serve` for HTTPS)
        │
        ▼
Docker Compose stack (pinned version):
  immich-server ── immich-machine-learning
        │                │
     Postgres ────── Redis
        │
  Host path /data/immich  (photo library — never inside a container volume)
```

- Photos live on a dedicated host directory (e.g. `/data/immich`), bind-mounted
  into the containers, so container rebuilds never touch the library.
- Tailscale gives the server a stable name (e.g. `photos.<tailnet>.ts.net`)
  with automatic HTTPS. No port forwarding, no public exposure.
- Each family iPhone installs two free App Store apps: **Tailscale** (log in
  once) and **Immich** (point at server URL, enable background backup).

## Repo layout

```
immich/docker-compose.yml   # pinned Immich version, healthchecks, restart policy
immich/example.env          # template: data paths, DB password, upload location
scripts/backup.sh           # nightly: pg_dump + rsync library → external drive
scripts/restore.md          # step-by-step, tested disaster recovery
scripts/update.sh           # safe update: show release notes, confirm, pull, migrate
docs/server-setup.md        # blank Linux box → running Immich
docs/tailscale-setup.md     # server setup + inviting family to the tailnet
docs/family-onboarding.md   # per-iPhone 10-minute setup guide
```

## Backup strategy

The server is copy #1 of photos that may soon exist nowhere else (phones fill
up and people delete). Therefore the server itself must be backed up:

- `scripts/backup.sh`, run nightly by cron:
  1. `pg_dump` the Immich Postgres database (albums, faces, metadata).
  2. `rsync` the photo library to an external USB drive (~4 TB covers the
     target scale).
  3. Log to a file; exit nonzero loudly if the drive is absent or rsync fails.
- `scripts/restore.md` documents full recovery onto a fresh machine and is
  verified once by restoring the DB dump into a scratch container. An untested
  backup is a hope, not a backup.
- Off-site backup (e.g. Backblaze B2) is documented as an optional later step —
  not built now.

## Update policy

Immich releases frequently and occasionally ships breaking changes. Therefore:

- The compose file pins an **exact version** — no `latest` tag.
- `scripts/update.sh` prints the release-notes URL, requires interactive
  confirmation, then pulls the new pinned version and restarts the stack.
- No automatic updates. A stale-but-working family server beats a broken
  current one.

## Operational safety

- All containers: healthchecks + `restart: unless-stopped`.
- Backup failures are loud (nonzero exit under cron, logged).
- `docs/server-setup.md` includes a "server seems down" troubleshooting
  checklist.

## Success criteria

1. A family iPhone backs up photos automatically over home Wi-Fi **and**
   cellular (via Tailscale).
2. Photos are viewable in the Immich iOS app and web UI.
3. `backup.sh` produces a restorable copy — verified by an actual test restore
   of the DB dump.
4. `update.sh` completes one successful version bump.

## Out of scope (YAGNI)

- Custom viewer/gallery UI (Immich's own UI suffices).
- Public share links to non-family members.
- Automated off-site backup.
- Ansible / full machine provisioning.
- GPU acceleration for machine learning.
