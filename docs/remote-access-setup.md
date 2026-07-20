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
       EnvironmentFile=/opt/family-photos/immich/.env
       ExecStart=/opt/family-photos/scripts/duckdns-update.sh
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
4. **fail2ban** — bans IPs that hammer the login. Two required steps:
   expose Caddy's access log on the host, then install the shipped jail.

   a. The stack already bind-mounts `/var/log/immich-caddy` on the host to
      Caddy's log dir. Create it and (re)start Caddy:

          sudo mkdir -p /var/log/immich-caddy
          docker compose up -d caddy

   b. Install fail2ban and the shipped filter + jail (the jail reads
      `/var/log/immich-caddy/access.log`):

          sudo apt install fail2ban            # Debian/Ubuntu
          sudo cp immich/fail2ban/filter.d/immich-caddy.conf /etc/fail2ban/filter.d/
          sudo cp immich/fail2ban/jail.d/immich.conf         /etc/fail2ban/jail.d/
          sudo systemctl restart fail2ban
          sudo fail2ban-client status immich-caddy

      The jail bans on Docker's `DOCKER-USER` chain (see `jail.d/immich.conf`),
      which requires the iptables backend — the default on Docker installs.

## 5. Verify the hardening works

- [ ] Cert valid when browsing `https://myfamily.duckdns.org` from cellular.
- [ ] Immich's raw port is NOT reachable: `curl -sS http://<server-LAN-IP>:2283`
      from another LAN host should refuse/timeout (port no longer published).
- [ ] Fire 6 bad logins from a test device, then prove the ban BLOCKS traffic
      (not just that it's listed): from that same IP, `curl -m5 https://<name>.duckdns.org`
      should now time out or be refused. Because Caddy runs in a container with
      published ports, the jail bans on the `DOCKER-USER` chain — verify the
      block, not just `sudo fail2ban-client status immich-caddy`.

## Notes

- If a phone can't reach the server: confirm `https://myfamily.duckdns.org`
  loads from cellular; if not, re-check port-forwarding and the DuckDNS timer
  (`systemctl status duckdns.timer`).
- Renewing certs is automatic (Caddy). Keep port 80 forwarded so renewals
  succeed.
