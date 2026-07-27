import XCTest

@testable import GolfTrace

final class MLM2PROSessionCodecTests: XCTestCase {
  private let key = Data(0..<32)

  func testAES256CBCRoundTripUsesPadding() throws {
    let codec = MLM2PROSessionCodec(testKey: key)
    let plaintext = Data([0x01, 0x0D, 0x00, 0x01, 0x00, 0x00, 0x00])

    let encrypted = try codec.encrypt(plaintext)

    XCTAssertNotEqual(encrypted, plaintext)
    XCTAssertEqual(encrypted.count, 16)
    XCTAssertEqual(
      encrypted,
      Data([
        0x31, 0x2B, 0x38, 0x88, 0xB2, 0xA1, 0x02, 0x77,
        0x79, 0xBC, 0xB9, 0x1E, 0x97, 0x36, 0xD7, 0x10,
      ])
    )
    XCTAssertEqual(try codec.decrypt(encrypted), plaintext)
  }

  func testAuthorizationRequestCarriesCipherIdentifierAndSessionKey() {
    let request = MLM2PROSessionCodec(testKey: key).authorizationRequest()

    XCTAssertEqual(request.count, 38)
    XCTAssertEqual(request.prefix(6), Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x01]))
    XCTAssertEqual(request.suffix(32), key)
  }

  func testConfigurationEncodesInjectedTokenLittleEndian() {
    let credential = MLM2PROAuthorizationCredential(
      token: 0x0102_0304_0506_0708,
      expiresAt: nil
    )

    let configuration = MLM2PROSessionMessages.configuration(for: credential)

    XCTAssertEqual(configuration.count, 18)
    XCTAssertEqual(configuration.prefix(4), Data([0x01, 0x02, 0x00, 0x00]))
    XCTAssertEqual(
      configuration[8..<16],
      Data([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    )
    XCTAssertEqual(configuration.suffix(2), Data([0x00, 0x00]))
  }

  func testLifecycleCommandsRemainExact() {
    XCTAssertEqual(MLM2PROSessionMessages.heartbeat, Data([0x01]))
    XCTAssertEqual(
      MLM2PROSessionMessages.arm,
      Data([0x01, 0x0D, 0x00, 0x01, 0x00, 0x00, 0x00])
    )
    XCTAssertEqual(
      MLM2PROSessionMessages.disarm,
      Data([0x01, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00])
    )
    XCTAssertEqual(MLM2PROSessionMessages.disconnect, Data(repeating: 0, count: 7))
  }

  func testParsesReadyMisreadAndDisarmedEvents() throws {
    XCTAssertEqual(try MLM2PROSessionMessages.parseDeviceEvent(Data([0x02])), .ready)
    XCTAssertEqual(try MLM2PROSessionMessages.parseDeviceEvent(Data([0x05, 0x00])), .misread)
    XCTAssertEqual(try MLM2PROSessionMessages.parseDeviceEvent(Data([0x05, 0x01])), .disarmed)
  }

  func testParsesBatteryAndPreservesUnknownEventPayload() throws {
    XCTAssertEqual(
      try MLM2PROSessionMessages.parseDeviceEvent(Data([0x03, 0x55])),
      .batteryLevel(percent: 0x55)
    )
    XCTAssertEqual(
      try MLM2PROSessionMessages.parseDeviceEvent(Data([0x04, 0xAA, 0xBB])),
      .unknown(type: 0x04, payload: Data([0xAA, 0xBB]))
    )
  }

  func testRejectsTruncatedKnownDeviceEvent() {
    XCTAssertThrowsError(try MLM2PROSessionMessages.parseDeviceEvent(Data([0x05]))) {
      XCTAssertEqual($0 as? MLM2PROSessionMessageError, .truncatedDeviceEvent(type: 0x05))
    }
  }

  func testHeartbeatWatchdogExpiresAndReceiveExtendsDeadline() {
    let startedAt = Date(timeIntervalSince1970: 100)
    var watchdog = MLM2PROHeartbeatWatchdog(timeout: 10, startingAt: startedAt)

    XCTAssertFalse(watchdog.hasExpired(at: Date(timeIntervalSince1970: 109.999)))
    XCTAssertTrue(watchdog.hasExpired(at: Date(timeIntervalSince1970: 110)))

    watchdog.recordHeartbeat(at: Date(timeIntervalSince1970: 108))

    XCTAssertFalse(watchdog.hasExpired(at: Date(timeIntervalSince1970: 117)))
    XCTAssertTrue(watchdog.hasExpired(at: Date(timeIntervalSince1970: 118)))
  }

  func testArmingStateHasNonReadyStatusText() {
    let state = LaunchMonitorConnectionState.arming(deviceName: "MLM2PRO-TEST")

    XCTAssertEqual(state.statusText, "MLM2PRO-TEST กำลังเตรียมพร้อมรับค่าการตี")
    XCTAssertNotEqual(state, .ready(deviceName: "MLM2PRO-TEST"))
  }

  func testPeripheralTrustRequiresConfirmationBeforePersisting() throws {
    let suiteName = "GolfTraceTests.MLM2PROTrust.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = MLM2PROTrustedPeripheralStore(userDefaults: defaults)
    let confirmedID = UUID()
    let otherID = UUID()

    XCTAssertNil(store.trustedPeripheralID)
    XCTAssertEqual(store.decision(for: confirmedID), .requestConfirmation)

    store.trust(confirmedID)

    XCTAssertEqual(store.trustedPeripheralID, confirmedID)
    XCTAssertEqual(store.decision(for: confirmedID), .connect)
    XCTAssertEqual(store.decision(for: otherID), .ignore)

    store.forget()
    XCTAssertNil(store.trustedPeripheralID)
    XCTAssertEqual(store.decision(for: confirmedID), .requestConfirmation)
  }

  func testPublishedGATTIdentifiersRemainExact() {
    XCTAssertEqual(MLM2PROGATT.service.uuidString, "DAF9B2A4-E4DB-4BE4-816D-298A050F25CD")
    XCTAssertEqual(
      MLM2PROGATT.measurement.uuidString,
      "76830BCE-B9A7-4F69-AEAA-FD5B9F6B0965"
    )
    XCTAssertEqual(
      MLM2PROGATT.writeResponse.uuidString,
      "CFBBCB0D-7121-4BC2-BF54-8284166D61F0"
    )
    XCTAssertEqual(Set(MLM2PROGATT.allCharacteristics).count, 7)
  }
}
