# Disaster Recovery: Restoring Immich from Backup

Use this when the server disk died, the machine was lost, or the database is
corrupted. You need: this repo, the external backup drive, and a Linux box
with Docker installed (see `docs/server-setup.md` for base setup).

## What's on the backup drive

- `immich-db-YYYY-MM-DD.sql.gz` — nightly Postgres dumps (newest = best)
- `library/` — full photo library mirror
- `immich.env` — a nightly copy of the old server's `immich/.env`, including
  its `DB_PASSWORD` and the `IMMICH_VERSION` it was running

## Steps

1. **Base setup** — Work from the repo root: `cd /opt/family-photos`. Follow
   `docs/server-setup.md` up to (but NOT including) "First start". Copy
   `immich/example.env` to `immich/.env` for now — you'll
   overwrite it with the old server's real settings in the next step, instead
   of reconstructing `DB_PASSWORD` and `IMMICH_VERSION` by hand. (Restoring an
   old dump under a much newer `IMMICH_VERSION` forces a large migration jump
   on first start, so getting the old pin back matters.)

2. **Mount the backup drive** (do NOT follow the formatting steps in
   server-setup §6 — the drive already holds your backup and mkfs would
   erase it), then copy back the old server's saved `.env` instead of
   reconstructing it:

       sudo blkid            # find the backup drive's UUID
       sudo mkdir -p /mnt/backup
       sudo mount -o ro UUID=<paste-uuid-here> /mnt/backup
       ls /mnt/backup        # you should see immich-db-*.sql.gz and library/
       cp /mnt/backup/immich.env /opt/family-photos/immich/.env

   `immich.env` on the drive has the same `DB_PASSWORD` and `IMMICH_VERSION`
   the old server was running. If it isn't there (older backup, from before
   this file existed), fall back to setting a new `DB_PASSWORD` in
   `immich/.env` — the dump recreates roles, so a new password also works, it
   is overwritten by the dump's role definitions — and set `IMMICH_VERSION`
   to whatever the old server was running, if you know it.

3. **Restore the photo library** (do this before starting Immich):

       sudo mkdir -p /data/immich
       sudo rsync -a /mnt/backup/library/ /data/immich/library/

4. **Start ONLY the database container:**

       cd immich && docker compose up -d database
       docker compose logs -f database   # wait for "ready to accept connections", Ctrl-C

5. **Load the newest dump:**

       gunzip -c "$(ls -t /mnt/backup/immich-db-*.sql.gz | head -1)" \
         | docker exec -i immich_postgres psql --username=postgres

   You will see several errors about roles or databases already existing, or the current user not being droppable — these are expected from a pg_dumpall --clean restore and harmless; psql continues and the data still loads.

6. **Start the rest of the stack:**

       docker compose up -d

7. **Verify:** open `http://<server>:2283` (or the Tailscale URL), log in with
   a family account, confirm photos, albums, and people are present.

8. **Re-arm nightly backups** — on a rebuilt machine they are NOT configured yet:

       sudo umount /mnt/backup     # it was mounted read-only for the restore

   Now do server-setup §6 (backup drive + cron) — but SKIP the mkfs.ext4
   formatting lines: this drive already holds your backup. The fstab entry,
   the .backup-drive marker, and the cron entry all need to be recreated.
   Finish by running one manual backup and checking the log ends with
   "backup completed OK".

## Verification drill (do once after initial setup)

Prove the dump restores cleanly without touching production:

    gunzip -c /mnt/backup/immich-db-<date>.sql.gz | head -50   # looks like SQL?
    docker run --rm -d --name restore_test \
      -e POSTGRES_PASSWORD=test ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    until docker exec restore_test pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
    gunzip -c /mnt/backup/immich-db-<date>.sql.gz \
      | docker exec -i restore_test psql --username=postgres
    docker exec restore_test psql -U postgres -d immich -c 'SELECT count(*) FROM asset;'
    docker rm -f restore_test

A nonzero asset count = your backup restores. If the count query errors instead
(table not found), run `docker exec restore_test psql -U postgres -d immich -c '\dt'`
to list tables — the asset table's name may differ across Immich versions; a
table list full of immich tables still means the restore worked. Run this
drill once now, then yearly thereafter.
