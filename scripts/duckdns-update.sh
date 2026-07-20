#!/usr/bin/env bash
set -euo pipefail

# Keeps a DuckDNS record pointed at this host's current public IP.
# Run on a timer (see docs/remote-access-setup.md). Required env:
#   DUCKDNS_DOMAIN  subdomain label only, e.g. "myfamily" for myfamily.duckdns.org
#   DUCKDNS_TOKEN   token from the DuckDNS account page
# Optional: LOG_FILE, DUCKDNS_URL_BASE (default https://www.duckdns.org/update)

: "${DUCKDNS_DOMAIN:?set DUCKDNS_DOMAIN}"
: "${DUCKDNS_TOKEN:?set DUCKDNS_TOKEN}"
URL_BASE="${DUCKDNS_URL_BASE:-https://www.duckdns.org/update}"

log() {
  local line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line"
  [ -n "${LOG_FILE:-}" ] && echo "$line" >> "$LOG_FILE" || true
}

# DuckDNS returns literal "OK" or "KO" in the body. Blank ip= lets DuckDNS
# detect the public IP from the request source.
resp="$(curl -fsS "${URL_BASE}?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" || true)"

if [ "$resp" = "OK" ]; then
  log "DuckDNS update OK for ${DUCKDNS_DOMAIN}"
  exit 0
fi

log "ERROR: DuckDNS update failed for ${DUCKDNS_DOMAIN} (response: '${resp:-<none>}')"
exit 1
