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
docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres \
  | gzip > "$dump_file" || fail "database dump failed"
log "database dump written to $dump_file"

# Prune old dumps, keep the newest $KEEP_DUMPS
prune_old_dumps() {
  local old
  while IFS= read -r old; do
    rm -- "$old" || return 1
    log "pruned old dump $old"
  done < <(ls -1t "$BACKUP_DRIVE"/immich-db-*.sql.gz 2>/dev/null | tail -n +"$((KEEP_DUMPS + 1))")
}
prune_old_dumps || fail "pruning old dumps failed"

log "starting library rsync"
rsync -a --delete "$UPLOAD_LOCATION/" "$BACKUP_DRIVE/library/" \
  || fail "library rsync failed"

log "backup completed OK"
