import Foundation
import CryptoKit
import Sodium

/// PoC of the End-to-End-Encrypted sync ENVELOPE (see the E2EE sync design / the E2EE sync design).
///
/// The point: a per-account JSON snapshot is encrypted ON-DEVICE so the backend only ever holds CIPHERTEXT — the
/// server (and we) can never read it. Key hierarchy:
///     secret (passphrase OR recovery phrase) → KDF → wrapKey → (un)wraps a random dataKey → AES-256-GCM(snapshot)
/// Wrapping the dataKey under EACH secret means a password change / adding a recovery phrase only re-wraps the small
/// key — it does NOT re-encrypt the whole blob.
///
/// CRYPTO NOTE: this PoC uses CryptoKit **AES-256-GCM** (hardware-accelerated, also on Android via javax.crypto) and
/// **HKDF-SHA256** as the key-derivation stand-in. PRODUCTION swaps the passphrase KDF for **Argon2id** (libsodium —
/// swift-sodium on iOS, kotlin-multiplatform-libsodium on Android) so a stolen ciphertext can't be brute-forced; the
/// envelope format and the rest of the flow are unchanged. Pure + deterministic given its inputs (caller passes the
/// clock), so it is fully unit-testable.
public enum E2EESync {

  /// What the backend stores / what crosses the wire. EVERYTHING here is ciphertext or a public salt — no plaintext.
  public struct Envelope: Codable, Equatable {
    public let v: Int                    // envelope format version
    public let kdfSalt: Data             // per-account KDF salt (public)
    public let blob: Data                // AES-GCM(snapshot) under dataKey — the encrypted account data
    public let wraps: [String: Data]     // label → AES-GCM(dataKey) under wrapKey(secret): "pass", "recovery", …
    public let updatedAt: Double         // Hybrid-Logical-Clock timestamp (caller-supplied → testable, no Date() inside)
    public let device: String            // which device wrote it (for HLC tie-break / "kept newest" notes)
    public init(v: Int, kdfSalt: Data, blob: Data, wraps: [String: Data], updatedAt: Double, device: String) {
      self.v = v; self.kdfSalt = kdfSalt; self.blob = blob; self.wraps = wraps; self.updatedAt = updatedAt; self.device = device
    }
  }

  public enum CryptoError: Error, Equatable { case badSecret, tamper, missingWrap, kdfFailed }

  /// Derive a 256-bit wrap key from an unlock secret + the account salt, by ENVELOPE VERSION:
  ///   • v1 = HKDF-SHA256 (fast, NOT brute-force-hard) — kept so the cross-platform interop fixture (a plain JDK has
  ///     no Argon2id) still verifies, and for fast unit tests.
  ///   • v2 = **Argon2id** (libsodium, memory-hard) — the PRODUCTION KDF: a stolen ciphertext can't be GPU-brute-forced.
  /// Same 32-byte output either way, so the rest of the envelope is unchanged. Android uses the identical Argon2id
  /// (kotlin-multiplatform-libsodium) for v2.
  static func wrapKey(_ secret: String, salt: Data, v: Int) throws -> SymmetricKey {
    if v >= 2 { return try argon2idKey(secret, salt: salt) }
    let ikm = SymmetricKey(data: Data(secret.utf8))
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("e2ee-wrap-v1".utf8), outputByteCount: 32)
  }

  /// Argon2id (v2). Fixed parameters = libsodium INTERACTIVE (ops=2, mem=64 MiB) — a good mobile-unlock cost; baked
  /// into v2 so decrypt derives identically. (Changing the cost = a new envelope version.) The 16-byte account salt
  /// matches `crypto_pwhash_SALTBYTES`.
  static func argon2idKey(_ secret: String, salt: Data) throws -> SymmetricKey {
    let sodium = Sodium()
    // Salt size is a true programmer invariant (our account salt is 16 bytes = bits128 = crypto_pwhash_SALTBYTES).
    precondition(salt.count == sodium.pwHash.SaltBytes, "Argon2id salt must be \(sodium.pwHash.SaltBytes) bytes")
    // swift-sodium's pwHash.hash defaults to crypto_pwhash_ALG_ARGON2ID13. A non-nil result is the only success;
    // it fails only on catastrophic OOM → THROW (retryable) rather than crash, and NEVER fall back to a weaker KDF
    // (that would derive a different key and silently break decrypt).
    guard let out = sodium.pwHash.hash(outputLength: 32, passwd: Array(secret.utf8), salt: Array(salt),
                                       opsLimit: sodium.pwHash.OpsLimitInteractive,
                                       memLimit: sodium.pwHash.MemLimitInteractive)
    else { throw CryptoError.kdfFailed }
    return SymmetricKey(data: Data(out))
  }

  static func randomData(_ size: SymmetricKeySize) -> Data { SymmetricKey(size: size).withUnsafeBytes { Data($0) } }

  // Additional Authenticated Data: cryptographically BINDS each ciphertext to its context so a malicious server
  // cannot splice pieces together. The blob is bound to (envelope-version, account-salt); each wrap is bound to
  // (its label, account-salt). This defeats wrap-relabeling (e.g. renaming a `device:` slot to `recovery`),
  // cross-account wrap-splicing (salt differs per account), and version downgrade — none of which plain GCM
  // (which only proves "these bytes weren't flipped") would catch. (Same-account rollback to an older blob is a
  // SYNC-layer concern, enforced by HLC monotonicity in the client — not crypto.)
  static func blobAAD(v: Int, salt: Data) -> Data { Data("e2ee-blob:v\(v):".utf8) + salt }
  static func wrapAAD(label: String, salt: Data) -> Data { Data("e2ee-wrap:\(label):".utf8) + salt }

  /// Encrypt a snapshot under one or more unlock secrets (e.g. ["pass": passphrase, "recovery": recoveryPhrase]).
  /// Generates a fresh random dataKey, wraps it under each secret, and AES-GCM-encrypts the snapshot with the dataKey.
  public static func encrypt(_ snapshot: Data, secrets: [String: String], updatedAt: Double, device: String, v: Int = 1) throws -> Envelope {
    let dataKey = SymmetricKey(size: .bits256)
    let salt = randomData(.bits128)
    let sealed = try AES.GCM.seal(snapshot, using: dataKey, authenticating: blobAAD(v: v, salt: salt))
    let rawKey = dataKey.withUnsafeBytes { Data($0) }
    var wraps: [String: Data] = [:]
    for (label, secret) in secrets {
      wraps[label] = try AES.GCM.seal(rawKey, using: try wrapKey(secret, salt: salt, v: v),
                                      authenticating: wrapAAD(label: label, salt: salt)).combined!
    }
    return Envelope(v: v, kdfSalt: salt, blob: sealed.combined!, wraps: wraps, updatedAt: updatedAt, device: device)
  }

  /// Decrypt with ONE secret (its label): unwrap the dataKey, then decrypt the blob. Throws on a wrong secret or any
  /// tampering (GCM authentication fails) — the server cannot silently alter the data.
  public static func decrypt(_ env: Envelope, label: String, secret: String) throws -> Data {
    guard let wrapped = env.wraps[label] else { throw CryptoError.missingWrap }
    let rawKey = try unwrapKey(wrapped, label: label, secret: secret, salt: env.kdfSalt, v: env.v)
    do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: env.blob), using: SymmetricKey(data: rawKey),
                                 authenticating: blobAAD(v: env.v, salt: env.kdfSalt)) }
    catch { throw CryptoError.tamper }
  }

  /// Unwrap the dataKey from a labeled wrap (AAD-bound, KDF chosen by envelope version). Throws `.badSecret` on a
  /// wrong secret OR an AAD mismatch (e.g. a relabeled / cross-account wrap) — both mean "this secret can't open it".
  static func unwrapKey(_ wrapped: Data, label: String, secret: String, salt: Data, v: Int) throws -> Data {
    let key = try wrapKey(secret, salt: salt, v: v)   // may throw .kdfFailed (OOM) — propagate, don't mask as badSecret
    do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: wrapped), using: key,
                                 authenticating: wrapAAD(label: label, salt: salt)) }
    catch { throw CryptoError.badSecret }
  }

  /// Add or replace an unlock secret WITHOUT re-encrypting the snapshot (password change / add a recovery phrase):
  /// unwrap the dataKey with an existing secret, re-wrap that same dataKey under the new secret. The blob is untouched.
  public static func rewrap(_ env: Envelope, unlock label: String, with secret: String,
                            add newLabel: String, secret newSecret: String) throws -> Envelope {
    guard let wrapped = env.wraps[label] else { throw CryptoError.missingWrap }
    let rawKey = try unwrapKey(wrapped, label: label, secret: secret, salt: env.kdfSalt, v: env.v)
    var wraps = env.wraps
    wraps[newLabel] = try AES.GCM.seal(rawKey, using: try wrapKey(newSecret, salt: env.kdfSalt, v: env.v),
                                       authenticating: wrapAAD(label: newLabel, salt: env.kdfSalt)).combined!
    return Envelope(v: env.v, kdfSalt: env.kdfSalt, blob: env.blob, wraps: wraps, updatedAt: env.updatedAt, device: env.device)
  }

  /// Save a NEW snapshot as a new version WITHOUT changing the data-key: unwrap the existing data-key with one
  /// secret, re-encrypt the new snapshot under it, and keep ALL wraps untouched (they still wrap the same key).
  /// This is the normal "local data changed → re-upload" path — every device secret and the recovery phrase stay
  /// valid, and only the blob + `updatedAt` change.
  public static func reseal(_ env: Envelope, unlock label: String, secret: String,
                            newSnapshot: Data, updatedAt: Double, device: String) throws -> Envelope {
    guard let wrapped = env.wraps[label] else { throw CryptoError.missingWrap }
    let rawKey = try unwrapKey(wrapped, label: label, secret: secret, salt: env.kdfSalt, v: env.v)
    let sealed = try AES.GCM.seal(newSnapshot, using: SymmetricKey(data: rawKey),
                                  authenticating: blobAAD(v: env.v, salt: env.kdfSalt))
    return Envelope(v: env.v, kdfSalt: env.kdfSalt, blob: sealed.combined!, wraps: env.wraps,
                    updatedAt: updatedAt, device: device)
  }

  /// A human-readable recovery phrase from the canonical **BIP39 2048-word list** (`bip39English`). Each word is a
  /// uniform 11-bit index drawn from a fresh CSPRNG byte-pair → **no modulo bias** (2048 = 2¹¹) and **11 bits of real
  /// entropy per word** (default 12 words = **132 bits**). This phrase is a second unlock secret for the dataKey.
  /// (Note: this is a BIP39 *wordlist* phrase, not a checksummed BIP39 *mnemonic* — we don't interop with wallets;
  /// correctness on unlock is enforced by the wrap's GCM authentication, not a checksum.)
  public static func newRecoveryPhrase(words count: Int = 12) -> String {
    precondition(bip39English.count == 2048, "BIP39 list must be 2048 words for unbiased 11-bit sampling")
    let n = max(1, count)
    let bytes = SymmetricKey(size: SymmetricKeySize(bitCount: n * 16)).withUnsafeBytes { Array($0) }
    return (0..<n).map { i -> String in
      let idx = (Int(bytes[2 * i]) << 8 | Int(bytes[2 * i + 1])) & 0x7FF   // low 11 bits → 0...2047, uniform
      return bip39English[idx]
    }.joined(separator: " ")
  }
}
