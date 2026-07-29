import CommonCrypto
import Foundation
import Security

enum MLM2PROSessionCodecError: Error, Equatable, LocalizedError {
  case randomNumberGenerationFailed(status: Int32)
  case encryptionFailed(status: Int32)
  case decryptionFailed(status: Int32)

  var errorDescription: String? {
    switch self {
    case .randomNumberGenerationFailed:
      "สร้างกุญแจชั่วคราวสำหรับ MLM2PRO ไม่สำเร็จ"
    case .encryptionFailed:
      "เข้ารหัสคำสั่ง MLM2PRO ไม่สำเร็จ"
    case .decryptionFailed:
      "ถอดรหัสข้อมูล MLM2PRO ไม่สำเร็จ"
    }
  }
}

enum MLM2PRODeviceEvent: Equatable, Sendable {
  case shotHappened
  case processingShot
  case ready
  case batteryLevel(percent: UInt8)
  case misread
  case disarmed
  case unknown(type: UInt8, payload: Data)
}

enum MLM2PROSessionMessageError: Error, Equatable, LocalizedError {
  case emptyDeviceEvent
  case truncatedDeviceEvent(type: UInt8)

  var errorDescription: String? {
    switch self {
    case .emptyDeviceEvent:
      "MLM2PRO ส่งสถานะว่างเปล่า"
    case .truncatedDeviceEvent(let type):
      "MLM2PRO ส่งสถานะชนิด \(type) มาไม่ครบ"
    }
  }
}

/// Session-only encryption used after the Mac advertises a fresh key to the
/// device. It deliberately contains no Rapsodo web API secret or user token.
struct MLM2PROSessionCodec {
  private static let initializationVector = Data([
    0x6D, 0x2E, 0x52, 0x13, 0x21, 0x32, 0x04, 0x45,
    0x6F, 0x2C, 0x79, 0x48, 0x10, 0x65, 0x6D, 0x42,
  ])

  private let key: Data

  init() throws {
    var keyBytes = [UInt8](repeating: 0, count: kCCKeySizeAES256)
    let status = keyBytes.withUnsafeMutableBytes { bytes in
      SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw MLM2PROSessionCodecError.randomNumberGenerationFailed(status: status)
    }
    key = Data(keyBytes)
  }

  init(testKey: Data) {
    precondition(testKey.count == kCCKeySizeAES256)
    key = testKey
  }

  /// The request is intentionally unencrypted: it announces a new, random
  /// AES-256 session key. The fixed prefix identifies the supported cipher.
  func authorizationRequest() -> Data {
    var request = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x01])
    request.append(key)
    return request
  }

  func encrypt(_ plaintext: Data) throws -> Data {
    try crypt(plaintext, operation: CCOperation(kCCEncrypt))
  }

  func decrypt(_ ciphertext: Data) throws -> Data {
    try crypt(ciphertext, operation: CCOperation(kCCDecrypt))
  }

  private func crypt(_ input: Data, operation: CCOperation) throws -> Data {
    let outputCapacity = input.count + kCCBlockSizeAES128
    var output = Data(count: outputCapacity)
    var written = 0

    let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
      Self.initializationVector.withUnsafeBytes { ivBytes in
        input.withUnsafeBytes { inputBytes in
          output.withUnsafeMutableBytes { outputBytes in
            CCCrypt(
              operation,
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              keyBytes.baseAddress,
              key.count,
              ivBytes.baseAddress,
              inputBytes.baseAddress,
              input.count,
              outputBytes.baseAddress,
              outputCapacity,
              &written
            )
          }
        }
      }
    }

    guard status == kCCSuccess else {
      if operation == CCOperation(kCCDecrypt) {
        throw MLM2PROSessionCodecError.decryptionFailed(status: status)
      }
      throw MLM2PROSessionCodecError.encryptionFailed(status: status)
    }
    output.removeSubrange(written..<output.count)
    return output
  }
}

enum MLM2PROSessionMessages {
  static let heartbeat = Data([0x01])
  static let arm = Data([0x01, 0x0D, 0x00, 0x01, 0x00, 0x00, 0x00])
  static let disarm = Data([0x01, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00])
  static let disconnect = Data(repeating: 0, count: 7)

  static func parseDeviceEvent(_ data: Data) throws -> MLM2PRODeviceEvent {
    guard let type = data.first else {
      throw MLM2PROSessionMessageError.emptyDeviceEvent
    }

    switch type {
    case 0:
      return .shotHappened
    case 1:
      return .processingShot
    case 2:
      return .ready
    case 3:
      guard data.count >= 2 else {
        throw MLM2PROSessionMessageError.truncatedDeviceEvent(type: type)
      }
      return .batteryLevel(percent: data[data.startIndex + 1])
    case 5:
      guard data.count >= 2 else {
        throw MLM2PROSessionMessageError.truncatedDeviceEvent(type: type)
      }
      switch data[data.startIndex + 1] {
      case 0:
        return .misread
      case 1:
        return .disarmed
      default:
        return .unknown(type: type, payload: Data(data.dropFirst()))
      }
    default:
      return .unknown(type: type, payload: Data(data.dropFirst()))
    }
  }

  /// Builds the plaintext configuration accepted after the device returns a
  /// user ID. The credential token comes from an injected provider and is not
  /// persisted or logged by the Bluetooth layer.
  static func configuration(for credential: MLM2PROAuthorizationCredential) -> Data {
    var result = Data([0x01, 0x02, 0x00, 0x00])

    // Published protocol defaults: sea-level air pressure and 15 °C.
    appendLittleEndian(UInt16(truncatingIfNeeded: 51_325), to: &result)
    appendLittleEndian(UInt16(1_500), to: &result)
    appendLittleEndian(credential.token, to: &result)
    result.append(contentsOf: [0x00, 0x00])
    return result
  }

  private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }
}
