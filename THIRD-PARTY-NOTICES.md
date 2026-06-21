# Third-Party Notices

GenieMax is MIT-licensed. It uses the following third-party components, each under its own license. Refer to each
project for the authoritative license text.

## Swift package (`Sources/GenieMax`)
- **swift-sodium** — https://github.com/jedisct1/swift-sodium — libsodium bindings (Argon2id, XChaCha20-Poly1305,
  Ed25519/X25519). See the project's LICENSE.
- **BIP-39 English wordlist** (`BIP39Words.swift`) — the standard 2048-word list from BIP-0039
  (https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt), public-domain word list.

## Backend (`backend/`)
- Cloudflare Workers runtime + the dependencies declared in `backend/package.json` (e.g. routing/JWT helpers).
  Each retains its own license; see `backend/package-lock.json` and the respective projects.

> If you believe an attribution is missing or incorrect, please open an issue.
