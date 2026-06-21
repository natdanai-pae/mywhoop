import Testing
import Foundation
@testable import WhoopCore

// PoC of the E2EE sync envelope — proves the privacy property end-to-end (the E2EE sync design).

private let snapshot = Data(#"{"profile":{"name":"Satayu"},"hr":72,"secret":"private health data"}"#.utf8)

// Encrypt then decrypt with the passphrase → the exact bytes come back.
@Test func e2eeRoundTrips() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "correct horse battery"], updatedAt: 1000, device: "iphone")
  let out = try E2EESync.decrypt(env, label: "pass", secret: "correct horse battery")
  #expect(out == snapshot)
}

// THE privacy property: what the server stores (the blob) contains NONE of the plaintext.
@Test func serverHoldsOnlyCiphertext() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "p"], updatedAt: 0, device: "d")
  #expect(env.blob.range(of: Data("Satayu".utf8)) == nil)
  #expect(env.blob.range(of: Data("private health data".utf8)) == nil)
}

// A wrong passphrase cannot unwrap the key → throws (no data leaks).
@Test func wrongSecretFails() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "right"], updatedAt: 0, device: "d")
  #expect(throws: E2EESync.CryptoError.badSecret) { try E2EESync.decrypt(env, label: "pass", secret: "wrong") }
}

// The server tampering with the ciphertext is DETECTED (GCM auth) → throws, never returns altered data.
@Test func tamperDetected() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "p"], updatedAt: 0, device: "d")
  var b = env.blob; b[b.count / 2] ^= 0xFF                       // flip a ciphertext byte (simulate a malicious server)
  let bad = E2EESync.Envelope(v: env.v, kdfSalt: env.kdfSalt, blob: b, wraps: env.wraps, updatedAt: env.updatedAt, device: env.device)
  #expect(throws: E2EESync.CryptoError.tamper) { try E2EESync.decrypt(bad, label: "pass", secret: "p") }
}

// A recovery phrase is a SECOND unlock secret — it decrypts the same data without the passphrase.
@Test func recoveryPhraseUnlocks() throws {
  let phrase = "amber river stone maple ember frost"
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "p", "recovery": phrase], updatedAt: 0, device: "d")
  #expect(try E2EESync.decrypt(env, label: "recovery", secret: phrase) == snapshot)
}

// Password change / adding recovery = re-wrap the small key, NOT re-encrypt the blob (key-hierarchy benefit).
@Test func rewrapAddsSecretWithoutReencrypting() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "old"], updatedAt: 0, device: "d")
  let env2 = try E2EESync.rewrap(env, unlock: "pass", with: "old", add: "recovery", secret: "amber river stone")
  #expect(env2.blob == env.blob)                                  // SAME ciphertext → no expensive re-encryption
  #expect(try E2EESync.decrypt(env2, label: "recovery", secret: "amber river stone") == snapshot)
  #expect(try E2EESync.decrypt(env2, label: "pass", secret: "old") == snapshot)   // original secret still works
}

// reseal saves a new snapshot under the SAME data-key → the blob changes but EVERY existing secret (device +
// recovery) still decrypts the new data. This is the normal "data changed → re-upload" path.
@Test func resealKeepsAllSecretsValid() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["device": "d-sec", "recovery": "amber river"], updatedAt: 1, device: "iphone")
  let next = Data(#"{"hr":99,"updated":true}"#.utf8)
  let env2 = try E2EESync.reseal(env, unlock: "device", secret: "d-sec", newSnapshot: next, updatedAt: 2, device: "iphone")
  #expect(env2.blob != env.blob)                                              // re-encrypted
  #expect(env2.wraps == env.wraps)                                            // same data-key → wraps untouched
  #expect(try E2EESync.decrypt(env2, label: "device", secret: "d-sec") == next)
  #expect(try E2EESync.decrypt(env2, label: "recovery", secret: "amber river") == next)   // recovery STILL works
  #expect(env2.updatedAt == 2)
}

// The recovery phrase is human-readable words.
@Test func recoveryPhraseIsWords() {
  #expect(E2EESync.newRecoveryPhrase(words: 12).split(separator: " ").count == 12)
}

// AAD binds each wrap to its LABEL: a malicious server that relabels the device wrap as "recovery" (hoping to
// unlock it with the device secret under the recovery slot) is rejected — the AAD no longer matches.
@Test func aadRejectsRelabeledWrap() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["device:iphone": "s", "recovery": "amber river"], updatedAt: 0, device: "iphone")
  var wraps = env.wraps
  wraps["recovery"] = env.wraps["device:iphone"]                              // server relabels the wrap
  let tampered = E2EESync.Envelope(v: env.v, kdfSalt: env.kdfSalt, blob: env.blob, wraps: wraps, updatedAt: 0, device: "iphone")
  #expect(throws: E2EESync.CryptoError.badSecret) { try E2EESync.decrypt(tampered, label: "recovery", secret: "s") }
  #expect(try E2EESync.decrypt(env, label: "device:iphone", secret: "s") == snapshot)   // original still fine
}

// A fresh random dataKey + nonce per encrypt → identical input never yields identical ciphertext.
@Test func encryptUsesFreshNoncePerCall() throws {
  let a = try E2EESync.encrypt(snapshot, secrets: ["p": "x"], updatedAt: 0, device: "d")
  let b = try E2EESync.encrypt(snapshot, secrets: ["p": "x"], updatedAt: 0, device: "d")
  #expect(a.blob != b.blob)
}

// reseal reuses the SAME dataKey but a FRESH nonce → same plaintext re-sealed twice still differs (no nonce reuse).
@Test func resealUsesFreshNonce() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["d": "s"], updatedAt: 0, device: "i")
  let r1 = try E2EESync.reseal(env, unlock: "d", secret: "s", newSnapshot: snapshot, updatedAt: 1, device: "i")
  let r2 = try E2EESync.reseal(env, unlock: "d", secret: "s", newSnapshot: snapshot, updatedAt: 2, device: "i")
  #expect(r1.blob != r2.blob)
}

// Recovery phrase = real BIP39 words (2048-word list), correct count, high-entropy (two phrases differ).
@Test func recoveryPhraseUsesBip39() {
  #expect(bip39English.count == 2048)                                        // unbiased 11-bit sampling
  let set = Set(bip39English)
  let words = E2EESync.newRecoveryPhrase(words: 12).split(separator: " ").map(String.init)
  #expect(words.count == 12)
  #expect(words.allSatisfy { set.contains($0) })
  #expect(E2EESync.newRecoveryPhrase() != E2EESync.newRecoveryPhrase())
}

// v2 = Argon2id (production, memory-hard KDF): full round-trip under both device + recovery wraps.
@Test func argon2idV2RoundTrips() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["device:d": "s", "recovery": "amber river"], updatedAt: 0, device: "d", v: 2)
  #expect(env.v == 2)
  #expect(try E2EESync.decrypt(env, label: "device:d", secret: "s") == snapshot)
  #expect(try E2EESync.decrypt(env, label: "recovery", secret: "amber river") == snapshot)
  #expect(throws: E2EESync.CryptoError.badSecret) { try E2EESync.decrypt(env, label: "device:d", secret: "wrong") }
}

// reseal under v2 keeps the Argon2id wraps valid (same data-key, version preserved).
@Test func argon2idV2ResealKeepsRecovery() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["device:d": "s", "recovery": "amber river"], updatedAt: 0, device: "d", v: 2)
  let next = Data(#"{"v2":true}"#.utf8)
  let env2 = try E2EESync.reseal(env, unlock: "device:d", secret: "s", newSnapshot: next, updatedAt: 1, device: "d")
  #expect(env2.v == 2)
  #expect(try E2EESync.decrypt(env2, label: "recovery", secret: "amber river") == next)
}

// The envelope round-trips through JSON exactly as it would to/from the backend.
@Test func envelopeIsCodable() throws {
  let env = try E2EESync.encrypt(snapshot, secrets: ["pass": "p"], updatedAt: 42, device: "d")
  let json = try JSONEncoder().encode(env)
  let back = try JSONDecoder().decode(E2EESync.Envelope.self, from: json)
  #expect(back == env)
  #expect(try E2EESync.decrypt(back, label: "pass", secret: "p") == snapshot)
}
