# albus-app.netlify.app

The public pages the App Store requires: a privacy policy (`/privacy/`) and a
support page (`/support/`). The app links to both from `AppLinks.swift`.
Static files, no build step; the Netlify project is `albus-app`.

**Not published yet.** Two things have to be true first:

1. `CONTACT_EMAIL` is replaced everywhere with the address Felipe chooses to
   publish. The privacy policy has to name a way to reach the developer.
2. The app has **Settings → Delete account**. Both pages promise it, and App
   Store guideline 5.1.1(v) expects account deletion in apps that create
   accounts.

Before publishing, this must print nothing:

```bash
grep -rn "CONTACT_EMAIL" website; grep -q '"Delete account"' ios/App/Albus/Screens/SettingsScreen.swift || echo "no Delete account in Settings"
```

Keep the privacy policy in step with the code. It makes specific promises:
marking sends text, never the photo; the submitted text is not stored; the
device identifier and IP address are hashed before storage; retention periods
match `prune-security-data`; no analytics or push service.
