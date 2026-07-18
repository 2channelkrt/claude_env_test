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
