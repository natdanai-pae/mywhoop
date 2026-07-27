@preconcurrency import CoreBluetooth
import XCTest

@testable import GolfTrace

final class MLM2PROBluetoothClientTests: XCTestCase {
  func testNotificationSubscriptionsUseStableSerialOrder() {
    XCTAssertEqual(
      MLM2PROGATT.notificationCharacteristics.map(\.uuidString),
      [
        MLM2PROGATT.events.uuidString,
        MLM2PROGATT.heartbeat.uuidString,
        MLM2PROGATT.measurement.uuidString,
        MLM2PROGATT.writeResponse.uuidString,
      ]
    )
  }

  func testATTSubscriptionFailureRequiresExplicitRestartAndPreservesDiagnostic() {
    let failure = MLM2PROGATTSubscriptionFailure(
      characteristicID: MLM2PROGATT.writeResponse.uuidString,
      reason: .attResult(1)
    )

    XCTAssertEqual(failure.recovery, .requiresExplicitRestart)
    XCTAssertEqual(
      failure.diagnosticMessage,
      "MLM2PRO เปิด notification ช่อง CFBBCB0D-7121-4BC2-BF54-8284166D61F0 ไม่สำเร็จ: ATT result 1. "
        + "หยุดการเชื่อมต่ออัตโนมัติเพื่อป้องกันการวนซ้ำ กรุณาเริ่ม GolfTrace ใหม่ก่อนลองอีกครั้ง"
    )
  }

  func testConnectionDiagnosticPersistsOnlyRedactedCallbackMetadata() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-MLM2PRO-diagnostic-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let diagnostics = MLM2PROConnectionDiagnostics(
      fileURL: fileURL,
      now: { Date(timeIntervalSince1970: 0) }
    )
    let attError = NSError(domain: CBATTErrorDomain, code: 1)

    let line = try XCTUnwrap(
      diagnostics.record(
        .notificationCallbackFailed,
        state: .discoveringServices(deviceName: "BleZ 5.50"),
        characteristicID: MLM2PROGATT.writeResponse,
        error: attError
      )
    )
    let stored = try String(contentsOf: fileURL, encoding: .utf8)

    XCTAssertEqual(stored, line)
    XCTAssertTrue(line.contains("event=notification-callback-failed"))
    XCTAssertTrue(line.contains("state=discovering-services"))
    XCTAssertTrue(line.contains("uuid=\(MLM2PROGATT.writeResponse.uuidString.suffix(8))"))
    XCTAssertTrue(line.contains("result=att:1"))
    XCTAssertFalse(line.contains("BleZ 5.50"))
    XCTAssertFalse(line.contains(MLM2PROGATT.writeResponse.uuidString))
  }

  func testWriteResponseDiagnosticPersistsOnlyNumericMetadata() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-MLM2PRO-write-response-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let diagnostics = MLM2PROConnectionDiagnostics(
      fileURL: fileURL,
      now: { Date(timeIntervalSince1970: 0) }
    )
    let line = try XCTUnwrap(
      diagnostics.record(
        .writeResponseReceived,
        state: .awaitingAuthorization(deviceName: "BleZ 5.50", userID: 42),
        characteristicID: MLM2PROGATT.writeResponse,
        responseLength: 6,
        responseType: 2,
        responseStatus: 1
      )
    )

    XCTAssertTrue(line.contains("event=write-response-received"))
    XCTAssertTrue(line.contains("response_length=6"))
    XCTAssertTrue(line.contains("response_type=2"))
    XCTAssertTrue(line.contains("response_status=1"))
    XCTAssertFalse(line.contains("BleZ 5.50"))
  }

  func testAuthorizationAndConfigurationRejectionsRequireExplicitRestart() {
    XCTAssertEqual(
      MLM2PROWriteResponseFailurePolicy.recovery(responseType: 0, status: 1),
      .requiresExplicitRestart
    )
    XCTAssertEqual(
      MLM2PROWriteResponseFailurePolicy.recovery(responseType: 2, status: 1),
      .requiresExplicitRestart
    )
    XCTAssertNil(MLM2PROWriteResponseFailurePolicy.recovery(responseType: 0, status: 0))
    XCTAssertNil(MLM2PROWriteResponseFailurePolicy.recovery(responseType: 9, status: 1))
  }

  func testInitialAuthorizationRejectionExplainsThatNoCredentialWasUsed() {
    XCTAssertEqual(
      MLM2PROAuthorizationError.initialAuthorizationRequestRejected(status: 1).localizedDescription,
      "MLM2PRO ปฏิเสธคำขอเริ่มสิทธิ์ของ GolfTrace (type 2, status 1) ก่อนส่งรหัสผู้ใช้ จึงยังไม่ได้ใช้ key จาก Rapsodo. สิทธิ์ของ Awesome Golf ใช้แทนสิทธิ์ของ GolfTrace ไม่ได้ — ต้องใช้สิทธิ์หรือสเปก Partner สำหรับ GolfTrace ที่ Rapsodo ออกให้"
    )
  }
}
