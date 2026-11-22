# Distributing Aeolus to other people (SideStore)

Nobody re-signs the app for anyone else. Each person signs Aeolus with **their own free Apple ID, on
their own iPhone**, using SideStore. SideStore re-signs it on the phone before the 7 days run out.
Nobody ever hands an Apple ID password to us. That matters even more for a wallet: an app signed by a
stranger's certificate could be swapped for anything.

What we host:

| Piece | What it is | Where |
|---|---|---|
| **Source** | A JSON list of Aeolus builds that SideStore can install and update from | Published automatically with each green build: `https://github.com/aeolus-crypto/Aeolus-Wallet-iOS/releases/download/test-build/source.json` |
| **Anisette server** (optional) | The helper SideStore uses to sign in to Apple. It supplies device data, never receives passwords; sign-in goes from the phone to Apple | `distribution/anisette/` (Docker), on your own machine |

## For users: install Aeolus with SideStore

One-time, with a computer (Windows, macOS or Linux):

1. On the iPhone, install **LocalDevVPN** from the App Store.
2. On the computer, install **iLoader** (github.com/nab138/iloader). On Windows, also install iTunes
   from apple.com (not the Microsoft Store), for the iPhone drivers.
3. Plug in the iPhone, unlock it, tap **Trust**. In iLoader sign in with your Apple ID and choose
   **Install SideStore**.
4. On the iPhone: Settings → Privacy & Security → **Developer Mode** → On (restart, confirm), then
   Settings → General → VPN & Device Management → your Apple ID → **Trust**.
5. Open SideStore, sign in with the **same Apple ID**.

Then, on the phone only:

6. Turn on LocalDevVPN, open SideStore → **Sources** → **+** → paste the source URL above → add
   **Aeolus Wallet** and tap **Get**.
7. Every few days (before 7 are up): LocalDevVPN on, SideStore → **My Apps** → **Refresh All**.
   New builds show up as updates in the same tab.

Optional, to use our anisette server: SideStore → Settings → **Anisette server** → add
`https://<our domain>`.

Free Apple ID limits: 3 sideloaded apps at once (SideStore counts as one), 10 new app IDs per week.
If a refresh is missed the app just won't open; refreshing or reinstalling over it brings it back
with the wallet intact. Deleting the app deletes the wallet: keep your seed phrase.

## For us: host the anisette server

Needs a machine that stays on, with a public IP, a domain name and Docker.

```
git clone https://github.com/aeolus-crypto/Aeolus-Wallet-iOS.git
cd Aeolus-Wallet-iOS/distribution/anisette
cp .env.example .env        # set ANISETTE_DOMAIN=ani.yourdomain.com
docker compose up -d
```

- Point the domain's A/AAAA record at the machine and open ports **80** and **443** (Caddy gets the
  HTTPS certificate from Let's Encrypt by itself).
- Check: `curl https://ani.yourdomain.com` returns JSON.
- Update: `docker compose pull && docker compose up -d`.
- Caddy is set to keep no access logs.
- A home connection works for friends and family; for many users put it on a small VPS.

## How the source is built

`.github/workflows/publish-ipa.yml` runs `make_source.py` after every green "iOS build": it reads the
version, build number (the CI run number) and privacy strings from the `.ipa`, adds its size and
SHA-256, and uploads `source.json` next to the `.ipa` on the `test-build` release. SideStore checks
both against the file it downloads, so they can't drift apart.
