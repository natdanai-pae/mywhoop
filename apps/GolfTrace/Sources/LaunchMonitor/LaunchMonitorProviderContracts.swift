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
  var deduplicationKey: String? {
    guard let providerDeviceID, let providerSessionID else { return nil }
    return
      "\(providerID.rawValue):\(providerDeviceID):\(providerSessionID):\(providerShotID)"
  }
}

struct LaunchMonitorProviderDescriptor: Codable, Equatable, Sendable {
  let id: LaunchMonitorProviderID
  let displayName: String
  let supportedMetrics: [LaunchMonitorMetricID]
  let supportsBatteryLevel: Bool
  let supportsAutomaticReconnect: Bool
}

struct LaunchMonitorCapabilitySnapshot: Codable, Equatable, Sendable {
  let measuredMetrics: Set<LaunchMonitorMetricID>
  let providerDerivedMetrics: Set<LaunchMonitorMetricID>
  let appDerivedMetrics: Set<LaunchMonitorMetricID>
  let unavailableReasons: [LaunchMonitorMetricID: String]

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

struct LaunchMonitorProviderStatus: Codable, Equatable, Sendable {
  let phase: LaunchMonitorProviderConnectionPhase
  let message: String
  let deviceName: String?
  let isRecoverable: Bool
}

struct LaunchMonitorDeviceCandidate: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let signalStrength: Int
}

enum LaunchMonitorProviderActionKind: String, Codable, Equatable, Sendable {
  case confirmDeviceTrust = "confirm_device_trust"
}

/// A sanitized request safe to publish to presentation state.
///
/// It identifies the required action but never contains an API secret, token,
/// authorization credential, or raw Bluetooth response.
struct LaunchMonitorProviderActionRequest: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let kind: LaunchMonitorProviderActionKind
  let title: String
  let message: String
  let deviceID: UUID?
  let challengeID: String?
  let requiresSecureInput: Bool
}

enum LaunchMonitorProviderCommand: Equatable, Sendable {
  case confirmDeviceTrust(deviceID: UUID)
  case rejectDeviceTrust(deviceID: UUID)
  case forgetTrustedDevice
}

enum LaunchMonitorProviderCommandError: Error, Equatable {
  case unsupported
}

enum LaunchMonitorProviderEvent: Equatable, Sendable {
  case capabilitiesChanged(LaunchMonitorCapabilitySnapshot)
  case statusChanged(LaunchMonitorProviderStatus)
  case deviceDiscovered(LaunchMonitorDeviceCandidate)
  case actionRequired(LaunchMonitorProviderActionRequest)
  case measurement(LaunchMonitorMeasurement)
  case batteryLevel(percent: Int)
  case failure(message: String)
}

/// Lifecycle and event boundary consumed by a future provider-agnostic store.
///
/// SwiftUI should observe that store, not a concrete provider. The current UI
/// remains on `LaunchMonitorController` until the later migration milestone.
@MainActor
protocol LaunchMonitorProviding: AnyObject {
  var descriptor: LaunchMonitorProviderDescriptor { get }
  var capabilities: LaunchMonitorCapabilitySnapshot { get }
  var eventPublisher: AnyPublisher<LaunchMonitorProviderEvent, Never> { get }
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

  var eventPublisher: AnyPublisher<LaunchMonitorProviderEvent, Never> {
    eventSubject.eraseToAnyPublisher()
  }

  var hasPendingStopWork: Bool {
    controller.hasPendingStopWork
  }

  private let controller: LaunchMonitorController
  private let eventSubject = PassthroughSubject<LaunchMonitorProviderEvent, Never>()
  private var cancellables: Set<AnyCancellable> = []

  init(controller: LaunchMonitorController) {
    self.controller = controller
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
        message: state.statusText,
        deviceName: nil,
        isRecoverable: true
      )
    case .bluetoothUnavailable:
      return LaunchMonitorProviderStatus(
        phase: .unavailable,
        message: state.statusText,
        deviceName: nil,
        isRecoverable: true
      )
    case .scanning:
      return LaunchMonitorProviderStatus(
        phase: .discovering,
        message: state.statusText,
        deviceName: nil,
        isRecoverable: true
      )
    case .awaitingDeviceTrust(_, let deviceName):
      return LaunchMonitorProviderStatus(
        phase: .awaitingUserAction,
        message: state.statusText,
        deviceName: deviceName,
        isRecoverable: true
      )
    case .connecting(let deviceName), .discoveringServices(let deviceName):
      return LaunchMonitorProviderStatus(
        phase: .connecting,
        message: state.statusText,
        deviceName: deviceName,
        isRecoverable: true
      )
    case .awaitingAuthorization(let deviceName, _):
      return LaunchMonitorProviderStatus(
        phase: .authorizing,
        message: state.statusText,
        deviceName: deviceName,
        isRecoverable: true
      )
    case .arming(let deviceName):
      return LaunchMonitorProviderStatus(
        phase: .preparing,
        message: state.statusText,
        deviceName: deviceName,
        isRecoverable: true
      )
    case .ready(let deviceName):
      return LaunchMonitorProviderStatus(
        phase: .ready,
        message: state.statusText,
        deviceName: deviceName,
        isRecoverable: true
      )
    case .stopping:
      return LaunchMonitorProviderStatus(
        phase: .stopping,
        message: state.statusText,
        deviceName: nil,
        isRecoverable: true
      )
    case .failed(let message):
      return LaunchMonitorProviderStatus(
        phase: .failed,
        message: message,
        deviceName: nil,
        isRecoverable: true
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
      eventSubject.send(.statusChanged(Self.status(from: state)))
    case .discoveredDevice(let id, let name, let rssi):
      eventSubject.send(
        .deviceDiscovered(
          LaunchMonitorDeviceCandidate(id: id, name: name, signalStrength: rssi)
        )
      )
    case .deviceTrustRequired(let id, let name):
      eventSubject.send(
        .actionRequired(
          LaunchMonitorProviderActionRequest(
            id: "mlm2pro.trust.\(id.uuidString.lowercased())",
            kind: .confirmDeviceTrust,
            title: "Confirm launch monitor",
            message: "Confirm that \(name) is your trusted launch monitor.",
            deviceID: id,
            challengeID: nil,
            requiresSecureInput: false
          )
        )
      )
    case .authorizationRequired(let challenge):
      eventSubject.send(
        .statusChanged(
          LaunchMonitorProviderStatus(
            phase: .authorizing,
            message:
              "Provider authorization is required for challenge \(challenge.userID).",
            deviceName: challenge.deviceName,
            isRecoverable: true
          )
        )
      )
    case .shot(let shot):
      eventSubject.send(.measurement(Self.measurement(from: shot)))
    case .batteryLevel(let percent):
      eventSubject.send(.batteryLevel(percent: percent))
    case .error(let message):
      eventSubject.send(.failure(message: message))
    }
  }
}
