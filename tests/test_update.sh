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
if [ -f "$SANDBOX/fail_pull" ]; then
  for arg in "\$@"; do
    if [ "\$arg" = "pull" ]; then
      exit 1
    fi
  done
fi
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

# --- Test 4: version with sed metacharacter is rejected ---
sed -i 's/^IMMICH_VERSION=.*/IMMICH_VERSION=v2.0.1/' "$IMMICH_DIR/.env"
rm -f "$SANDBOX/docker.calls"
if printf 'v2.1&0\ny\n' | PATH="$MOCKS:$PATH" IMMICH_DIR="$IMMICH_DIR" \
  bash "$REPO_ROOT/scripts/update.sh" 2>/dev/null; then
  fail "update.sh proceeded with an invalid version tag"
fi
grep -q '^IMMICH_VERSION=v2.0.1$' "$IMMICH_DIR/.env" || fail ".env changed after invalid version"
[ ! -f "$SANDBOX/docker.calls" ] || fail "docker invoked after invalid version"

# --- Test 5: missing IMMICH_VERSION line in .env errors clearly ---
printf 'DB_PASSWORD=x\n' > "$IMMICH_DIR/.env"
rm -f "$SANDBOX/docker.calls"
output="$(printf 'v2.1.0\ny\n' | PATH="$MOCKS:$PATH" IMMICH_DIR="$IMMICH_DIR" \
  bash "$REPO_ROOT/scripts/update.sh" 2>&1)" && fail "update.sh proceeded without IMMICH_VERSION line"
echo "$output" | grep -q "no IMMICH_VERSION line" || fail "missing IMMICH_VERSION line error message not shown"

# restore a good .env in case later assertions are added after this point
printf 'IMMICH_VERSION=v2.0.1\nDB_PASSWORD=x\n' > "$IMMICH_DIR/.env"

# --- Test 6: pull failure leaves .env unchanged and never reaches up -d ---
rm -f "$SANDBOX/docker.calls"
touch "$SANDBOX/fail_pull"
if printf 'v2.1.0\ny\n' | PATH="$MOCKS:$PATH" IMMICH_DIR="$IMMICH_DIR" \
  bash "$REPO_ROOT/scripts/update.sh" 2>/dev/null; then
  fail "update.sh succeeded despite a failed docker compose pull"
fi
grep -q '^IMMICH_VERSION=v2.0.1$' "$IMMICH_DIR/.env" || fail ".env changed after a failed pull"
grep -q "up -d" "$SANDBOX/docker.calls" && fail "up -d was called despite a failed pull"
rm -f "$SANDBOX/fail_pull"

echo "ALL UPDATE TESTS PASSED"
