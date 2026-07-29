import Combine
import Foundation

/// Stable provider identity used by domain, persistence, and diagnostics.
///
/// This is a value type instead of a closed enum so adding an authorized
/// provider never requires changing shared switch statements in the UI.
struct LaunchMonitorProviderID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let mlm2Pro = LaunchMonitorProviderID(rawValue: "mlm2pro")
  static let garmin = LaunchMonitorProviderID(rawValue: "garmin")
  static let trackMan = LaunchMonitorProviderID(rawValue: "trackman")
  static let foresight = LaunchMonitorProviderID(rawValue: "foresight")
  static let uneekor = LaunchMonitorProviderID(rawValue: "uneekor")
}

struct LaunchMonitorMetricID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let clubHeadSpeed = LaunchMonitorMetricID(rawValue: "club_head_speed")
  static let ballSpeed = LaunchMonitorMetricID(rawValue: "ball_speed")
  static let horizontalLaunchAngle = LaunchMonitorMetricID(rawValue: "horizontal_launch_angle")
  static let verticalLaunchAngle = LaunchMonitorMetricID(rawValue: "vertical_launch_angle")
  static let spinAxis = LaunchMonitorMetricID(rawValue: "spin_axis")
  static let totalSpin = LaunchMonitorMetricID(rawValue: "total_spin")
  static let smashFactor = LaunchMonitorMetricID(rawValue: "smash_factor")
  static let carryDistance = LaunchMonitorMetricID(rawValue: "carry_distance")
  static let clubPath = LaunchMonitorMetricID(rawValue: "club_path")
  static let angleOfAttack = LaunchMonitorMetricID(rawValue: "angle_of_attack")
}

struct LaunchMonitorUnitID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let metersPerSecond = LaunchMonitorUnitID(rawValue: "m_per_s")
  static let degrees = LaunchMonitorUnitID(rawValue: "degrees")
  static let revolutionsPerMinute = LaunchMonitorUnitID(rawValue: "rpm")
  static let ratio = LaunchMonitorUnitID(rawValue: "ratio")
  static let meters = LaunchMonitorUnitID(rawValue: "meters")
}

enum LaunchMonitorMetricOrigin: String, Codable, Equatable, Sendable {
  case measured
  case providerDerived = "provider_derived"
  case appDerived = "app_derived"
}

struct LaunchMonitorMetricValue: Codable, Equatable, Identifiable, Sendable {
  var id: LaunchMonitorMetricID { metricID }

  let metricID: LaunchMonitorMetricID
  let value: Double
  let unit: LaunchMonitorUnitID
  let origin: LaunchMonitorMetricOrigin
  let confidence: Double?
}

/// Structured identity for provider shots that are safe to deduplicate across
/// app launches. Each field participates independently in equality and hashing,
/// so delimiter characters inside provider identifiers cannot create aliases.
struct LaunchMonitorMeasurementDeduplicationKey: Codable, Equatable, Hashable, Sendable {
  let providerID: LaunchMonitorProviderID
  let providerDeviceID: String
  let providerSessionID: String
  let providerShotID: String
}

/// Provider-neutral shot measurement.
///
/// Values are normalized to SI-compatible units at the adapter boundary.
/// Raw provider bytes deliberately remain behind the adapter boundary so they
/// cannot leak into presentation or AI state.
struct LaunchMonitorMeasurement: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let providerID: LaunchMonitorProviderID
  let providerDeviceID: String?
  let providerSessionID: String?
  let providerShotID: String
  let receivedAt: Date
  let metrics: [LaunchMonitorMetricValue]

  init(
    id: UUID = UUID(),
    providerID: LaunchMonitorProviderID,
    providerDeviceID: String? = nil,
    providerSessionID: String? = nil,
    providerShotID: String,
    receivedAt: Date,
    metrics: [LaunchMonitorMetricValue]
  ) {
    self.id = id
    self.providerID = providerID
    self.providerDeviceID = providerDeviceID
    self.providerSessionID = providerSessionID
    self.providerShotID = providerShotID
    self.receivedAt = receivedAt
    self.metrics = metrics
  }

  func value(for metricID: LaunchMonitorMetricID) -> LaunchMonitorMetricValue? {
    metrics.first { $0.metricID == metricID }
  }

  /// A durable key is available only when the provider supplies device and
  /// session identity. A process-local counter alone is not safe for dedupe.
  var deduplicationKey: LaunchMonitorMeasurementDeduplicationKey? {
    guard let providerDeviceID, let providerSessionID else { return nil }
    return LaunchMonitorMeasurementDeduplicationKey(
      providerID: providerID,
      providerDeviceID: providerDeviceID,
      providerSessionID: providerSessionID,
      providerShotID: providerShotID
    )
  }
}

struct LaunchMonitorProviderDescriptor: Codable, Equatable, Sendable {
  let id: LaunchMonitorProviderID
  let displayName: String
  let supportedMetrics: [LaunchMonitorMetricID]
  let supportsBatteryLevel: Bool
  let supportsAutomaticReconnect: Bool
}

enum LaunchMonitorMetricUnavailabilityReason: String, Codable, Equatable, Sendable {
  case unsupportedByProvider = "unsupported_by_provider"
  case unavailableFromDevice = "unavailable_from_device"
  case authorizationRequired = "authorization_required"
  case prerequisiteUnavailable = "prerequisite_unavailable"
}

struct LaunchMonitorCapabilitySnapshot: Codable, Equatable, Sendable {
  let measuredMetrics: Set<LaunchMonitorMetricID>
  let providerDerivedMetrics: Set<LaunchMonitorMetricID>
  let appDerivedMetrics: Set<LaunchMonitorMetricID>
  let unavailableReasons: [LaunchMonitorMetricID: LaunchMonitorMetricUnavailabilityReason]

  var availableMetrics: Set<LaunchMonitorMetricID> {
    measuredMetrics.union(providerDerivedMetrics).union(appDerivedMetrics)
  }
}

enum LaunchMonitorProviderConnectionPhase: String, Codable, Equatable, Sendable {
  case inactive
  case unavailable
  case discovering
  case awaitingUserAction = "awaiting_user_action"
  case connecting
  case authorizing
  case preparing
  case ready
  case stopping
  case failed
}

enum LaunchMonitorProviderStatusDetail: String, Codable, Equatable, Sendable {
  case idle
  case bluetoothPoweredOff = "bluetooth_powered_off"
  case bluetoothUnauthorized = "bluetooth_unauthorized"
  case bluetoothUnsupported = "bluetooth_unsupported"
  case bluetoothResetting = "bluetooth_resetting"
  case bluetoothStateUnknown = "bluetooth_state_unknown"
  case scanning
  case deviceTrustRequired = "device_trust_required"
  case connecting
  case discoveringServices = "discovering_services"
  case authorizationRequired = "authorization_required"
  case arming
  case ready
  case stopping
  case providerFailed = "provider_failed"
}

enum LaunchMonitorProviderRecovery: String, Codable, Equatable, Sendable {
  case none
  case automatic
  case start
  case enableBluetooth = "enable_bluetooth"
  case grantBluetoothPermission = "grant_bluetooth_permission"
  case useSupportedHardware = "use_supported_hardware"
  case confirmDeviceTrust = "confirm_device_trust"
  case completeAuthorization = "complete_authorization"
  case restart
}

struct LaunchMonitorProviderStatus: Codable, Equatable, Sendable {
  let phase: LaunchMonitorProviderConnectionPhase
  let detail: LaunchMonitorProviderStatusDetail
  let recovery: LaunchMonitorProviderRecovery
}

struct LaunchMonitorDeviceCandidate: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let displayName: String
  let signalStrength: Int
}

/// A sanitized request safe to publish to presentation state.
///
/// It identifies the required action but never contains an API secret, token,
/// authorization credential, or raw Bluetooth response.
enum LaunchMonitorProviderActionRequest: Codable, Equatable, Identifiable, Sendable {
  case confirmDeviceTrust(deviceID: UUID, deviceDisplayName: String)

  var id: String {
    switch self {
    case .confirmDeviceTrust(let deviceID, _):
      "confirm-device-trust:\(deviceID.uuidString.lowercased())"
    }
  }
}

enum LaunchMonitorProviderCommand: Equatable, Sendable {
  case confirmDeviceTrust(deviceID: UUID)
  case rejectDeviceTrust(deviceID: UUID)
  case forgetTrustedDevice
}

enum LaunchMonitorProviderCommandError: Error, Equatable {
  case unsupported
}

enum LaunchMonitorProviderFailure: String, Codable, Equatable, Sendable {
  case providerReported = "provider_reported"
}

enum LaunchMonitorProviderEvent: Equatable, Sendable {
  case capabilitiesChanged(LaunchMonitorCapabilitySnapshot)
  case statusChanged(LaunchMonitorProviderStatus)
  case deviceDiscovered(LaunchMonitorDeviceCandidate)
  case actionRequired(LaunchMonitorProviderActionRequest)
  case measurement(LaunchMonitorMeasurement)
  case batteryLevel(percent: Int)
  case failure(LaunchMonitorProviderFailure)
}

/// A process-local consumer binding identity. This is never a provider session
/// identity and must not be persisted as measurement provenance.
struct LaunchMonitorProviderEventStreamID:
  RawRepresentable, Codable, Equatable, Hashable, Sendable
{
  let rawValue: UUID

  init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

/// Sequence numbers are scoped to `streamID` and begin at one for each provider
/// adapter instance.
struct LaunchMonitorProviderEventEnvelope: Equatable, Sendable {
  let streamID: LaunchMonitorProviderEventStreamID
  let sequence: UInt64
  let event: LaunchMonitorProviderEvent
}

/// Consumer-side stale-event filter. The consumer binds this cursor to the
/// provider's current stream at initialization; envelopes from another stream
/// and envelopes at or behind the cursor are rejected.
struct LaunchMonitorProviderEventCursor: Sendable {
  private(set) var streamID: LaunchMonitorProviderEventStreamID
  private(set) var lastAcceptedSequence: UInt64?

  init(streamID: LaunchMonitorProviderEventStreamID) {
    self.streamID = streamID
  }

  mutating func accept(
    _ envelope: LaunchMonitorProviderEventEnvelope
  ) -> LaunchMonitorProviderEvent? {
    guard envelope.sequence > 0 else { return nil }
    guard envelope.streamID == streamID else { return nil }
    if let lastAcceptedSequence {
      guard envelope.sequence > lastAcceptedSequence else { return nil }
    }
    lastAcceptedSequence = envelope.sequence
    return envelope.event
  }
}

/// Lifecycle and event boundary consumed by a future provider-agnostic store.
///
/// SwiftUI should observe that store, not a concrete provider. The current UI
/// remains on `LaunchMonitorController` until the later migration milestone.
@MainActor
protocol LaunchMonitorProviding: AnyObject {
  var descriptor: LaunchMonitorProviderDescriptor { get }
  var capabilities: LaunchMonitorCapabilitySnapshot { get }
  var eventStreamID: LaunchMonitorProviderEventStreamID { get }
  var eventPublisher: AnyPublisher<LaunchMonitorProviderEventEnvelope, Never> { get }
  var hasPendingStopWork: Bool { get }

  func start()
  func stop()
  func perform(_ command: LaunchMonitorProviderCommand) throws
  func flushPendingStop() async
}

/// Compatibility adapter for the current MLM2PRO controller.
///
/// The app does not switch ownership to this adapter in Milestone 1. It exists
/// so the existing implementation can be exercised behind the provider-neutral
/// contract before UI and persistence are migrated.
@MainActor
final class MLM2PROLaunchMonitorProviderAdapter: LaunchMonitorProviding {
  static let providerDescriptor = LaunchMonitorProviderDescriptor(
    id: .mlm2Pro,
    displayName: "Rapsodo MLM2PRO",
    supportedMetrics: [
      .clubHeadSpeed,
      .ballSpeed,
      .horizontalLaunchAngle,
      .verticalLaunchAngle,
      .spinAxis,
      .totalSpin,
    ],
    supportsBatteryLevel: true,
    supportsAutomaticReconnect: true
  )

  let descriptor = providerDescriptor
  let capabilities = LaunchMonitorCapabilitySnapshot(
    measuredMetrics: Set(providerDescriptor.supportedMetrics),
    providerDerivedMetrics: [],
    appDerivedMetrics: [],
    unavailableReasons: [:]
  )

  var eventPublisher: AnyPublisher<LaunchMonitorProviderEventEnvelope, Never> {
    eventSubject.eraseToAnyPublisher()
  }

  var hasPendingStopWork: Bool {
    controller.hasPendingStopWork
  }

  private let controller: LaunchMonitorController
  let eventStreamID: LaunchMonitorProviderEventStreamID
  private let eventSubject = PassthroughSubject<LaunchMonitorProviderEventEnvelope, Never>()
  private var lastPublishedSequence: UInt64 = 0
  private var cancellables: Set<AnyCancellable> = []

  init(
    controller: LaunchMonitorController,
    eventStreamID: LaunchMonitorProviderEventStreamID =
      LaunchMonitorProviderEventStreamID()
  ) {
    self.controller = controller
    self.eventStreamID = eventStreamID
    controller.events
      .sink { [weak self] event in
        self?.publish(event)
      }
      .store(in: &cancellables)
  }

  func start() {
    controller.start()
  }

  func stop() {
    controller.stop()
  }

  func perform(_ command: LaunchMonitorProviderCommand) throws {
    switch command {
    case .confirmDeviceTrust(let deviceID):
      controller.confirmTrustAndConnect(to: deviceID)
    case .rejectDeviceTrust(let deviceID):
      controller.rejectDeviceTrust(for: deviceID)
    case .forgetTrustedDevice:
      controller.forgetTrustedDevice()
    }
  }

  func flushPendingStop() async {
    await controller.flushPendingStop()
  }

  static func status(from state: LaunchMonitorConnectionState) -> LaunchMonitorProviderStatus {
    switch state {
    case .idle:
      return LaunchMonitorProviderStatus(
        phase: .inactive,
        detail: .idle,
        recovery: .start
      )
    case .bluetoothUnavailable(let availability):
      let detail: LaunchMonitorProviderStatusDetail
      let recovery: LaunchMonitorProviderRecovery
      switch availability {
      case .poweredOff:
        detail = .bluetoothPoweredOff
        recovery = .enableBluetooth
      case .unauthorized:
        detail = .bluetoothUnauthorized
        recovery = .grantBluetoothPermission
      case .unsupported:
        detail = .bluetoothUnsupported
        recovery = .useSupportedHardware
      case .resetting:
        detail = .bluetoothResetting
        recovery = .automatic
      case .unknown:
        detail = .bluetoothStateUnknown
        recovery = .automatic
      }
      return LaunchMonitorProviderStatus(
        phase: .unavailable,
        detail: detail,
        recovery: recovery
      )
    case .scanning:
      return LaunchMonitorProviderStatus(
        phase: .discovering,
        detail: .scanning,
        recovery: .automatic
      )
    case .awaitingDeviceTrust:
      return LaunchMonitorProviderStatus(
        phase: .awaitingUserAction,
        detail: .deviceTrustRequired,
        recovery: .confirmDeviceTrust
      )
    case .connecting:
      return LaunchMonitorProviderStatus(
        phase: .connecting,
        detail: .connecting,
        recovery: .automatic
      )
    case .discoveringServices:
      return LaunchMonitorProviderStatus(
        phase: .connecting,
        detail: .discoveringServices,
        recovery: .automatic
      )
    case .awaitingAuthorization:
      return LaunchMonitorProviderStatus(
        phase: .authorizing,
        detail: .authorizationRequired,
        recovery: .completeAuthorization
      )
    case .arming:
      return LaunchMonitorProviderStatus(
        phase: .preparing,
        detail: .arming,
        recovery: .automatic
      )
    case .ready:
      return LaunchMonitorProviderStatus(
        phase: .ready,
        detail: .ready,
        recovery: .none
      )
    case .stopping:
      return LaunchMonitorProviderStatus(
        phase: .stopping,
        detail: .stopping,
        recovery: .automatic
      )
    case .failed:
      return LaunchMonitorProviderStatus(
        phase: .failed,
        detail: .providerFailed,
        recovery: .restart
      )
    }
  }

  static func measurement(from shot: LaunchMonitorShot) -> LaunchMonitorMeasurement {
    LaunchMonitorMeasurement(
      id: shot.id,
      providerID: .mlm2Pro,
      providerShotID: String(shot.deviceShotID),
      receivedAt: shot.receivedAt,
      metrics: [
        LaunchMonitorMetricValue(
          metricID: .clubHeadSpeed,
          value: shot.clubHeadSpeedMetersPerSecond,
          unit: .metersPerSecond,
          origin: .measured,
          confidence: nil
        ),
        LaunchMonitorMetricValue(
          metricID: .ballSpeed,
          value: shot.ballSpeedMetersPerSecond,
          unit: .metersPerSecond,
          origin: .measured,
          confidence: nil
        ),
        LaunchMonitorMetricValue(
          metricID: .horizontalLaunchAngle,
          value: shot.horizontalLaunchAngleDegrees,
          unit: .degrees,
          origin: .measured,
          confidence: nil
        ),
        LaunchMonitorMetricValue(
          metricID: .verticalLaunchAngle,
          value: shot.verticalLaunchAngleDegrees,
          unit: .degrees,
          origin: .measured,
          confidence: nil
        ),
        LaunchMonitorMetricValue(
          metricID: .spinAxis,
          value: shot.spinAxisDegrees,
          unit: .degrees,
          origin: .measured,
          confidence: nil
        ),
        LaunchMonitorMetricValue(
          metricID: .totalSpin,
          value: Double(shot.totalSpinRPM),
          unit: .revolutionsPerMinute,
          origin: .measured,
          confidence: nil
        ),
      ]
    )
  }

  private func publish(_ event: LaunchMonitorEvent) {
    switch event {
    case .stateChanged(let state):
      emit(.statusChanged(Self.status(from: state)))
    case .discoveredDevice(let id, let name, let rssi):
      emit(
        .deviceDiscovered(
          LaunchMonitorDeviceCandidate(
            id: id,
            displayName: name,
            signalStrength: rssi
          )
        )
      )
    case .deviceTrustRequired(let id, let name):
      emit(
        .actionRequired(
          .confirmDeviceTrust(deviceID: id, deviceDisplayName: name)
        )
      )
    case .authorizationRequired:
      emit(
        .statusChanged(
          LaunchMonitorProviderStatus(
            phase: .authorizing,
            detail: .authorizationRequired,
            recovery: .completeAuthorization
          )
        )
      )
    case .shot(let shot):
      emit(.measurement(Self.measurement(from: shot)))
    case .batteryLevel(let percent):
      emit(.batteryLevel(percent: percent))
    case .error:
      emit(.failure(.providerReported))
    }
  }

  private func emit(_ event: LaunchMonitorProviderEvent) {
    let (sequence, overflow) = lastPublishedSequence.addingReportingOverflow(1)
    guard !overflow else { return }

    lastPublishedSequence = sequence
    eventSubject.send(
      LaunchMonitorProviderEventEnvelope(
        streamID: eventStreamID,
        sequence: sequence,
        event: event
      )
    )
  }
}
