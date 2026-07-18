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

# --- Test 3: retention prunes old dumps, keeping the KEEP_DUMPS newest ---
rm -f "$SANDBOX/backup.log"
rm -f "$DRIVE"/immich-db-*.sql.gz

touch -t 202601010000 "$DRIVE/immich-db-2026-01-01.sql.gz"
touch -t 202601020000 "$DRIVE/immich-db-2026-01-02.sql.gz"
touch -t 202601030000 "$DRIVE/immich-db-2026-01-03.sql.gz"

PATH="$MOCKS:$PATH" BACKUP_DRIVE="$DRIVE" UPLOAD_LOCATION="$LIB" \
  LOG_FILE="$SANDBOX/backup.log" KEEP_DUMPS=2 \
  bash "$REPO_ROOT/scripts/backup.sh" || fail "backup.sh exited nonzero during retention test"

today_dump="$DRIVE/immich-db-$(date +%F).sql.gz"
[ -f "$today_dump" ] || fail "today's dump was not written during retention test"

remaining_count=$(ls -1 "$DRIVE"/immich-db-*.sql.gz | wc -l)
[ "$remaining_count" -eq 2 ] || fail "expected 2 dumps after pruning, found $remaining_count"

# KEEP_DUMPS=2 keeps the 2 newest overall: today's fresh dump and the newest
# of the pre-seeded old dumps (2026-01-03); the older two must be pruned.
[ -f "$DRIVE/immich-db-2026-01-03.sql.gz" ] || fail "newest old dump was pruned but should have survived"
[ -f "$DRIVE/immich-db-2026-01-01.sql.gz" ] && fail "oldest dump should have been pruned"
[ -f "$DRIVE/immich-db-2026-01-02.sql.gz" ] && fail "second-oldest dump should have been pruned"

grep -q "pruned old dump" "$SANDBOX/backup.log" || fail "no pruning log line during retention test"

echo "ALL BACKUP TESTS PASSED"
