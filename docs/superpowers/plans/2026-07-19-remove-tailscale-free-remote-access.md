# Remove Tailscale — Free Public Remote Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Tailscale with a zero-subscription public-access stack — DuckDNS + Caddy HTTPS + a hardened Immich login layer (fail2ban, TOTP, no self-registration).

**Architecture:** Immich stops publishing its port to the host and is reached only through a new Caddy reverse proxy that terminates Let's Encrypt TLS for a DuckDNS hostname. A small updater script keeps the DuckDNS record pointed at the home IP. fail2ban watches Caddy's access log and bans brute-forcers. Docs are rewritten to drop the VPN and describe the new access + auth flow.

**Tech Stack:** Docker Compose, Caddy 2, DuckDNS, fail2ban, Bash (POSIX-ish, `set -euo pipefail`), mocked Bash test harnesses.

## Global Constraints

- Backup/restore scripts are **untouched**: no edits to `scripts/backup.sh`, `scripts/update.sh`, `scripts/restore.md`. `tests/test_backup.sh` and `tests/test_update.sh` must still pass unchanged.
- New Bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`, matching existing scripts.
- New tests follow the existing mocked-harness style: `mktemp -d` sandbox, `trap 'rm -rf' EXIT`, mock binaries on `PATH`, `fail()` helper, final `echo "ALL ... TESTS PASSED"`.
- Immich version pin (`v3.0.3`) and image digests in `docker-compose.yml` are NOT changed by this work.
- Every commit uses `git config user.email noreply@anthropic.com` / `user.name Claude` (already set on this branch).
- No secrets committed: real DuckDNS tokens, passwords, and the actual hostname live only in `.env`, never in tracked files. `example.env` uses placeholders.

---

### Task 1: DuckDNS updater script

**Files:**
- Create: `scripts/duckdns-update.sh`
- Test: `tests/test_duckdns-update.sh`

**Interfaces:**
- Consumes: env vars `DUCKDNS_DOMAIN` (subdomain label, no `.duckdns.org`), `DUCKDNS_TOKEN`, optional `LOG_FILE`, optional `DUCKDNS_URL_BASE` (defaults to `https://www.duckdns.org/update`, overridable so tests can point `curl` anywhere).
- Produces: exit 0 on DuckDNS `OK`, non-zero on `KO` / curl failure; appends a timestamped result line to `LOG_FILE` if set.

- [ ] **Step 1: Write the failing test**

Create `tests/test_duckdns-update.sh`:

```bash
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

echo "ALL DUCKDNS TESTS PASSED"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_duckdns-update.sh`
Expected: FAIL — `scripts/duckdns-update.sh` does not exist yet (bash: No such file).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/duckdns-update.sh`:

```bash
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
  [ -n "${LOG_FILE:-}" ] && echo "$line" >> "$LOG_FILE"
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
```

Then `chmod +x scripts/duckdns-update.sh`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_duckdns-update.sh`
Expected: `ALL DUCKDNS TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/duckdns-update.sh
git add scripts/duckdns-update.sh tests/test_duckdns-update.sh
git commit -m "feat: add DuckDNS updater script with mocked test"
```

---

### Task 2: Caddy reverse proxy + compose/env changes

**Files:**
- Create: `immich/Caddyfile`
- Modify: `immich/docker-compose.yml` (remove `ports` on `immich-server`; add `caddy` service + `caddy-data`/`caddy-config`/`caddy-logs` volumes)
- Modify: `immich/example.env` (add access/DuckDNS vars)

**Interfaces:**
- Consumes: `PUBLIC_HOSTNAME` (full DuckDNS FQDN, e.g. `myfamily.duckdns.org`) from `.env`.
- Produces: Caddy listening on host ports 80/443, proxying to `immich-server:2283` over the compose network; a JSON access log at the `caddy-logs` volume path `/var/log/caddy/access.log` (consumed by fail2ban in Task 3).

- [ ] **Step 1: Create the Caddyfile**

Create `immich/Caddyfile`:

```
# Caddy terminates HTTPS for the DuckDNS hostname and proxies to Immich.
# {$PUBLIC_HOSTNAME} is read from the environment (set in .env).
{$PUBLIC_HOSTNAME} {
	encode zstd gzip

	# Reverse-proxy everything to Immich on the internal compose network.
	reverse_proxy immich-server:2283

	# Security headers.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# JSON access log to a shared volume so fail2ban can watch it.
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MiB
			roll_keep 5
		}
		format json
	}
}
```

- [ ] **Step 2: Modify `docker-compose.yml` — stop exposing Immich, add Caddy**

In `immich/docker-compose.yml`, on `immich-server`, delete these two lines (currently lines 12–13):

```yaml
    ports:
      - '2283:2283'
```

Add a `caddy` service immediately after the `immich-server` block (before `immich-machine-learning`):

```yaml
  caddy:
    container_name: immich_caddy
    image: docker.io/library/caddy:2-alpine
    ports:
      - '80:80'
      - '443:443'
    environment:
      PUBLIC_HOSTNAME: ${PUBLIC_HOSTNAME}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
      - caddy-logs:/var/log/caddy
    depends_on:
      - immich-server
    restart: unless-stopped
```

Extend the `volumes:` block at the bottom (currently `model-cache:` only) to:

```yaml
volumes:
  model-cache:
  caddy-data:
  caddy-config:
  caddy-logs:
```

- [ ] **Step 3: Modify `example.env` — add access vars**

Append to `immich/example.env`:

```bash

# --- Public remote access (Caddy + DuckDNS) ---
# Full DuckDNS hostname Caddy serves HTTPS for. Must resolve to your home IP.
PUBLIC_HOSTNAME=myfamily.duckdns.org

# DuckDNS subdomain label (the part before .duckdns.org) and account token.
# Used by scripts/duckdns-update.sh. Keep the token secret — .env only.
DUCKDNS_DOMAIN=myfamily
DUCKDNS_TOKEN=CHANGE_ME_DUCKDNS_TOKEN

# SECURITY: Immich public sign-up MUST stay disabled so strangers cannot
# self-register on your internet-exposed server. Disable it in the Immich
# web UI: Administration -> Settings -> User Settings -> turn OFF "Allow
# public user registration". (There is no compose flag for this in v3.0.3.)
```

- [ ] **Step 4: Validate compose parses**

Run: `docker compose -f immich/docker-compose.yml --env-file immich/example.env config >/dev/null && echo COMPOSE_OK`
Expected: `COMPOSE_OK` (validates YAML + variable interpolation without starting anything).
If `docker` is unavailable in the execution environment, instead run `python3 -c "import yaml,sys; yaml.safe_load(open('immich/docker-compose.yml')); print('YAML_OK')"` and confirm `YAML_OK`.

- [ ] **Step 5: Confirm Immich port is no longer published**

Run: `grep -n "2283:2283" immich/docker-compose.yml || echo NO_HOST_PORT`
Expected: `NO_HOST_PORT` (the host publish was removed; `2283` still appears only inside `reverse_proxy` in the Caddyfile).

- [ ] **Step 6: Commit**

```bash
git add immich/Caddyfile immich/docker-compose.yml immich/example.env
git commit -m "feat: front Immich with Caddy HTTPS and stop exposing its raw port"
```

---

### Task 3: fail2ban config + remote-access setup doc (replaces Tailscale doc)

**Files:**
- Create: `immich/fail2ban/filter.d/immich-caddy.conf`
- Create: `immich/fail2ban/jail.d/immich.conf`
- Create: `docs/remote-access-setup.md`
- Delete: `docs/tailscale-setup.md`

**Interfaces:**
- Consumes: Caddy JSON access log from Task 2 (`caddy-logs` volume → bind-mount to host `/var/log/immich-caddy/access.log` per the doc).
- Produces: a host-level fail2ban jail that bans IPs after repeated failed Immich logins.

- [ ] **Step 1: Create the fail2ban filter**

Create `immich/fail2ban/filter.d/immich-caddy.conf`:

```ini
# Matches failed Immich logins in Caddy's JSON access log.
# Immich returns HTTP 401 from POST /api/auth/login on bad credentials.
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"uri":"/api/auth/login".*"status":401.*$
ignoreregex =
```

- [ ] **Step 2: Create the fail2ban jail**

Create `immich/fail2ban/jail.d/immich.conf`:

```ini
[immich-caddy]
enabled  = true
backend  = auto
filter   = immich-caddy
logpath  = /var/log/immich-caddy/access.log
maxretry = 5
findtime = 10m
bantime  = 1h
# Requires nftables or iptables on the host; see remote-access-setup.md.
```

- [ ] **Step 3: Write the setup doc**

Create `docs/remote-access-setup.md`:

```markdown
# Remote Access — Free & Self-Hosted (DuckDNS + Caddy)

Goal: every family iPhone can reach the Immich server from anywhere over
HTTPS, with **no VPN and no subscription**. The server is now reachable from
the public internet, so the login layer is the whole defense — this guide
sets up the hardening that replaces what the VPN used to guarantee.

## 0. Check for CGNAT FIRST (do this before anything else)

Public access needs your ISP to give you a real public IP. If you are behind
CGNAT, inbound port-forwarding cannot work and this approach won't either.

Compare the two:

    curl -s https://api.ipify.org ; echo         # your public IP
    # then read the "WAN IP" on your router's status page

If they MATCH, you have a public IP — continue. If the router shows a
`100.64.x.x`–`100.127.x.x` address or a different IP than ipify, you are
likely behind CGNAT: stop here and either ask your ISP for a public IP, or
switch to a tunnel-based approach.

## 1. DuckDNS

1. Sign in at https://www.duckdns.org with any listed provider (free).
2. Create a subdomain, e.g. `myfamily` → gives `myfamily.duckdns.org`.
3. Copy your **token** from the top of the page.
4. Put both in `immich/.env`:

       PUBLIC_HOSTNAME=myfamily.duckdns.org
       DUCKDNS_DOMAIN=myfamily
       DUCKDNS_TOKEN=<your token>

5. Keep the record current with a systemd timer running the updater:

   Create `/etc/systemd/system/duckdns.service`:

       [Unit]
       Description=DuckDNS update
       After=network-online.target

       [Service]
       Type=oneshot
       EnvironmentFile=/opt/immich/immich/.env
       ExecStart=/opt/immich/immich/../scripts/duckdns-update.sh
       # (point ExecStart at the real path of scripts/duckdns-update.sh)

   Create `/etc/systemd/system/duckdns.timer`:

       [Unit]
       Description=Run DuckDNS update every 5 minutes

       [Timer]
       OnBootSec=1min
       OnUnitActiveSec=5min

       [Install]
       WantedBy=timers.target

   Enable it:

       sudo systemctl enable --now duckdns.timer

   (Cron fallback: `*/5 * * * * DUCKDNS_DOMAIN=myfamily DUCKDNS_TOKEN=... /path/to/scripts/duckdns-update.sh`)

## 2. Port-forward on your router

Forward TCP **443** (and **80**, needed once for the Let's Encrypt challenge)
from the router to the server's LAN IP. Give the server a static DHCP lease so
that IP doesn't change.

## 3. Start Caddy (comes up with the stack)

Caddy is part of `immich/docker-compose.yml`. On `docker compose up -d` it
requests a Let's Encrypt certificate for `PUBLIC_HOSTNAME` automatically.
Verify from a phone on **cellular** (not home Wi-Fi):

    https://myfamily.duckdns.org

You should get the Immich login over a valid certificate. This URL is what
family members enter in the Immich app.

## 4. Harden the login layer (this replaces the VPN's gatekeeping)

1. **Disable public registration** — Immich web UI → Administration →
   Settings → User Settings → turn **off** "Allow public user registration".
2. **One account per person, strong unique passwords** — admin creates each
   account (Administration → Users) and shares a strong starting password.
3. **Require TOTP two-factor** — each member enables it in Account Settings
   during onboarding (see `docs/family-onboarding.md`).
4. **fail2ban** — bans IPs that hammer the login:

       sudo apt install fail2ban            # Debian/Ubuntu

   Expose Caddy's log to the host by bind-mounting the `caddy-logs` volume,
   or copy the shipped config which reads `/var/log/immich-caddy/access.log`:

       sudo mkdir -p /var/log/immich-caddy
       # bind Caddy's log here, e.g. add to the caddy service:
       #   - /var/log/immich-caddy:/var/log/caddy
       sudo cp immich/fail2ban/filter.d/immich-caddy.conf /etc/fail2ban/filter.d/
       sudo cp immich/fail2ban/jail.d/immich.conf         /etc/fail2ban/jail.d/
       sudo systemctl restart fail2ban
       sudo fail2ban-client status immich-caddy

## 5. Verify the hardening works

- [ ] Cert valid when browsing `https://myfamily.duckdns.org` from cellular.
- [ ] Immich's raw port is NOT reachable: `curl -sS http://<server-LAN-IP>:2283`
      from another LAN host should refuse/timeout (port no longer published).
- [ ] Fire 6 bad logins, then `sudo fail2ban-client status immich-caddy` shows
      your test IP banned.

## Notes

- If a phone can't reach the server: confirm `https://myfamily.duckdns.org`
  loads from cellular; if not, re-check port-forwarding and the DuckDNS timer
  (`systemctl status duckdns.timer`).
- Renewing certs is automatic (Caddy). Keep port 80 forwarded so renewals
  succeed.
```

- [ ] **Step 4: Delete the Tailscale doc**

```bash
git rm docs/tailscale-setup.md
```

- [ ] **Step 5: Verify no stray references to the deleted doc remain (fixed in Task 4)**

Run: `grep -rn "tailscale-setup.md" --include='*.md' . || echo NO_REFS`
Expected: matches in `README.md` (fixed in Task 4). Note them; do not fail here.

- [ ] **Step 6: Commit**

```bash
git add immich/fail2ban docs/remote-access-setup.md
git add -A docs/tailscale-setup.md
git commit -m "feat: add fail2ban config and free remote-access guide; drop Tailscale doc"
```

---

### Task 4: Rewrite onboarding + README for the VPN-free flow

**Files:**
- Modify: `docs/family-onboarding.md` (remove Tailscale part; new URL; TOTP step)
- Modify: `README.md` (retitle, layout table, order-of-operations, threat-model note)
- Modify: `docs/server-setup.md` (redirect its two Tailscale references at §7 and the troubleshooting list)

**Interfaces:**
- Consumes: the DuckDNS hostname convention and TOTP requirement from Task 3.
- Produces: docs with zero remaining references to Tailscale/VPN.

- [ ] **Step 1: Rewrite `docs/family-onboarding.md`**

Replace the whole file with:

```markdown
# iPhone Setup — 5 Minutes Per Person

No VPN app anymore — just Immich. What each family member needs from you
(the admin) beforehand:
- Their Immich login (email + starting password you created)
- The server URL: `https://<name>.duckdns.org`

## Install & sign in (2 min)

1. App Store → install **Immich**.
2. Open it → Server Endpoint URL: `https://<name>.duckdns.org` → Next.
3. Log in with your email + starting password.
4. Change the password in **Settings → Account** after first login.

## Turn on two-factor (required) (2 min)

1. Install an authenticator app (Google Authenticator, or the built-in iOS
   Passwords app can store codes).
2. In Immich: **Settings → Account → Two-factor authentication** → scan the
   QR code with the authenticator → enter the 6-digit code to confirm.
3. Save the recovery codes somewhere safe. From now on login asks for a code.

   (If you genuinely can't manage an authenticator, tell the admin — 2FA can
   be left off for your account, but your password alone then guards your
   photos on a public server. Not recommended.)

## Turn on backup (3 min)

1. Enable backup: tap the **cloud icon** (top right) →
   - **Select albums**: choose *Recents* (that's the whole camera roll)
   - Turn ON **Automatic backup**
   - Turn ON **Background backup**
2. Enable Background App Refresh for Immich, or background backup silently
   won't run: iPhone **Settings → General → Background App Refresh** → make
   sure it's on globally AND for Immich. (iOS runs background uploads when it
   decides conditions are good — typically on Wi-Fi and charging — so they
   are not instant.)
3. **Allow Access to All Photos**: iOS shows this prompt when you turn on
   Automatic backup — choose **Allow Access to All Photos**.
4. Keep the app open on the backup screen until the first big upload finishes
   (first backup of a full phone can take hours — plug in, leave on Wi-Fi
   overnight; it continues in the background afterwards).

## Checking it works

Cloud icon shows "Backed up" with a growing count. Take a photo, wait a few
minutes (or open the app) — it should appear on the server.

If new photos stop appearing for days: open the Immich app (foreground upload
always works), then check Background App Refresh is still on — iOS turns it
off for everyone when Low Power Mode is enabled.

## FAQ

- **Does this use my mobile data?** No — by default Immich only uploads on
  Wi-Fi. If you WANT backup over cellular too, turn it on in Immich's backup
  settings (watch your data plan).
- **Can I delete photos from my phone after backup?** Yes — once backed up,
  they stay on the server. The Immich app can even do this for you
  (Backup → free up space), but double-check the photo is on the server first.
- **Is someone else seeing my photos?** Each person has their own library.
  Sharing happens only through albums you explicitly share.
- **The app says it can't reach the server.** Check `https://<name>.duckdns.org`
  loads in Safari. If not, the server or its internet connection may be down —
  tell the admin.
```

- [ ] **Step 2: Update `README.md`**

Apply these edits to `README.md`:

Replace lines 1–15 (title through the "## Why this design" paragraph) with:

```markdown
# Family Photo Backup Server

Self-hosted [Immich](https://immich.app) so the whole family's iPhones back
up automatically to a box at home — no Apple developer account, no cloud
subscription, no VPN subscription. Reached over HTTPS from anywhere via free
[DuckDNS](https://www.duckdns.org) dynamic DNS and a [Caddy](https://caddyserver.com)
reverse proxy.

## Why this design

iOS won't let a web page back up the camera roll in the background, and we
can't ship a native app. Immich's official iOS app (free, App Store) does
automatic background backup; we only host the server. Instead of a paid VPN,
family phones reach the server directly over HTTPS at a DuckDNS address, and
the login layer is hardened (no public sign-up, per-person accounts, required
TOTP two-factor, fail2ban) since the server is now internet-facing.
```

In the layout table, replace the `docs/tailscale-setup.md` row with:

```markdown
| `docs/remote-access-setup.md` | Free public HTTPS access + login hardening |
```

Also add, right after the `immich/` row:

```markdown
| `immich/Caddyfile` | Caddy reverse proxy (HTTPS termination) config |
| `immich/fail2ban/` | fail2ban filter + jail for failed-login bans |
| `scripts/duckdns-update.sh` | Keeps the DuckDNS record on your home IP |
```

Replace the "Order of operations" list with:

```markdown
1. `docs/server-setup.md`
2. `docs/remote-access-setup.md`
3. `docs/family-onboarding.md` for each person
```

Replace the closing "Keeping backups honest" paragraph's threat-model note so
it also covers internet exposure. Change the final paragraph to:

```markdown
Backups fail silently if nobody looks: once a month, check that the last line
of `/var/log/immich-backup.log` says "backup completed OK". Off-site copies
(e.g. a Backblaze B2 sync of `/mnt/backup`) are a good later upgrade once this
is routine; note that the backup drive itself is unencrypted — anyone holding
it can read the photos, and since the drive also carries `immich.env`, they
can read the server's database password too.

**Security note (internet-facing):** unlike the old VPN setup, the server is
now reachable from the public internet at your DuckDNS address. Your defense
is the login layer — keep public registration OFF, use strong unique
passwords, keep TOTP two-factor on for every account, and keep fail2ban
running. See `docs/remote-access-setup.md`.
```

Update the design-spec pointer line at the bottom to reference the new spec:

```markdown
Design spec: `docs/superpowers/specs/2026-07-19-remove-tailscale-free-remote-access-design.md`
```

- [ ] **Step 3: Redirect the Tailscale references in `docs/server-setup.md`**

`docs/server-setup.md` has two Tailscale mentions. Apply both edits:

Replace §7 (currently `## 7. Remote access` followed by `Follow \`docs/tailscale-setup.md\`.`) body line:

```markdown
Follow `docs/remote-access-setup.md`.
```

Replace the troubleshooting bullet `5. Tailscale up? \`tailscale status\` on the server.` with:

```markdown
5. Reachable from outside? Load `https://<name>.duckdns.org` from a phone on
   cellular. If not, check port-forwarding and the DuckDNS timer
   (`systemctl status duckdns.timer`).
```

- [ ] **Step 4: Verify no VPN/Tailscale references remain**

Run: `grep -rin "tailscale\|\bVPN\b" README.md docs/family-onboarding.md docs/server-setup.md docs/remote-access-setup.md || echo NO_REFS`
Expected: `NO_REFS`. (Historical mentions inside `docs/superpowers/specs/` and `docs/superpowers/plans/` are design records and are intentionally NOT checked here.)

- [ ] **Step 5: Commit**

```bash
git add README.md docs/family-onboarding.md docs/server-setup.md
git commit -m "docs: rewrite onboarding and README for VPN-free public access"
```

---

### Task 5: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run every shell test**

Run:
```bash
bash tests/test_backup.sh && bash tests/test_update.sh && bash tests/test_duckdns-update.sh
```
Expected: `ALL BACKUP TESTS PASSED`, `ALL UPDATE TESTS PASSED`, `ALL DUCKDNS TESTS PASSED` — proving the untouched backup/update paths still pass and the new updater works.

- [ ] **Step 2: Final reference sweep**

Run: `grep -rin "tailscale" README.md docs/family-onboarding.md docs/server-setup.md docs/remote-access-setup.md || echo CLEAN`
Expected: `CLEAN`.

- [ ] **Step 3: Push the branch**

```bash
git push -u origin claude/remove-vpn-free-auth-haka2h
```
(Retry with exponential backoff on network errors: 2s, 4s, 8s, 16s.)

---

## Self-Review

- **Spec coverage:** DuckDNS updater (Task 1) ✓; Caddy + stop exposing port + example.env + disable-registration note (Task 2) ✓; fail2ban + remote-access doc + delete tailscale doc (Task 3) ✓; onboarding + README + threat-model note (Task 4) ✓; new test + untouched tests still pass (Tasks 1 & 5) ✓; TOTP required with documented opt-out (Task 4 onboarding) ✓; CGNAT check first (Task 3 doc §0) ✓.
- **Placeholders:** none — all scripts, configs, and doc bodies are complete. `CHANGE_ME_*` / `<name>` are intentional user-supplied values, not plan gaps.
- **Type/name consistency:** `PUBLIC_HOSTNAME`, `DUCKDNS_DOMAIN`, `DUCKDNS_TOKEN`, `DUCKDNS_URL_BASE`, `LOG_FILE` used identically across script, test, Caddyfile, compose, and doc. Log path `/var/log/caddy/access.log` (container) ↔ `/var/log/immich-caddy/access.log` (host bind) is consistent between Caddyfile, jail config, and doc.
