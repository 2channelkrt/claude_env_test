#!/usr/bin/env bash
# Nightly Immich backup: Postgres dump + photo library rsync to external drive.
# Install via cron (see docs/server-setup.md):
#   30 2 * * * /opt/family-photos/scripts/backup.sh
set -euo pipefail

BACKUP_DRIVE="${BACKUP_DRIVE:-/mnt/backup}"
UPLOAD_LOCATION="${UPLOAD_LOCATION:-/data/immich/library}"
LOG_FILE="${LOG_FILE:-/var/log/immich-backup.log}"
KEEP_DUMPS="${KEEP_DUMPS:-14}"
IMMICH_ENV_FILE="${IMMICH_ENV_FILE:-/opt/family-photos/immich/.env}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; exit 1; }

mountpoint -q "$BACKUP_DRIVE" || [ -e "$BACKUP_DRIVE/.backup-drive" ] \
  || fail "backup drive not mounted at $BACKUP_DRIVE"

log "starting database dump"
dump_file="$BACKUP_DRIVE/immich-db-$(date +%F).sql.gz"
docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres \
  | gzip > "$dump_file.tmp" || { rm -f "$dump_file.tmp"; fail "database dump failed"; }
mv "$dump_file.tmp" "$dump_file"
log "database dump written to $dump_file"

# Copy the .env (DB_PASSWORD, IMMICH_VERSION) alongside the dump so a dead
# server's pin and password aren't lost with it. Missing file is a warning,
# not a failure — the nightly backup must not break because of it.
if [ -f "$IMMICH_ENV_FILE" ]; then
  install -m 600 "$IMMICH_ENV_FILE" "$BACKUP_DRIVE/immich.env"
  log "env file copied"
else
  log "WARNING: env file $IMMICH_ENV_FILE not found; skipping env backup"
fi

# Prune old dumps, keep the newest $KEEP_DUMPS
prune_old_dumps() {
  local old
  while IFS= read -r old; do
    rm -- "$old" || return 1
    log "pruned old dump $old"
  done < <(ls -1t "$BACKUP_DRIVE"/immich-db-*.sql.gz 2>/dev/null | tail -n +"$((KEEP_DUMPS + 1))")
}
prune_old_dumps || fail "pruning old dumps failed"

# Refuse to mirror with --delete if the source library is missing or empty —
# an unmounted data disk must never look like "the family deleted everything".
[ -n "$(ls -A "$UPLOAD_LOCATION" 2>/dev/null)" ] \
  || fail "library at $UPLOAD_LOCATION is missing or empty; refusing to mirror with --delete"

log "starting library rsync"
rsync -a --delete "$UPLOAD_LOCATION/" "$BACKUP_DRIVE/library/" \
  || fail "library rsync failed"

log "backup completed OK"
