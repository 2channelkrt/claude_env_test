# iPhone Setup — 10 Minutes Per Person

What each family member needs from you (the admin) beforehand:
- A Tailscale invite email (sent from the Tailscale admin console)
- Their Immich login (email + starting password you created)
- The server URL: `https://photos.<tailnet>.ts.net`

## Part 1: Tailscale (3 min)

1. App Store → install **Tailscale**.
2. Open it → **Log in** → use the SAME account/email the invite went to.
3. Allow the VPN configuration when iOS asks.
4. Leave the toggle **on**. It stays connected in the background and only
   carries traffic to our server — normal internet use is unaffected, and
   battery impact is negligible.

## Part 2: Immich (5 min)

1. App Store → install **Immich**.
2. Open it → Server Endpoint URL: `https://photos.<tailnet>.ts.net` → Next.
3. Log in with your email + password (change the password in
   Settings → Account after first login).
4. Enable backup: tap the **cloud icon** (top right) →
   - **Select albums**: choose *Recents* (that's the whole camera roll)
   - Turn ON **Automatic backup**
   - Turn ON **Background backup**
5. iOS will ask for photo access → choose **Allow Access to All Photos**.
6. Keep the app open on the backup screen until the first big upload finishes
   (first backup of a full phone can take hours — plug in, leave on Wi-Fi
   overnight; it continues in the background afterwards).

## Checking it works

Cloud icon shows "Backed up" with a growing count. Take a photo, wait a few
minutes (or open the app) — it should appear on the server.

## FAQ

- **Does this use my mobile data?** By default backup runs on Wi-Fi and
  cellular. To restrict: Immich → Backup settings → turn off cellular upload.
- **Can I delete photos from my phone after backup?** Yes — once backed up,
  they stay on the server. The Immich app can even do this for you
  (Backup → free up space), but double-check the photo is on the server first.
- **Is someone else seeing my photos?** Each person has their own library.
  Sharing happens only through albums you explicitly share.
- **The app says it can't reach the server.** Open Tailscale, make sure the
  toggle is on and it says Connected.
