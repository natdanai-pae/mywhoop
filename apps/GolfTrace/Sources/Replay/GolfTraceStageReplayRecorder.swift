@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

enum GolfTraceStageReplayRecorderError: LocalizedError {
  case noMainWindow
  case windowNotShareable
  case cannotCreateWriter
  case cannotAddWriterInput
  case noVideoFrames
  case recordingFailed(String)

  var errorDescription: String? {
    switch self {
    case .noMainWindow:
      return "ไม่พบหน้าต่าง GolfTrace ที่ต้องบันทึก"
    case .windowNotShareable:
      return "หน้าต่าง GolfTrace ยังไม่พร้อมให้ระบบบันทึก"
    case .cannotCreateWriter:
      return "เตรียมไฟล์ภาพย้อนหลังทั้งหน้าจอไม่สำเร็จ"
    case .cannotAddWriterInput:
      return "เตรียมช่องเข้ารหัสภาพหน้าจอไม่สำเร็จ"
    case .noVideoFrames:
      return "ยังไม่ได้รับภาพหน้าจอสำหรับวงนี้"
    case .recordingFailed(let detail):
      return "บันทึกภาพย้อนหลังทั้งหน้าจอไม่สำเร็จ: \(detail)"
    }
  }
}

/// The recorder owns only this lifecycle surface. Keeping it separate from the
/// ScreenCaptureKit implementation makes cancellation ordering deterministic in
/// tests without requiring screen-recording permission.
protocol GolfTraceStageCapturePipeline: AnyObject, Sendable {
  var onUnexpectedFailure: (@Sendable (Error) -> Void)? { get set }
  var frameCounters: GolfTraceStageCaptureFrameCounters { get }
  var replayClockAnchors: [SwingReplayClockAnchor] { get }

  func start() async throws
  func stop() async throws -> URL
  func requestDiscard()
  func abortAndDiscard() async
  func discardOutput()
}

extension GolfTraceStageCapturePipeline {
  /// Test doubles and capture implementations that do not expose frame timing
  /// remain source compatible. Production ScreenCaptureKit capture overrides
  /// this with anchors from frames that were actually appended to the movie.
  var replayClockAnchors: [SwingReplayClockAnchor] { [] }
}

struct GolfTraceStageCaptureFrameCounters: Equatable, Sendable {
  var received = 0
  var appended = 0
  var backpressureDrops = 0
}

struct GolfTraceCaptureDimensions: Equatable {
  let width: Int
  let height: Int

  static func aspectPreserving(
    sourceSize: CGSize,
    pointPixelScale: CGFloat
  ) -> GolfTraceCaptureDimensions? {
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

    let scale = max(1, pointPixelScale)
    let nativeWidth = sourceSize.width * scale
    let nativeHeight = sourceSize.height * scale
    let maximumDimension: CGFloat = 2_560
    let minimumWidth: CGFloat = 1_280
    let minimumHeight: CGFloat = 720

    let maximumScale = maximumDimension / max(nativeWidth, nativeHeight)
    var outputScale = min(1, maximumScale)
    if nativeWidth * outputScale < minimumWidth
      || nativeHeight * outputScale < minimumHeight
    {
      let minimumScale = max(minimumWidth / nativeWidth, minimumHeight / nativeHeight)
      if minimumScale <= maximumScale {
        outputScale = max(outputScale, minimumScale)
      }
    }

    let aspectRatio = sourceSize.width / sourceSize.height
    let outputWidth = even(max(2, Int((nativeWidth * outputScale).rounded())))
    let outputHeight = even(
      max(2, Int((CGFloat(outputWidth) / aspectRatio).rounded()))
    )
    return GolfTraceCaptureDimensions(width: outputWidth, height: outputHeight)
  }

  private static func even(_ value: Int) -> Int {
    max(2, value - value % 2)
  }
}

struct GolfTraceNormalizedRect: Codable, Equatable, Hashable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  init?(frame: CGRect, canvasSize: CGSize) {
    guard canvasSize.width > 0, canvasSize.height > 0, frame.width > 0, frame.height > 0 else {
      return nil
    }
    self.init(
      x: frame.minX / canvasSize.width,
      y: frame.minY / canvasSize.height,
      width: frame.width / canvasSize.width,
      height: frame.height / canvasSize.height
    )
    guard isValid else { return nil }
  }

  var isValid: Bool {
    [x, y, width, height].allSatisfy(\.isFinite)
      && x >= 0
      && y >= 0
      && width > 0
      && height > 0
      && x + width <= 1.001
      && y + height <= 1.001
  }

  func pixelRect(in size: CGSize) -> CGRect {
    CGRect(
      x: x * size.width,
      y: y * size.height,
      width: width * size.width,
      height: height * size.height
    ).integral
  }
}

struct GolfTraceStagePaneLayout: Codable, Equatable, Hashable, Sendable {
  let rapsodo: GolfTraceNormalizedRect
  let swingCamera: GolfTraceNormalizedRect

  init(rapsodo: GolfTraceNormalizedRect, swingCamera: GolfTraceNormalizedRect) {
    self.rapsodo = rapsodo
    self.swingCamera = swingCamera
  }

  init?(rapsodoFrame: CGRect, swingCameraFrame: CGRect, canvasSize: CGSize) {
    guard
      let rapsodo = GolfTraceNormalizedRect(frame: rapsodoFrame, canvasSize: canvasSize),
      let swingCamera = GolfTraceNormalizedRect(
        frame: swingCameraFrame,
        canvasSize: canvasSize
      )
    else { return nil }
    self.init(rapsodo: rapsodo, swingCamera: swingCamera)
  }

  var isValid: Bool {
    rapsodo.isValid && swingCamera.isValid
  }
}

struct GolfTraceStageMovieDescriptor: Equatable, Sendable {
  let canvasSize: CGSize
  let paneLayout: GolfTraceStagePaneLayout?
}

enum GolfTraceStageMovieMetadata {
  private static let canvasSizePrefix = "golftrace.canvas-size="

  static func description(
    for canvasSize: CGSize,
    paneLayout: GolfTraceStagePaneLayout? = nil
  ) -> String {
    var components = ["\(canvasSizePrefix)\(canvasSize.width),\(canvasSize.height)"]
    if let paneLayout, paneLayout.isValid {
      components.append("rapsodo=\(encoded(paneLayout.rapsodo))")
      components.append("camera=\(encoded(paneLayout.swingCamera))")
    }
    return components.joined(separator: ";")
  }

  static func canvasSize(from description: String) -> CGSize? {
    descriptor(from: description)?.canvasSize
  }

  static func paneLayout(from description: String) -> GolfTraceStagePaneLayout? {
    descriptor(from: description)?.paneLayout
  }

  static func descriptor(from description: String) -> GolfTraceStageMovieDescriptor? {
    let fields = description.split(separator: ";", omittingEmptySubsequences: false)
    guard let canvasField = fields.first, canvasField.hasPrefix(canvasSizePrefix) else {
      return nil
    }
    let components = canvasField.dropFirst(canvasSizePrefix.count)
      .split(separator: ",", omittingEmptySubsequences: false)
    guard components.count == 2,
      let width = Double(components[0]),
      let height = Double(components[1]),
      width.isFinite,
      height.isFinite,
      width > 0,
      height > 0
    else {
      return nil
    }
    let canvasSize = CGSize(width: CGFloat(width), height: CGFloat(height))
    // Treat malformed duplicate metadata fields as invalid instead of using
    // `Dictionary(uniqueKeysWithValues:)`, which traps on duplicate keys.
    var values: [String: Substring] = [:]
    for field in fields.dropFirst() {
      guard let separator = field.firstIndex(of: "=") else { continue }
      let key = String(field[..<separator])
      guard values[key] == nil else { return nil }
      values[key] = field[field.index(after: separator)...]
    }
    let paneLayout: GolfTraceStagePaneLayout?
    if let rapsodoValue = values["rapsodo"], let cameraValue = values["camera"],
      let rapsodo = decoded(rapsodoValue), let camera = decoded(cameraValue)
    {
      let candidate = GolfTraceStagePaneLayout(rapsodo: rapsodo, swingCamera: camera)
      paneLayout = candidate.isValid ? candidate : nil
    } else {
      paneLayout = nil
    }
    return GolfTraceStageMovieDescriptor(canvasSize: canvasSize, paneLayout: paneLayout)
  }

  private static func encoded(_ rect: GolfTraceNormalizedRect) -> String {
    [rect.x, rect.y, rect.width, rect.height].map { String($0) }.joined(separator: ",")
  }

  private static func decoded(_ value: Substring) -> GolfTraceNormalizedRect? {
    let components = value.split(separator: ",", omittingEmptySubsequences: false)
    guard components.count == 4,
      let x = Double(components[0]),
      let y = Double(components[1]),
      let width = Double(components[2]),
      let height = Double(components[3])
    else { return nil }
    let rect = GolfTraceNormalizedRect(x: x, y: y, width: width, height: height)
    return rect.isValid ? rect : nil
  }
}

/// Records the WindowServer-composited GolfTrace window. The resulting movie
/// therefore contains the Rapsodo pane, iPhone camera, skeleton, hand trace and
/// selected guideline exactly as they appeared together during the swing.
@MainActor
final class GolfTraceStageReplayRecorder: ObservableObject {
  typealias Completion = @MainActor (Result<URL, Error>) -> Void
  typealias WindowNumberProvider = @MainActor () -> Int?
  typealias PipelineFactory = @MainActor (Int) async throws -> any GolfTraceStageCapturePipeline
  private typealias LayoutAwarePipelineFactory =
    @MainActor (
      Int, GolfTraceStagePaneLayout?
    ) async throws -> any GolfTraceStageCapturePipeline

  @Published private(set) var isPreparing = false
  @Published private(set) var isRecording = false
  @Published private(set) var statusText = "พร้อมบันทึกภาพย้อนหลังทั้งหน้าจอ"
  @Published private(set) var frameCounters = GolfTraceStageCaptureFrameCounters()
  private(set) var lastCompletedReplayClockAnchors: [SwingReplayClockAnchor] = []
  private(set) var lastCompletedPaneLayout: GolfTraceStagePaneLayout?

  private let windowNumberProvider: WindowNumberProvider
  private let pipelineFactory: LayoutAwarePipelineFactory
  private var pipeline: (any GolfTraceStageCapturePipeline)?
  private var startTask: Task<Void, Never>?
  private var stopCompletion: Completion?
  private var stopRequested = false
  private var isStopping = false
  private var shouldDiscardOutput = false
  private var drainContinuations: [CheckedContinuation<Void, Never>] = []
  private var activeCaptureID: UUID?
  private var configuredPaneLayout: GolfTraceStagePaneLayout?
  private var activePaneLayout: GolfTraceStagePaneLayout?

  init() {
    windowNumberProvider = GolfTraceStageReplayRecorder.mainWindowNumber
    pipelineFactory = { windowNumber, paneLayout in
      try await GolfTraceWindowCapturePipeline.make(
        windowNumber: windowNumber,
        paneLayout: paneLayout
      )
    }
  }

  init(
    windowNumberProvider: @escaping WindowNumberProvider,
    pipelineFactory: @escaping PipelineFactory
  ) {
    self.windowNumberProvider = windowNumberProvider
    self.pipelineFactory = { windowNumber, _ in
      try await pipelineFactory(windowNumber)
    }
  }

  deinit {
    startTask?.cancel()
  }

  var hasPendingWork: Bool {
    pipeline != nil || startTask != nil || isStopping
  }

  func updatePaneLayout(_ paneLayout: GolfTraceStagePaneLayout?) {
    guard paneLayout?.isValid != false else { return }
    if hasPendingWork, activePaneLayout != paneLayout {
      // The movie metadata was fixed when the pipeline was created. If the
      // user resizes or drags the divider during this take, retaining the old
      // coordinates would crop the wrong pixels. Keep the movie, but omit PIP
      // metadata so replay safely falls back to the complete window.
      activePaneLayout = nil
    }
    configuredPaneLayout = paneLayout
  }

  func prepareForTermination() {
    cancelUnfinishedRecording()
  }

  func flushPendingWork() async {
    guard hasPendingWork else { return }
    await withCheckedContinuation { continuation in
      drainContinuations.append(continuation)
    }
  }

  func startIfNeeded() {
    // Never start a replacement capture after teardown. It would begin in the
    // middle of the new swing and look complete even though its address and
    // takeaway are missing. That swing must use the raw-camera fallback.
    guard !isStopping, !stopRequested else { return }
    guard pipeline == nil, startTask == nil else { return }
    guard let windowNumber = windowNumberProvider() else {
      statusText = GolfTraceStageReplayRecorderError.noMainWindow.localizedDescription
      return
    }

    isPreparing = true
    frameCounters = GolfTraceStageCaptureFrameCounters()
    lastCompletedReplayClockAnchors = []
    lastCompletedPaneLayout = nil
    stopRequested = false
    shouldDiscardOutput = false
    let captureID = UUID()
    activeCaptureID = captureID
    activePaneLayout = configuredPaneLayout
    statusText = "กำลังเตรียมบันทึก Rapsodo กล้อง และเส้นวิเคราะห์…"

    startTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var createdPipeline: (any GolfTraceStageCapturePipeline)?
      do {
        let newPipeline = try await pipelineFactory(windowNumber, activePaneLayout)
        createdPipeline = newPipeline
        guard self.activeCaptureID == captureID else {
          await newPipeline.abortAndDiscard()
          return
        }
        if Task.isCancelled || (self.stopRequested && self.shouldDiscardOutput) {
          self.isStopping = true
          newPipeline.requestDiscard()
          await newPipeline.abortAndDiscard()
          guard self.activeCaptureID == captureID else { return }
          self.frameCounters = newPipeline.frameCounters
          self.finish(with: nil)
          return
        }

        newPipeline.onUnexpectedFailure = { [weak self, weak newPipeline] error in
          Task { @MainActor [weak self, weak newPipeline] in
            guard let self,
              self.activeCaptureID == captureID,
              self.pipeline === newPipeline
            else {
              return
            }
            guard !self.isStopping, let newPipeline else { return }
            self.isStopping = true
            self.isRecording = false
            if self.shouldDiscardOutput {
              newPipeline.requestDiscard()
            }
            await newPipeline.abortAndDiscard()
            guard self.activeCaptureID == captureID,
              self.pipeline === newPipeline
            else {
              return
            }
            self.frameCounters = newPipeline.frameCounters
            self.finish(with: self.shouldDiscardOutput ? nil : .failure(error))
          }
        }
        pipeline = newPipeline
        try Task.checkCancellation()
        try await newPipeline.start()
        if Task.isCancelled || (stopRequested && shouldDiscardOutput) {
          isStopping = true
          newPipeline.requestDiscard()
          await newPipeline.abortAndDiscard()
          guard activeCaptureID == captureID,
            pipeline === newPipeline
          else {
            return
          }
          frameCounters = newPipeline.frameCounters
          finish(with: nil)
          return
        }
        guard activeCaptureID == captureID,
          pipeline === newPipeline,
          !isStopping
        else {
          return
        }
        startTask = nil
        isPreparing = false
        isRecording = true
        statusText = "กำลังบันทึกทั้งหน้าจอ GolfTrace สำหรับภาพย้อนหลัง"

        if stopRequested {
          requestPipelineStop()
        }
      } catch {
        guard activeCaptureID == captureID else {
          if let createdPipeline {
            await createdPipeline.abortAndDiscard()
          }
          return
        }
        if Task.isCancelled || shouldDiscardOutput || error is CancellationError {
          isStopping = true
          if let createdPipeline {
            createdPipeline.requestDiscard()
            await createdPipeline.abortAndDiscard()
          }
          guard activeCaptureID == captureID,
            createdPipeline == nil || pipeline == nil || pipeline === createdPipeline
          else {
            return
          }
          if let createdPipeline {
            frameCounters = createdPipeline.frameCounters
          }
          finish(with: nil)
          return
        }
        // An unexpected-failure task already owns cleanup/finalization.
        guard !isStopping else { return }
        isStopping = true
        if let createdPipeline {
          await createdPipeline.abortAndDiscard()
        }
        guard activeCaptureID == captureID,
          createdPipeline == nil || pipeline === createdPipeline
        else {
          return
        }
        if let createdPipeline {
          frameCounters = createdPipeline.frameCounters
        }
        startTask = nil
        isPreparing = false
        isRecording = false
        statusText = error.localizedDescription
        finish(with: .failure(error))
      }
    }
  }

  /// Returns `false` when no composited recording was in flight; callers may
  /// then use the legacy raw-camera replay as a compatibility fallback.
  @discardableResult
  func finishRecording(_ completion: @escaping Completion) -> Bool {
    guard pipeline != nil || startTask != nil else { return false }
    guard !stopRequested, !isStopping, stopCompletion == nil else {
      // This swing finished while the previous movie was still closing. Its
      // caller will use raw-camera fallback.
      return false
    }
    stopCompletion = completion
    stopRequested = true
    shouldDiscardOutput = false
    statusText = "กำลังปิดไฟล์ภาพย้อนหลังทั้งหน้าจอ…"
    requestPipelineStop()
    return true
  }

  func cancelRecording() {
    guard pipeline != nil || startTask != nil else { return }
    stopRequested = true
    shouldDiscardOutput = true
    stopCompletion = nil
    pipeline?.requestDiscard()
    startTask?.cancel()
    requestPipelineStop()
  }

  /// Closing the view should discard only a capture that has not produced a
  /// swing result. A recording already finalizing must keep its completion so
  /// history persistence can finish safely.
  func cancelUnfinishedRecording() {
    guard stopCompletion == nil else {
      return
    }
    cancelRecording()
  }

  private func requestPipelineStop() {
    guard stopRequested,
      startTask == nil,
      !isStopping,
      let activePipeline = pipeline,
      let captureID = activeCaptureID
    else {
      return
    }
    isStopping = true
    isRecording = false

    Task { @MainActor [weak self, weak activePipeline] in
      guard let self, let activePipeline else { return }
      if self.shouldDiscardOutput {
        activePipeline.requestDiscard()
        await activePipeline.abortAndDiscard()
        guard self.activeCaptureID == captureID,
          self.pipeline === activePipeline
        else {
          return
        }
        self.frameCounters = activePipeline.frameCounters
        self.finish(with: nil)
        return
      }
      do {
        let outputURL = try await activePipeline.stop()
        guard self.activeCaptureID == captureID,
          self.pipeline === activePipeline
        else {
          activePipeline.discardOutput()
          return
        }
        if self.shouldDiscardOutput {
          await activePipeline.abortAndDiscard()
          self.frameCounters = activePipeline.frameCounters
          self.finish(with: nil)
        } else {
          self.frameCounters = activePipeline.frameCounters
          self.finish(with: .success(outputURL))
        }
      } catch {
        guard self.activeCaptureID == captureID,
          self.pipeline === activePipeline
        else {
          return
        }
        if self.shouldDiscardOutput {
          await activePipeline.abortAndDiscard()
          guard self.activeCaptureID == captureID,
            self.pipeline === activePipeline
          else {
            return
          }
          self.frameCounters = activePipeline.frameCounters
          self.finish(with: nil)
        } else {
          self.frameCounters = activePipeline.frameCounters
          activePipeline.discardOutput()
          self.finish(with: .failure(error))
        }
      }
    }
  }

  private static func mainWindowNumber() -> Int? {
    let rootWindows = NSApp.windows.filter { window in
      window.isVisible && window.parent == nil && window.level == .normal
    }
    let largestRootWindow = rootWindows.max { first, second in
      first.frame.width * first.frame.height < second.frame.width * second.frame.height
    }
    let mainWindow = NSApp.mainWindow?.parent ?? NSApp.mainWindow
    let keyWindow = NSApp.keyWindow?.parent ?? NSApp.keyWindow
    return (largestRootWindow ?? mainWindow ?? keyWindow)?.windowNumber
  }

  private func finish(with result: Result<URL, Error>?) {
    let completion = stopCompletion
    if case .success? = result {
      lastCompletedReplayClockAnchors = pipeline?.replayClockAnchors ?? []
      lastCompletedPaneLayout = activePaneLayout
    } else {
      lastCompletedReplayClockAnchors = []
      lastCompletedPaneLayout = nil
    }
    stopCompletion = nil
    pipeline = nil
    startTask = nil
    stopRequested = false
    isStopping = false
    isPreparing = false
    isRecording = false
    shouldDiscardOutput = false
    activeCaptureID = nil
    activePaneLayout = nil

    if let result {
      switch result {
      case .success:
        statusText = "ภาพย้อนหลังทั้งหน้าจอพร้อมแล้ว"
      case .failure(let error):
        statusText = error.localizedDescription
      }
      if let completion {
        completion(result)
      }
    } else {
      statusText = "ยกเลิกการบันทึกวงที่ไม่สมบูรณ์แล้ว"
    }

    resumeDrainContinuationsIfNeeded()
  }

  private func resumeDrainContinuationsIfNeeded() {
    guard !hasPendingWork, !drainContinuations.isEmpty else { return }
    let continuations = drainContinuations
    drainContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }
}

/// Owns one ScreenCaptureKit stream and one real-time AVAssetWriter. All
/// mutable writer state is confined to `writerQueue`.
private final class GolfTraceWindowCapturePipeline: NSObject, GolfTraceStageCapturePipeline,
  @unchecked Sendable
{
  private let failureCallbackLock = NSLock()
  private var failureCallback: (@Sendable (Error) -> Void)?

  var onUnexpectedFailure: (@Sendable (Error) -> Void)? {
    get {
      failureCallbackLock.lock()
      defer { failureCallbackLock.unlock() }
      return failureCallback
    }
    set {
      failureCallbackLock.lock()
      failureCallback = newValue
      failureCallbackLock.unlock()
    }
  }

  let outputURL: URL
  private let teardownLock = NSLock()
  private var stream: SCStream?
  private var teardownTask: Task<URL, Error>?
  private var discardRequested = false
  private let writer: AVAssetWriter
  private let writerInput: AVAssetWriterInput
  private let writerQueue = DispatchQueue(
    label: "com.bda.golftrace.stage-replay-writer",
    qos: .userInitiated
  )
  private var hasStartedWriting = false
  private var hasAppendedFrame = false
  private var receivedFrameCount = 0
  private var appendedFrameCount = 0
  private var backpressureDropCount = 0
  private let replayClockAnchorBuffer = SwingReplayClockAnchorBuffer()
  private var writerSessionStartTimestamp: CMTime?
  /// A terminal writer gate, not merely an indication that AVAssetWriter is
  /// currently inside `finishWriting`. It is set before stopping SCStream so
  /// late ScreenCaptureKit callbacks can never append another frame.
  private var isFinishing = false
  private var hasStartedFinalizingWriter = false

  var frameCounters: GolfTraceStageCaptureFrameCounters {
    writerQueue.sync {
      GolfTraceStageCaptureFrameCounters(
        received: receivedFrameCount,
        appended: appendedFrameCount,
        backpressureDrops: backpressureDropCount
      )
    }
  }

  var replayClockAnchors: [SwingReplayClockAnchor] {
    replayClockAnchorBuffer.snapshot()
  }

  private init(
    filter: SCContentFilter,
    configuration: SCStreamConfiguration,
    outputURL: URL,
    sourceCanvasSize: CGSize,
    paneLayout: GolfTraceStagePaneLayout?,
    width: Int,
    height: Int
  ) throws {
    self.outputURL = outputURL
    do {
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      throw GolfTraceStageReplayRecorderError.cannotCreateWriter
    }

    let canvasMetadata = AVMutableMetadataItem()
    canvasMetadata.identifier = .quickTimeMetadataDescription
    canvasMetadata.value =
      GolfTraceStageMovieMetadata.description(
        for: sourceCanvasSize,
        paneLayout: paneLayout
      ) as NSString
    canvasMetadata.dataType = kCMMetadataBaseDataType_UTF8 as String
    writer.metadata = [canvasMetadata]

    let bitRate = min(24_000_000, max(10_000_000, width * height * 5))
    writerInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitRate,
          AVVideoExpectedSourceFrameRateKey: 60,
          AVVideoMaxKeyFrameIntervalKey: 120,
          AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ]
    )
    writerInput.expectsMediaDataInRealTime = true
    guard writer.canAdd(writerInput) else {
      throw GolfTraceStageReplayRecorderError.cannotAddWriterInput
    }
    writer.add(writerInput)

    super.init()
    let captureStream = SCStream(
      filter: filter,
      configuration: configuration,
      delegate: self
    )
    try captureStream.addStreamOutput(
      self,
      type: .screen,
      sampleHandlerQueue: writerQueue
    )
    stream = captureStream
  }

  static func make(
    windowNumber: Int,
    paneLayout: GolfTraceStagePaneLayout?
  ) async throws -> GolfTraceWindowCapturePipeline {
    let shareableContent = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard
      let window = shareableContent.windows.first(where: {
        Int($0.windowID) == windowNumber
      })
    else {
      throw GolfTraceStageReplayRecorderError.windowNotShareable
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let sourceSize = filter.contentRect.size
    guard
      let outputDimensions = GolfTraceCaptureDimensions.aspectPreserving(
        sourceSize: sourceSize,
        pointPixelScale: CGFloat(filter.pointPixelScale)
      )
    else {
      throw GolfTraceStageReplayRecorderError.windowNotShareable
    }

    let configuration = SCStreamConfiguration()
    configuration.width = outputDimensions.width
    configuration.height = outputDimensions.height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    configuration.queueDepth = 3
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = false
    configuration.capturesAudio = false
    configuration.scalesToFit = true
    configuration.preservesAspectRatio = true

    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-วงล่าสุด-stage-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    try? FileManager.default.removeItem(at: outputURL)

    return try GolfTraceWindowCapturePipeline(
      filter: filter,
      configuration: configuration,
      outputURL: outputURL,
      sourceCanvasSize: sourceSize,
      paneLayout: paneLayout,
      width: outputDimensions.width,
      height: outputDimensions.height
    )
  }

  func start() async throws {
    guard let activeStream = currentStream() else {
      throw GolfTraceStageReplayRecorderError.recordingFailed(
        "ตัวบันทึกหน้าจอถูกปิดไปแล้ว"
      )
    }
    try await activeStream.startCapture()
  }

  func stop() async throws -> URL {
    let finalizedURL = try await sharedTeardownTask(discard: false).value
    guard !isDiscardRequested else { throw CancellationError() }
    return finalizedURL
  }

  func abortAndDiscard() async {
    let task = sharedTeardownTask(discard: true)
    _ = try? await task.value
    discardOutput()
  }

  /// Deletes an output whose capture has already stopped. Active captures must
  /// use `abortAndDiscard()` so ScreenCaptureKit is detached as well.
  func discardOutput() {
    requestDiscard()
    clearFailureCallback()
    writerQueue.sync {
      self.isFinishing = true
      if !self.hasStartedFinalizingWriter,
        self.writer.status == .unknown || self.writer.status == .writing
      {
        self.writer.cancelWriting()
      }
    }
    try? FileManager.default.removeItem(at: outputURL)
  }

  private func sharedTeardownTask(discard: Bool) -> Task<URL, Error> {
    teardownLock.lock()
    defer { teardownLock.unlock() }

    if discard {
      discardRequested = true
    }
    if let teardownTask {
      return teardownTask
    }

    let task = Task { [self] in
      try await performTeardown()
    }
    teardownTask = task
    return task
  }

  private func performTeardown() async throws -> URL {
    // This sync barrier drains callbacks already queued and closes the writer
    // gate before `stopCapture()` can yield back to ScreenCaptureKit.
    writerQueue.sync {
      self.isFinishing = true
    }
    clearFailureCallback()

    guard let activeStream = takeStreamForTeardown() else {
      cancelWriterAndRemoveOutput()
      throw GolfTraceStageReplayRecorderError.recordingFailed(
        "ตัวบันทึกหน้าจอถูกปิดไปแล้ว"
      )
    }

    var stopError: Error?
    do {
      try await activeStream.stopCapture()
    } catch {
      stopError = error
    }

    // Removing the output is required even when stopCapture throws. The
    // terminal writer gate above makes any callback racing this removal inert.
    try? activeStream.removeStreamOutput(self, type: .screen)

    if isDiscardRequested {
      cancelWriterAndRemoveOutput()
      throw CancellationError()
    }
    if let stopError {
      cancelWriterAndRemoveOutput()
      throw GolfTraceStageReplayRecorderError.recordingFailed(
        stopError.localizedDescription
      )
    }

    let finalizedURL = try await finalizeWriter()
    // Abort may have arrived while AVAssetWriter was finalizing. In that case
    // abort wins and no caller receives a URL that is about to be deleted.
    if isDiscardRequested {
      discardOutput()
      throw CancellationError()
    }
    return finalizedURL
  }

  private func finalizeWriter() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      writerQueue.async { [weak self] in
        guard let self else {
          continuation.resume(throwing: GolfTraceStageReplayRecorderError.noVideoFrames)
          return
        }
        guard !self.hasStartedFinalizingWriter else {
          continuation.resume(
            throwing: GolfTraceStageReplayRecorderError.recordingFailed("กำลังปิดไฟล์ซ้ำ")
          )
          return
        }

        // Serialize the final discard check with `requestDiscard()`. If
        // cancellation wins this gate, no finishWriting call may begin.
        self.teardownLock.lock()
        let shouldDiscardBeforeFinalizing = self.discardRequested
        if !shouldDiscardBeforeFinalizing {
          self.hasStartedFinalizingWriter = true
        }
        self.teardownLock.unlock()
        if shouldDiscardBeforeFinalizing {
          if self.writer.status == .unknown || self.writer.status == .writing {
            self.writer.cancelWriting()
          }
          try? FileManager.default.removeItem(at: self.outputURL)
          continuation.resume(throwing: CancellationError())
          return
        }

        guard self.hasStartedWriting, self.hasAppendedFrame else {
          self.writer.cancelWriting()
          continuation.resume(throwing: GolfTraceStageReplayRecorderError.noVideoFrames)
          return
        }

        self.writerInput.markAsFinished()
        self.writer.finishWriting { [weak self] in
          guard let self else {
            continuation.resume(throwing: GolfTraceStageReplayRecorderError.noVideoFrames)
            return
          }
          if self.writer.status == .completed {
            continuation.resume(returning: self.outputURL)
          } else {
            continuation.resume(
              throwing: GolfTraceStageReplayRecorderError.recordingFailed(
                self.writer.error?.localizedDescription ?? "ไม่ทราบสาเหตุ"
              )
            )
          }
        }
      }
    }
  }

  private func cancelWriterAndRemoveOutput() {
    writerQueue.sync {
      self.isFinishing = true
      if !self.hasStartedFinalizingWriter,
        self.writer.status == .unknown || self.writer.status == .writing
      {
        self.writer.cancelWriting()
      }
    }
    try? FileManager.default.removeItem(at: outputURL)
  }

  private func currentStream() -> SCStream? {
    teardownLock.lock()
    defer { teardownLock.unlock() }
    return stream
  }

  private func takeStreamForTeardown() -> SCStream? {
    teardownLock.lock()
    defer { teardownLock.unlock() }
    let activeStream = stream
    stream = nil
    return activeStream
  }

  func requestDiscard() {
    teardownLock.lock()
    discardRequested = true
    teardownLock.unlock()
  }

  private var isDiscardRequested: Bool {
    teardownLock.lock()
    defer { teardownLock.unlock() }
    return discardRequested
  }

  private func clearFailureCallback() {
    onUnexpectedFailure = nil
  }

  /// Must be called on `writerQueue`. Closing the writer gate before invoking
  /// the owner prevents a burst of callbacks from reporting the same fatal
  /// encoder/stream failure while the asynchronous abort is being scheduled.
  private func reportUnexpectedFailure(_ error: Error) {
    guard !isFinishing else { return }
    isFinishing = true
    onUnexpectedFailure?(error)
  }

}

extension GolfTraceWindowCapturePipeline: SCStreamOutput, SCStreamDelegate {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    receivedFrameCount += 1

    guard
      !isFinishing,
      sampleBuffer.isValid,
      sampleBuffer.dataReadiness == .ready,
      CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
      Self.frameStatus(of: sampleBuffer) == .complete
    else {
      return
    }

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard timestamp.isValid else { return }
    let monotonicReceiptTime = ProcessInfo.processInfo.systemUptime

    if !hasStartedWriting {
      guard writer.startWriting() else {
        let failure = GolfTraceStageReplayRecorderError.recordingFailed(
          writer.error?.localizedDescription ?? "เริ่มตัวเข้ารหัสไม่สำเร็จ"
        )
        reportUnexpectedFailure(failure)
        return
      }
      writer.startSession(atSourceTime: timestamp)
      writerSessionStartTimestamp = timestamp
      hasStartedWriting = true
    }

    guard writer.status == .writing else { return }
    guard writerInput.isReadyForMoreMediaData else {
      backpressureDropCount += 1
      return
    }
    if writerInput.append(sampleBuffer) {
      hasAppendedFrame = true
      appendedFrameCount += 1
      if let writerSessionStartTimestamp {
        let replayTimestamp = timestamp - writerSessionStartTimestamp
        _ = replayClockAnchorBuffer.append(
          mediaTime: replayTimestamp,
          monotonicTimeSeconds: monotonicReceiptTime
        )
      }
    } else if let error = writer.error {
      let failure = GolfTraceStageReplayRecorderError.recordingFailed(
        error.localizedDescription
      )
      reportUnexpectedFailure(failure)
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    writerQueue.async { [weak self] in
      guard let self, !self.isFinishing else { return }
      let wrapped = GolfTraceStageReplayRecorderError.recordingFailed(
        error.localizedDescription
      )
      self.reportUnexpectedFailure(wrapped)
    }
  }

  private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[SCStreamFrameInfo: Any]],
      let frameAttachment = attachments.first,
      let statusNumber = frameAttachment[.status] as? NSNumber
    else {
      return nil
    }
    return SCFrameStatus(rawValue: statusNumber.intValue)
  }
}
