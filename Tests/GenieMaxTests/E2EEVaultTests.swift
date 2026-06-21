import Testing
import Foundation
@testable import GenieMax

// E2EEVault — account key lifecycle (the E2EE sync design P3).

private let snap = Data(#"{"hr":72,"name":"Satayu"}"#.utf8)

// Enroll on a device → that device unlocks silently with its cached secret.
@Test func vaultEnrollUnlocksWithDeviceSecret() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "iphone", updatedAt: 1,
                                 deviceSecret: "dev-secret", recoveryPhrase: "amber river stone")
  #expect(try E2EEVault.unlock(env, deviceId: "iphone", deviceSecret: "dev-secret") == snap)
}

// The recovery phrase is the portable backup → unlocks the same data without the device secret.
@Test func vaultRecoveryUnlocks() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "iphone", updatedAt: 1,
                                 deviceSecret: "dev-secret", recoveryPhrase: "amber river stone")
  #expect(try E2EEVault.unlockWithRecovery(env, phrase: "amber river stone") == snap)
}

// Wrong device secret cannot unwrap → throws (no data leaks).
@Test func vaultWrongDeviceSecretThrows() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "iphone", updatedAt: 1,
                                 deviceSecret: "right", recoveryPhrase: "amber river stone")
  #expect(throws: E2EESync.CryptoError.badSecret) {
    try E2EEVault.unlock(env, deviceId: "iphone", deviceSecret: "wrong")
  }
}

// A NEW device enrolls via the recovery phrase, getting its OWN slot — without re-encrypting the blob, and
// without disturbing the first device's slot.
@Test func vaultEnrollNewDeviceKeepsBothAndBlob() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "iphone", updatedAt: 1,
                                 deviceSecret: "phone-secret", recoveryPhrase: "amber river stone")
  let env2 = try E2EEVault.enrollNewDevice(env, recoveryPhrase: "amber river stone",
                                           deviceId: "ipad", deviceSecret: "pad-secret")
  #expect(env2.blob == env.blob)                                                       // no re-encryption
  #expect(try E2EEVault.unlock(env2, deviceId: "ipad", deviceSecret: "pad-secret") == snap)   // new device works
  #expect(try E2EEVault.unlock(env2, deviceId: "iphone", deviceSecret: "phone-secret") == snap) // old still works
}

// Enrolling a new device must NOT drop the shared recovery wrap (it's the only backup).
@Test func vaultEnrollNewDevicePreservesRecovery() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "iphone", updatedAt: 1,
                                 deviceSecret: "p", recoveryPhrase: "amber river stone")
  let env2 = try E2EEVault.enrollNewDevice(env, recoveryPhrase: "amber river stone", deviceId: "ipad", deviceSecret: "q")
  #expect(try E2EEVault.unlockWithRecovery(env2, phrase: "amber river stone") == snap)
}

// "Same words" must unlock regardless of spacing / capitalization (normalization on both wrap + unlock).
@Test func vaultRecoveryNormalizesSpacingAndCase() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "d", updatedAt: 1,
                                 deviceSecret: "s", recoveryPhrase: "Amber River Stone")
  #expect(try E2EEVault.unlockWithRecovery(env, phrase: "  amber   river\nstone ") == snap)
}

// A wrong recovery phrase throws (no data leak).
@Test func vaultWrongRecoveryThrows() throws {
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "d", updatedAt: 1,
                                 deviceSecret: "s", recoveryPhrase: "amber river stone")
  #expect(throws: E2EESync.CryptoError.badSecret) {
    try E2EEVault.unlockWithRecovery(env, phrase: "wrong words entirely")
  }
}

// makeAccountId is deterministic, subject-sensitive, and never embeds the raw subject.
@Test func vaultAccountIdHashesSubject() {
  let id1 = E2EEVault.makeAccountId(provider: "apple", subject: "000123.abc")
  let id2 = E2EEVault.makeAccountId(provider: "apple", subject: "000123.abc")
  let id3 = E2EEVault.makeAccountId(provider: "apple", subject: "999999.xyz")
  #expect(id1 == id2)
  #expect(id1 != id3)
  #expect(id1.count == 64)                          // SHA-256 hex
  #expect(!id1.contains("000123"))                  // raw subject not present
}

// CROSS-PLATFORM CONTRACT: the Cloudflare Worker (TS) and the Android client (Kotlin) derive the account id the
// SAME way — hex(SHA-256("<provider>:<sub>")). Locked vector (verified with `shasum -a 256` of "apple:000123.abc").
@Test func accountIdMatchesCrossPlatformContract() {
  #expect(E2EEVault.makeAccountId(provider: "apple", subject: "000123.abc")
          == "f1ec0ee576744543de54885a341e7f554c6bf0f432afbb81a6d8bbc9ef2f9bfc")
}

// Device secrets are high-entropy and unique per call.
@Test func vaultNewDeviceSecretsDiffer() {
  let a = E2EEVault.newDeviceSecret(), b = E2EEVault.newDeviceSecret()
  #expect(a != b)
  #expect(Data(base64Encoded: a)?.count == 32)
}

// The EnvelopeStore seam round-trips (the local stand-in for the cloud).
@Test func inMemoryEnvelopeStoreRoundTrips() throws {
  let store = InMemoryEnvelopeStore()
  #expect(store.loadEnvelope(account: "acc") == nil)
  let env = try E2EEVault.enroll(snapshot: snap, deviceId: "d", updatedAt: 1,
                                 deviceSecret: "s", recoveryPhrase: "p")
  store.saveEnvelope(env, account: "acc")
  #expect(store.loadEnvelope(account: "acc") == env)
}
