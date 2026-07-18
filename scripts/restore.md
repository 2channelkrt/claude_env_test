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
