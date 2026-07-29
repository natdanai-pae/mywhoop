import Combine
@preconcurrency import CoreBluetooth
import Foundation

enum MLM2PROGATT {
  static let service = CBUUID(string: "DAF9B2A4-E4DB-4BE4-816D-298A050F25CD")
  static let authorizationRequest = CBUUID(string: "B1E9CE5B-48C8-4A28-89DD-12FFD779F5E1")
  static let command = CBUUID(string: "1EA0FA51-1649-4603-9C5F-59C940323471")
  static let configure = CBUUID(string: "DF5990CF-47FB-4115-8FDD-40061D40AF84")
  static let events = CBUUID(string: "02E525FD-7960-4EF0-BFB7-DE0F514518FF")
  static let heartbeat = CBUUID(string: "EF6A028E-F78B-47A4-B56C-DDA6DAE85CBF")
  static let measurement = CBUUID(string: "76830BCE-B9A7-4F69-AEAA-FD5B9F6B0965")
  static let writeResponse = CBUUID(string: "CFBBCB0D-7121-4BC2-BF54-8284166D61F0")

  static let allCharacteristics = [
    authorizationRequest,
    command,
    configure,
    events,
    heartbeat,
    measurement,
    writeResponse,
  ]

  /// Keep CCCD writes deterministic and issue the next one only after
  /// CoreBluetooth has acknowledged the previous subscription. The device
  /// protocol begins authorization after this phase, so a `Set` (with an
  /// unspecified iteration order) is not suitable here.
  static let notificationCharacteristics: [CBUUID] = [
    events,
    heartbeat,
    measurement,
    writeResponse,
  ]
}

/// Events written to the local, redacted hardware diagnostic trace. These are
/// deliberately fixed labels: callers cannot put a device name, token, secret,
/// error description, or BLE payload into the file.
enum MLM2PROConnectionDiagnosticEvent: String, Sendable {
  case start
  case bluetoothStateChanged = "bluetooth-state"
  case scanStarted = "scan-started"
  case connectionRequested = "connection-requested"
  case connected
  case serviceDiscoveryRequested = "service-discovery-requested"
  case serviceDiscovered = "service-discovered"
  case characteristicDiscoveryRequested = "characteristic-discovery-requested"
  case characteristicsDiscovered = "characteristics-discovered"
  case notificationRequested = "notification-requested"
  case notificationEnabled = "notification-enabled"
  case notificationCallbackFailed = "notification-callback-failed"
  case authorizationRequested = "authorization-requested"
  case writeResponseReceived = "write-response-received"
  case connectionFailed = "connection-failed"
  case serviceDiscoveryFailed = "service-discovery-failed"
  case characteristicDiscoveryFailed = "characteristic-discovery-failed"
  case valueCallbackFailed = "value-callback-failed"
  case writeCallbackFailed = "write-callback-failed"
  case failed
  case disconnected
  case stopped
}

/// Keeps a small, privacy-safe record of the Bluetooth state machine so a
/// hardware retest can be diagnosed without collecting credentials or traffic.
/// The file is overwritten atomically and retained at a fixed maximum size.
struct MLM2PROConnectionDiagnostics {
  static let maximumFileSize = 32 * 1024

  private let fileManager: FileManager
  private let fileURL: URL
  private let now: () -> Date

  init(
    fileManager: FileManager = .default,
    fileURL: URL? = nil,
    now: @escaping () -> Date = Date.init
  ) {
    self.fileManager = fileManager
    self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    self.now = now
  }

  @discardableResult
  func record(
    _ event: MLM2PROConnectionDiagnosticEvent,
    state: LaunchMonitorConnectionState,
    characteristicID: CBUUID? = nil,
    error: (any Error)? = nil,
    responseLength: Int? = nil,
    responseType: Int? = nil,
    responseStatus: Int? = nil
  ) -> String? {
    let line = Self.redactedLine(
      event: event,
      state: state,
      characteristicID: characteristicID,
      error: error,
      responseLength: responseLength,
      responseType: responseType,
      responseStatus: responseStatus,
      date: now()
    )

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
      let existing = (try? Data(contentsOf: fileURL)) ?? Data()
      let retained = Self.cappedData(existing: existing, appending: Data(line.utf8))
      try retained.write(to: fileURL, options: .atomic)
      return line
    } catch {
      // Diagnostics must never alter the connection state machine when storage
      // is unavailable (for example, a read-only home directory).
      return nil
    }
  }

  static func redactedLine(
    event: MLM2PROConnectionDiagnosticEvent,
    state: LaunchMonitorConnectionState,
    characteristicID: CBUUID? = nil,
    error: (any Error)? = nil,
    responseLength: Int? = nil,
    responseType: Int? = nil,
    responseStatus: Int? = nil,
    date: Date
  ) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var fields = [
      "timestamp=\(formatter.string(from: date))",
      "event=\(event.rawValue)",
      "state=\(redactedStateName(state))",
    ]
    if let characteristicID {
      fields.append("uuid=\(characteristicID.uuidString.suffix(8))")
    }
    if let error {
      fields.append("result=\(redactedErrorResult(error))")
    }
    if let responseLength {
      fields.append("response_length=\(max(0, responseLength))")
    }
    if let responseType {
      fields.append("response_type=\(max(0, min(255, responseType)))")
    }
    if let responseStatus {
      fields.append("response_status=\(max(0, min(255, responseStatus)))")
    }
    return fields.joined(separator: " ") + "\n"
  }

  private static func defaultFileURL(fileManager: FileManager) -> URL {
    let applicationSupport =
      fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? fileManager.temporaryDirectory
    return
      applicationSupport
      .appendingPathComponent("GolfTrace", isDirectory: true)
      .appendingPathComponent("Diagnostics", isDirectory: true)
      .appendingPathComponent("mlm2pro-connection.log", isDirectory: false)
  }

  private static func cappedData(existing: Data, appending line: Data) -> Data {
    let combined = existing + line
    guard combined.count > maximumFileSize else { return combined }

    let retained = Data(combined.suffix(maximumFileSize))
    guard let firstLineBreak = retained.firstIndex(of: 0x0A) else { return retained }
    return Data(retained[retained.index(after: firstLineBreak)...])
  }

  private static func redactedStateName(_ state: LaunchMonitorConnectionState) -> String {
    switch state {
    case .idle: "idle"
    case .bluetoothUnavailable: "bluetooth-unavailable"
    case .scanning: "scanning"
    case .awaitingDeviceTrust: "awaiting-device-trust"
    case .connecting: "connecting"
    case .discoveringServices: "discovering-services"
    case .awaitingAuthorization: "awaiting-authorization"
    case .arming: "arming"
    case .ready: "ready"
    case .stopping: "stopping"
    case .failed: "failed"
    }
  }

  private static func redactedErrorResult(_ error: any Error) -> String {
    let nsError = error as NSError
    if nsError.domain == CBATTErrorDomain {
      return "att:\(nsError.code)"
    }
    return "cb:\(nsError.code)"
  }
}

enum MLM2PROConnectionFailureRecovery: Equatable, Sendable {
  /// The transport may be transient, so the controller can try again.
  case reconnectAutomatically
  /// A deterministic GATT incompatibility must not repeatedly disturb the
  /// physical device. A later explicit `start()` is required to retry.
  case requiresExplicitRestart
}

/// A device-declared rejection of the initial authorization or configuration
/// is deterministic for the current session. Retrying it automatically makes
/// the physical MLM2PRO reconnect and flash without changing that outcome.
enum MLM2PROWriteResponseFailurePolicy {
  static func recovery(responseType: UInt8, status: UInt8) -> MLM2PROConnectionFailureRecovery? {
    guard status != 0 else { return nil }
    switch responseType {
    case 0, 2:
      return .requiresExplicitRestart
    default:
      return nil
    }
  }
}

enum MLM2PROGATTSubscriptionFailureReason: Equatable, Sendable {
  case requiredCharacteristicMissing
  case notificationsUnavailable
  case attResult(Int)
  case coreBluetoothResult(Int)
  case notificationDisabled
  case unexpectedCallback

  fileprivate var diagnosticText: String {
    switch self {
    case .requiredCharacteristicMissing:
      "ไม่พบช่องข้อมูลที่จำเป็น"
    case .notificationsUnavailable:
      "ช่องข้อมูลไม่รองรับ notification หรือ indication"
    case .attResult(let result):
      "ATT result \(result)"
    case .coreBluetoothResult(let result):
      "CoreBluetooth result \(result)"
    case .notificationDisabled:
      "อุปกรณ์ไม่ได้ยืนยันว่า notification เปิดอยู่"
    case .unexpectedCallback:
      "ลำดับการยืนยัน notification ไม่ตรงกับที่ร้องขอ"
    }
  }
}

/// A subscription failure is preserved as user-visible diagnostic state and
/// intentionally requires an explicit retry. Retrying a deterministic ATT
/// rejection in a tight loop makes the MLM2PRO reconnect and flash repeatedly.
struct MLM2PROGATTSubscriptionFailure: Equatable, Sendable {
  let characteristicID: String
  let reason: MLM2PROGATTSubscriptionFailureReason

  var recovery: MLM2PROConnectionFailureRecovery { .requiresExplicitRestart }

  var diagnosticMessage: String {
    "MLM2PRO เปิด notification ช่อง \(characteristicID) ไม่สำเร็จ: \(reason.diagnosticText). "
      + "หยุดการเชื่อมต่ออัตโนมัติเพื่อป้องกันการวนซ้ำ กรุณาเริ่ม GolfTrace ใหม่ก่อนลองอีกครั้ง"
  }
}

enum MLM2PROBluetoothClientError: Error, Equatable, LocalizedError {
  case sessionUnavailable
  case untrustedPeripheral
  case characteristicNotWritable
  case payloadTooLong

  var errorDescription: String? {
    switch self {
    case .sessionUnavailable:
      "MLM2PRO ขาดการเชื่อมต่อหรือยังไม่พร้อมรับคำสั่ง"
    case .untrustedPeripheral:
      "ยังไม่ได้ยืนยันว่า MLM2PRO เครื่องนี้เป็นอุปกรณ์ที่ไว้ใจ"
    case .characteristicNotWritable:
      "ช่อง Bluetooth ของ MLM2PRO เขียนข้อมูลไม่ได้"
    case .payloadTooLong:
      "ข้อมูล Bluetooth ยาวเกินขนาดที่อุปกรณ์รับได้"
    }
  }
}

enum MLM2PROPeripheralTrustDecision: Equatable, Sendable {
  case connect
  case requestConfirmation
  case ignore
}

struct MLM2PROTrustedPeripheralStore {
  private static let trustedPeripheralKey = "GolfTrace.MLM2PRO.trustedPeripheralIdentifier"

  private let userDefaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  var trustedPeripheralID: UUID? {
    guard let value = userDefaults.string(forKey: Self.trustedPeripheralKey) else { return nil }
    return UUID(uuidString: value)
  }

  func decision(for peripheralID: UUID) -> MLM2PROPeripheralTrustDecision {
    guard let trustedPeripheralID else { return .requestConfirmation }
    return trustedPeripheralID == peripheralID ? .connect : .ignore
  }

  func trust(_ peripheralID: UUID) {
    userDefaults.set(peripheralID.uuidString, forKey: Self.trustedPeripheralKey)
  }

  func forget() {
    userDefaults.removeObject(forKey: Self.trustedPeripheralKey)
  }
}

struct MLM2PROHeartbeatWatchdog: Equatable, Sendable {
  let timeout: TimeInterval
  private(set) var lastReceivedAt: Date

  init(timeout: TimeInterval, startingAt: Date) {
    precondition(timeout > 0)
    self.timeout = timeout
    lastReceivedAt = startingAt
  }

  mutating func recordHeartbeat(at date: Date) {
    lastReceivedAt = date
  }

  func hasExpired(at date: Date) -> Bool {
    date.timeIntervalSince(lastReceivedAt) >= timeout
  }
}

@MainActor
final class LaunchMonitorController: NSObject, ObservableObject {
  private static let heartbeatInterval: Duration = .seconds(2)
  private static let heartbeatStartupGrace: TimeInterval = 20
  private static let heartbeatTimeout: TimeInterval = 120
  private static let readyTimeout: Duration = .seconds(15)
  private static let gracefulStopCommandDelay: Duration = .milliseconds(250)
  private static let disconnectCallbackTimeout: Duration = .seconds(2)

  @Published private(set) var state: LaunchMonitorConnectionState = .idle
  @Published private(set) var latestShot: LaunchMonitorShot?
  @Published private(set) var batteryLevel: Int?
  @Published private(set) var lastError: String?

  let events = PassthroughSubject<LaunchMonitorEvent, Never>()

  var statusText: String { state.statusText }
  var hasPendingStopWork: Bool { gracefulStopTask != nil }
  var trustedPeripheralID: UUID? { trustedPeripheralStore.trustedPeripheralID }

  private let parser: any LaunchMonitorMeasurementParsing
  private let trustedPeripheralStore: MLM2PROTrustedPeripheralStore
  private let connectionDiagnostics: MLM2PROConnectionDiagnostics
  private var tokenProvider: (any MLM2PROTokenProvider)?
  private var centralManager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var deviceName = "MLM2PRO"
  private var characteristics: [CBUUID: CBCharacteristic] = [:]
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var discoveredPeripheralNames: [UUID: String] = [:]
  private var pendingTrustCandidateID: UUID?
  private var rejectedPeripheralIDs: Set<UUID> = []
  private var subscribedCharacteristicIDs: Set<CBUUID> = []
  private var notificationSubscriptionIndex = 0
  private var codec: MLM2PROSessionCodec?
  private var pendingChallenge: MLM2PROAuthorizationChallenge?
  private var shouldRun = false
  private var automaticReconnectSuspended = false
  private var nextDeviceShotID: UInt64 = 0
  private var lastMeasurement: (data: Data, receivedAt: Date)?
  private var acceptsMeasurements = false
  private var discardMeasurementsUntilReady = false
  private var hasSentArmCommand = false
  private var heartbeatWatchdog: MLM2PROHeartbeatWatchdog?
  private var heartbeatTask: Task<Void, Never>?
  private var readyTimeoutTask: Task<Void, Never>?
  private var tokenTask: Task<Void, Never>?
  private var repeatedConfigurationTask: Task<Void, Never>?
  private var gracefulStopTask: Task<Void, Never>?
  private var reconnectFallbackTask: Task<Void, Never>?

  init(
    parser: any LaunchMonitorMeasurementParsing = MLM2PROMeasurementParser(),
    tokenProvider: (any MLM2PROTokenProvider)? = nil,
    trustedPeripheralStore: MLM2PROTrustedPeripheralStore = MLM2PROTrustedPeripheralStore(),
    connectionDiagnostics: MLM2PROConnectionDiagnostics = MLM2PROConnectionDiagnostics()
  ) {
    self.parser = parser
    self.tokenProvider = tokenProvider
    self.trustedPeripheralStore = trustedPeripheralStore
    self.connectionDiagnostics = connectionDiagnostics
    super.init()
  }

  func setTokenProvider(_ tokenProvider: (any MLM2PROTokenProvider)?) {
    self.tokenProvider = tokenProvider
    guard let tokenProvider, let pendingChallenge else { return }
    requestToken(from: tokenProvider, for: pendingChallenge)
  }

  func start() {
    if !shouldRun {
      rejectedPeripheralIDs.removeAll()
      automaticReconnectSuspended = false
    }
    shouldRun = true
    recordConnectionDiagnostic(.start)
    if let centralManager {
      respondToBluetoothState(centralManager.state)
    } else {
      centralManager = CBCentralManager(delegate: self, queue: .main)
    }
  }

  func stop() {
    shouldRun = false
    if case .stopping = state { return }
    cancelSessionTasks()
    reconnectFallbackTask?.cancel()
    reconnectFallbackTask = nil
    centralManager?.stopScan()
    setState(.stopping)
    recordConnectionDiagnostic(.stopped)
    if let peripheral {
      beginGracefulStop(for: peripheral)
    } else {
      clearConnection()
      setState(.idle)
    }
  }

  func flushPendingStop() async {
    let pendingTask = gracefulStopTask
    await pendingTask?.value
  }

  func confirmTrustAndConnect(to peripheralID: UUID) {
    guard shouldRun, pendingTrustCandidateID == peripheralID,
      let candidate = discoveredPeripherals[peripheralID]
    else {
      publishError("ไม่พบ MLM2PRO เครื่องที่รอการยืนยัน กรุณาค้นหาใหม่")
      return
    }

    trustedPeripheralStore.trust(peripheralID)
    pendingTrustCandidateID = nil
    connect(
      candidate,
      name: discoveredPeripheralNames[peripheralID] ?? candidate.name ?? "MLM2PRO"
    )
  }

  func rejectDeviceTrust(for peripheralID: UUID) {
    guard pendingTrustCandidateID == peripheralID else { return }
    rejectedPeripheralIDs.insert(peripheralID)
    discoveredPeripherals[peripheralID] = nil
    discoveredPeripheralNames[peripheralID] = nil
    pendingTrustCandidateID = nil
    if shouldRun {
      scan()
    }
  }

  func forgetTrustedDevice() {
    let hadConnection = peripheral != nil
    if hadConnection {
      stop()
    }
    trustedPeripheralStore.forget()
    pendingTrustCandidateID = nil
    rejectedPeripheralIDs.removeAll()
    if !hadConnection, shouldRun {
      scan()
    }
  }

  /// Continues a challenge with a credential obtained by the UI or another
  /// approved source. This keeps tokens and API secrets out of Bluetooth code.
  func submitAuthorizationCredential(
    _ credential: MLM2PROAuthorizationCredential,
    forUserID userID: UInt32
  ) {
    guard pendingChallenge?.userID == userID else {
      publishError(MLM2PROAuthorizationError.challengeChanged.localizedDescription)
      return
    }
    completeAuthorization(with: credential)
  }

  private func respondToBluetoothState(_ bluetoothState: CBManagerState) {
    switch bluetoothState {
    case .poweredOn:
      guard shouldRun, peripheral == nil else { return }
      scan()
    case .poweredOff:
      setState(.bluetoothUnavailable(.poweredOff))
    case .unauthorized:
      setState(.bluetoothUnavailable(.unauthorized))
    case .unsupported:
      setState(.bluetoothUnavailable(.unsupported))
    case .resetting:
      setState(.bluetoothUnavailable(.resetting))
    case .unknown:
      setState(.bluetoothUnavailable(.unknown))
    @unknown default:
      setState(.bluetoothUnavailable(.unknown))
    }
  }

  private func scan() {
    guard shouldRun, !automaticReconnectSuspended,
      let centralManager, centralManager.state == .poweredOn
    else { return }
    centralManager.stopScan()
    lastError = nil
    setState(.scanning)
    recordConnectionDiagnostic(.scanStarted)
    centralManager.scanForPeripherals(
      withServices: [MLM2PROGATT.service],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
  }

  private func beginServiceDiscovery(for connectedPeripheral: CBPeripheral) {
    guard trustedPeripheralStore.decision(for: connectedPeripheral.identifier) == .connect else {
      fail(MLM2PROBluetoothClientError.untrustedPeripheral.localizedDescription)
      return
    }
    peripheral = connectedPeripheral
    connectedPeripheral.delegate = self
    characteristics.removeAll()
    discoveredPeripherals.removeAll()
    discoveredPeripheralNames.removeAll()
    pendingTrustCandidateID = nil
    subscribedCharacteristicIDs.removeAll()
    notificationSubscriptionIndex = 0
    codec = nil
    pendingChallenge = nil
    acceptsMeasurements = false
    discardMeasurementsUntilReady = false
    hasSentArmCommand = false
    setState(.discoveringServices(deviceName: deviceName))
    recordConnectionDiagnostic(.serviceDiscoveryRequested)
    connectedPeripheral.discoverServices([MLM2PROGATT.service])
  }

  private func subscribe(to discoveredCharacteristics: [CBCharacteristic]) {
    for characteristic in discoveredCharacteristics {
      characteristics[characteristic.uuid] = characteristic
    }

    let missing = MLM2PROGATT.allCharacteristics.filter { characteristics[$0] == nil }
    guard missing.isEmpty else {
      let missingID = missing.map(\.uuidString).sorted().joined(separator: ", ")
      failSubscription(
        MLM2PROGATTSubscriptionFailure(
          characteristicID: missingID,
          reason: .requiredCharacteristicMissing
        )
      )
      return
    }

    for uuid in MLM2PROGATT.notificationCharacteristics {
      guard let characteristic = characteristics[uuid],
        characteristic.properties.contains(.notify)
          || characteristic.properties.contains(.indicate)
      else {
        failSubscription(
          MLM2PROGATTSubscriptionFailure(
            characteristicID: uuid.uuidString,
            reason: .notificationsUnavailable
          )
        )
        return
      }
    }

    subscribedCharacteristicIDs.removeAll()
    notificationSubscriptionIndex = 0
    subscribeToNextNotification()
  }

  private func subscribeToNextNotification() {
    guard shouldRun, !automaticReconnectSuspended else { return }
    guard notificationSubscriptionIndex < MLM2PROGATT.notificationCharacteristics.count else {
      beginHandshake()
      return
    }

    let uuid = MLM2PROGATT.notificationCharacteristics[notificationSubscriptionIndex]
    guard let characteristic = characteristics[uuid] else {
      failSubscription(
        MLM2PROGATTSubscriptionFailure(
          characteristicID: uuid.uuidString,
          reason: .requiredCharacteristicMissing
        )
      )
      return
    }
    recordConnectionDiagnostic(.notificationRequested, characteristicID: uuid)
    peripheral?.setNotifyValue(true, for: characteristic)
  }

  private func beginHandshake() {
    guard codec == nil,
      let authorizationCharacteristic = characteristics[
        MLM2PROGATT.authorizationRequest
      ]
    else { return }

    do {
      let codec = try MLM2PROSessionCodec()
      self.codec = codec
      try write(codec.authorizationRequest(), to: authorizationCharacteristic)
      setState(.awaitingAuthorization(deviceName: deviceName, userID: nil))
      recordConnectionDiagnostic(.authorizationRequested)
      startHeartbeat()
    } catch {
      fail(error.localizedDescription)
    }
  }

  private func handleWriteResponse(_ data: Data) {
    guard shouldRun else { return }
    guard data.count >= 2 else {
      recordConnectionDiagnostic(
        .writeResponseReceived,
        characteristicID: MLM2PROGATT.writeResponse,
        responseLength: data.count
      )
      publishError(MLM2PROAuthorizationError.invalidDeviceResponse.localizedDescription)
      return
    }

    let responseType = data[data.startIndex]
    let status = data[data.startIndex + 1]
    recordConnectionDiagnostic(
      .writeResponseReceived,
      characteristicID: MLM2PROGATT.writeResponse,
      responseLength: data.count,
      responseType: Int(responseType),
      responseStatus: Int(status)
    )

    switch responseType {
    case 0:
      guard pendingChallenge != nil else { return }
      guard status == 0 else {
        fail(
          "MLM2PRO ปฏิเสธค่าตั้งต้นสำหรับเซสชันนี้",
          recovery: MLM2PROWriteResponseFailurePolicy.recovery(
            responseType: responseType,
            status: status
          ) ?? .reconnectAutomatically
        )
        return
      }
      pendingChallenge = nil
      repeatedConfigurationTask?.cancel()
      repeatedConfigurationTask = nil
      armDevice()
    case 2:
      guard status == 0 else {
        // The device did not issue a user ID, so a Rapsodo credential provider
        // has not been invoked and cannot be retried in place. Preserve the
        // failure instead of repeatedly reconnecting and making the physical
        // device flash.
        fail(
          MLM2PROAuthorizationError.initialAuthorizationRequestRejected(status: status)
            .localizedDescription,
          recovery: MLM2PROWriteResponseFailurePolicy.recovery(
            responseType: responseType,
            status: status
          ) ?? .reconnectAutomatically
        )
        return
      }
      guard data.count >= 6 else {
        publishError(MLM2PROAuthorizationError.invalidDeviceResponse.localizedDescription)
        return
      }
      let userID = readLittleEndianUInt32(data, offset: 2)
      let challenge = MLM2PROAuthorizationChallenge(userID: userID, deviceName: deviceName)
      pendingChallenge = challenge
      setState(.awaitingAuthorization(deviceName: deviceName, userID: userID))
      events.send(.authorizationRequired(challenge))
      if let tokenProvider {
        requestToken(from: tokenProvider, for: challenge)
      }
    default:
      break
    }
  }

  private func requestToken(
    from provider: any MLM2PROTokenProvider,
    for challenge: MLM2PROAuthorizationChallenge
  ) {
    guard isCurrentPeripheralTrusted else {
      fail(MLM2PROBluetoothClientError.untrustedPeripheral.localizedDescription)
      return
    }
    tokenTask?.cancel()
    tokenTask = Task { @MainActor [weak self, provider] in
      guard self?.isCurrentPeripheralTrusted == true else {
        self?.fail(MLM2PROBluetoothClientError.untrustedPeripheral.localizedDescription)
        return
      }
      do {
        let credential = try await provider.token(for: challenge.userID)
        try Task.checkCancellation()
        guard self?.isCurrentPeripheralTrusted == true else {
          self?.fail(MLM2PROBluetoothClientError.untrustedPeripheral.localizedDescription)
          return
        }
        guard self?.pendingChallenge == challenge else {
          throw MLM2PROAuthorizationError.challengeChanged
        }
        self?.completeAuthorization(with: credential)
      } catch is CancellationError {
        return
      } catch {
        self?.publishError(error.localizedDescription)
      }
    }
  }

  private func completeAuthorization(with credential: MLM2PROAuthorizationCredential) {
    guard isCurrentPeripheralTrusted else {
      fail(MLM2PROBluetoothClientError.untrustedPeripheral.localizedDescription)
      return
    }
    if let expiresAt = credential.expiresAt, expiresAt <= Date() {
      publishError(MLM2PROAuthorizationError.expired.localizedDescription)
      return
    }
    guard pendingChallenge != nil, let codec,
      let configurationCharacteristic = characteristics[MLM2PROGATT.configure]
    else {
      publishError(MLM2PROAuthorizationError.challengeChanged.localizedDescription)
      return
    }

    do {
      let encrypted = try codec.encrypt(MLM2PROSessionMessages.configuration(for: credential))
      try write(encrypted, to: configurationCharacteristic)

      // The device protocol expects the initial configuration twice. Keep the
      // credential itself out of the delayed task; only the encrypted packet
      // remains briefly in memory.
      repeatedConfigurationTask?.cancel()
      repeatedConfigurationTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(200))
          guard let self, self.pendingChallenge != nil,
            let characteristic = self.characteristics[MLM2PROGATT.configure]
          else { return }
          try self.write(encrypted, to: characteristic)
        } catch is CancellationError {
          return
        } catch {
          self?.fail("ส่งค่าตั้งต้นไป MLM2PRO ไม่สำเร็จ: \(error.localizedDescription)")
        }
      }
    } catch {
      fail("ส่งค่าตั้งต้นไป MLM2PRO ไม่สำเร็จ: \(error.localizedDescription)")
    }
  }

  private func handleMeasurement(_ encryptedData: Data) {
    guard shouldRun, acceptsMeasurements, !discardMeasurementsUntilReady, let codec else { return }
    do {
      let decrypted = try codec.decrypt(encryptedData)
      let receivedAt = Date()

      // Some GATT stacks repeat the same notification immediately. Suppress
      // only an identical packet inside a very small window so two legitimate,
      // similar shots are not merged.
      if let lastMeasurement, lastMeasurement.data == decrypted,
        receivedAt.timeIntervalSince(lastMeasurement.receivedAt) < 0.25
      {
        return
      }
      lastMeasurement = (decrypted, receivedAt)
      let deviceShotID = nextDeviceShotID &+ 1
      let shot = try parser.parseDecryptedMeasurement(
        decrypted,
        receivedAt: receivedAt,
        deviceShotID: deviceShotID
      )
      nextDeviceShotID = deviceShotID
      latestShot = shot
      events.send(.shot(shot))
    } catch MLM2PROMeasurementParserError.allZeroMeasurement {
      acceptsMeasurements = false
      discardMeasurementsUntilReady = true
      setState(.arming(deviceName: deviceName))
      startReadyTimeout()
      publishError(MLM2PROMeasurementParserError.allZeroMeasurement.localizedDescription)
    } catch {
      publishError(error.localizedDescription)
    }
  }

  private func handleDeviceEvent(_ encryptedData: Data) {
    guard let codec else { return }
    do {
      let decrypted = try codec.decrypt(encryptedData)
      let event = try MLM2PROSessionMessages.parseDeviceEvent(decrypted)
      switch event {
      case .shotHappened, .processingShot:
        guard shouldRun, hasSentArmCommand else { return }
        setState(.arming(deviceName: deviceName))
        startReadyTimeout()
      case .ready:
        guard shouldRun, hasSentArmCommand, case .arming = state else { return }
        acceptsMeasurements = true
        discardMeasurementsUntilReady = false
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        setState(.ready(deviceName: deviceName))
      case .batteryLevel(let rawPercent):
        let percent = min(100, max(0, Int(rawPercent)))
        batteryLevel = percent
        events.send(.batteryLevel(percent: percent))
      case .misread:
        guard shouldRun, hasSentArmCommand else { return }
        acceptsMeasurements = false
        discardMeasurementsUntilReady = true
        setState(.arming(deviceName: deviceName))
        startReadyTimeout()
        publishError("MLM2PRO อ่านช็อตล่าสุดไม่สำเร็จ จึงไม่บันทึกค่าการตี")
      case .disarmed:
        guard shouldRun, hasSentArmCommand else { return }
        acceptsMeasurements = false
        discardMeasurementsUntilReady = true
        hasSentArmCommand = false
        armDevice()
      case .unknown:
        break
      }
    } catch {
      publishError(error.localizedDescription)
    }
  }

  private func armDevice() {
    guard shouldRun else { return }
    acceptsMeasurements = false
    discardMeasurementsUntilReady = false
    hasSentArmCommand = false
    setState(.arming(deviceName: deviceName))
    do {
      try sendEncryptedCommand(MLM2PROSessionMessages.arm)
      hasSentArmCommand = true
      startReadyTimeout()
    } catch {
      fail("เตรียม MLM2PRO ให้พร้อมรับค่าการตีไม่สำเร็จ: \(error.localizedDescription)")
    }
  }

  private func startReadyTimeout() {
    readyTimeoutTask?.cancel()
    readyTimeoutTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.readyTimeout)
      } catch is CancellationError {
        return
      } catch {
        return
      }
      guard let self, self.shouldRun, case .arming = self.state else { return }
      self.fail("MLM2PRO ไม่ส่งสถานะพร้อมรับค่าการตีภายในเวลาที่กำหนด")
    }
  }

  private func sendEncryptedCommand(_ command: Data) throws {
    guard let codec, let commandCharacteristic = characteristics[MLM2PROGATT.command] else {
      throw MLM2PROBluetoothClientError.sessionUnavailable
    }
    try write(codec.encrypt(command), to: commandCharacteristic)
  }

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatWatchdog = MLM2PROHeartbeatWatchdog(
      timeout: Self.heartbeatTimeout,
      startingAt: Date().addingTimeInterval(Self.heartbeatStartupGrace)
    )
    heartbeatTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.heartbeatInterval)
          guard let self, self.shouldRun,
            let heartbeatCharacteristic = self.characteristics[MLM2PROGATT.heartbeat]
          else { return }
          if self.heartbeatWatchdog?.hasExpired(at: Date()) == true {
            self.fail("ไม่ได้รับ heartbeat จาก MLM2PRO กำลังเชื่อมต่อใหม่")
            return
          }
          try self.write(MLM2PROSessionMessages.heartbeat, to: heartbeatCharacteristic)
        } catch is CancellationError {
          return
        } catch {
          self?.fail("ส่ง heartbeat ไป MLM2PRO ไม่สำเร็จ: \(error.localizedDescription)")
        }
      }
    }
  }

  private func recordHeartbeat() {
    heartbeatWatchdog?.recordHeartbeat(at: Date())
  }

  private var isCurrentPeripheralTrusted: Bool {
    guard let peripheral else { return false }
    return trustedPeripheralStore.decision(for: peripheral.identifier) == .connect
  }

  private func connect(_ discoveredPeripheral: CBPeripheral, name: String) {
    guard shouldRun,
      trustedPeripheralStore.decision(for: discoveredPeripheral.identifier) == .connect,
      let centralManager,
      centralManager.state == .poweredOn
    else {
      publishError(MLM2PROBluetoothClientError.untrustedPeripheral.localizedDescription)
      return
    }
    guard peripheral == nil else { return }

    peripheral = discoveredPeripheral
    deviceName = name
    centralManager.stopScan()
    setState(.connecting(deviceName: name))
    recordConnectionDiagnostic(.connectionRequested)
    centralManager.connect(discoveredPeripheral)
  }

  private func beginGracefulStop(for connectedPeripheral: CBPeripheral) {
    let peripheralID = connectedPeripheral.identifier
    gracefulStopTask?.cancel()
    gracefulStopTask = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        try self.sendEncryptedCommand(MLM2PROSessionMessages.disarm)
      } catch {
        self.publishError("ส่งคำสั่งหยุดรับค่าการตีไม่สำเร็จ: \(error.localizedDescription)")
      }

      do {
        try await Task.sleep(for: Self.gracefulStopCommandDelay)
      } catch is CancellationError {
        return
      } catch {
        return
      }
      guard self.peripheral?.identifier == peripheralID else { return }

      do {
        try self.sendEncryptedCommand(MLM2PROSessionMessages.disconnect)
      } catch {
        self.publishError("ส่งคำสั่งจบเซสชัน MLM2PRO ไม่สำเร็จ: \(error.localizedDescription)")
      }

      do {
        try await Task.sleep(for: Self.gracefulStopCommandDelay)
      } catch is CancellationError {
        return
      } catch {
        return
      }
      guard let currentPeripheral = self.peripheral,
        currentPeripheral.identifier == peripheralID
      else { return }
      self.centralManager?.cancelPeripheralConnection(currentPeripheral)

      do {
        try await Task.sleep(for: Self.disconnectCallbackTimeout)
      } catch is CancellationError {
        return
      } catch {
        return
      }
      guard self.peripheral?.identifier == peripheralID else { return }
      self.gracefulStopTask = nil
      self.retireCentralManagerAfterDisconnectTimeout()
    }
  }

  private func write(_ data: Data, to characteristic: CBCharacteristic) throws {
    guard let peripheral else {
      throw MLM2PROBluetoothClientError.sessionUnavailable
    }

    let writeType: CBCharacteristicWriteType
    if characteristic.properties.contains(.write) {
      writeType = .withResponse
    } else if characteristic.properties.contains(.writeWithoutResponse) {
      writeType = .withoutResponse
    } else {
      throw MLM2PROBluetoothClientError.characteristicNotWritable
    }

    guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else {
      throw MLM2PROBluetoothClientError.payloadTooLong
    }
    peripheral.writeValue(data, for: characteristic, type: writeType)
  }

  private func readLittleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { partial, byteOffset in
      partial | (UInt32(data[data.startIndex + offset + byteOffset]) << UInt32(byteOffset * 8))
    }
  }

  private func setState(_ newState: LaunchMonitorConnectionState) {
    guard state != newState else { return }
    state = newState
    events.send(.stateChanged(newState))
  }

  private func publishError(_ message: String) {
    lastError = message
    events.send(.error(message: message))
  }

  private func recordConnectionDiagnostic(
    _ event: MLM2PROConnectionDiagnosticEvent,
    characteristicID: CBUUID? = nil,
    error: (any Error)? = nil,
    responseLength: Int? = nil,
    responseType: Int? = nil,
    responseStatus: Int? = nil
  ) {
    connectionDiagnostics.record(
      event,
      state: state,
      characteristicID: characteristicID,
      error: error,
      responseLength: responseLength,
      responseType: responseType,
      responseStatus: responseStatus
    )
  }

  private func failSubscription(_ failure: MLM2PROGATTSubscriptionFailure) {
    fail(failure.diagnosticMessage, recovery: failure.recovery)
  }

  private func fail(
    _ message: String,
    recovery: MLM2PROConnectionFailureRecovery = .reconnectAutomatically
  ) {
    recordConnectionDiagnostic(.failed)
    publishError(message)
    setState(.failed(message: message))
    cancelTasks()

    if recovery == .requiresExplicitRestart {
      // A concrete ATT/CCCD failure will recur until the firmware/session
      // compatibility changes. Release the peripheral once, but retain the
      // failed state and diagnostic instead of immediately scanning again.
      automaticReconnectSuspended = true
      shouldRun = false
      centralManager?.stopScan()
    }

    if let peripheral, let centralManager {
      centralManager.cancelPeripheralConnection(peripheral)
      scheduleReconnectFallback(for: peripheral.identifier)
    } else if shouldRun, !automaticReconnectSuspended {
      clearConnection()
      scan()
    } else {
      clearConnection()
    }
  }

  private func scheduleReconnectFallback(for peripheralID: UUID) {
    reconnectFallbackTask?.cancel()
    reconnectFallbackTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.disconnectCallbackTimeout)
      } catch is CancellationError {
        return
      } catch {
        return
      }
      guard let self, self.peripheral?.identifier == peripheralID else { return }
      self.reconnectFallbackTask = nil
      self.retireCentralManagerAfterDisconnectTimeout()
    }
  }

  /// Retires the whole CoreBluetooth callback source after a disconnect
  /// timeout. A peripheral identifier or object is not enough to distinguish
  /// an obsolete callback when CoreBluetooth reuses the same CBPeripheral for
  /// the replacement attempt; a fresh manager gives callbacks an identity we
  /// can reliably guard.
  private func retireCentralManagerAfterDisconnectTimeout() {
    centralManager?.stopScan()
    centralManager?.delegate = nil
    centralManager = nil
    clearConnection()

    guard !automaticReconnectSuspended else { return }
    if shouldRun {
      centralManager = CBCentralManager(delegate: self, queue: .main)
    } else {
      setState(.idle)
    }
  }

  private func cancelSessionTasks() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
    heartbeatWatchdog = nil
    readyTimeoutTask?.cancel()
    readyTimeoutTask = nil
    tokenTask?.cancel()
    tokenTask = nil
    repeatedConfigurationTask?.cancel()
    repeatedConfigurationTask = nil
  }

  private func cancelTasks() {
    cancelSessionTasks()
    gracefulStopTask?.cancel()
    gracefulStopTask = nil
    reconnectFallbackTask?.cancel()
    reconnectFallbackTask = nil
  }

  private func clearConnection() {
    cancelTasks()
    peripheral?.delegate = nil
    peripheral = nil
    characteristics.removeAll()
    discoveredPeripherals.removeAll()
    discoveredPeripheralNames.removeAll()
    pendingTrustCandidateID = nil
    subscribedCharacteristicIDs.removeAll()
    notificationSubscriptionIndex = 0
    codec = nil
    pendingChallenge = nil
    lastMeasurement = nil
    acceptsMeasurements = false
    discardMeasurementsUntilReady = false
    hasSentArmCommand = false
    batteryLevel = nil
  }
}

extension LaunchMonitorController: @preconcurrency CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === centralManager else { return }
    recordConnectionDiagnostic(.bluetoothStateChanged)
    respondToBluetoothState(central.state)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover discoveredPeripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi rssiValue: NSNumber
  ) {
    guard central === centralManager else { return }
    let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = discoveredPeripheral.name ?? advertisedName ?? "MLM2PRO"
    events.send(
      .discoveredDevice(
        id: discoveredPeripheral.identifier,
        name: name,
        rssi: rssiValue.intValue
      )
    )
    guard shouldRun, peripheral == nil,
      !rejectedPeripheralIDs.contains(discoveredPeripheral.identifier)
    else { return }

    switch trustedPeripheralStore.decision(for: discoveredPeripheral.identifier) {
    case .connect:
      connect(discoveredPeripheral, name: name)
    case .requestConfirmation:
      guard pendingTrustCandidateID == nil else { return }
      discoveredPeripherals[discoveredPeripheral.identifier] = discoveredPeripheral
      discoveredPeripheralNames[discoveredPeripheral.identifier] = name
      pendingTrustCandidateID = discoveredPeripheral.identifier
      central.stopScan()
      setState(
        .awaitingDeviceTrust(id: discoveredPeripheral.identifier, deviceName: name)
      )
      events.send(.deviceTrustRequired(id: discoveredPeripheral.identifier, name: name))
    case .ignore:
      break
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect connectedPeripheral: CBPeripheral) {
    guard central === centralManager, shouldRun, peripheral === connectedPeripheral else { return }
    recordConnectionDiagnostic(.connected)
    beginServiceDiscovery(for: connectedPeripheral)
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect failedPeripheral: CBPeripheral,
    error: (any Error)?
  ) {
    // CoreBluetooth may deliver a delayed callback after the fallback path has
    // already started another connection. Never let an obsolete peripheral
    // clear the replacement session.
    guard central === centralManager, peripheral === failedPeripheral, case .connecting = state
    else { return }
    recordConnectionDiagnostic(.connectionFailed, error: error)
    clearConnection()
    publishError(error?.localizedDescription ?? "เชื่อมต่อ MLM2PRO ไม่สำเร็จ")
    if shouldRun {
      scan()
    } else {
      setState(.idle)
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral disconnectedPeripheral: CBPeripheral,
    error: (any Error)?
  ) {
    guard central === centralManager, peripheral === disconnectedPeripheral else { return }
    recordConnectionDiagnostic(.disconnected, error: error)
    // When a reconnect uses the same CBPeripheral object, an old disconnect
    // callback can still arrive while the replacement attempt is connecting.
    // The active attempt owns failures through didFailToConnect instead.
    if case .connecting = state { return }
    clearConnection()
    // `failSubscription` intentionally releases the device once, then keeps
    // this failed state visible until the user explicitly starts another
    // attempt. Do not turn this callback into another scan cycle.
    if automaticReconnectSuspended { return }
    if let error {
      publishError("MLM2PRO หลุดการเชื่อมต่อ: \(error.localizedDescription)")
    }
    if shouldRun {
      scan()
    } else {
      setState(.idle)
    }
  }
}

extension LaunchMonitorController: @preconcurrency CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    guard shouldRun else { return }
    if let error {
      recordConnectionDiagnostic(.serviceDiscoveryFailed, error: error)
      fail("อ่านบริการ Bluetooth ไม่สำเร็จ: \(error.localizedDescription)")
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == MLM2PROGATT.service }) else {
      fail("ไม่พบบริการ Bluetooth ของ MLM2PRO")
      return
    }
    recordConnectionDiagnostic(.serviceDiscovered)
    recordConnectionDiagnostic(.characteristicDiscoveryRequested)
    peripheral.discoverCharacteristics(MLM2PROGATT.allCharacteristics, for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?
  ) {
    guard shouldRun else { return }
    if let error {
      recordConnectionDiagnostic(.characteristicDiscoveryFailed, error: error)
      fail("อ่านช่องข้อมูล Bluetooth ไม่สำเร็จ: \(error.localizedDescription)")
      return
    }
    recordConnectionDiagnostic(.characteristicsDiscovered)
    subscribe(to: service.characteristics ?? [])
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    guard shouldRun else { return }
    guard notificationSubscriptionIndex < MLM2PROGATT.notificationCharacteristics.count else {
      return
    }

    // There is exactly one outstanding CCCD write. Treat a different callback
    // as a protocol diagnostic instead of advancing an ambiguous handshake.
    let expectedUUID = MLM2PROGATT.notificationCharacteristics[notificationSubscriptionIndex]
    if subscribedCharacteristicIDs.contains(characteristic.uuid) {
      return
    }
    guard characteristic.uuid == expectedUUID else {
      failSubscription(
        MLM2PROGATTSubscriptionFailure(
          characteristicID: characteristic.uuid.uuidString,
          reason: .unexpectedCallback
        )
      )
      return
    }

    if let error {
      recordConnectionDiagnostic(
        .notificationCallbackFailed,
        characteristicID: characteristic.uuid,
        error: error
      )
      let nsError = error as NSError
      let reason: MLM2PROGATTSubscriptionFailureReason
      if nsError.domain == CBATTErrorDomain {
        reason = .attResult(nsError.code)
      } else {
        reason = .coreBluetoothResult(nsError.code)
      }
      failSubscription(
        MLM2PROGATTSubscriptionFailure(
          characteristicID: characteristic.uuid.uuidString,
          reason: reason
        )
      )
      return
    }
    guard characteristic.isNotifying else {
      failSubscription(
        MLM2PROGATTSubscriptionFailure(
          characteristicID: characteristic.uuid.uuidString,
          reason: .notificationDisabled
        )
      )
      return
    }
    subscribedCharacteristicIDs.insert(characteristic.uuid)
    recordConnectionDiagnostic(.notificationEnabled, characteristicID: characteristic.uuid)
    notificationSubscriptionIndex += 1
    subscribeToNextNotification()
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    if let error {
      recordConnectionDiagnostic(
        .valueCallbackFailed,
        characteristicID: characteristic.uuid,
        error: error
      )
      let message = "อ่านข้อมูล MLM2PRO ไม่สำเร็จ: \(error.localizedDescription)"
      if case .stopping = state {
        publishError(message)
      } else {
        fail(message)
      }
      return
    }
    if characteristic.uuid == MLM2PROGATT.heartbeat {
      recordHeartbeat()
      return
    }
    guard let data = characteristic.value else { return }
    switch characteristic.uuid {
    case MLM2PROGATT.writeResponse:
      handleWriteResponse(data)
    case MLM2PROGATT.measurement:
      handleMeasurement(data)
    case MLM2PROGATT.events:
      handleDeviceEvent(data)
    default:
      break
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    if let error {
      recordConnectionDiagnostic(
        .writeCallbackFailed,
        characteristicID: characteristic.uuid,
        error: error
      )
      let message = "ส่งข้อมูลไป MLM2PRO ไม่สำเร็จ: \(error.localizedDescription)"
      if case .stopping = state {
        publishError(message)
      } else {
        fail(message)
      }
    }
  }
}
