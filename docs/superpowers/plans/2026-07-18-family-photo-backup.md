# Family Photo Backup Server (Immich + Tailscale) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a curated deployment repo that stands up, operates, backs up, and rebuilds a self-hosted Immich photo server for a 4–8 person family, reached via Tailscale.

**Architecture:** Docker Compose stack (Immich server, machine learning, Postgres, Redis) with photo library on a host bind mount; Tailscale on the host provides private HTTPS access. The repo carries pinned config, a nightly backup script (DB dump + rsync to external drive), a confirm-before-update script, a tested restore procedure, and setup/onboarding docs.

**Tech Stack:** Docker Compose, Bash (strict mode), Immich (pinned release), Tailscale, rsync, cron.

## Global Constraints

- Immich version is pinned exactly in `immich/example.env` (`IMMICH_VERSION=v2.0.1`); never use a `latest`/`release` floating tag. At execution time, check https://github.com/immich-app/immich/releases and substitute the current stable tag if newer — but it must remain an exact pin.
- All shell scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`, and must pass `shellcheck` with zero warnings (if `shellcheck` is unavailable in the environment, `bash -n` at minimum and note it in the commit message).
- Photo library lives at host path `${UPLOAD_LOCATION}` (default `/data/immich/library`); Postgres data at `${DB_DATA_LOCATION}` (default `/data/immich/postgres`). Never inside named container volumes (except the ML model cache, which is disposable).
- Real secrets live only in `immich/.env` (gitignored). The repo ships `immich/example.env` with placeholder password `CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD`.
- Scripts must be runnable from any working directory (resolve paths relative to the script's own location).
- This container cannot run the real stack; verification here is: script test harnesses (mocked commands), `bash -n`/`shellcheck`, and YAML validation. On-server verification steps are documented, not executed.
- Commit after every task; commit messages must not mention model identity.

---

### Task 1: Immich Compose stack + environment template

**Files:**
- Create: `immich/docker-compose.yml`
- Create: `immich/example.env`
- Create: `.gitignore`

**Interfaces:**
- Produces: container names `immich_server`, `immich_machine_learning`, `immich_postgres`, `immich_redis` (backup/update scripts and docs depend on these exact names); env vars `IMMICH_VERSION`, `UPLOAD_LOCATION`, `DB_DATA_LOCATION`, `DB_PASSWORD`, `DB_USERNAME`, `DB_DATABASE_NAME`, `TZ`.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
immich/.env
*.log
```

- [ ] **Step 2: Create `immich/example.env`**

```bash
# Copy to .env alongside docker-compose.yml, then edit values.
# cp example.env .env

# Exact pinned Immich release. Check breaking changes before bumping:
# https://github.com/immich-app/immich/releases
IMMICH_VERSION=v2.0.1

# Where photos are stored on the HOST. Must exist before first start.
UPLOAD_LOCATION=/data/immich/library

# Where the Postgres database files are stored on the HOST.
DB_DATA_LOCATION=/data/immich/postgres

# Timezone for correct photo timestamps in logs.
TZ=Etc/UTC

# Postgres credentials. Set a long random password:
#   openssl rand -base64 30
DB_PASSWORD=CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

- [ ] **Step 3: Create `immich/docker-compose.yml`**

Based on the official Immich release compose, with exact version pin and stable container names:

```yaml
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION}
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - '2283:2283'
    depends_on:
      - redis
      - database
    restart: unless-stopped
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION}
    volumes:
      - model-cache:/cache
    env_file:
      - .env
    restart: unless-stopped
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:8-bookworm
    healthcheck:
      test: redis-cli ping || exit 1
    restart: unless-stopped

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  model-cache:
```

At execution time, cross-check image tags for the pinned version against the official release assets (`https://github.com/immich-app/immich/releases/download/<tag>/docker-compose.yml`) if network access allows; keep the container names and bind-mount decisions above.

- [ ] **Step 4: Validate the compose file**

Run:
```bash
cd immich && cp example.env .env && docker compose config >/dev/null && echo COMPOSE_OK; rm .env
```
Expected: `COMPOSE_OK`.
If the `docker` CLI is unavailable, fallback validation:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('immich/docker-compose.yml')); print('YAML_OK')"
```
Expected: `YAML_OK`.

- [ ] **Step 5: Commit**

```bash
git add .gitignore immich/docker-compose.yml immich/example.env
git commit -m "feat: add pinned Immich docker-compose stack and env template"
```

---

### Task 2: Nightly backup script with test harness

**Files:**
- Create: `scripts/backup.sh`
- Test: `tests/test_backup.sh`

**Interfaces:**
- Consumes: container name `immich_postgres` (Task 1); env var names from Task 1.
- Produces: `scripts/backup.sh` honoring env overrides `BACKUP_DRIVE` (default `/mnt/backup`), `UPLOAD_LOCATION` (default `/data/immich/library`), `LOG_FILE` (default `/var/log/immich-backup.log`), `KEEP_DUMPS` (default `14`). Exit 0 on success, nonzero with `ERROR:` log line on any failure. Writes `immich-db-YYYY-MM-DD.sql.gz` and `library/` into `$BACKUP_DRIVE`.

- [ ] **Step 1: Write the failing test**

`tests/test_backup.sh` — runs `backup.sh` against mocked `docker`, `rsync`, and `mountpoint` binaries placed first on `PATH`, in a temp sandbox:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MOCKS="$SANDBOX/mocks"
DRIVE="$SANDBOX/drive"
LIB="$SANDBOX/library"
mkdir -p "$MOCKS" "$DRIVE" "$LIB"
echo "fake-photo" > "$LIB/img1.jpg"

# Mock: mountpoint succeeds only for $DRIVE
cat > "$MOCKS/mountpoint" <<EOF
#!/usr/bin/env bash
[ "\$2" = "$DRIVE" ] || [ "\$1" = "$DRIVE" ]
EOF

# Mock: docker exec prints a fake SQL dump and records its invocation
cat > "$MOCKS/docker" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SANDBOX/docker.calls"
echo "-- fake sql dump"
EOF

# Mock: rsync records its invocation and copies with cp -r
cat > "$MOCKS/rsync" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SANDBOX/rsync.calls"
src="\${@: -2:1}"; dst="\${@: -1}"
mkdir -p "\$dst" && cp -r "\$src". "\$dst"
EOF
chmod +x "$MOCKS"/*

run_backup() {
  PATH="$MOCKS:$PATH" \
  BACKUP_DRIVE="$DRIVE" \
  UPLOAD_LOCATION="$LIB" \
  LOG_FILE="$SANDBOX/backup.log" \
  bash "$REPO_ROOT/scripts/backup.sh"
}

fail() { echo "FAIL: $1"; exit 1; }

# --- Test 1: happy path ---
run_backup || fail "backup.sh exited nonzero on happy path"
ls "$DRIVE"/immich-db-*.sql.gz >/dev/null 2>&1 || fail "no DB dump written"
gzip -t "$DRIVE"/immich-db-*.sql.gz || fail "DB dump is not valid gzip"
[ -f "$DRIVE/library/img1.jpg" ] || fail "library not synced"
grep -q "pg_dumpall" "$SANDBOX/docker.calls" || fail "pg_dumpall not invoked"
grep -q -- "--delete" "$SANDBOX/rsync.calls" || fail "rsync missing --delete"
grep -q "backup completed OK" "$SANDBOX/backup.log" || fail "no success log line"

# --- Test 2: missing drive fails loudly ---
rm -f "$SANDBOX/backup.log"
if PATH="$MOCKS:$PATH" BACKUP_DRIVE="$SANDBOX/nonexistent" \
   UPLOAD_LOCATION="$LIB" LOG_FILE="$SANDBOX/backup.log" \
   bash "$REPO_ROOT/scripts/backup.sh" 2>/dev/null; then
  fail "backup.sh succeeded with missing backup drive"
fi
grep -q "ERROR:" "$SANDBOX/backup.log" || fail "no ERROR log line for missing drive"

echo "ALL BACKUP TESTS PASSED"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_backup.sh`
Expected: FAIL — `scripts/backup.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/backup.sh`**

```bash
#!/usr/bin/env bash
# Nightly Immich backup: Postgres dump + photo library rsync to external drive.
# Install via cron (see docs/server-setup.md):
#   30 2 * * * /opt/family-photos/scripts/backup.sh
set -euo pipefail

BACKUP_DRIVE="${BACKUP_DRIVE:-/mnt/backup}"
UPLOAD_LOCATION="${UPLOAD_LOCATION:-/data/immich/library}"
LOG_FILE="${LOG_FILE:-/var/log/immich-backup.log}"
KEEP_DUMPS="${KEEP_DUMPS:-14}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; exit 1; }

mountpoint -q "$BACKUP_DRIVE" || [ -e "$BACKUP_DRIVE/.backup-drive" ] \
  || fail "backup drive not mounted at $BACKUP_DRIVE"

log "starting database dump"
dump_file="$BACKUP_DRIVE/immich-db-$(date +%F).sql.gz"
docker exec -t immich_postgres pg_dumpall --clean --if-exists --username=postgres \
  | gzip > "$dump_file" || fail "database dump failed"
log "database dump written to $dump_file"

# Prune old dumps, keep the newest $KEEP_DUMPS
find "$BACKUP_DRIVE" -maxdepth 1 -name 'immich-db-*.sql.gz' -print0 \
  | xargs -0 ls -1t 2>/dev/null | tail -n +"$((KEEP_DUMPS + 1))" \
  | while IFS= read -r old; do rm -- "$old"; log "pruned old dump $old"; done

log "starting library rsync"
rsync -a --delete "$UPLOAD_LOCATION/" "$BACKUP_DRIVE/library/" \
  || fail "library rsync failed"

log "backup completed OK"
```

Note on the mount check: `mountpoint -q` is the primary guard against
writing a "backup" onto the empty mount directory when the drive is absent.
The `.backup-drive` marker file (created once on the real drive per
`docs/server-setup.md`, Task 5) is a fallback for setups where the drive is
auto-mounted somewhere `mountpoint` doesn't apply. The test exercises the
`mountpoint` path via its mock.

- [ ] **Step 4: Make executable, lint, and run the test**

Run:
```bash
chmod +x scripts/backup.sh tests/test_backup.sh
bash -n scripts/backup.sh && (command -v shellcheck >/dev/null && shellcheck scripts/backup.sh || echo "shellcheck unavailable")
bash tests/test_backup.sh
```
Expected: `ALL BACKUP TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/backup.sh tests/test_backup.sh
git commit -m "feat: add nightly backup script (pg_dumpall + rsync) with test harness"
```

---

### Task 3: Safe update script with test harness

**Files:**
- Create: `scripts/update.sh`
- Test: `tests/test_update.sh`

**Interfaces:**
- Consumes: `immich/.env` with `IMMICH_VERSION=` line (Task 1); `immich/docker-compose.yml` (Task 1).
- Produces: `scripts/update.sh` — interactive; env override `IMMICH_DIR` (default: `<repo>/immich` resolved from script location). Prompts for new version tag and confirmation that release notes were read; rewrites `IMMICH_VERSION` in `.env`; runs `docker compose pull` then `up -d`. Aborts (nonzero) on empty version or unconfirmed notes.

- [ ] **Step 1: Write the failing test**

`tests/test_update.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MOCKS="$SANDBOX/mocks"
IMMICH_DIR="$SANDBOX/immich"
mkdir -p "$MOCKS" "$IMMICH_DIR"
cp "$REPO_ROOT/immich/docker-compose.yml" "$IMMICH_DIR/"
printf 'IMMICH_VERSION=v2.0.1\nDB_PASSWORD=x\n' > "$IMMICH_DIR/.env"

cat > "$MOCKS/docker" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SANDBOX/docker.calls"
EOF
chmod +x "$MOCKS/docker"

fail() { echo "FAIL: $1"; exit 1; }

# --- Test 1: happy path (version + confirmation piped in) ---
printf 'v2.1.0\ny\n' | PATH="$MOCKS:$PATH" IMMICH_DIR="$IMMICH_DIR" \
  bash "$REPO_ROOT/scripts/update.sh" || fail "update.sh failed on happy path"
grep -q '^IMMICH_VERSION=v2.1.0$' "$IMMICH_DIR/.env" || fail ".env not updated"
grep -q "pull" "$SANDBOX/docker.calls" || fail "docker compose pull not invoked"
grep -q "up -d" "$SANDBOX/docker.calls" || fail "docker compose up -d not invoked"

# --- Test 2: declining the release-notes confirmation aborts ---
sed -i 's/^IMMICH_VERSION=.*/IMMICH_VERSION=v2.0.1/' "$IMMICH_DIR/.env"
rm -f "$SANDBOX/docker.calls"
if printf 'v2.1.0\nn\n' | PATH="$MOCKS:$PATH" IMMICH_DIR="$IMMICH_DIR" \
  bash "$REPO_ROOT/scripts/update.sh" 2>/dev/null; then
  fail "update.sh proceeded despite declined confirmation"
fi
grep -q '^IMMICH_VERSION=v2.0.1$' "$IMMICH_DIR/.env" || fail ".env changed after abort"
[ ! -f "$SANDBOX/docker.calls" ] || fail "docker invoked after abort"

# --- Test 3: empty version aborts ---
if printf '\n' | PATH="$MOCKS:$PATH" IMMICH_DIR="$IMMICH_DIR" \
  bash "$REPO_ROOT/scripts/update.sh" 2>/dev/null; then
  fail "update.sh proceeded with empty version"
fi

echo "ALL UPDATE TESTS PASSED"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_update.sh`
Expected: FAIL — `scripts/update.sh: No such file or directory`.

- [ ] **Step 3: Write `scripts/update.sh`**

```bash
#!/usr/bin/env bash
# Safe Immich update: pin bump with mandatory release-notes check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMMICH_DIR="${IMMICH_DIR:-$SCRIPT_DIR/../immich}"
ENV_FILE="$IMMICH_DIR/.env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (copy example.env to .env first)"; exit 1; }

current="$(grep -E '^IMMICH_VERSION=' "$ENV_FILE" | cut -d= -f2)"
echo "Current pinned version: $current"
echo "Read the release notes FIRST — Immich sometimes ships breaking changes:"
echo "  https://github.com/immich-app/immich/releases"
echo

read -rp "New version tag to install (e.g. v2.1.0), empty to abort: " new_version
[ -n "$new_version" ] || { echo "Aborted: no version given."; exit 1; }

read -rp "Have you read the release notes for $new_version? [y/N] " confirmed
[ "$confirmed" = "y" ] || { echo "Aborted: read the release notes, then re-run."; exit 1; }

sed -i "s|^IMMICH_VERSION=.*|IMMICH_VERSION=$new_version|" "$ENV_FILE"
echo "Pinned $new_version in $ENV_FILE"

docker compose -f "$IMMICH_DIR/docker-compose.yml" --env-file "$ENV_FILE" pull
docker compose -f "$IMMICH_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d
echo "Update to $new_version complete. Verify: open the web UI and check Server Status."
```

- [ ] **Step 4: Make executable, lint, and run the test**

Run:
```bash
chmod +x scripts/update.sh tests/test_update.sh
bash -n scripts/update.sh && (command -v shellcheck >/dev/null && shellcheck scripts/update.sh || echo "shellcheck unavailable")
bash tests/test_update.sh
```
Expected: `ALL UPDATE TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add scripts/update.sh tests/test_update.sh
git commit -m "feat: add confirm-before-update script with test harness"
```

---

### Task 4: Restore procedure (disaster recovery doc)

**Files:**
- Create: `scripts/restore.md`

**Interfaces:**
- Consumes: backup artifacts from Task 2 (`immich-db-YYYY-MM-DD.sql.gz`, `library/` on the backup drive); compose stack from Task 1.

- [ ] **Step 1: Write `scripts/restore.md`**

```markdown
# Disaster Recovery: Restoring Immich from Backup

Use this when the server disk died, the machine was lost, or the database is
corrupted. You need: this repo, the external backup drive, and a Linux box
with Docker installed (see `docs/server-setup.md` for base setup).

## What's on the backup drive

- `immich-db-YYYY-MM-DD.sql.gz` — nightly Postgres dumps (newest = best)
- `library/` — full photo library mirror

## Steps

1. **Base setup** — follow `docs/server-setup.md` up to (but NOT including)
   "First start". Copy `immich/example.env` to `immich/.env` and set the SAME
   `DB_PASSWORD` as the old server if you know it; otherwise set a new one
   (the dump recreates roles, so a new password also works — it is overwritten
   by the dump's role definitions).

2. **Restore the photo library** (do this before starting Immich):

       sudo mkdir -p /data/immich
       sudo rsync -a /mnt/backup/library/ /data/immich/library/

3. **Start ONLY the database container:**

       cd immich && docker compose up -d database
       docker compose logs -f database   # wait for "ready to accept connections", Ctrl-C

4. **Load the newest dump:**

       gunzip -c /mnt/backup/immich-db-2026-07-18.sql.gz \
         | docker exec -i immich_postgres psql --username=postgres

   Errors about "role postgres already exists" are harmless.

5. **Start the rest of the stack:**

       docker compose up -d

6. **Verify:** open `http://<server>:2283` (or the Tailscale URL), log in with
   a family account, confirm photos, albums, and people are present.

7. **Re-arm backups:** re-plug the backup drive and confirm the cron entry
   (see `docs/server-setup.md`) is active:

       sudo crontab -l | grep backup.sh

## Verification drill (do once after initial setup)

Prove the dump restores cleanly without touching production:

    gunzip -c /mnt/backup/immich-db-<date>.sql.gz | head -50   # looks like SQL?
    docker run --rm -d --name restore_test \
      -e POSTGRES_PASSWORD=test ghcr.io/immich-app/postgres:14-vectorchord0.3.0-pgvectors0.2.0
    sleep 15
    gunzip -c /mnt/backup/immich-db-<date>.sql.gz \
      | docker exec -i restore_test psql --username=postgres
    docker exec restore_test psql -U postgres -d immich -c 'SELECT count(*) FROM asset;'
    docker rm -f restore_test

A nonzero asset count = your backup restores. Do this drill yearly.
```

- [ ] **Step 2: Review consistency with Tasks 1–2**

Check: container name `immich_postgres`, dump filename pattern
`immich-db-YYYY-MM-DD.sql.gz`, paths `/data/immich/library` and `/mnt/backup`
all match Task 1/2 definitions exactly.

- [ ] **Step 3: Commit**

```bash
git add scripts/restore.md
git commit -m "docs: add tested disaster-recovery restore procedure"
```

---

### Task 5: Server setup guide + README

**Files:**
- Create: `docs/server-setup.md`
- Create: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4 (paths, container names, script locations).

- [ ] **Step 1: Write `docs/server-setup.md`**

```markdown
# Server Setup: Blank Linux Box → Running Immich

Target: any x86 Linux machine (mini-PC, spare laptop) with Ubuntu Server or
Debian, ≥8 GB RAM recommended (Immich ML wants ~4 GB), and a data disk with
room for 2 TB of photos.

## 1. Install Docker

    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER   # log out and back in

## 2. Get this repo onto the server

    sudo mkdir -p /opt/family-photos && sudo chown $USER /opt/family-photos
    git clone <this-repo-url> /opt/family-photos
    cd /opt/family-photos

## 3. Prepare storage

    sudo mkdir -p /data/immich/library /data/immich/postgres

If /data is a separate disk, mount it via /etc/fstab first.

## 4. Configure

    cd immich
    cp example.env .env
    openssl rand -base64 30    # use output as DB_PASSWORD in .env
    nano .env                  # set DB_PASSWORD and TZ (e.g. America/Los_Angeles)

## 5. First start

    docker compose up -d
    docker compose ps          # all services healthy/running after ~1 min

Open http://<server-ip>:2283 and create the FIRST account — this becomes the
admin. Create one account per family member (Administration → Users), or let
them register if you prefer.

## 6. Backup drive + cron

Plug in the external USB drive (≥4 TB), then:

    lsblk                                   # find it, e.g. /dev/sda1
    sudo mkdir -p /mnt/backup
    echo '/dev/sda1 /mnt/backup ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
    sudo mount -a
    sudo touch /mnt/backup/.backup-drive    # marker checked by backup.sh
    sudo crontab -e
    # add:
    30 2 * * * /opt/family-photos/scripts/backup.sh

Run once manually and check it: `sudo /opt/family-photos/scripts/backup.sh`
then `cat /var/log/immich-backup.log`.

Now do the restore **verification drill** in `scripts/restore.md` — once, now,
while nothing is on fire.

## 7. Remote access

Follow `docs/tailscale-setup.md`.

## Troubleshooting: "the server seems down"

1. Is the box on and on the network? `ping <server-ip>` from your laptop.
2. Containers running? `cd /opt/family-photos/immich && docker compose ps`
3. Anything crash-looping? `docker compose logs --tail 50 immich-server`
4. Disk full? `df -h /data` — Immich stops accepting uploads on a full disk.
5. Tailscale up? `tailscale status` on the server.
6. Nuclear option (safe — photos are on the host disk):
   `docker compose down && docker compose up -d`
```

- [ ] **Step 2: Write `README.md`**

```markdown
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

Design spec: `docs/superpowers/specs/2026-07-18-family-photo-backup-design.md`
```

- [ ] **Step 3: Commit**

```bash
git add docs/server-setup.md README.md
git commit -m "docs: add server setup guide and README"
```

---

### Task 6: Tailscale setup guide

**Files:**
- Create: `docs/tailscale-setup.md`

**Interfaces:**
- Consumes: server from Task 5; port 2283 from Task 1.
- Produces: the HTTPS URL shape `https://<machine-name>.<tailnet>.ts.net` used by Task 7.

- [ ] **Step 1: Write `docs/tailscale-setup.md`**

```markdown
# Tailscale: Private Remote Access

Goal: every family iPhone can reach the Immich server from anywhere, over an
encrypted private network, with a valid HTTPS URL — and nothing on the server
is exposed to the public internet.

## 1. Create a tailnet

Sign up at https://login.tailscale.com (free "Personal" plan covers 3 users;
the "Family" plan covers 6 — check current plans). Use your own account as
the tailnet owner.

## 2. Install on the server

    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up

Follow the printed login URL. Then name the machine something friendly in the
admin console (e.g. `photos`), and in **DNS settings** enable **MagicDNS**
and **HTTPS certificates**.

## 3. Serve Immich over HTTPS

    sudo tailscale serve --bg 2283

This proxies `https://photos.<tailnet>.ts.net` → local port 2283 with an
automatic TLS certificate. Verify from any tailnet device:

    https://photos.<your-tailnet>.ts.net

This URL is what family members enter in the Immich app.

## 4. Disable key expiry for the server

Admin console → Machines → `photos` → ⋯ → **Disable key expiry**.
Otherwise the server silently drops off the tailnet after ~180 days.

## 5. Invite the family

Admin console → **Users** → **Invite users** → enter each person's email.
They accept on their iPhone during onboarding (`docs/family-onboarding.md`).

## Notes

- Backup traffic on home Wi-Fi still goes through the Tailscale URL, but
  Tailscale routes device-to-device on the LAN automatically — no slow path.
- If a phone can't reach the server: check the Tailscale app is connected
  (toggle at top), then check `tailscale status` on the server.
```

- [ ] **Step 2: Commit**

```bash
git add docs/tailscale-setup.md
git commit -m "docs: add Tailscale remote access guide"
```

---

### Task 7: Family onboarding guide

**Files:**
- Create: `docs/family-onboarding.md`

**Interfaces:**
- Consumes: server URL shape from Task 6; per-person Immich accounts from Task 5.

- [ ] **Step 1: Write `docs/family-onboarding.md`**

```markdown
# iPhone Setup — 10 Minutes Per Person

What each family member needs from you (the admin) beforehand:
- A Tailscale invite email (sent from the Tailscale admin console)
- Their Immich login (email + starting password you created)
- The server URL: `https://photos.<tailnet>.ts.net`

## Part 1: Tailscale (3 min)

1. App Store → install **Tailscale**.
2. Open it → **Log in** → use the SAME account/email the invite went to.
3. Allow the VPN configuration when iOS asks.
4. Leave the toggle **on**. It stays connected in the background and only
   carries traffic to our server — normal internet use is unaffected, and
   battery impact is negligible.

## Part 2: Immich (5 min)

1. App Store → install **Immich**.
2. Open it → Server Endpoint URL: `https://photos.<tailnet>.ts.net` → Next.
3. Log in with your email + password (change the password in
   Settings → Account after first login).
4. Enable backup: tap the **cloud icon** (top right) →
   - **Select albums**: choose *Recents* (that's the whole camera roll)
   - Turn ON **Automatic backup**
   - Turn ON **Background backup**
5. iOS will ask for photo access → choose **Allow Access to All Photos**.
6. Keep the app open on the backup screen until the first big upload finishes
   (first backup of a full phone can take hours — plug in, leave on Wi-Fi
   overnight; it continues in the background afterwards).

## Checking it works

Cloud icon shows "Backed up" with a growing count. Take a photo, wait a few
minutes (or open the app) — it should appear on the server.

## FAQ

- **Does this use my mobile data?** By default backup runs on Wi-Fi and
  cellular. To restrict: Immich → Backup settings → turn off cellular upload.
- **Can I delete photos from my phone after backup?** Yes — once backed up,
  they stay on the server. The Immich app can even do this for you
  (Backup → free up space), but double-check the photo is on the server first.
- **Is someone else seeing my photos?** Each person has their own library.
  Sharing happens only through albums you explicitly share.
- **The app says it can't reach the server.** Open Tailscale, make sure the
  toggle is on and it says Connected.
```

- [ ] **Step 2: Commit**

```bash
git add docs/family-onboarding.md
git commit -m "docs: add family iPhone onboarding guide"
```

---

### Task 8: Final verification and push

**Files:**
- Modify: none (verification only)

- [ ] **Step 1: Run everything**

```bash
bash tests/test_backup.sh && bash tests/test_update.sh
python3 -c "import yaml; yaml.safe_load(open('immich/docker-compose.yml')); print('YAML_OK')"
```
Expected: `ALL BACKUP TESTS PASSED`, `ALL UPDATE TESTS PASSED`, `YAML_OK`.

- [ ] **Step 2: Cross-reference sweep**

Grep that every referenced path/name resolves:
```bash
grep -rn "immich_postgres\|/data/immich\|/mnt/backup\|photos\." docs/ scripts/ immich/ README.md | less
```
Check: container names match compose; every doc link (`docs/*.md`, `scripts/restore.md`) exists.

- [ ] **Step 3: Push**

```bash
git push -u origin claude/family-photo-backup-web-tlq1b2
```
