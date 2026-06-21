import Foundation
import CryptoKit

/// The account-level key LIFECYCLE on top of the raw `E2EESync` envelope (the E2EE sync design P3).
///
/// Convention (the "OAuth + auto-generated key" model, Q1 option ii): the data is wrapped under
///   • one **device secret** PER device — a random high-entropy key cached in the Keychain/Keystore so the user's
///     own devices unlock silently (no passphrase typing), keyed by `device:<deviceId>` so each device has its own
///     slot (this is what makes multi-device in P5 work), and
///   • one shared **recovery phrase** — the portable backup that lets a brand-new device (or a reinstall) unlock.
/// Adding a device or rotating a secret only re-wraps the small data-key (via `E2EESync.rewrap`) — the blob is
/// never re-encrypted.
///
/// Pure + deterministic given its inputs (caller supplies the snapshot, secrets, and HLC), so it is fully testable.
public enum E2EEVault {

  /// The shared recovery-phrase wrap label.
  public static let recoveryLabel = "recovery"
  /// The per-device wrap label.
  public static func deviceLabel(_ deviceId: String) -> String { "device:\(deviceId)" }

  /// A signed-in account's stable, NON-reversible identity. We hash the OAuth subject so the raw provider id is
  /// never stored or uploaded.
  public struct Identity: Codable, Equatable, Sendable {
    public let accountId: String   // SHA-256(provider:subject) hex — stable, opaque
    public let provider: String    // "apple" | "google"
    public let deviceId: String    // this device (random UUID, persisted in Keychain)
    public init(accountId: String, provider: String, deviceId: String) {
      self.accountId = accountId; self.provider = provider; self.deviceId = deviceId
    }
  }

  /// Derive the opaque account id from an OAuth provider + its subject (`sub`). Deterministic; reveals nothing
  /// about the subject.
  public static func makeAccountId(provider: String, subject: String) -> String {
    SHA256.hash(data: Data("\(provider):\(subject)".utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// A fresh high-entropy device secret (32 random bytes, base64). The caller caches it in the Keychain/Keystore.
  public static func newDeviceSecret() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
  }

  /// Canonical form of a recovery phrase so that "the same words" always derive the same key regardless of the
  /// user's spacing or capitalization: lowercase, trim, and collapse all whitespace to single spaces. Applied to the
  /// recovery phrase on BOTH the wrap and the unlock side. (Device secrets are opaque base64 → never normalized.)
  public static func normalizeRecovery(_ phrase: String) -> String {
    phrase.lowercased().split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }.joined(separator: " ")
  }

  /// First-time enrollment: encrypt the snapshot under THIS device's secret + the recovery phrase (same data-key).
  /// `v` selects the wrap KDF: v2 = Argon2id (production), v1 = HKDF (PoC/interop). Production callers pass v: 2.
  public static func enroll(snapshot: Data, deviceId: String, updatedAt: Double,
                            deviceSecret: String, recoveryPhrase: String, v: Int = 1) throws -> E2EESync.Envelope {
    try E2EESync.encrypt(snapshot,
                         secrets: [deviceLabel(deviceId): deviceSecret, recoveryLabel: normalizeRecovery(recoveryPhrase)],
                         updatedAt: updatedAt, device: deviceId, v: v)
  }

  /// Silent unlock on one of the user's own devices (its cached secret).
  public static func unlock(_ env: E2EESync.Envelope, deviceId: String, deviceSecret: String) throws -> Data {
    try E2EESync.decrypt(env, label: deviceLabel(deviceId), secret: deviceSecret)
  }

  /// Unlock with the recovery phrase (new device / reinstall / lost device secret).
  public static func unlockWithRecovery(_ env: E2EESync.Envelope, phrase: String) throws -> Data {
    try E2EESync.decrypt(env, label: recoveryLabel, secret: normalizeRecovery(phrase))
  }

  /// Enroll a NEW device into an existing envelope using the recovery phrase: unwrap via recovery, add this
  /// device's own slot. The blob is not re-encrypted. Returns the updated envelope to upload.
  public static func enrollNewDevice(_ env: E2EESync.Envelope, recoveryPhrase: String,
                                     deviceId: String, deviceSecret: String) throws -> E2EESync.Envelope {
    try E2EESync.rewrap(env, unlock: recoveryLabel, with: normalizeRecovery(recoveryPhrase),
                        add: deviceLabel(deviceId), secret: deviceSecret)
  }

  /// The device ids that have a wrap slot in this envelope (P5 "your devices" listing). Excludes the recovery slot.
  public static func enrolledDevices(_ env: E2EESync.Envelope) -> [String] {
    env.wraps.keys.compactMap { $0.hasPrefix("device:") ? String($0.dropFirst("device:".count)) : nil }.sorted()
  }

  /// Whether THIS device can silently unlock the envelope (has its own slot). If false on a pulled envelope, the
  /// device must `enrollNewDevice` via the recovery phrase before it can decrypt.
  public static func hasDeviceSlot(_ env: E2EESync.Envelope, deviceId: String) -> Bool {
    env.wraps[deviceLabel(deviceId)] != nil
  }
}

/// The seam between the sync logic and where the encrypted envelope actually lives. P3 uses a local file (to
/// simulate the cloud); P4 swaps in a Cloudflare-backed implementation with the SAME interface.
public protocol EnvelopeStore {
  func loadEnvelope(account: String) -> E2EESync.Envelope?
  /// Returns whether the envelope was durably stored. Callers MUST NOT report "encrypted" on a `false` return —
  /// a failed save with a discarded recovery phrase = silent total data loss.
  @discardableResult func saveEnvelope(_ env: E2EESync.Envelope, account: String) -> Bool
}

/// In-memory store for tests (and a stand-in before the file/cloud store exists).
public final class InMemoryEnvelopeStore: EnvelopeStore {
  private var map: [String: E2EESync.Envelope] = [:]
  public init() {}
  public func loadEnvelope(account: String) -> E2EESync.Envelope? { map[account] }
  @discardableResult public func saveEnvelope(_ env: E2EESync.Envelope, account: String) -> Bool { map[account] = env; return true }
}
