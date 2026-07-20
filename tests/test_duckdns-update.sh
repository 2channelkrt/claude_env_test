#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MOCKS="$SANDBOX/mocks"
mkdir -p "$MOCKS"

# Mock curl: record args, print whatever RESPONSE file holds
cat > "$MOCKS/curl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$SANDBOX/curl.calls"
cat "$SANDBOX/response"
EOF
chmod +x "$MOCKS"/*

fail() { echo "FAIL: $1"; exit 1; }

run() {
  PATH="$MOCKS:$PATH" \
  DUCKDNS_DOMAIN=myfamily \
  DUCKDNS_TOKEN=tok-123 \
  DUCKDNS_URL_BASE="http://mock.invalid/update" \
  LOG_FILE="$SANDBOX/duckdns.log" \
  bash "$REPO_ROOT/scripts/duckdns-update.sh"
}

# --- Test 1: OK response -> exit 0, logs success, passes domain+token ---
printf 'OK' > "$SANDBOX/response"
run || fail "updater exited nonzero on OK response"
grep -q "domains=myfamily" "$SANDBOX/curl.calls" || fail "domain not sent to DuckDNS"
grep -q "token=tok-123" "$SANDBOX/curl.calls" || fail "token not sent to DuckDNS"
grep -q "OK" "$SANDBOX/duckdns.log" || fail "no success line logged"

# --- Test 2: KO response -> non-zero exit, logs error ---
rm -f "$SANDBOX/duckdns.log"
printf 'KO' > "$SANDBOX/response"
if run 2>/dev/null; then fail "updater succeeded on KO response"; fi
grep -qi "error\|KO" "$SANDBOX/duckdns.log" || fail "no error line logged on KO"

# --- Test 3: OK response with LOG_FILE unset -> still exit 0 ---
printf 'OK' > "$SANDBOX/response"
PATH="$MOCKS:$PATH" DUCKDNS_DOMAIN=myfamily DUCKDNS_TOKEN=tok-123 \
  DUCKDNS_URL_BASE="http://mock.invalid/update" \
  bash "$REPO_ROOT/scripts/duckdns-update.sh" >/dev/null \
  || fail "updater exited nonzero on OK response with LOG_FILE unset"

echo "ALL DUCKDNS TESTS PASSED"
