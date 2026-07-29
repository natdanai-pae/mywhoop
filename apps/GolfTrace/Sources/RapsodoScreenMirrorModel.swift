@preconcurrency import AVFoundation
import Combine
import CoreMediaIO
import Foundation

/// Receives K's on-device Rapsodo display through the same USB screen source
/// used by QuickTime. This stays pixels-only: no OCR, parsing or app control.
@MainActor
final class RapsodoScreenMirrorModel: ObservableObject {
  @Published private(set) var devices: [AVCaptureDevice] = []
  @Published private(set) var status = "เสียบ K ด้วย USB, ปลดล็อกและกด Trust"
  @Published private(set) var isRunning = false
  @Published private(set) var isBusy = false
  @Published private(set) var hasReceivedFrame = false
  @Published private(set) var activeReplaySourceSession: RapsodoReplaySourceSession?
  @Published var selectedDeviceID: String? {
    didSet {
      guard isInitialized, !isApplyingSelection, selectedDeviceID != oldValue else { return }
      if let selectedDeviceID {
        defaults.set(selectedDeviceID, forKey: Self.preferredDeviceIDKey)
      } else {
        defaults.removeObject(forKey: Self.preferredDeviceIDKey)
      }
      restartForChangedSelectionIfNeeded()
    }
  }

  let session: AVCaptureSession

  private let runtime: RapsodoUSBScreenRuntime
  private let defaults: UserDefaults
  private var confirmedDeviceID: String?
  private var activeDeviceID: String?
  private var desiredRunning = false
  private var operationGeneration: UInt64 = 0
  private var reconnectAttempt = 0
  private var reconnectTask: Task<Void, Never>?
  private var firstFrameTimeoutTask: Task<Void, Never>?
  private var notificationTokens: [NSObjectProtocol] = []
  private var isApplyingSelection = false
  private var isInitialized = false

  private static let preferredDeviceIDKey = "golftrace.rapsodoMirror.preferredDeviceID"
  private static let confirmedDeviceIDKey = "golftrace.rapsodoMirror.confirmedDeviceID"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    confirmedDeviceID = defaults.string(forKey: Self.confirmedDeviceIDKey)
    selectedDeviceID = confirmedDeviceID

    let runtime = RapsodoUSBScreenRuntime()
    self.runtime = runtime
    session = runtime.session

    runtime.setEventHandler { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleRuntimeEvent(event)
      }
    }

    enableIPhoneScreenCaptureDevices()
    installObservers()
    isInitialized = true
    refreshDevices()
  }

  deinit {
    reconnectTask?.cancel()
    firstFrameTimeoutTask?.cancel()
    for token in notificationTokens {
      NotificationCenter.default.removeObserver(token)
    }
  }

  /// Keeps K's USB display attached and reconnects after cable/session changes.
  func startAutomatic() {
    desiredRunning = true
    reconnectAttempt = 0
    ensurePermissionAndStart()
  }

  /// Preserved for existing callers; USB capture now always maintains itself.
  func start() {
    startAutomatic()
  }

  func stop() {
    desiredRunning = false
    reconnectTask?.cancel()
    reconnectTask = nil
    firstFrameTimeoutTask?.cancel()
    firstFrameTimeoutTask = nil
    reconnectAttempt = 0

    operationGeneration &+= 1
    let generation = operationGeneration
    activeDeviceID = nil
    activeReplaySourceSession = nil
    isRunning = false
    isBusy = false
    hasReceivedFrame = false
    status = "หยุดรับภาพ Rapsodo จาก K แล้ว"
    runtime.stop(generation: generation)
  }

  /// Installs one nonblocking source-MOV tap. The handler runs on the USB
  /// capture queue and must return immediately.
  func setReplaySampleHandler(_ handler: RapsodoReplaySampleHandler?) {
    runtime.setReplaySampleHandler(handler)
  }

  func refreshDevices() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      publishPermissionStatus()
      return
    }

    publishDiscoveredDevices()
    if desiredRunning, !isRunning, !isBusy {
      attemptStart()
    }
  }

  private func ensurePermissionAndStart() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      publishDiscoveredDevices()
      attemptStart()

    case .notDetermined:
      isBusy = true
      status = "รออนุญาต Camera เพื่อรับหน้าจอ K ผ่าน USB…"
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.isBusy = false
          guard self.desiredRunning else { return }
          if granted {
            self.publishDiscoveredDevices()
            self.attemptStart()
          } else {
            self.publishPermissionStatus()
          }
        }
      }

    case .denied, .restricted:
      publishPermissionStatus()

    @unknown default:
      status = "macOS ไม่อนุญาตให้ GolfTrace รับหน้าจอ K"
    }
  }

  private func publishPermissionStatus() {
    let authorization = AVCaptureDevice.authorizationStatus(for: .video)
    status =
      authorization == .restricted
      ? "Camera ถูกจำกัด จึงรับหน้าจอ K ผ่าน USB ไม่ได้"
      : "อนุญาต Camera ให้ GolfTrace เพื่อรับหน้าจอ K ผ่าน USB"
    isBusy = false
  }

  private func publishDiscoveredDevices() {
    enableIPhoneScreenCaptureDevices()
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external],
      mediaType: .muxed,
      position: .unspecified
    )

    var seenIDs = Set<String>()
    let discovered = discovery.devices
      .filter { seenIDs.insert($0.uniqueID).inserted }
      .sorted { lhs, rhs in
        let lhsIsK = lhs.localizedName.caseInsensitiveCompare("K") == .orderedSame
        let rhsIsK = rhs.localizedName.caseInsensitiveCompare("K") == .orderedSame
        if lhsIsK != rhsIsK { return lhsIsK }
        return lhs.localizedName.localizedStandardCompare(rhs.localizedName) == .orderedAscending
      }
    devices = discovered

    let availableIDs = Set(discovered.map(\.uniqueID))
    let preferredID = defaults.string(forKey: Self.preferredDeviceIDKey)
    let chosenID: String?

    if let selectedDeviceID, availableIDs.contains(selectedDeviceID) {
      chosenID = selectedDeviceID
    } else if let confirmedDeviceID, availableIDs.contains(confirmedDeviceID) {
      chosenID = confirmedDeviceID
    } else if let preferredID, availableIDs.contains(preferredID) {
      chosenID = preferredID
    } else if let k = discovered.first(where: {
      $0.localizedName.caseInsensitiveCompare("K") == .orderedSame
    }) {
      chosenID = k.uniqueID
    } else if discovered.count == 1, confirmedDeviceID == nil, selectedDeviceID == nil {
      chosenID = discovered[0].uniqueID
    } else {
      // A previously confirmed K stays pinned while disconnected. Never jump
      // to a second phone merely because K temporarily disappeared.
      chosenID = selectedDeviceID ?? confirmedDeviceID
    }

    applySelection(chosenID)

    if discovered.isEmpty {
      status = "ยังไม่พบจอ K — เสียบ USB, ปลดล็อกและกด Trust"
    } else if let chosenID,
      let chosen = discovered.first(where: { $0.uniqueID == chosenID })
    {
      status = "พบ \(chosen.localizedName) ผ่าน USB — พร้อมรับภาพ Rapsodo"
    } else {
      status = "พบ iPhone มากกว่าหนึ่งเครื่อง — เลือกเครื่อง Rapsodo"
    }
  }

  private func applySelection(_ id: String?) {
    guard selectedDeviceID != id else { return }
    isApplyingSelection = true
    selectedDeviceID = id
    isApplyingSelection = false
  }

  private func attemptStart() {
    guard desiredRunning, !isRunning, !isBusy else { return }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      ensurePermissionAndStart()
      return
    }

    publishDiscoveredDevices()
    guard
      let selectedDeviceID,
      let device = devices.first(where: { $0.uniqueID == selectedDeviceID })
    else {
      scheduleReconnect()
      return
    }

    reconnectTask?.cancel()
    reconnectTask = nil
    operationGeneration &+= 1
    let generation = operationGeneration
    activeDeviceID = selectedDeviceID
    activeReplaySourceSession = RapsodoReplaySourceSession(
      sourceKind: .usb(deviceID: selectedDeviceID),
      generationID: generation
    )
    hasReceivedFrame = false
    isRunning = false
    isBusy = true
    status = "กำลังเปิดหน้าจอ Rapsodo จาก \(device.localizedName)…"
    runtime.start(device: device, generation: generation)
  }

  private func handleRuntimeEvent(_ event: RapsodoUSBScreenRuntime.Event) {
    switch event {
    case .sessionStarted(let generation, let deviceID, let deviceName):
      guard generation == operationGeneration, deviceID == activeDeviceID else { return }
      status = "เชื่อมต่อ \(deviceName) แล้ว — รอภาพแรกจาก Rapsodo…"
      startFirstFrameTimeout(generation: generation)

    case .firstFrame(let generation, let deviceID, let deviceName, let dimensions):
      guard generation == operationGeneration, deviceID == activeDeviceID else { return }
      firstFrameTimeoutTask?.cancel()
      firstFrameTimeoutTask = nil
      reconnectAttempt = 0
      isBusy = false
      isRunning = true
      hasReceivedFrame = true
      confirmedDeviceID = deviceID
      defaults.set(deviceID, forKey: Self.confirmedDeviceIDKey)
      status = "กำลังแสดง Rapsodo จาก \(deviceName) · \(dimensions.width)×\(dimensions.height)"

    case .stopped(let generation):
      guard generation == operationGeneration else { return }
      firstFrameTimeoutTask?.cancel()
      firstFrameTimeoutTask = nil
      isBusy = false
      isRunning = false
      hasReceivedFrame = false
      activeReplaySourceSession = nil
      if desiredRunning {
        status = "ภาพจาก K หยุดชั่วคราว — กำลังต่อกลับ…"
        scheduleReconnect()
      }

    case .failed(let generation, let message):
      guard generation == operationGeneration else { return }
      firstFrameTimeoutTask?.cancel()
      firstFrameTimeoutTask = nil
      isBusy = false
      isRunning = false
      hasReceivedFrame = false
      activeReplaySourceSession = nil
      status = "รับหน้าจอ K ไม่สำเร็จ: \(message)"
      scheduleReconnect()
    }
  }

  private func startFirstFrameTimeout(generation: UInt64) {
    firstFrameTimeoutTask?.cancel()
    firstFrameTimeoutTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(7))
      } catch {
        return
      }
      guard let self, self.desiredRunning, self.operationGeneration == generation,
        !self.hasReceivedFrame
      else { return }

      self.operationGeneration &+= 1
      let stopGeneration = self.operationGeneration
      self.activeDeviceID = nil
      self.activeReplaySourceSession = nil
      self.isBusy = false
      self.status = "เชื่อมต่อ K แล้วแต่ยังไม่มีภาพ — กำลังเปิดใหม่…"
      self.runtime.stop(generation: stopGeneration)
      self.scheduleReconnect(after: 1)
    }
  }

  private func scheduleReconnect(after explicitDelay: Int? = nil) {
    guard desiredRunning else { return }
    reconnectTask?.cancel()
    reconnectAttempt += 1
    let delay = explicitDelay ?? min(5, max(1, reconnectAttempt))
    reconnectTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard let self, self.desiredRunning else { return }
      self.reconnectTask = nil
      self.publishDiscoveredDevices()
      self.attemptStart()
    }
  }

  private func restartForChangedSelectionIfNeeded() {
    guard desiredRunning else { return }
    reconnectTask?.cancel()
    firstFrameTimeoutTask?.cancel()
    operationGeneration &+= 1
    let generation = operationGeneration
    activeDeviceID = nil
    activeReplaySourceSession = nil
    isRunning = false
    isBusy = false
    hasReceivedFrame = false
    runtime.stop(generation: generation)
    scheduleReconnect(after: 1)
  }

  private func handleDeviceTopologyChange() {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
    publishDiscoveredDevices()

    if let activeDeviceID,
      !devices.contains(where: { $0.uniqueID == activeDeviceID })
    {
      operationGeneration &+= 1
      let generation = operationGeneration
      self.activeDeviceID = nil
      activeReplaySourceSession = nil
      isRunning = false
      isBusy = false
      hasReceivedFrame = false
      status = "K หลุดจาก USB — รอเสียบกลับและจะเชื่อมต่อเอง"
      runtime.stop(generation: generation)
      scheduleReconnect(after: 1)
    } else if desiredRunning, !isRunning, !isBusy {
      attemptStart()
    }
  }

  private func handleSessionRuntimeError(_ message: String) {
    guard desiredRunning else { return }
    operationGeneration &+= 1
    let generation = operationGeneration
    activeDeviceID = nil
    activeReplaySourceSession = nil
    isRunning = false
    isBusy = false
    hasReceivedFrame = false
    status = "สัญญาณ USB หยุด: \(message) — กำลังต่อกลับ…"
    runtime.stop(generation: generation)
    scheduleReconnect(after: 1)
  }

  private func installObservers() {
    let center = NotificationCenter.default
    for name in [
      AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
    ] {
      notificationTokens.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.handleDeviceTopologyChange()
          }
        }
      )
    }

    notificationTokens.append(
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification,
        object: session,
        queue: nil
      ) { [weak self] notification in
        let message =
          (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
          .localizedDescription ?? "AVCaptureSession runtime error"
        Task { @MainActor [weak self, message] in
          self?.handleSessionRuntimeError(message)
        }
      }
    )
  }

  private func enableIPhoneScreenCaptureDevices() {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject),
      &address,
      0,
      nil,
      UInt32(MemoryLayout.size(ofValue: allow)),
      &allow
    )
  }
}

private final class RapsodoUSBScreenRuntime: NSObject,
  AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
  enum Event: Sendable {
    case sessionStarted(UInt64, String, String)
    case firstFrame(UInt64, String, String, CMVideoDimensions)
    case stopped(UInt64)
    case failed(UInt64, String)
  }

  let session = AVCaptureSession()
  private let queue = DispatchQueue(
    label: "com.bda.golftrace.rapsodo-usb-session",
    qos: .userInitiated
  )
  private var currentInput: AVCaptureDeviceInput?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var activeGeneration: UInt64 = 0
  private var activeDeviceID: String?
  private var activeDeviceName = "K"
  private var didSignalFirstFrame = false
  private var eventHandler: (@Sendable (Event) -> Void)?
  private var replaySampleHandler: RapsodoReplaySampleHandler?
  private var replaySourceSession: RapsodoReplaySourceSession?

  func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
    eventHandler = handler
  }

  func setReplaySampleHandler(_ handler: RapsodoReplaySampleHandler?) {
    queue.async { [weak self] in
      self?.replaySampleHandler = handler
    }
  }

  func start(device: AVCaptureDevice, generation: UInt64) {
    let transfer = RapsodoCaptureDeviceTransfer(device)
    queue.async { [weak self, transfer] in
      self?.startLocked(device: transfer.device, generation: generation)
    }
  }

  func stop(generation: UInt64) {
    queue.async { [weak self] in
      self?.stopLocked(generation: generation)
    }
  }

  private func startLocked(device: AVCaptureDevice, generation: UInt64) {
    guard generation >= activeGeneration else { return }
    activeGeneration = generation
    activeDeviceID = device.uniqueID
    activeDeviceName = device.localizedName
    replaySourceSession = RapsodoReplaySourceSession(
      sourceKind: .usb(deviceID: device.uniqueID),
      generationID: generation
    )
    didSignalFirstFrame = false

    if session.isRunning {
      session.stopRunning()
    }

    do {
      let input = try AVCaptureDeviceInput(device: device)
      let output = AVCaptureVideoDataOutput()
      output.alwaysDiscardsLateVideoFrames = true
      output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      output.setSampleBufferDelegate(self, queue: queue)

      session.beginConfiguration()
      defer { session.commitConfiguration() }
      session.sessionPreset = .high

      for existingInput in session.inputs {
        session.removeInput(existingInput)
      }
      for existingOutput in session.outputs {
        session.removeOutput(existingOutput)
      }

      guard session.canAddInput(input) else {
        throw RapsodoUSBScreenRuntimeError.cannotAddInput
      }
      session.addInput(input)
      guard session.canAddOutput(output) else {
        session.removeInput(input)
        throw RapsodoUSBScreenRuntimeError.cannotAddOutput
      }
      session.addOutput(output)
      currentInput = input
      videoOutput = output
    } catch {
      eventHandler?(.failed(generation, error.localizedDescription))
      return
    }

    session.startRunning()
    guard session.isRunning, let activeDeviceID else {
      eventHandler?(.failed(generation, "AVCaptureSession ไม่เริ่มทำงาน"))
      return
    }
    eventHandler?(.sessionStarted(generation, activeDeviceID, activeDeviceName))
  }

  private func stopLocked(generation: UInt64) {
    guard generation >= activeGeneration else { return }
    activeGeneration = generation
    if session.isRunning {
      session.stopRunning()
    }
    videoOutput?.setSampleBufferDelegate(nil, queue: nil)
    session.beginConfiguration()
    for input in session.inputs {
      session.removeInput(input)
    }
    for output in session.outputs {
      session.removeOutput(output)
    }
    session.commitConfiguration()
    currentInput = nil
    videoOutput = nil
    activeDeviceID = nil
    replaySourceSession = nil
    didSignalFirstFrame = false
    eventHandler?(.stopped(generation))
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard
      sampleBuffer.isValid,
      sampleBuffer.dataReadiness == .ready,
      CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
      let activeDeviceID
    else { return }

    if let replaySampleHandler, let replaySourceSession {
      replaySampleHandler(
        RapsodoReplaySample(
          sampleBuffer: sampleBuffer,
          sourceSession: replaySourceSession
        )
      )
    }

    guard !didSignalFirstFrame else { return }

    didSignalFirstFrame = true
    let dimensions =
      sampleBuffer.formatDescription.map(CMVideoFormatDescriptionGetDimensions)
      ?? CMVideoDimensions(width: 0, height: 0)
    eventHandler?(
      .firstFrame(
        activeGeneration,
        activeDeviceID,
        activeDeviceName,
        dimensions
      )
    )
  }
}

private final class RapsodoCaptureDeviceTransfer: @unchecked Sendable {
  let device: AVCaptureDevice

  init(_ device: AVCaptureDevice) {
    self.device = device
  }
}

private enum RapsodoUSBScreenRuntimeError: LocalizedError {
  case cannotAddInput
  case cannotAddOutput

  var errorDescription: String? {
    switch self {
    case .cannotAddInput:
      return "เพิ่มหน้าจอ iPhone เป็น input ไม่ได้"
    case .cannotAddOutput:
      return "เพิ่มตัวตรวจภาพ USB ไม่ได้"
    }
  }
}
