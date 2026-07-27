import Foundation

/// A short-lived Third-party credential returned by an approved credential
/// service. The web API secret belongs in that service or Keychain-backed
/// provider, never in the app source tree.
struct MLM2PROAuthorizationCredential: Equatable, Sendable {
  let token: UInt64
  let expiresAt: Date?

  init(token: UInt64, expiresAt: Date? = nil) {
    self.token = token
    self.expiresAt = expiresAt
  }
}

protocol MLM2PROTokenProvider: Sendable {
  func token(for userID: UInt32) async throws -> MLM2PROAuthorizationCredential
}

enum MLM2PROAuthorizationError: Error, Equatable, LocalizedError {
  case providerNotConfigured
  case expired
  /// The MLM2PRO declined our initial GATT authorization request before it
  /// returned the user ID required to obtain a partner credential. This is
  /// intentionally separate from an expired credential: no credential has
  /// been requested or sent yet at this point.
  case initialAuthorizationRequestRejected(status: UInt8)
  case challengeChanged
  case invalidDeviceResponse

  var errorDescription: String? {
    switch self {
    case .providerNotConfigured:
      "ยังไม่ได้ตั้งค่าช่องทางรับสิทธิ์ Third-party จาก Rapsodo"
    case .expired:
      "สิทธิ์ Third-party หมดอายุ กรุณายืนยันใหม่ในแอป Rapsodo"
    case .initialAuthorizationRequestRejected(let status):
      "MLM2PRO ปฏิเสธคำขอเริ่มสิทธิ์ของ GolfTrace (type 2, status \(status)) ก่อนส่งรหัสผู้ใช้ จึงยังไม่ได้ใช้ key จาก Rapsodo. สิทธิ์ของ Awesome Golf ใช้แทนสิทธิ์ของ GolfTrace ไม่ได้ — ต้องใช้สิทธิ์หรือสเปก Partner สำหรับ GolfTrace ที่ Rapsodo ออกให้"
    case .challengeChanged:
      "MLM2PRO เปลี่ยนคำขอยืนยันตัวตน กรุณาเชื่อมต่อใหม่"
    case .invalidDeviceResponse:
      "MLM2PRO ส่งคำตอบการยืนยันตัวตนที่อ่านไม่ได้"
    }
  }
}

struct MLM2PROAuthorizationRequiredProvider: MLM2PROTokenProvider {
  func token(for userID: UInt32) async throws -> MLM2PROAuthorizationCredential {
    throw MLM2PROAuthorizationError.providerNotConfigured
  }
}
