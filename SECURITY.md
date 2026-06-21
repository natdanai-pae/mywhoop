# Security Policy

## Reporting a vulnerability
Please report security issues **privately** — do not open a public issue.

- Use GitHub's **"Report a vulnerability"** (Security → Advisories) on this repository, or
- email the maintainers (see the repo profile).

Include steps to reproduce and impact. We aim to acknowledge within a few days.

## Scope notes
- This is a **local-first** library: it holds no server-side user data. The optional sync backend
  (`backend/`) is **zero-knowledge** — it stores only end-to-end-encrypted blobs and never sees plaintext or
  encryption keys. The encryption key is derived client-side from the user's recovery phrase (Argon2id);
  losing the phrase means the data is unrecoverable by design (no server-side key escrow).
- Cryptography uses standard primitives via libsodium (Argon2id, XChaCha20-Poly1305, Ed25519/X25519). Please
  report any misuse of these primitives, nonce-reuse, or key-handling issues.
- Rhythm screening is non-diagnostic and out of scope for medical claims.
