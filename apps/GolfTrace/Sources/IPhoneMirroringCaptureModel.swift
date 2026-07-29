@preconcurrency import AVFoundation
import AppKit
import Combine
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// A lightweight, UI-safe description of a capturable Apple iPhone Mirroring window.
///
/// `SCWindow` itself deliberately stays private to the model. Keeping only value
/// types here makes the list safe to bind to a SwiftUI picker.
struct IPhoneMirroringWindowDescriptor: Identifiable, Equatable, Sendable {
  let id: CGWindowID
  let title: String
  let width: Int
  let height: Int
  let isActive: Bool

  var dimensionsText: String {
    "\(width) × \(height)"
  }

  var displayName: String {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedTitle.isEmpty
      ? "หน้าต่างสะท้อนหน้าจอ iPhone (\(dimensionsText))"
      : "\(trimmedTitle) (\(dimensionsText))"
  }
}

/// Captures only the window owned by Apple's iPhone Mirroring app.
///
/// This is a local visual feed. It does not OCR, inspect, or interact with the
/// mirrored iPhone. ScreenCaptureKit can continue supplying the independent
/// window while GolfTrace is in front of it, allowing the iPhone itself to stay
/// locked as required by iPhone Mirroring.
@MainActor
final class IPhoneMirroringCaptureModel: NSObject, ObservableObject {
  static let iPhoneMirroringBundleIdentifier = "com.apple.ScreenContinuity"

  @Published private(set) var status =
    "เปิด “สะท้อนหน้าจอ iPhone” ให้เห็น Rapsodo แล้วกดเชื่อมต่อ"
  @Published private(set) var isRunning = false
  @Published private(set) var isBusy = false
  @Published private(set) var hasReceivedFrame = false
  @Published private(set) var windows: [IPhoneMirroringWindowDescriptor] = []
  @Published private(set) var activeReplaySourceSession: RapsodoReplaySourceSession?
  @Published var selectedWindowID: CGWindowID?

  var hasAvailableWindow: Bool {
    !windows.isEmpty
  }

  private let frameOutput = IPhoneMirroringStreamOutput()
  private var shareableWindows: [CGWindowID: SCWindow] = [:]
  private var stream: SCStream?
  private var activeStreamID: ObjectIdentifier?
  private var operationTask: Task<Void, Never>?
  private var automaticReconnectTask: Task<Void, Never>?
  private var operationGeneration: UInt64 = 0
  private var shouldReconnectAutomatically = false

  override init() {
    super.init()

    frameOutput.setEventHandler { [weak self] event in
      Task { @MainActor [weak self] in
        self?.handleOutputEvent(event)
      }
    }
  }

  deinit {
    operationTask?.cancel()
    automaticReconnectTask?.cancel()
  }

  /// Refreshes the Apple iPhone Mirroring window list without starting capture.
  func refreshWindows() {
    guard !isBusy else { return }

    let generation = beginOperation()
    operationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finishOperation(generation) }

      do {
        try Task.checkCancellation()
        let discoveredWindows = try await self.loadShareableWindows()
        try Task.checkCancellation()
        self.publish(discoveredWindows, updateStatus: true)
      } catch is CancellationError {
        return
      } catch {
        self.status = self.captureErrorMessage(error)
      }
    }
  }

  /// Requests macOS Screen Recording permission when necessary, then starts
  /// the selected (or highest-ranked) iPhone Mirroring window.
  func requestPermissionAndStart() {
    launchStart(requestPermission: true)
  }

  /// Opens Apple's iPhone Mirroring app and keeps looking for its phone window.
  /// This is the fallback path when a trusted USB screen feed is unavailable.
  func startAutomatically() {
    shouldReconnectAutomatically = true
    openIPhoneMirroringApplication()

    if !isBusy, !isRunning {
      requestPermissionAndStart()
    }
    startAutomaticReconnectLoopIfNeeded()
  }

  /// Starts capture only when permission has already been granted.
  /// Use `requestPermissionAndStart()` for the primary UI action.
  func start() {
    launchStart(requestPermission: false)
  }

  /// Stops the active stream and clears the preview asynchronously.
  func stop() {
    shouldReconnectAutomatically = false
    automaticReconnectTask?.cancel()
    automaticReconnectTask = nil
    operationTask?.cancel()
    operationGeneration &+= 1
    let generation = operationGeneration
    operationTask = nil

    let activeStream = stream
    stream = nil
    activeStreamID = nil
    isRunning = false
    hasReceivedFrame = false
    activeReplaySourceSession = nil
    frameOutput.prepareForStop()
    frameOutput.flushRenderer(removingDisplayedImage: true)

    guard let activeStream else {
      isBusy = false
      status = "หยุดรับภาพ Apple iPhone Mirroring แล้ว"
      return
    }

    isBusy = true
    status = "กำลังหยุดภาพ Apple iPhone Mirroring…"
    operationTask = Task { @MainActor [weak self] in
      do {
        try await activeStream.stopCapture()
      } catch {
        guard let self, self.operationGeneration == generation else { return }
        self.status = "หยุดภาพแล้ว (\(error.localizedDescription))"
        self.finishOperation(generation)
        return
      }

      guard let self, self.operationGeneration == generation else { return }
      self.status = "หยุดรับภาพ Apple iPhone Mirroring แล้ว"
      self.finishOperation(generation)
    }
  }

  /// The SwiftUI/AppKit preview owns the display layer. The stream output keeps
  /// only a weak reference to its thread-safe sample-buffer renderer.
  func attachPreviewLayer(_ layer: AVSampleBufferDisplayLayer?) {
    layer?.videoGravity = .resizeAspect
    frameOutput.attachRenderer(layer?.sampleBufferRenderer)
  }

  /// Installs one nonblocking source-MOV tap. The handler runs on the existing
  /// ScreenCaptureKit output queue and must return immediately.
  func setReplaySampleHandler(_ handler: RapsodoReplaySampleHandler?) {
    frameOutput.setReplaySampleHandler(handler)
  }

  func openScreenRecordingSettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func openIPhoneMirroringApplication() {
    guard
      let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.iPhoneMirroringBundleIdentifier
      )
    else {
      status = "ไม่พบแอป Apple iPhone Mirroring บน Mac เครื่องนี้"
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(
      at: applicationURL,
      configuration: configuration
    ) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor [weak self] in
        self?.status = "เปิด Apple iPhone Mirroring ไม่สำเร็จ: \(error.localizedDescription)"
      }
    }
  }

  private func startAutomaticReconnectLoopIfNeeded() {
    guard automaticReconnectTask == nil else { return }

    automaticReconnectTask = Task { @MainActor [weak self] in
      defer { self?.automaticReconnectTask = nil }
      var failedAttempts = 0

      while !Task.isCancelled {
        guard let self, self.shouldReconnectAutomatically else { return }

        if self.isRunning {
          failedAttempts = 0
          try? await Task.sleep(for: .seconds(2))
          continue
        }

        if !self.isBusy, CGPreflightScreenCaptureAccess() {
          self.start()
          failedAttempts += 1
        }

        let delaySeconds = min(5, max(1, failedAttempts))
        try? await Task.sleep(for: .seconds(delaySeconds))
      }
    }
  }

  private func launchStart(requestPermission: Bool) {
    guard !isBusy, !isRunning else { return }

    let generation = beginOperation()
    operationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.finishOperation(generation) }

      do {
        if requestPermission, !CGPreflightScreenCaptureAccess() {
          self.status = "รออนุญาตบันทึกหน้าจอให้ GolfTrace…"
          guard CGRequestScreenCaptureAccess() else {
            self.status = Self.permissionRequiredStatus
            return
          }
        } else if !CGPreflightScreenCaptureAccess() {
          self.status = Self.permissionRequiredStatus
          return
        }

        try Task.checkCancellation()
        let discoveredWindows = try await self.loadShareableWindows()
        try Task.checkCancellation()
        self.publish(discoveredWindows, updateStatus: false)

        guard
          let selectedWindowID = self.selectedWindowID,
          let selectedWindow = self.shareableWindows[selectedWindowID]
        else {
          self.status = Self.noWindowStatus
          return
        }

        try await self.startCapture(of: selectedWindow)
      } catch is CancellationError {
        return
      } catch {
        self.stream = nil
        self.activeStreamID = nil
        self.activeReplaySourceSession = nil
        self.frameOutput.prepareForStop()
        self.isRunning = false
        self.status = self.captureErrorMessage(error)
      }
    }
  }

  private func startCapture(of window: SCWindow) async throws {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = Self.configuration(for: window, filter: filter)
    let newStream = SCStream(filter: filter, configuration: configuration, delegate: frameOutput)
    let newStreamID = ObjectIdentifier(newStream)
    let replaySourceSession = RapsodoReplaySourceSession(
      sourceKind: .appleMirroring(windowID: window.windowID),
      generationID: operationGeneration
    )

    frameOutput.prepareForStart(
      streamID: newStreamID,
      sourceSession: replaySourceSession
    )
    hasReceivedFrame = false
    activeReplaySourceSession = replaySourceSession
    try newStream.addStreamOutput(
      frameOutput,
      type: .screen,
      sampleHandlerQueue: frameOutput.outputQueue
    )

    stream = newStream
    activeStreamID = newStreamID
    status = "กำลังเริ่มภาพจาก Apple iPhone Mirroring…"

    var didStart = false
    do {
      try await newStream.startCapture()
      didStart = true
      try Task.checkCancellation()
      guard stream === newStream else {
        try? await newStream.stopCapture()
        return
      }
      isRunning = true
      status =
        hasReceivedFrame
        ? "กำลังรับภาพสดจาก Apple iPhone Mirroring"
        : "เชื่อมต่อ Apple iPhone Mirroring แล้ว — รอภาพแรก…"
    } catch {
      if stream === newStream {
        stream = nil
        activeStreamID = nil
        activeReplaySourceSession = nil
      }
      frameOutput.prepareForStop()
      if didStart {
        try? await newStream.stopCapture()
      }
      throw error
    }
  }

  private func loadShareableWindows() async throws -> [SCWindow] {
    let content = try await SCShareableContent.current
    return content.windows
      .filter(Self.isUsableIPhoneMirroringWindow)
      .sorted { Self.windowRank($0) > Self.windowRank($1) }
  }

  private func publish(_ discoveredWindows: [SCWindow], updateStatus: Bool) {
    shareableWindows = Dictionary(
      uniqueKeysWithValues: discoveredWindows.map { ($0.windowID, $0) }
    )
    windows = discoveredWindows.map(Self.descriptor)

    if let selectedWindowID, shareableWindows[selectedWindowID] != nil {
      // Preserve an explicit user choice while that window still exists.
    } else {
      selectedWindowID = discoveredWindows.first?.windowID
    }

    guard updateStatus else { return }
    if let selected = windows.first(where: { $0.id == selectedWindowID }) {
      status = "พบ Apple iPhone Mirroring: \(selected.dimensionsText) — พร้อมเชื่อมต่อ"
    } else {
      status = Self.noWindowStatus
    }
  }

  private func handleOutputEvent(_ event: IPhoneMirroringStreamOutput.Event) {
    switch event {
    case .firstCompleteFrame(let streamID):
      guard activeStreamID == streamID else { return }
      isRunning = true
      hasReceivedFrame = true
      status = "กำลังรับภาพสดจาก Apple iPhone Mirroring"

    case .stopped(let streamID, let failure):
      guard activeStreamID == streamID else { return }
      stream = nil
      activeStreamID = nil
      isRunning = false
      hasReceivedFrame = false
      activeReplaySourceSession = nil
      frameOutput.prepareForStop()
      isBusy = false

      if failure.isUserStop {
        status = "Apple iPhone Mirroring หยุดส่งภาพ — กดเชื่อมต่อเพื่อเริ่มใหม่"
      } else {
        status = captureErrorMessage(failure)
      }
    }
  }

  private func beginOperation() -> UInt64 {
    operationTask?.cancel()
    operationGeneration &+= 1
    isBusy = true
    return operationGeneration
  }

  private func finishOperation(_ generation: UInt64) {
    guard operationGeneration == generation else { return }
    isBusy = false
    operationTask = nil
  }

  private func captureErrorMessage(_ error: Error) -> String {
    if !CGPreflightScreenCaptureAccess() {
      return Self.permissionRequiredStatus
    }

    let nsError = error as NSError
    return captureErrorMessage(
      IPhoneMirroringStreamOutput.CaptureFailure(
        domain: nsError.domain,
        code: nsError.code,
        message: nsError.localizedDescription
      )
    )
  }

  private func captureErrorMessage(
    _ failure: IPhoneMirroringStreamOutput.CaptureFailure
  ) -> String {
    if failure.isPermissionFailure {
      return Self.permissionRequiredStatus
    }
    if failure.isMissingEntitlement {
      return "macOS ไม่อนุญาตตัวรับภาพของ GolfTrace (missing entitlement)"
    }
    if failure.isMissingSource {
      return Self.noWindowStatus
    }
    return "รับภาพ Apple iPhone Mirroring ไม่สำเร็จ: \(failure.message)"
  }

  private static func descriptor(_ window: SCWindow) -> IPhoneMirroringWindowDescriptor {
    IPhoneMirroringWindowDescriptor(
      id: window.windowID,
      title: window.title ?? "",
      width: Int(window.frame.width.rounded()),
      height: Int(window.frame.height.rounded()),
      isActive: window.isActive
    )
  }

  private static func isUsableIPhoneMirroringWindow(_ window: SCWindow) -> Bool {
    guard
      window.owningApplication?.bundleIdentifier == iPhoneMirroringBundleIdentifier,
      window.isOnScreen,
      window.windowLayer == 0
    else { return false }

    let width = window.frame.width
    let height = window.frame.height
    let shortEdge = min(width, height)
    let area = width * height
    guard shortEdge >= 180, area >= 60_000 else { return false }

    let normalizedTitle = (window.title ?? "")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
    let rejectedTitleFragments = [
      "welcome",
      "onboarding",
      "getting started",
      "get started",
      "what's new",
      "what’s new",
      "ยินดีต้อนรับ",
      "เริ่มต้นใช้งาน",
    ]
    return !rejectedTitleFragments.contains(where: normalizedTitle.contains)
  }

  private static func windowRank(_ window: SCWindow) -> Double {
    let width = max(window.frame.width, 1)
    let height = max(window.frame.height, 1)
    let phoneAspect = min(width, height) / max(width, height)
    let isPhoneLike = (0.38...0.75).contains(phoneAspect)
    let title = (window.title ?? "").lowercased()
    let titleLooksRelevant = title.contains("iphone") || title.contains("ไอโฟน")

    return (isPhoneLike ? 10_000_000 : 0)
      + (window.isActive ? 2_000_000 : 0)
      + (titleLooksRelevant ? 1_000_000 : 0)
      + min(width * height, 900_000)
  }

  private static func configuration(
    for window: SCWindow,
    filter: SCContentFilter
  ) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    let scale = max(CGFloat(filter.pointPixelScale), 1)
    let sourceSize = CGSize(
      width: max(window.frame.width * scale, 2),
      height: max(window.frame.height * scale, 2)
    )
    let maximumDimension: CGFloat = 2_560
    let downscale = min(1, maximumDimension / max(sourceSize.width, sourceSize.height))

    configuration.width = Int(max(2, (sourceSize.width * downscale).rounded()))
    configuration.height = Int(max(2, (sourceSize.height * downscale).rounded()))
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.queueDepth = 3
    configuration.scalesToFit = true
    configuration.preservesAspectRatio = true
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.ignoreGlobalClipSingleWindow = true
    configuration.captureResolution = .best
    configuration.shouldBeOpaque = true
    configuration.streamName = "GolfTrace Apple iPhone Mirroring"
    return configuration
  }

  private static let noWindowStatus =
    "ไม่พบหน้าต่าง Apple iPhone Mirroring — เปิด “สะท้อนหน้าจอ iPhone” ให้เห็น Rapsodo แล้วค้นหาใหม่"

  private static let permissionRequiredStatus =
    "ต้องอนุญาต “บันทึกหน้าจอและเสียงระบบ” ให้ GolfTrace แล้วปิดและเปิดแอปใหม่หนึ่งครั้ง"
}

/// Receives ScreenCaptureKit callbacks and renders on one serial queue. This
/// keeps AVSampleBufferVideoRenderer off the main actor while preserving the
/// `@MainActor` contract of the observable model.
private final class IPhoneMirroringStreamOutput: NSObject, SCStreamOutput,
  SCStreamDelegate, @unchecked Sendable
{
  struct CaptureFailure: Sendable {
    let domain: String
    let code: Int
    let message: String

    var isPermissionFailure: Bool {
      domain == SCStreamErrorDomain && (code == -3801 || code == -3802)
    }

    var isMissingEntitlement: Bool {
      domain == SCStreamErrorDomain && code == -3803
    }

    var isMissingSource: Bool {
      domain == SCStreamErrorDomain && [-3806, -3813, -3815].contains(code)
    }

    var isUserStop: Bool {
      domain == SCStreamErrorDomain && code == -3817
    }
  }

  enum Event: Sendable {
    case firstCompleteFrame(ObjectIdentifier)
    case stopped(ObjectIdentifier, CaptureFailure)
  }

  let outputQueue = DispatchQueue(
    label: "com.bda.golftrace.iphone-mirroring.frames",
    qos: .userInteractive
  )

  private weak var renderer: AVSampleBufferVideoRenderer?
  private var activeStreamID: ObjectIdentifier?
  private var didSignalFirstFrame = false
  private var eventHandler: (@Sendable (Event) -> Void)?
  private var replaySampleHandler: RapsodoReplaySampleHandler?
  private var replaySourceSession: RapsodoReplaySourceSession?

  func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
    eventHandler = handler
  }

  func prepareForStart(
    streamID: ObjectIdentifier,
    sourceSession: RapsodoReplaySourceSession
  ) {
    outputQueue.sync {
      activeStreamID = streamID
      didSignalFirstFrame = false
      replaySourceSession = sourceSession
    }
  }

  func prepareForStop() {
    outputQueue.async { [weak self] in
      self?.activeStreamID = nil
      self?.didSignalFirstFrame = false
      self?.replaySourceSession = nil
    }
  }

  func setReplaySampleHandler(_ handler: RapsodoReplaySampleHandler?) {
    outputQueue.async { [weak self] in
      self?.replaySampleHandler = handler
    }
  }

  func attachRenderer(_ newRenderer: AVSampleBufferVideoRenderer?) {
    let transfer = RendererTransfer(newRenderer)
    outputQueue.async { [weak self, transfer] in
      self?.renderer = transfer.renderer
    }
  }

  func flushRenderer(removingDisplayedImage: Bool) {
    outputQueue.async { [weak self] in
      self?.renderer?.flush(
        removingDisplayedImage: removingDisplayedImage,
        completionHandler: nil
      )
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard
      activeStreamID == ObjectIdentifier(stream),
      outputType == .screen,
      sampleBuffer.isValid,
      sampleBuffer.dataReadiness == .ready,
      CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
      Self.frameStatus(of: sampleBuffer) == .complete
    else { return }

    // Attach before handing the immutable buffer to either consumer. Mutating
    // attachments after the replay writer retains the same CMSampleBuffer would
    // race the writer queue.
    CMSetAttachment(
      sampleBuffer,
      key: kCMSampleAttachmentKey_DisplayImmediately,
      value: kCFBooleanTrue,
      attachmentMode: kCMAttachmentMode_ShouldPropagate
    )

    if let replaySampleHandler, let replaySourceSession {
      replaySampleHandler(
        RapsodoReplaySample(
          sampleBuffer: sampleBuffer,
          sourceSession: replaySourceSession
        )
      )
    }

    if !didSignalFirstFrame {
      didSignalFirstFrame = true
      eventHandler?(.firstCompleteFrame(ObjectIdentifier(stream)))
    }

    guard let renderer else { return }
    if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
      renderer.flush(removingDisplayedImage: true, completionHandler: nil)
      return
    }
    guard renderer.isReadyForMoreMediaData else { return }

    renderer.enqueue(sampleBuffer)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    let streamID = ObjectIdentifier(stream)
    let nsError = error as NSError
    let failure = CaptureFailure(
      domain: nsError.domain,
      code: nsError.code,
      message: nsError.localizedDescription
    )

    outputQueue.async { [weak self] in
      self?.didSignalFirstFrame = false
      self?.eventHandler?(.stopped(streamID, failure))
    }
  }

  private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[SCStreamFrameInfo: Any]],
      let frameAttachment = attachments.first,
      let statusNumber = frameAttachment[SCStreamFrameInfo.status] as? NSNumber
    else { return nil }
    return SCFrameStatus(rawValue: statusNumber.intValue)
  }
}

private final class RendererTransfer: @unchecked Sendable {
  let renderer: AVSampleBufferVideoRenderer?

  init(_ renderer: AVSampleBufferVideoRenderer?) {
    self.renderer = renderer
  }
}
