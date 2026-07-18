#!/usr/bin/env bash
# Safe Immich update: pin bump with mandatory release-notes check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMMICH_DIR="${IMMICH_DIR:-$SCRIPT_DIR/../immich}"
ENV_FILE="$IMMICH_DIR/.env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found (copy example.env to .env first)"; exit 1; }

current="$(grep -E '^IMMICH_VERSION=' "$ENV_FILE" | cut -d= -f2 || true)"
[ -n "$current" ] \
  || { echo "ERROR: no IMMICH_VERSION line found in $ENV_FILE"; exit 1; }
echo "Current pinned version: $current"
echo "Read the release notes FIRST — Immich sometimes ships breaking changes:"
echo "  https://github.com/immich-app/immich/releases"
echo

read -rp "New version tag to install (e.g. v2.1.0), empty to abort: " new_version
[ -n "$new_version" ] || { echo "Aborted: no version given."; exit 1; }
[[ "$new_version" =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "Aborted: '$new_version' is not a valid version tag."; exit 1; }

read -rp "Have you read the release notes for $new_version? [y/N] " confirmed
[ "$confirmed" = "y" ] || { echo "Aborted: read the release notes, then re-run."; exit 1; }

sed -i "s|^IMMICH_VERSION=.*|IMMICH_VERSION=$new_version|" "$ENV_FILE"
echo "Pinned $new_version in $ENV_FILE"

docker compose -f "$IMMICH_DIR/docker-compose.yml" --env-file "$ENV_FILE" pull
docker compose -f "$IMMICH_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d
echo "Update to $new_version complete. Verify: open the web UI and check Server Status."
