@preconcurrency import AVFoundation
import Combine
@preconcurrency import CoreMedia
import CoreVideo
import Foundation

enum RapsodoReplaySourceKind: Equatable, Sendable {
  case appleMirroring(windowID: UInt32)
  case usb(deviceID: String)

  var displayName: String {
    switch self {
    case .appleMirroring:
      return "Apple iPhone Mirroring"
    case .usb:
      return "Rapsodo USB"
    }
  }
}

struct RapsodoReplaySourceSession: Equatable, Sendable {
  let sourceKind: RapsodoReplaySourceKind
  let generationID: UInt64
}

enum RapsodoReplayPixelOrientation: String, Codable, Equatable, Sendable {
  case landscape
  case portrait
  case square

  init(width: Int, height: Int) {
    if width > height {
      self = .landscape
    } else if height > width {
      self = .portrait
    } else {
      self = .square
    }
  }
}

struct RapsodoReplayVideoFormat: Equatable, Sendable {
  let width: Int
  let height: Int
  let pixelFormat: OSType
  let orientation: RapsodoReplayPixelOrientation

  init(width: Int, height: Int, pixelFormat: OSType) {
    self.width = width
    self.height = height
    self.pixelFormat = pixelFormat
    orientation = RapsodoReplayPixelOrientation(width: width, height: height)
  }

  init?(sampleBuffer: CMSampleBuffer) {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
    self.init(
      width: CVPixelBufferGetWidth(imageBuffer),
      height: CVPixelBufferGetHeight(imageBuffer),
      pixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer)
    )
  }
}

struct RapsodoReplayFrameCounters: Equatable, Sendable {
  var received = 0
  var appended = 0
  var ingressDrops = 0
  var throttleDrops = 0
  var backpressureDrops = 0
  var invalidFrameDrops = 0
  var sourceMismatchDrops = 0
  var formatMismatchDrops = 0
}

struct RapsodoReplayExportResult: Sendable {
  let url: URL
  let sourceKind: RapsodoReplaySourceKind
  let generationID: UInt64
  let format: RapsodoReplayVideoFormat
  let duration: TimeInterval
  let anchors: [SwingReplayClockAnchor]
  let counters: RapsodoReplayFrameCounters
}

enum RapsodoSourceReplayRecorderError: Error, Equatable, LocalizedError, Sendable {
  case alreadyRecording
  case notRecording
  case noVideoFrames
  case cancelled
  case cannotCreateWriter(String)
  case cannotAddWriterInput
  case cannotStartWriter(String)
  case appendFailed(String)
  case finishTimedOut
  case finishFailed(String)

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      return "กำลังบันทึกภาพ Rapsodo อยู่แล้ว"
    case .notRecording:
      return "ยังไม่ได้เริ่มบันทึกภาพ Rapsodo"
    case .noVideoFrames:
      return "ยังไม่มีภาพ Rapsodo สำหรับสร้างวิดีโอ"
    case .cancelled:
      return "ยกเลิกการบันทึกภาพ Rapsodo แล้ว"
    case .cannotCreateWriter(let detail):
      return "สร้างไฟล์ภาพ Rapsodo ไม่สำเร็จ: \(detail)"
    case .cannotAddWriterInput:
      return "เตรียมช่องเข้ารหัสภาพ Rapsodo ไม่สำเร็จ"
    case .cannotStartWriter(let detail):
      return "เริ่มเขียนภาพ Rapsodo ไม่สำเร็จ: \(detail)"
    case .appendFailed(let detail):
      return "เขียนเฟรม Rapsodo ไม่สำเร็จ: \(detail)"
    case .finishTimedOut:
      return "ปิดไฟล์ภาพ Rapsodo ใช้เวลานานเกิน 12 วินาที"
    case .finishFailed(let detail):
      return "ปิดไฟล์ภาพ Rapsodo ไม่สำเร็จ: \(detail)"
    }
  }
}

/// Retains a CoreMedia buffer while it crosses from a source callback into the
/// recorder's bounded writer queue. The source callback captures Mac uptime
/// immediately, before preview rendering or any MainActor publication.
final class RapsodoReplaySample: @unchecked Sendable {
  let sampleBuffer: CMSampleBuffer
  let sourceSession: RapsodoReplaySourceSession
  let monotonicTimeSeconds: Double

  init(
    sampleBuffer: CMSampleBuffer,
    sourceSession: RapsodoReplaySourceSession,
    monotonicTimeSeconds: Double = ProcessInfo.processInfo.systemUptime
  ) {
    self.sampleBuffer = sampleBuffer
    self.sourceSession = sourceSession
    self.monotonicTimeSeconds = monotonicTimeSeconds
  }
}

typealias RapsodoReplaySampleHandler = @Sendable (RapsodoReplaySample) -> Void

/// MainActor owns only recording lifecycle state. Every frame enters the
/// nonisolated bounded writer below, so a 60 Hz source never schedules UI work.
@MainActor
final class RapsodoSourceReplayRecorder: ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var isFinalizing = false
  @Published private(set) var isSourceFresh = false
  @Published private(set) var activeSourceKind: RapsodoReplaySourceKind?
  @Published private(set) var lastStatusText = "พร้อมบันทึกภาพ Rapsodo แยก"

  var hasPendingWork: Bool { isRecording || isFinalizing }

  private let writer: RapsodoSourceReplayWriter
  private let freshnessMonitor = RapsodoSourceFreshnessMonitor()
  private var lifecycleGeneration: UInt64 = 0
  private var freshnessPollingTask: Task<Void, Never>?

  private static let sourceFreshnessMaximumAgeSeconds: TimeInterval = 0.75
  private static let sourceFreshnessPollingInterval = Duration.milliseconds(200)

  init(outputDirectory: URL = FileManager.default.temporaryDirectory) {
    writer = RapsodoSourceReplayWriter(outputDirectory: outputDirectory)
  }

  func start(
    sourceKind: RapsodoReplaySourceKind,
    generationID: UInt64
  ) throws {
    guard !hasPendingWork else {
      throw RapsodoSourceReplayRecorderError.alreadyRecording
    }

    let sourceSession = RapsodoReplaySourceSession(
      sourceKind: sourceKind,
      generationID: generationID
    )
    try writer.start(sourceSession: sourceSession)
    freshnessMonitor.begin(sourceSession: sourceSession)
    lifecycleGeneration &+= 1
    activeSourceKind = sourceKind
    isRecording = true
    isFinalizing = false
    isSourceFresh = false
    lastStatusText = "กำลังบันทึกภาพจาก \(sourceKind.displayName)"
    beginFreshnessPolling()
  }

  nonisolated func append(
    sampleBuffer: CMSampleBuffer,
    sourceKind: RapsodoReplaySourceKind,
    generationID: UInt64,
    monotonicTimeSeconds: Double = ProcessInfo.processInfo.systemUptime
  ) {
    append(
      RapsodoReplaySample(
        sampleBuffer: sampleBuffer,
        sourceSession: RapsodoReplaySourceSession(
          sourceKind: sourceKind,
          generationID: generationID
        ),
        monotonicTimeSeconds: monotonicTimeSeconds
      )
    )
  }

  nonisolated func append(_ sample: RapsodoReplaySample) {
    freshnessMonitor.observe(sample)
    writer.offer(sample)
  }

  /// Pulls one freshness snapshot from the lock-backed ingress monitor. The
  /// regular caller is a 5 Hz MainActor poll; tests can pass a fixed monotonic
  /// time to verify source/generation matching without sleeping.
  func refreshSourceFreshness(
    nowMonotonicTimeSeconds: Double = ProcessInfo.processInfo.systemUptime
  ) {
    let refreshedValue =
      isRecording
      && freshnessMonitor.isFresh(
        nowMonotonicTimeSeconds: nowMonotonicTimeSeconds,
        maximumAgeSeconds: Self.sourceFreshnessMaximumAgeSeconds
      )
    if isSourceFresh != refreshedValue {
      isSourceFresh = refreshedValue
    }
  }

  func finish() async -> Result<
    RapsodoReplayExportResult, RapsodoSourceReplayRecorderError
  > {
    guard isRecording else {
      return .failure(.notRecording)
    }

    let finishingGeneration = lifecycleGeneration
    isRecording = false
    isFinalizing = true
    stopFreshnessPolling()
    freshnessMonitor.end()
    isSourceFresh = false
    lastStatusText = "กำลังปิดไฟล์ภาพ Rapsodo…"
    let result = await writer.finish()

    guard lifecycleGeneration == finishingGeneration else { return result }
    isFinalizing = false
    activeSourceKind = nil
    switch result {
    case .success:
      lastStatusText = "ไฟล์ภาพ Rapsodo แยกพร้อมแล้ว"
    case .failure(let error):
      lastStatusText = error.localizedDescription
    }
    return result
  }

  func cancel() {
    lifecycleGeneration &+= 1
    writer.cancel()
    stopFreshnessPolling()
    freshnessMonitor.end()
    isRecording = false
    isFinalizing = false
    isSourceFresh = false
    activeSourceKind = nil
    lastStatusText = RapsodoSourceReplayRecorderError.cancelled.localizedDescription
  }

  /// An unfinished take has no record to attach to, so termination discards it.
  /// A finalizing take is owned by `SwingReplayBundleWorkTracker` and is allowed
  /// to reach its atomic History commit.
  func prepareForTermination() {
    if isRecording {
      cancel()
    }
  }

  func flushPendingWork() async {
    while isFinalizing {
      await writer.flushPendingFrames()
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// A deterministic queue barrier used by focused tests and orderly teardown.
  /// It does not publish UI state and performs no work on the MainActor.
  func flushPendingFrames() async {
    await writer.flushPendingFrames()
  }

  private func beginFreshnessPolling() {
    freshnessPollingTask?.cancel()
    freshnessPollingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, self.isRecording else { return }
        self.refreshSourceFreshness()
        try? await Task.sleep(for: Self.sourceFreshnessPollingInterval)
      }
    }
  }

  private func stopFreshnessPolling() {
    freshnessPollingTask?.cancel()
    freshnessPollingTask = nil
  }
}

private final class RapsodoSourceFreshnessMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private var expectedSourceSession: RapsodoReplaySourceSession?
  private var lastMatchingSampleTimeSeconds: Double?

  func begin(sourceSession: RapsodoReplaySourceSession) {
    lock.withLock {
      expectedSourceSession = sourceSession
      lastMatchingSampleTimeSeconds = nil
    }
  }

  func observe(_ sample: RapsodoReplaySample) {
    lock.withLock {
      guard sample.sourceSession == expectedSourceSession,
        sample.monotonicTimeSeconds.isFinite
      else { return }
      lastMatchingSampleTimeSeconds = sample.monotonicTimeSeconds
    }
  }

  func isFresh(
    nowMonotonicTimeSeconds: Double,
    maximumAgeSeconds: TimeInterval
  ) -> Bool {
    lock.withLock {
      guard expectedSourceSession != nil,
        let lastMatchingSampleTimeSeconds,
        nowMonotonicTimeSeconds.isFinite
      else { return false }
      let ageSeconds = nowMonotonicTimeSeconds - lastMatchingSampleTimeSeconds
      return ageSeconds >= 0 && ageSeconds <= maximumAgeSeconds
    }
  }

  func end() {
    lock.withLock {
      expectedSourceSession = nil
      lastMatchingSampleTimeSeconds = nil
    }
  }
}

private final class RapsodoSourceReplayWriter: @unchecked Sendable {
  private let outputDirectory: URL
  private let writerQueue = DispatchQueue(
    label: "com.bda.golftrace.rapsodo-source-replay",
    qos: .userInitiated
  )
  private let ingressLock = NSLock()
  private var acceptsSamples = false
  private var pendingSample: RapsodoReplaySample?
  private var isDrainScheduled = false
  private var offeredFrameCount = 0
  private var ingressDropCount = 0

  // Accessed only on writerQueue.
  private var sourceSession: RapsodoReplaySourceSession?
  private var outputURL: URL?
  private var assetWriter: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var frozenSourceFormat: RapsodoReplayVideoFormat?
  private var encodedFormat: RapsodoReplayVideoFormat?
  private var writerSessionStartTimestamp: CMTime?
  private var lastAppendedTimestamp: CMTime?
  private var replayClockAnchors = SwingReplayClockAnchorBuffer()
  private var counters = RapsodoReplayFrameCounters()
  private var terminalError: RapsodoSourceReplayRecorderError?
  private var finalizationID: UUID?
  private var finishCompletion:
    (
      @Sendable (
        Result<RapsodoReplayExportResult, RapsodoSourceReplayRecorderError>
      ) -> Void
    )?

  init(outputDirectory: URL) {
    self.outputDirectory = outputDirectory
  }

  func start(sourceSession: RapsodoReplaySourceSession) throws {
    let result: Result<Void, RapsodoSourceReplayRecorderError> = writerQueue.sync {
      guard self.sourceSession == nil, self.finalizationID == nil else {
        return .failure(.alreadyRecording)
      }
      self.resetWriterState(removingOutput: true)
      self.sourceSession = sourceSession
      self.outputURL = self.outputDirectory
        .appendingPathComponent("GolfTrace-Rapsodo-source-\(UUID().uuidString)")
        .appendingPathExtension("mov")
      self.replayClockAnchors.reset()
      return .success(())
    }
    try result.get()

    ingressLock.withLock {
      pendingSample = nil
      isDrainScheduled = false
      offeredFrameCount = 0
      ingressDropCount = 0
      acceptsSamples = true
    }
  }

  func offer(_ sample: RapsodoReplaySample) {
    var shouldScheduleDrain = false
    ingressLock.withLock {
      guard acceptsSamples else { return }
      offeredFrameCount += 1
      if pendingSample != nil {
        ingressDropCount += 1
      }
      pendingSample = sample
      if !isDrainScheduled {
        isDrainScheduled = true
        shouldScheduleDrain = true
      }
    }

    if shouldScheduleDrain {
      writerQueue.async { [weak self] in
        self?.drainPendingSamples()
      }
    }
  }

  func finish() async -> Result<
    RapsodoReplayExportResult, RapsodoSourceReplayRecorderError
  > {
    closeIngress(clearingPendingSample: false)
    return await withCheckedContinuation { continuation in
      writerQueue.async { [weak self] in
        guard let self else {
          continuation.resume(returning: .failure(.cancelled))
          return
        }
        self.finishLocked { result in
          continuation.resume(returning: result)
        }
      }
    }
  }

  func cancel() {
    closeIngress(clearingPendingSample: true)
    writerQueue.async { [weak self] in
      self?.cancelLocked()
    }
  }

  func flushPendingFrames() async {
    await withCheckedContinuation { continuation in
      writerQueue.async {
        continuation.resume()
      }
    }
  }

  private func drainPendingSamples() {
    while let sample = takePendingSample() {
      appendLocked(sample)
    }
  }

  private func takePendingSample() -> RapsodoReplaySample? {
    ingressLock.withLock {
      guard let sample = pendingSample else {
        isDrainScheduled = false
        return nil
      }
      pendingSample = nil
      return sample
    }
  }

  private func closeIngress(clearingPendingSample: Bool) {
    ingressLock.withLock {
      acceptsSamples = false
      if clearingPendingSample {
        pendingSample = nil
      }
    }
  }

  private func appendLocked(_ sample: RapsodoReplaySample) {
    guard let sourceSession else { return }
    guard sample.sourceSession == sourceSession else {
      counters.sourceMismatchDrops += 1
      return
    }
    guard sample.sampleBuffer.isValid,
      sample.sampleBuffer.dataReadiness == .ready,
      let format = RapsodoReplayVideoFormat(sampleBuffer: sample.sampleBuffer)
    else {
      counters.invalidFrameDrops += 1
      return
    }

    if let frozenSourceFormat {
      guard frozenSourceFormat == format else {
        counters.formatMismatchDrops += 1
        return
      }
    } else {
      frozenSourceFormat = format
    }

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sample.sampleBuffer)
    guard timestamp.isValid,
      CMTimeGetSeconds(timestamp).isFinite,
      lastAppendedTimestamp.map({ CMTimeCompare(timestamp, $0) > 0 }) ?? true
    else {
      counters.invalidFrameDrops += 1
      return
    }

    if let lastAppendedTimestamp {
      let elapsed = CMTimeGetSeconds(timestamp - lastAppendedTimestamp)
      if elapsed.isFinite, elapsed < (1.0 / 30.0) - 0.000_001 {
        counters.throttleDrops += 1
        return
      }
    }

    do {
      try prepareWriterIfNeeded(format: format, firstTimestamp: timestamp)
    } catch let error as RapsodoSourceReplayRecorderError {
      terminalError = error
      closeIngress(clearingPendingSample: true)
      return
    } catch {
      terminalError = .cannotCreateWriter(error.localizedDescription)
      closeIngress(clearingPendingSample: true)
      return
    }

    guard let assetWriter, assetWriter.status == .writing, let writerInput else {
      terminalError = .appendFailed("ตัวเขียนไฟล์ไม่ได้อยู่ในสถานะพร้อมทำงาน")
      closeIngress(clearingPendingSample: true)
      return
    }
    guard writerInput.isReadyForMoreMediaData else {
      counters.backpressureDrops += 1
      return
    }
    guard writerInput.append(sample.sampleBuffer) else {
      terminalError = .appendFailed(
        assetWriter.error?.localizedDescription ?? "AVAssetWriter ไม่รับเฟรม"
      )
      closeIngress(clearingPendingSample: true)
      return
    }

    counters.appended += 1
    lastAppendedTimestamp = timestamp
    if let writerSessionStartTimestamp {
      _ = replayClockAnchors.append(
        mediaTime: timestamp - writerSessionStartTimestamp,
        monotonicTimeSeconds: sample.monotonicTimeSeconds
      )
    }
  }

  private func prepareWriterIfNeeded(
    format: RapsodoReplayVideoFormat,
    firstTimestamp: CMTime
  ) throws {
    guard assetWriter == nil else { return }
    guard let outputURL else { throw RapsodoSourceReplayRecorderError.notRecording }

    let newWriter: AVAssetWriter
    do {
      newWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      throw RapsodoSourceReplayRecorderError.cannotCreateWriter(error.localizedDescription)
    }
    let outputFormat = Self.outputFormat(for: format)
    let bitRate = min(
      6_000_000,
      max(4_000_000, outputFormat.width * outputFormat.height * 5)
    )
    let newInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: outputFormat.width,
        AVVideoHeightKey: outputFormat.height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: bitRate,
          AVVideoExpectedSourceFrameRateKey: 30,
          AVVideoMaxKeyFrameIntervalKey: 60,
          AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ]
    )
    newInput.expectsMediaDataInRealTime = true
    guard newWriter.canAdd(newInput) else {
      throw RapsodoSourceReplayRecorderError.cannotAddWriterInput
    }
    newWriter.add(newInput)
    guard newWriter.startWriting() else {
      throw RapsodoSourceReplayRecorderError.cannotStartWriter(
        newWriter.error?.localizedDescription ?? "AVAssetWriter เริ่มไม่ได้"
      )
    }
    newWriter.startSession(atSourceTime: firstTimestamp)

    assetWriter = newWriter
    writerInput = newInput
    encodedFormat = outputFormat
    writerSessionStartTimestamp = firstTimestamp
  }

  private static func outputFormat(
    for sourceFormat: RapsodoReplayVideoFormat
  ) -> RapsodoReplayVideoFormat {
    let maximumDimension = max(sourceFormat.width, sourceFormat.height)
    let scale = min(1, 1_280.0 / Double(maximumDimension))

    func evenDimension(_ sourceDimension: Int) -> Int {
      let scaled = Int((Double(sourceDimension) * scale).rounded())
      return max(2, scaled - scaled % 2)
    }

    return RapsodoReplayVideoFormat(
      width: evenDimension(sourceFormat.width),
      height: evenDimension(sourceFormat.height),
      pixelFormat: sourceFormat.pixelFormat
    )
  }

  private func finishLocked(
    completion:
      @escaping @Sendable (
        Result<RapsodoReplayExportResult, RapsodoSourceReplayRecorderError>
      ) -> Void
  ) {
    guard let sourceSession else {
      completion(.failure(.notRecording))
      return
    }
    guard finalizationID == nil else {
      completion(.failure(.alreadyRecording))
      return
    }

    let ingressSnapshot = ingressLock.withLock {
      (received: offeredFrameCount, dropped: ingressDropCount)
    }
    counters.received = ingressSnapshot.received
    counters.ingressDrops = ingressSnapshot.dropped

    if let terminalError {
      cancelWriterAndRemoveOutput()
      resetWriterState(removingOutput: false)
      completion(.failure(terminalError))
      return
    }
    guard let assetWriter, let writerInput, let outputURL, let encodedFormat,
      let writerSessionStartTimestamp, let lastAppendedTimestamp,
      counters.appended > 0
    else {
      cancelWriterAndRemoveOutput()
      resetWriterState(removingOutput: false)
      completion(.failure(.noVideoFrames))
      return
    }

    let result = RapsodoReplayExportResult(
      url: outputURL,
      sourceKind: sourceSession.sourceKind,
      generationID: sourceSession.generationID,
      format: encodedFormat,
      duration: max(
        0,
        CMTimeGetSeconds(lastAppendedTimestamp - writerSessionStartTimestamp)
      ),
      anchors: replayClockAnchors.snapshot(),
      counters: counters
    )
    let identifier = UUID()
    finalizationID = identifier
    finishCompletion = completion
    writerInput.markAsFinished()
    let writerTransfer = RapsodoAssetWriterTransfer(assetWriter)
    assetWriter.finishWriting { [weak self, writerTransfer] in
      guard let self else { return }
      self.writerQueue.async {
        let finalResult:
          Result<
            RapsodoReplayExportResult, RapsodoSourceReplayRecorderError
          >
        if writerTransfer.writer.status == .completed {
          finalResult = .success(result)
        } else {
          finalResult = .failure(
            .finishFailed(
              writerTransfer.writer.error?.localizedDescription ?? "AVAssetWriter ปิดไฟล์ไม่ได้"
            )
          )
        }
        self.completeFinalizationLocked(
          identifier: identifier,
          outputURL: outputURL,
          result: finalResult
        )
      }
    }
    writerQueue.asyncAfter(deadline: .now() + 12) { [weak self, writerTransfer] in
      guard let self, self.finalizationID == identifier else { return }
      if writerTransfer.writer.status == .unknown || writerTransfer.writer.status == .writing {
        writerTransfer.writer.cancelWriting()
      }
      self.completeFinalizationLocked(
        identifier: identifier,
        outputURL: outputURL,
        result: .failure(.finishTimedOut)
      )
    }
  }

  private func completeFinalizationLocked(
    identifier: UUID,
    outputURL: URL,
    result: Result<RapsodoReplayExportResult, RapsodoSourceReplayRecorderError>
  ) {
    guard finalizationID == identifier else { return }
    if case .failure = result {
      try? FileManager.default.removeItem(at: outputURL)
    }
    let callback = finishCompletion
    finishCompletion = nil
    finalizationID = nil
    resetWriterState(removingOutput: false)
    callback?(result)
  }

  private func cancelLocked() {
    let callback = finishCompletion
    finishCompletion = nil
    finalizationID = nil
    cancelWriterAndRemoveOutput()
    resetWriterState(removingOutput: false)
    callback?(.failure(.cancelled))
  }

  private func cancelWriterAndRemoveOutput() {
    if let assetWriter, assetWriter.status == .unknown || assetWriter.status == .writing {
      assetWriter.cancelWriting()
    }
    if let outputURL {
      try? FileManager.default.removeItem(at: outputURL)
    }
  }

  private func resetWriterState(removingOutput: Bool) {
    if removingOutput, let outputURL {
      try? FileManager.default.removeItem(at: outputURL)
    }
    sourceSession = nil
    outputURL = nil
    assetWriter = nil
    writerInput = nil
    frozenSourceFormat = nil
    encodedFormat = nil
    writerSessionStartTimestamp = nil
    lastAppendedTimestamp = nil
    counters = RapsodoReplayFrameCounters()
    terminalError = nil
    replayClockAnchors.reset()
  }
}

private final class RapsodoAssetWriterTransfer: @unchecked Sendable {
  let writer: AVAssetWriter

  init(_ writer: AVAssetWriter) {
    self.writer = writer
  }
}
