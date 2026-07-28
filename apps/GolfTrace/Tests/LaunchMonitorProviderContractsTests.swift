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

    XCTAssertEqual(mlm.deduplicationKey, "mlm2pro:device-a:session-1:7")
    XCTAssertEqual(garmin.deduplicationKey, "garmin:device-a:session-1:7")
    XCTAssertNotEqual(mlm.deduplicationKey, garmin.deduplicationKey)

    let legacy = LaunchMonitorMeasurement(
      providerID: .mlm2Pro,
      providerShotID: "7",
      receivedAt: date,
      metrics: []
    )
    XCTAssertNil(legacy.deduplicationKey)
  }

  @MainActor
  func testMLM2PROStateMapsToVendorNeutralPhase() {
    let ready = MLM2PROLaunchMonitorProviderAdapter.status(
      from: .ready(deviceName: "My MLM2PRO")
    )
    let authorizing = MLM2PROLaunchMonitorProviderAdapter.status(
      from: .awaitingAuthorization(deviceName: "My MLM2PRO", userID: 123)
    )

    XCTAssertEqual(ready.phase, .ready)
    XCTAssertEqual(ready.deviceName, "My MLM2PRO")
    XCTAssertEqual(authorizing.phase, .authorizing)
    XCTAssertEqual(authorizing.deviceName, "My MLM2PRO")
  }

  @MainActor
  func testAdapterPublishesSanitizedActionsAndMeasurements() {
    let controller = LaunchMonitorController()
    let provider = MLM2PROLaunchMonitorProviderAdapter(controller: controller)
    var received: [LaunchMonitorProviderEvent] = []
    var cancellables: Set<AnyCancellable> = []
    provider.eventPublisher
      .sink { received.append($0) }
      .store(in: &cancellables)

    let deviceID = UUID()
    controller.events.send(.deviceTrustRequired(id: deviceID, name: "Practice MLM2PRO"))
    controller.events.send(
      .authorizationRequired(
        MLM2PROAuthorizationChallenge(userID: 77, deviceName: "Practice MLM2PRO")
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

    guard case .actionRequired(let trust) = received[0] else {
      return XCTFail("Expected trust action")
    }
    XCTAssertEqual(trust.kind, .confirmDeviceTrust)
    XCTAssertEqual(trust.deviceID, deviceID)
    XCTAssertFalse(trust.requiresSecureInput)

    guard case .statusChanged(let authorization) = received[1] else {
      return XCTFail("Expected authorization status")
    }
    XCTAssertEqual(authorization.phase, .authorizing)
    XCTAssertEqual(authorization.deviceName, "Practice MLM2PRO")

    guard case .measurement(let measurement) = received[2] else {
      return XCTFail("Expected measurement")
    }
    XCTAssertEqual(measurement.providerID, .mlm2Pro)
    XCTAssertEqual(measurement.providerShotID, "9")

    let encoded = try? JSONEncoder().encode(authorization)
    let publishedJSON = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    XCTAssertFalse(publishedJSON.lowercased().contains("token"))
    XCTAssertFalse(publishedJSON.lowercased().contains("credential"))
    _ = cancellables
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

  var eventPublisher: AnyPublisher<LaunchMonitorProviderEvent, Never> {
    Empty().eraseToAnyPublisher()
  }

  let hasPendingStopWork = false

  func start() {}
  func stop() {}
  func perform(_ command: LaunchMonitorProviderCommand) throws {}
  func flushPendingStop() async {}
}
