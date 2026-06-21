# whoop-e2ee-sync — zero-knowledge sync backend (Cloudflare Worker)

The thin backend for E2EE cloud sync (the E2EE sync design **P4**). It stores **only ciphertext**: the encrypted
`Envelope` in R2 and a 4-column metadata row in D1 (`account_id`, `version`, `updated_at`, `device_id`). It never
sees a key or any plaintext — the iOS/Android clients encrypt/decrypt on-device.

## API
```
GET    /v1/meta     Auth: Bearer <idToken> + X-Auth-Provider: apple|google   → { version, updatedAt, deviceId } | 404
GET    /v1/blob     "                                                          → { version, envelope } | 404
PUT    /v1/blob     "  body { version, envelope }                             → { version } | 409 { serverVersion }
DELETE /v1/account  "                                                          → { deleted: true }   (GDPR erasure)
```
- **Identity**: the `idToken` (Sign in with Apple / Google) is verified against the provider **JWKS** (RS256 pinned,
  `iss`/`aud`/`exp` checked). The account id is derived server-side as `hex(SHA-256("<provider>:<sub>"))` — **identical**
  to the client (`E2EEVault.makeAccountId`) and the Android client. The request never supplies the account id (no IDOR).
- **Concurrency**: versions are HLC `packed` strings (lexicographically sortable). PUT stages the blob under a
  version-suffixed R2 key, then atomically advances the D1 pointer **only if strictly newer**
  (`ON CONFLICT … DO UPDATE … WHERE excluded.version > blobs.version`) — winning the concurrent-PUT race and never
  pointing D1 at a missing/old object. A non-newer PUT returns **409** with the server's version; the client pulls +
  re-decides (`SyncEngine`).
- **Abuse guards**: 10 MB body / 9 MB blob caps; `version` is format- and future-bounded so a client can't poison the
  account with a max-version write-lock.

## Deploy
```bash
npm install
npx wrangler r2 bucket create whoop-e2ee-blobs
npx wrangler d1 create whoop-e2ee-meta          # copy the database_id into wrangler.toml
npm run db:init                                  # apply schema.sql
# set APPLE_AUD / GOOGLE_AUD in wrangler.toml (your bundle id / OAuth client id), choose an EU jurisdiction for GDPR
npm run deploy
```

## Not yet done (later phases)
- Section-level blobs (P5) — store several `Envelope`s per account so only the changed section uploads.
- Scheduled R2 cleanup of superseded version objects (they accumulate; cheap, but prune them).
- Rate limiting per account (Cloudflare rules / Durable Object).
