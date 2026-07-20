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
