# Tailscale: Private Remote Access

Goal: every family iPhone can reach the Immich server from anywhere, over an
encrypted private network, with a valid HTTPS URL — and nothing on the server
is exposed to the public internet.

## 1. Create a tailnet

Sign up at https://login.tailscale.com (free "Personal" plan covers 3 users;
the "Family" plan covers 6 — check current plans). Use your own account as
the tailnet owner.

## 2. Install on the server

    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up

Follow the printed login URL. Then name the machine something friendly in the
admin console (e.g. `photos`), and in **DNS settings** enable **MagicDNS**
and **HTTPS certificates**.

## 3. Serve Immich over HTTPS

    sudo tailscale serve --bg 2283

This proxies `https://photos.<tailnet>.ts.net` → local port 2283 with an
automatic TLS certificate. Verify from any tailnet device:

    https://photos.<your-tailnet>.ts.net

This URL is what family members enter in the Immich app.

## 4. Disable key expiry for the server

Admin console → Machines → `photos` → ⋯ → **Disable key expiry**.
Otherwise the server silently drops off the tailnet after ~180 days.

## 5. Invite the family

Admin console → **Users** → **Invite users** → enter each person's email.
They accept on their iPhone during onboarding (`docs/family-onboarding.md`).

## Notes

- Backup traffic on home Wi-Fi still goes through the Tailscale URL, but
  Tailscale routes device-to-device on the LAN automatically — no slow path.
- If a phone can't reach the server: check the Tailscale app is connected
  (toggle at top), then check `tailscale status` on the server.
