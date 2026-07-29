import XCTest

@testable import GolfTrace

final class MLM2PROMeasurementParserTests: XCTestCase {
  private let parser = MLM2PROMeasurementParser()

  func testParsesSixConfirmedMetricsFromPublishedPacket() throws {
    let packet = Data([
      0x44, 0x00,  // Club speed: 6.8 m/s
      0x4F, 0x00,  // Ball speed: 7.9 m/s
      0xE2, 0xFF,  // Horizontal launch angle: -3.0°
      0x0A, 0x01,  // Vertical launch angle: 26.6°
      0xC8, 0xFF,  // Spin axis: -5.6°
      0xFC, 0x07,  // Total spin: 2044 RPM
      0x05, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00,
    ])
    let receivedAt = Date(timeIntervalSince1970: 123)

    let shot = try parser.parseDecryptedMeasurement(
      packet,
      receivedAt: receivedAt,
      deviceShotID: 42
    )

    XCTAssertEqual(shot.receivedAt, receivedAt)
    XCTAssertEqual(shot.deviceShotID, 42)
    XCTAssertEqual(shot.clubHeadSpeedMetersPerSecond, 6.8, accuracy: 0.000_001)
    XCTAssertEqual(shot.ballSpeedMetersPerSecond, 7.9, accuracy: 0.000_001)
    XCTAssertEqual(shot.horizontalLaunchAngleDegrees, -3.0, accuracy: 0.000_001)
    XCTAssertEqual(shot.verticalLaunchAngleDegrees, 26.6, accuracy: 0.000_001)
    XCTAssertEqual(shot.spinAxisDegrees, -5.6, accuracy: 0.000_001)
    XCTAssertEqual(shot.totalSpinRPM, 2_044)
    XCTAssertEqual(shot.rawMeasurement, packet)
  }

  func testConvertsCanonicalSpeedToMPHAndDerivesSmashFactor() throws {
    let packet = Data([
      0xF4, 0x01,  // 50.0 m/s
      0xEE, 0x02,  // 75.0 m/s
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
    ])

    let shot = try parser.parseDecryptedMeasurement(packet, deviceShotID: 1)

    XCTAssertEqual(shot.clubHeadSpeedMPH, 111.846_814_602_72, accuracy: 0.000_001)
    XCTAssertEqual(shot.ballSpeedMPH, 167.770_221_904_08, accuracy: 0.000_001)
    XCTAssertEqual(try XCTUnwrap(shot.smashFactor), 1.5, accuracy: 0.000_001)
  }

  func testAcceptsMinimumTwelveByteMeasurement() throws {
    let packet = Data([
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0x00, 0x00,
      0x01, 0x00,
    ])

    let shot = try parser.parseDecryptedMeasurement(packet, deviceShotID: 7)

    XCTAssertEqual(shot.totalSpinRPM, 1)
    XCTAssertNil(shot.smashFactor)
  }

  func testRejectsAllZeroMisreadMeasurement() {
    let packet = Data(repeating: 0, count: 20)

    XCTAssertThrowsError(try parser.parseDecryptedMeasurement(packet, deviceShotID: 1)) {
      XCTAssertEqual($0 as? MLM2PROMeasurementParserError, .allZeroMeasurement)
    }
  }

  func testRejectsShortMeasurement() {
    let packet = Data(repeating: 0, count: 11)

    XCTAssertThrowsError(try parser.parseDecryptedMeasurement(packet, deviceShotID: 1)) {
      XCTAssertEqual(
        $0 as? MLM2PROMeasurementParserError,
        .payloadTooShort(actualBytes: 11, requiredBytes: 12)
      )
    }
  }

  func testRejectsNegativeSpeedWithoutRejectingSignedAngles() {
    let packet = Data([
      0xFF, 0xFF,
      0x00, 0x00,
      0xFF, 0xFF,
      0xFF, 0xFF,
      0xFF, 0xFF,
      0x00, 0x00,
    ])

    XCTAssertThrowsError(try parser.parseDecryptedMeasurement(packet, deviceShotID: 1)) {
      XCTAssertEqual(
        $0 as? MLM2PROMeasurementParserError,
        .invalidSpeed(field: "หัวไม้", rawValue: -1)
      )
    }
  }
}
