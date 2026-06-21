/**
 * E2EE sync backend — Cloudflare Worker (the E2EE sync design P4).
 *
 * ZERO-KNOWLEDGE: this server stores ONLY the opaque encrypted Envelope (ciphertext + a public salt) in R2, and a
 * tiny metadata row in D1 (account id, version, timestamp, device). It never sees a key or any plaintext. The
 * client encrypts/decrypts on-device.
 *
 * Identity: each request carries a provider OAuth id-token (Sign in with Apple / Google). The Worker VERIFIES the
 * token signature against the provider JWKS, extracts the stable `sub`, and derives the SAME opaque account id the
 * Swift/Kotlin client uses: accountId = hex(SHA-256("<provider>:<sub>")). That id is the R2 key + D1 primary key.
 *
 * Concurrency: versions are Hybrid Logical Clocks serialized as the client's `packed` string, which sorts
 * lexicographically in HLC order — so a plain string compare decides "newer". PUT rejects a non-newer version (409)
 * so a stale device can't clobber fresh data; the client then pulls + merges (SyncEngine) and retries.
 */

export interface Env {
  DB: D1Database;      // stores the ciphertext envelope + metadata (D1-only; swap to R2 for $0-egress at scale)
  APPLE_AUD: string;   // your app's bundle id / Apple service id (the `aud` claim to require)
  GOOGLE_AUD: string;  // your Google OAuth client id
}

interface Envelope {
  v: number; kdfSalt: string; blob: string; wraps: Record<string, string>; updatedAt: number; device: string;
}

const JSON_HEADERS = { "content-type": "application/json" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
const err = (status: number, msg: string) => json({ error: msg }, status);

const MAX_BODY = 10 * 1024 * 1024;   // 10 MB request cap (anti-abuse / Worker-OOM guard)
const MAX_BLOB = 9 * 1024 * 1024;    // ciphertext blob cap

/** Validate the client-supplied HLC `packed` version string: "<15 digits>:<6 digits>:<node ≤128 chars>", and reject
 *  an implausibly-future wall time so a malicious client can't poison the account with a max-version write-lock. */
function validVersion(v: string): boolean {
  if (!/^\d{15}:\d{6}:.{1,128}$/.test(v)) return false;
  const wall = Number(v.slice(0, 15));
  return Number.isFinite(wall) && wall <= Date.now() + 24 * 3600 * 1000;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    try {
      // Every route below /v1/* requires a verified identity.
      const account = await authenticate(req, env);
      if (!account) return err(401, "unauthorized");

      if (url.pathname === "/v1/meta" && req.method === "GET") return getMeta(env, account);
      if (url.pathname === "/v1/blob" && req.method === "GET") return getBlob(env, account);
      if (url.pathname === "/v1/blob" && req.method === "PUT") return putBlob(req, env, account);
      if (url.pathname === "/v1/account" && req.method === "DELETE") return deleteAccount(env, account);
      return err(404, "not found");
    } catch (e) {
      return err(500, `server error: ${(e as Error).message}`);
    }
  },
};

// ---- routes ---------------------------------------------------------------

async function getMeta(env: Env, account: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT version, updated_at, device_id FROM blobs WHERE account_id = ?")
    .bind(account).first<{ version: string; updated_at: number; device_id: string }>();
  if (!row) return err(404, "no blob");
  return json({ version: row.version, updatedAt: row.updated_at, deviceId: row.device_id });
}

// The ciphertext envelope is stored IN the D1 row (one row per account). Storing the blob in the same row as the
// version makes the write fully atomic in a single statement — no R2/D1 split, no torn pointer. (Swap the `envelope`
// column for an R2 object with $0 egress when storage at scale matters.)

async function getBlob(env: Env, account: string): Promise<Response> {
  const row = await env.DB.prepare("SELECT version, envelope FROM blobs WHERE account_id = ?")
    .bind(account).first<{ version: string; envelope: string }>();
  if (!row) return err(404, "no blob");
  return json({ version: row.version, envelope: JSON.parse(row.envelope) as Envelope });
}

async function putBlob(req: Request, env: Env, account: string): Promise<Response> {
  if (Number(req.headers.get("content-length") || 0) > MAX_BODY) return err(413, "payload too large");
  const body = await req.json<{ version: string; envelope: Envelope }>().catch(() => null);
  if (!body || typeof body.version !== "string" || !body.envelope) return err(400, "bad body");
  if (!validVersion(body.version)) return err(400, "bad version");

  // Reject anything that doesn't look like a ciphertext-only envelope (defense-in-depth; client never sends plaintext).
  const e = body.envelope;
  if (!e.blob || !e.kdfSalt || typeof e.wraps !== "object") return err(400, "malformed envelope");
  if (typeof e.blob !== "string" || e.blob.length > MAX_BLOB) return err(413, "blob too large");

  // Atomically insert/replace the row ONLY if strictly newer. The WHERE collapses check-and-write into one statement,
  // winning the concurrent-PUT race (SQLite reports 0 changes when the guard fails).
  const res = await env.DB.prepare(
    `INSERT INTO blobs (account_id, version, envelope, updated_at, device_id) VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT(account_id) DO UPDATE SET version = excluded.version, envelope = excluded.envelope,
       updated_at = excluded.updated_at, device_id = excluded.device_id WHERE excluded.version > blobs.version`
  ).bind(account, body.version, JSON.stringify(e), Math.floor(Date.now() / 1000), e.device).run();

  if (res.meta.changes === 0) {
    const cur = await env.DB.prepare("SELECT version FROM blobs WHERE account_id = ?")
      .bind(account).first<{ version: string }>();
    return json({ error: "version conflict", serverVersion: cur?.version }, 409);
  }
  return json({ version: body.version });
}

async function deleteAccount(env: Env, account: string): Promise<Response> {
  await env.DB.prepare("DELETE FROM blobs WHERE account_id = ?").bind(account).run();   // GDPR erasure
  return json({ deleted: true });
}

// ---- identity (OAuth id-token verification → opaque account id) ------------

async function authenticate(req: Request, env: Env): Promise<string | null> {
  const auth = req.headers.get("authorization");
  const provider = req.headers.get("x-auth-provider"); // "apple" | "google"
  if (!auth?.startsWith("Bearer ") || !provider) return null;
  const token = auth.slice(7);
  const claims = await verifyIdToken(token, provider, env);
  if (!claims?.sub) return null;
  return accountIdFor(provider, claims.sub);
}

/** Must match the client's E2EEVault.makeAccountId: hex(SHA-256("<provider>:<sub>")). */
async function accountIdFor(provider: string, sub: string): Promise<string> {
  const data = new TextEncoder().encode(`${provider}:${sub}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface Claims { sub: string; iss: string; aud: string; exp: number; }

const PROVIDERS: Record<string, { jwks: string; iss: string[]; aud: (e: Env) => string }> = {
  apple: { jwks: "https://appleid.apple.com/auth/keys", iss: ["https://appleid.apple.com"], aud: (e) => e.APPLE_AUD },
  google: {
    jwks: "https://www.googleapis.com/oauth2/v3/certs",
    iss: ["https://accounts.google.com", "accounts.google.com"], aud: (e) => e.GOOGLE_AUD,
  },
};

const jwksCache = new Map<string, { keys: JsonWebKey[]; fetchedAt: number }>();

async function verifyIdToken(token: string, provider: string, env: Env): Promise<Claims | null> {
  const cfg = PROVIDERS[provider];
  if (!cfg) return null;
  const [headerB64, payloadB64, sigB64] = token.split(".");
  if (!headerB64 || !payloadB64 || !sigB64) return null;
  const header = JSON.parse(b64urlToString(headerB64)) as { kid: string; alg: string };
  if (header.alg !== "RS256") return null;   // pin RS256: refuse alg:none / HS256 / EC confusion outright
  const payload = JSON.parse(b64urlToString(payloadB64)) as Claims;

  // Claim checks (do these regardless of signature so we fail fast on obviously-wrong tokens).
  if (!cfg.iss.includes(payload.iss)) return null;
  // aud may be a comma-separated allow-list (e.g. iOS Google client id + Android's web serverClientId — both map
  // to the same stable `sub`, so the same user gets the same account id across platforms).
  const allowedAud = cfg.aud(env).split(",").map((a) => a.trim()).filter(Boolean);
  if (!allowedAud.includes(payload.aud)) return null;
  if (payload.exp * 1000 < Date.now()) return null;

  // Signature check against the provider's JWKS (RS256).
  const jwk = await jwkFor(cfg.jwks, header.kid);
  if (!jwk) return null;
  const key = await crypto.subtle.importKey(
    "jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key,
    b64urlToBytes(sigB64), new TextEncoder().encode(`${headerB64}.${payloadB64}`));
  return ok ? payload : null;
}

async function jwkFor(jwksUrl: string, kid: string): Promise<JsonWebKey | null> {
  let cached = jwksCache.get(jwksUrl);
  if (!cached || Date.now() - cached.fetchedAt > 6 * 3600 * 1000) {
    const res = await fetch(jwksUrl);
    const body = (await res.json()) as { keys: JsonWebKey[] };
    cached = { keys: body.keys, fetchedAt: Date.now() };
    jwksCache.set(jwksUrl, cached);
  }
  return cached.keys.find((k) => (k as { kid?: string }).kid === kid) ?? null;
}

function b64urlToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=");
  const bin = atob(b64);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}
function b64urlToString(s: string): string {
  return new TextDecoder().decode(b64urlToBytes(s));
}
