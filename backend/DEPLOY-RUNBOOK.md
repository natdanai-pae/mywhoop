# Deploy runbook — E2EE sync Worker (copy-paste)

You run these (they need YOUR Cloudflare login + bill to your account, so I can't run them for you). ~10 min.
Everything the server stores is **ciphertext** — these steps never expose your data.

## 0. Prereqs (once)
- **Node 18+** and npm. Check: `node -v`.
- A **Cloudflare account** (free tier is fine to start).
- Your **OAuth audiences**: the iOS bundle id `com.example.yourapp` (Apple), and — if you use Google sign-in — a Google OAuth **client id**.

## 1. Install + log in
```bash
cd e2ee-backend
npm install
npx wrangler login          # opens a browser → approve. (one-time)
```

## 2. Create the storage (R2 + D1)
```bash
npx wrangler r2 bucket create whoop-e2ee-blobs
npx wrangler d1 create whoop-e2ee-meta
```
The `d1 create` prints a `database_id`. **Paste it into `wrangler.toml`** at `database_id = "REPLACE_WITH_D1_DATABASE_ID"`.

Then create the table:
```bash
npm run db:init             # applies schema.sql to whoop-e2ee-meta
```

## 3. Set the OAuth audiences
Edit `wrangler.toml` → `[vars]`:
```toml
APPLE_AUD  = "com.example.yourapp"
GOOGLE_AUD = "REPLACE_WITH_GOOGLE_OAUTH_CLIENT_ID"   # or leave as-is if you only use Apple
```
> **GDPR**: in the Cloudflare dashboard, set the D1 database + R2 bucket **location to EU** (or create them with an EU jurisdiction) before storing real users' data.

## 4. Deploy
```bash
npm run deploy
```
Copy the printed URL, e.g. `https://whoop-e2ee-sync.<your-subdomain>.workers.dev`.

## 5. Smoke test (no real token needed)
The API is auth-gated, so an unauthenticated call must be rejected — that proves it's live and locked down:
```bash
curl -i https://whoop-e2ee-sync.<your-subdomain>.workers.dev/v1/meta
# expect: HTTP/1.1 401  {"error":"unauthorized"}

curl -i -X PUT https://whoop-e2ee-sync.<your-subdomain>.workers.dev/v1/blob -d '{}'
# expect: HTTP/1.1 401  {"error":"unauthorized"}
```
(Real reads/writes need a valid Apple/Google id-token, which the app sends after Sign in with Apple.)

## 6. Wire it into the app
1. Build/deploy the iOS app once after this session — the first build fetches **swift-sodium** automatically (it's a transitive dependency of GenieMax; no `project.yml` change needed). Production enrollment now uses **Argon2id (envelope v2)**.
2. In the app: **Settings → Cloud Sync → End-to-end encrypted sync**.
3. Tap **Sign in with Apple** → **Protect my data** (write down the recovery phrase).
4. Paste your Worker URL into **Sync server URL**, then tap **Sync now**.
   - First device → "Uploaded your latest data."
   - A second device (same Apple ID + recovery phrase) → "Downloaded the latest from the cloud."

## Notes / gotchas
- **Apple id-token lifetime**: the `identityToken` from Sign in with Apple is short-lived. For always-on background sync you'll later add a token refresh (exchange the auth code at Apple's token endpoint). For manual "Sync now" right after signing in, the captured token works.
- **Android (P6)**: the same Worker serves Android unchanged. The Kotlin port decrypts **both v1 and v2 (Argon2id)** envelopes (proven — `android/VerifyV2.java`), so iOS↔Android sync works for production accounts.
- **Cost** @100k users ≈ R2 ~$7.5/mo storage, $0 egress; D1 free-tier-ish. Backend is cheap; the cost is engineering.
- **Mass-scale launch is still gated** by the legal/ToS generic-BLE pivot (separate from the backend).
