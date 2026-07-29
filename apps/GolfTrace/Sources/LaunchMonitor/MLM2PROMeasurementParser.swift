import Foundation

protocol LaunchMonitorMeasurementParsing: Sendable {
  func parseDecryptedMeasurement(
    _ data: Data,
    receivedAt: Date,
    deviceShotID: UInt64
  ) throws -> LaunchMonitorShot
}

enum MLM2PROMeasurementParserError: Error, Equatable, LocalizedError {
  case payloadTooShort(actualBytes: Int, requiredBytes: Int)
  case allZeroMeasurement
  case invalidSpeed(field: String, rawValue: Int16)

  var errorDescription: String? {
    switch self {
    case .payloadTooShort(let actualBytes, let requiredBytes):
      "ข้อมูลการตีสั้นเกินไป: ได้ \(actualBytes) ไบต์ แต่ต้องมีอย่างน้อย \(requiredBytes) ไบต์"
    case .allZeroMeasurement:
      "MLM2PRO อ่านช็อตล่าสุดไม่สำเร็จและส่งค่าศูนย์ทั้งหมด"
    case .invalidSpeed(let field, let rawValue):
      "ค่าความเร็ว \(field) ไม่ถูกต้อง (ค่าดิบ \(rawValue))"
    }
  }
}

/// Parses the first six confirmed values in a decrypted MLM2PRO measurement.
///
/// Each value occupies two little-endian bytes. Speeds and angles use one
/// decimal place; spin is an unsigned RPM value. Later bytes remain attached
/// to the shot as raw, non-secret measurement data until their meaning is
/// independently validated.
struct MLM2PROMeasurementParser: LaunchMonitorMeasurementParsing {
  static let requiredByteCount = 12

  func parseDecryptedMeasurement(
    _ data: Data,
    receivedAt: Date = Date(),
    deviceShotID: UInt64
  ) throws -> LaunchMonitorShot {
    guard data.count >= Self.requiredByteCount else {
      throw MLM2PROMeasurementParserError.payloadTooShort(
        actualBytes: data.count,
        requiredBytes: Self.requiredByteCount
      )
    }
    guard data.contains(where: { $0 != 0 }) else {
      throw MLM2PROMeasurementParserError.allZeroMeasurement
    }

    let clubHeadSpeedRaw = signedLittleEndian(in: data, at: 0)
    let ballSpeedRaw = signedLittleEndian(in: data, at: 2)
    guard clubHeadSpeedRaw >= 0 else {
      throw MLM2PROMeasurementParserError.invalidSpeed(
        field: "หัวไม้",
        rawValue: clubHeadSpeedRaw
      )
    }
    guard ballSpeedRaw >= 0 else {
      throw MLM2PROMeasurementParserError.invalidSpeed(
        field: "ลูก",
        rawValue: ballSpeedRaw
      )
    }

    return LaunchMonitorShot(
      receivedAt: receivedAt,
      deviceShotID: deviceShotID,
      clubHeadSpeedMetersPerSecond: Double(clubHeadSpeedRaw) / 10,
      ballSpeedMetersPerSecond: Double(ballSpeedRaw) / 10,
      horizontalLaunchAngleDegrees: Double(signedLittleEndian(in: data, at: 4)) / 10,
      verticalLaunchAngleDegrees: Double(signedLittleEndian(in: data, at: 6)) / 10,
      spinAxisDegrees: Double(signedLittleEndian(in: data, at: 8)) / 10,
      totalSpinRPM: unsignedLittleEndian(in: data, at: 10),
      rawMeasurement: data
    )
  }

  private func signedLittleEndian(in data: Data, at offset: Int) -> Int16 {
    Int16(bitPattern: unsignedLittleEndian(in: data, at: offset))
  }

  private func unsignedLittleEndian(in data: Data, at offset: Int) -> UInt16 {
    let low = UInt16(data[data.startIndex + offset])
    let high = UInt16(data[data.startIndex + offset + 1]) << 8
    return low | high
  }
}
