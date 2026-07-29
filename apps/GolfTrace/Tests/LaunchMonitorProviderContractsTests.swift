import Combine
import Foundation
import XCTest

@testable import GolfTrace

final class LaunchMonitorProviderContractsTests: XCTestCase {
  func testProviderIdentifiersSupportKnownAndFutureProviders() throws {
    let custom = LaunchMonitorProviderID(rawValue: "authorized-future-provider")

    XCTAssertEqual(try roundTrip(LaunchMonitorProviderID.mlm2Pro), .mlm2Pro)
    XCTAssertEqual(try roundTrip(custom), custom)
    XCTAssertNotEqual(custom, .garmin)
    XCTAssertEqual(LaunchMonitorProviderID.trackMan.rawValue, "trackman")
    XCTAssertEqual(LaunchMonitorProviderID.foresight.rawValue, "foresight")
    XCTAssertEqual(LaunchMonitorProviderID.uneekor.rawValue, "uneekor")
  }

  @MainActor
  func testMLM2PROMappingNormalizesSixMeasuredMetrics() throws {
    let raw = Data([0x01, 0x02, 0x03])
    let shot = LaunchMonitorShot(
      id: UUID(),
      receivedAt: Date(timeIntervalSince1970: 100),
      deviceShotID: 42,
      clubHeadSpeedMetersPerSecond: 40,
      ballSpeedMetersPerSecond: 60,
      horizontalLaunchAngleDegrees: -2,
      verticalLaunchAngleDegrees: 18,
      spinAxisDegrees: 4,
      totalSpinRPM: 2_300,
      rawMeasurement: raw
    )

    let measurement = MLM2PROLaunchMonitorProviderAdapter.measurement(from: shot)

    XCTAssertEqual(measurement.id, shot.id)
    XCTAssertEqual(measurement.providerID, .mlm2Pro)
    XCTAssertEqual(measurement.providerShotID, "42")
    XCTAssertEqual(measurement.metrics.count, 6)
    XCTAssertEqual(measurement.value(for: .clubHeadSpeed)?.value, 40)
    XCTAssertEqual(measurement.value(for: .clubHeadSpeed)?.unit, .metersPerSecond)
    XCTAssertEqual(measurement.value(for: .verticalLaunchAngle)?.value, 18)
    XCTAssertEqual(measurement.value(for: .totalSpin)?.value, 2_300)
    XCTAssertEqual(measurement.value(for: .totalSpin)?.unit, .revolutionsPerMinute)
    XCTAssertNil(measurement.value(for: .carryDistance))
  }

  func testMeasurementDeduplicationIsProviderQualified() {
    let date = Date(timeIntervalSince1970: 100)
    let mlm = LaunchMonitorMeasurement(
      providerID: .mlm2Pro,
      providerDeviceID: "device-a",
      providerSessionID: "session-1",
      providerShotID: "7",
      receivedAt: date,
      metrics: []
    )
    let garmin = LaunchMonitorMeasurement(
      providerID: .garmin,
      providerDeviceID: "device-a",
      providerSessionID: "session-1",
      providerShotID: "7",
      receivedAt: date,
      metrics: []
    )

    XCTAssertEqual(
      mlm.deduplicationKey,
      LaunchMonitorMeasurementDeduplicationKey(
        providerID: .mlm2Pro,
        providerDeviceID: "device-a",
        providerSessionID: "session-1",
        providerShotID: "7"
      )
    )
    XCTAssertEqual(
      garmin.deduplicationKey,
      LaunchMonitorMeasurementDeduplicationKey(
        providerID: .garmin,
        providerDeviceID: "device-a",
        providerSessionID: "session-1",
        providerShotID: "7"
      )
    )
    XCTAssertNotEqual(mlm.deduplicationKey, garmin.deduplicationKey)

    let legacy = LaunchMonitorMeasurement(
      providerID: .mlm2Pro,
      providerShotID: "7",
      receivedAt: date,
      metrics: []
    )
    XCTAssertNil(legacy.deduplicationKey)
  }

  func testStructuredDeduplicationKeyPreservesFieldBoundaries() throws {
    let first = LaunchMonitorMeasurementDeduplicationKey(
      providerID: .mlm2Pro,
      providerDeviceID: "device:a",
      providerSessionID: "session",
      providerShotID: "7"
    )
    let second = LaunchMonitorMeasurementDeduplicationKey(
      providerID: .mlm2Pro,
      providerDeviceID: "device",
      providerSessionID: "a:session",
      providerShotID: "7"
    )

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(Set([first, second]).count, 2)
    XCTAssertEqual(try roundTrip(first), first)
  }

  @MainActor
  func testMLM2PROStateMapsToTypedVendorNeutralStatus() throws {
    let ready = MLM2PROLaunchMonitorProviderAdapter.status(
      from: .ready(deviceName: "My MLM2PRO")
    )
    let authorizing = MLM2PROLaunchMonitorProviderAdapter.status(
      from: .awaitingAuthorization(deviceName: "My MLM2PRO", userID: 123)
    )
    let failed = MLM2PROLaunchMonitorProviderAdapter.status(
      from: .failed(message: "raw provider failure text")
    )

    XCTAssertEqual(ready.phase, .ready)
    XCTAssertEqual(ready.detail, .ready)
    XCTAssertEqual(ready.recovery, .none)
    XCTAssertEqual(authorizing.phase, .authorizing)
    XCTAssertEqual(authorizing.detail, .authorizationRequired)
    XCTAssertEqual(authorizing.recovery, .completeAuthorization)
    XCTAssertEqual(failed.detail, .providerFailed)
    XCTAssertEqual(failed.recovery, .restart)

    let encoded = try JSONEncoder().encode([ready, authorizing, failed])
    let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertFalse(json.contains("My MLM2PRO"))
    XCTAssertFalse(json.contains("123"))
    XCTAssertFalse(json.contains("raw provider failure text"))
  }

  @MainActor
  func testAdapterPublishesSanitizedSequencedEnvelopes() throws {
    let controller = LaunchMonitorController()
    let streamID = LaunchMonitorProviderEventStreamID()
    let provider = MLM2PROLaunchMonitorProviderAdapter(
      controller: controller,
      eventStreamID: streamID
    )
    var received: [LaunchMonitorProviderEventEnvelope] = []
    var cancellables: Set<AnyCancellable> = []
    provider.eventPublisher
      .sink { received.append($0) }
      .store(in: &cancellables)

    let deviceID = UUID()
    controller.events.send(.deviceTrustRequired(id: deviceID, name: "Practice MLM2PRO"))
    controller.events.send(
      .authorizationRequired(
        MLM2PROAuthorizationChallenge(
          userID: 4_294_967_295,
          deviceName: "AUTH-DEVICE-SECRET"
        )
      )
    )
    controller.events.send(
      .shot(
        LaunchMonitorShot(
          receivedAt: Date(timeIntervalSince1970: 10),
          deviceShotID: 9,
          clubHeadSpeedMetersPerSecond: 30,
          ballSpeedMetersPerSecond: 45,
          horizontalLaunchAngleDegrees: 0,
          verticalLaunchAngleDegrees: 15,
          spinAxisDegrees: 0,
          totalSpinRPM: 2_000,
          rawMeasurement: Data([0x01])
        )
      )
    )
    controller.events.send(.error(message: "RAW-ERROR-SECRET"))

    XCTAssertEqual(received.map(\.streamID), Array(repeating: streamID, count: 4))
    XCTAssertEqual(received.map(\.sequence), [1, 2, 3, 4])

    guard case .actionRequired(let trust) = received[0].event else {
      return XCTFail("Expected trust action")
    }
    guard case .confirmDeviceTrust(let trustedDeviceID, let deviceDisplayName) = trust else {
      return XCTFail("Expected associated-value trust action")
    }
    XCTAssertEqual(trustedDeviceID, deviceID)
    XCTAssertEqual(deviceDisplayName, "Practice MLM2PRO")

    guard case .statusChanged(let authorization) = received[1].event else {
      return XCTFail("Expected authorization status")
    }
    XCTAssertEqual(authorization.phase, .authorizing)
    XCTAssertEqual(authorization.detail, .authorizationRequired)
    XCTAssertEqual(authorization.recovery, .completeAuthorization)

    guard case .measurement(let measurement) = received[2].event else {
      return XCTFail("Expected measurement")
    }
    XCTAssertEqual(measurement.providerID, .mlm2Pro)
    XCTAssertEqual(measurement.providerShotID, "9")

    guard case .failure(let failure) = received[3].event else {
      return XCTFail("Expected typed failure")
    }
    XCTAssertEqual(failure, .providerReported)

    let authorizationJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(authorization), encoding: .utf8)
    )
    let failureJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(failure), encoding: .utf8)
    )
    let publishedJSON = authorizationJSON + failureJSON
    XCTAssertFalse(publishedJSON.contains("4294967295"))
    XCTAssertFalse(publishedJSON.contains("AUTH-DEVICE-SECRET"))
    XCTAssertFalse(publishedJSON.contains("RAW-ERROR-SECRET"))
    _ = cancellables
  }

  func testEventCursorRejectsWrongStreamDuplicateAndOutOfOrderEnvelopes() {
    let expectedStream = LaunchMonitorProviderEventStreamID()
    let otherStream = LaunchMonitorProviderEventStreamID()
    var cursor = LaunchMonitorProviderEventCursor(streamID: expectedStream)

    let second = envelope(streamID: expectedStream, sequence: 2, percent: 20)
    XCTAssertEqual(cursor.accept(second), .batteryLevel(percent: 20))
    XCTAssertNil(cursor.accept(second))
    XCTAssertNil(cursor.accept(envelope(streamID: expectedStream, sequence: 1, percent: 10)))
    XCTAssertNil(cursor.accept(envelope(streamID: otherStream, sequence: 3, percent: 30)))
    XCTAssertNil(cursor.accept(envelope(streamID: expectedStream, sequence: 0, percent: 0)))
    XCTAssertEqual(
      cursor.accept(envelope(streamID: expectedStream, sequence: 3, percent: 30)),
      .batteryLevel(percent: 30)
    )
    XCTAssertEqual(cursor.streamID, expectedStream)
    XCTAssertEqual(cursor.lastAcceptedSequence, 3)
  }

  @MainActor
  func testContractAcceptsAProviderWithoutConcreteTypeChecks() {
    let provider: any LaunchMonitorProviding = FakeLaunchMonitorProvider()

    XCTAssertEqual(provider.descriptor.id.rawValue, "test-provider")
    XCTAssertEqual(provider.capabilities.availableMetrics, [.ballSpeed])
    XCTAssertFalse(provider.hasPendingStopWork)
  }

  @MainActor
  func testMLM2PROAdapterDeclaresOnlyCurrentlyMappedCapabilities() {
    let provider = MLM2PROLaunchMonitorProviderAdapter(controller: LaunchMonitorController())

    XCTAssertEqual(
      provider.capabilities.measuredMetrics,
      [
        .clubHeadSpeed,
        .ballSpeed,
        .horizontalLaunchAngle,
        .verticalLaunchAngle,
        .spinAxis,
        .totalSpin,
      ]
    )
    XCTAssertEqual(provider.capabilities.providerDerivedMetrics, [])
    XCTAssertEqual(provider.capabilities.appDerivedMetrics, [])
    XCTAssertFalse(provider.capabilities.availableMetrics.contains(.carryDistance))
    XCTAssertFalse(provider.capabilities.availableMetrics.contains(.clubPath))
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
  }

  private func envelope(
    streamID: LaunchMonitorProviderEventStreamID,
    sequence: UInt64,
    percent: Int
  ) -> LaunchMonitorProviderEventEnvelope {
    LaunchMonitorProviderEventEnvelope(
      streamID: streamID,
      sequence: sequence,
      event: .batteryLevel(percent: percent)
    )
  }
}

@MainActor
private final class FakeLaunchMonitorProvider: LaunchMonitorProviding {
  let descriptor = LaunchMonitorProviderDescriptor(
    id: LaunchMonitorProviderID(rawValue: "test-provider"),
    displayName: "Test Provider",
    supportedMetrics: [.ballSpeed],
    supportsBatteryLevel: false,
    supportsAutomaticReconnect: false
  )
  let capabilities = LaunchMonitorCapabilitySnapshot(
    measuredMetrics: [.ballSpeed],
    providerDerivedMetrics: [],
    appDerivedMetrics: [],
    unavailableReasons: [:]
  )
  let eventStreamID = LaunchMonitorProviderEventStreamID()

  var eventPublisher: AnyPublisher<LaunchMonitorProviderEventEnvelope, Never> {
    Empty().eraseToAnyPublisher()
  }

  let hasPendingStopWork = false

  func start() {}
  func stop() {}
  func perform(_ command: LaunchMonitorProviderCommand) throws {}
  func flushPendingStop() async {}
}
