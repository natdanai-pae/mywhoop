@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import Network
import VideoToolbox

enum HighSpeedReceiverState: Equatable {
  case stopped
  case advertising
  case connected
  case stalled
  case failed(String)

  var title: String {
    switch self {
    case .stopped:
      return "หยุดรับภาพความเร็วสูงแล้ว"
    case .advertising:
      return "กำลังรอแอปกล้องวงสวิงบน iPhone"
    case .connected:
      return "เชื่อมต่อภาพความเร็วสูงจาก iPhone แล้ว"
    case .stalled:
      return "ภาพหยุดชั่วคราว — กำลังรอ iPhone ส่งต่อ"
    case .failed(let message):
      return "รับภาพความเร็วสูงไม่สำเร็จ: \(message)"
    }
  }
}

struct HighSpeedReceiverMetrics: Equatable {
  var dimensions = CGSize.zero
  var decodedFrames = 0
  var decodedFPS = 0.0
  var decoderDrops = 0
  var renderDrops = 0
  var receivedFrames = 0
  var receivedFPS = 0.0

  var resolutionText: String {
    guard dimensions != .zero else { return "กำลังรอภาพจาก iPhone" }
    return "\(Int(dimensions.width)) × \(Int(dimensions.height))"
  }

  var fpsText: String {
    decodedFPS > 0 ? String(format: "%.1f FPS", decodedFPS) : "กำลังวัด FPS หลังถอดภาพ"
  }
}

/// Encoded camera properties captured alongside a persisted replay master.
/// Optional dimensions/FPS mean the compressed stream was valid for export,
/// but its live decoder had not published that diagnostic yet.
struct CameraMasterReplayFormat: Equatable, Sendable {
  let codec: String
  let encodedPixelWidth: Int?
  let encodedPixelHeight: Int?
  let nominalFrameRate: Double?
  let rotationDegrees: Double
}

/// Immutable diagnostics from the same receiver-queue snapshot as the
/// compressed segment. These counters are evidence about source completeness;
/// they are not recomputed after the asynchronous MOV write finishes.
struct CameraMasterReplayCounters: Equatable, Sendable {
  let selectedFrames: Int
  let selectedBytes: Int
  let receiverReceivedFrames: Int
  let receiverDecodedFrames: Int
  let decoderDrops: Int
  let renderDrops: Int
}

/// A camera master plus the metadata needed to align analysis captured on the
/// iPhone presentation clock with the zero-based timeline inside the MOV.
struct CameraMasterReplayExportResult: Equatable, @unchecked Sendable {
  let url: URL
  let sourcePTSOrigin: CMTime
  let durationSeconds: TimeInterval
  let fileClockAnchors: [SwingReplayClockAnchor]
  let format: CameraMasterReplayFormat
  let counters: CameraMasterReplayCounters
}

/// Immutable metadata submitted with one VideoToolbox decode request. Encoding
/// it into `sourceFrameRefcon` keeps orientation attached to the exact access
/// unit even when a later orientation packet arrives before decode completes.
struct GolfTraceDecodedFrameContext: Equatable {
  let generation: UInt64
  let videoOrientation: GolfTraceVideoOrientation

  var packedValue: UInt64 {
    (generation << 2) | UInt64(videoOrientation.rawValue / 90)
  }

  var opaquePointer: UnsafeMutableRawPointer {
    // Zero is reserved for nil, so store packedValue + 1.
    UnsafeMutableRawPointer(bitPattern: UInt(truncatingIfNeeded: packedValue &+ 1))!
  }

  init(generation: UInt64, videoOrientation: GolfTraceVideoOrientation) {
    self.generation = generation
    self.videoOrientation = videoOrientation
  }

  init?(opaquePointer: UnsafeMutableRawPointer?) {
    guard let opaquePointer else { return nil }
    let packedValue = UInt64(UInt(bitPattern: opaquePointer)) &- 1
    generation = packedValue >> 2
    let rawOrientation = UInt16((packedValue & 0b11) * 90)
    guard let videoOrientation = GolfTraceVideoOrientation(rawValue: rawOrientation) else {
      return nil
    }
    self.videoOrientation = videoOrientation
  }
}

/// Thread-safe single slot used to coalesce preview work while the main actor
/// is busy. New camera frames replace an older pending frame, so recovery from
/// a UI hitch shows the freshest frame rather than replaying stale work.
final class GolfTraceLatestValueSlot<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var latestValue: Value?
  private var isCancelled = false

  init(_ initialValue: Value) {
    latestValue = initialValue
  }

  @discardableResult
  func offer(_ value: Value) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled else { return false }
    let didReplacePendingValue = latestValue != nil
    latestValue = value
    return didReplacePendingValue
  }

  func takeLatest() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled else { return nil }
    let value = latestValue
    latestValue = nil
    return value
  }

  var hasPendingValue: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isCancelled && latestValue != nil
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    latestValue = nil
    lock.unlock()
  }
}

/// Receives a low-latency H.264 stream from Golf Trace Camera and decodes it on
/// the Mac with VideoToolbox. It deliberately has no GX10 dependency: callers
/// receive local `CMSampleBuffer`s that can go straight to Vision/Core ML.
/// All mutable transport and decoder state is confined to `networkQueue`; UI
/// delivery is explicitly hopped to the main queue.
final class HighSpeedVideoReceiver: NSObject, ObservableObject, @unchecked Sendable {
  static let bonjourServiceType = GolfTraceWireService.bonjourType

  @Published private(set) var state: HighSpeedReceiverState = .stopped
  @Published private(set) var metrics = HighSpeedReceiverMetrics()
  @Published private(set) var practiceSettings = GolfPracticeSettings.default
  @Published private(set) var hasReceivedPracticeSettings = false
  @Published private(set) var videoOrientation = GolfTraceVideoOrientation.degrees0
  /// Orientation of the exact sample most recently handed to the display
  /// layer. This may intentionally lag `videoOrientation` during a device turn.
  @Published private(set) var presentedVideoOrientation = GolfTraceVideoOrientation.degrees0

  /// Called on the receiver's serial decode queue with each decoded frame.
  /// Keep expensive inference behind a latest-frame gate so analysis never
  /// queues stale video; rendering is dispatched independently to the main
  /// queue and must not hold up local analysis.
  var onSampleBuffer: ((CMSampleBuffer, GolfTraceVideoOrientation) -> Void)?
  /// Called on the main queue whenever the incoming stream starts over or pauses long enough
  /// that an in-progress swing must not be joined to later frames.
  var onStreamReset: (() -> Void)?

  private let networkQueue = DispatchQueue(
    label: "com.bda.golftrace.high-speed.receiver", qos: .userInteractive)
  private let networkQueueKey = DispatchSpecificKey<UInt8>()
  private let replayExportQueue = DispatchQueue(
    label: "com.bda.golftrace.replay-export", qos: .userInitiated)
  private var listener: NWListener?
  private var activeConnection: NWConnection?
  private var wantsToRun = false
  private var transportConnected = false
  private var streamIsStalled = false
  private var lastAccessUnitWallTime: TimeInterval?
  private var lastAccessUnitTimestamp: CMTime?
  private var watchdog: DispatchSourceTimer?
  private var packetAccumulator = GolfTracePacketAccumulator()
  private var replayBuffer = H264ReplayBuffer()
  // Keep clock evidence for the whole 11-second compressed window. At the
  // collector's 30 Hz ceiling, 384 anchors leave margin around both edges.
  private let replayClockAnchorBuffer = SwingReplayClockAnchorBuffer(capacity: 384)
  private var videoFormatDescription: CMVideoFormatDescription?
  private var decodedOutputFormatDescription: CMVideoFormatDescription?
  private var decodedOutputFormatKey: DecodedOutputFormatKey?
  private var decoderConfiguration: GolfTraceH264Configuration?
  private var decoderGeneration: UInt64 = 0
  /// Mutated only on `networkQueue`. Each decode submission snapshots this
  /// value into its frame refcon so a later rotation packet cannot relabel an
  /// older frame while VideoToolbox is still decoding it.
  private var activeVideoOrientation = GolfTraceVideoOrientation.degrees0
  private var decompressionSession: VTDecompressionSession?
  private var receivedTimestamps: [CMTime] = []
  private var decodeTimestamps: [CMTime] = []
  private var receivedFrameCount = 0
  private var decodedFrameCount = 0
  private var decoderDrops = 0
  private var renderDrops = 0
  private var decodedDimensions = CGSize.zero
  private var pendingPreviewSlot: GolfTraceLatestValueSlot<DecodedPreviewFrame>?
  private var lastMetricsPublishedAt: TimeInterval = 0
  private var lastMetricsLoggedAt: TimeInterval = 0
  private weak var displayLayer: AVSampleBufferDisplayLayer?

  private let stalledWarningDelay: TimeInterval = 2
  private let stalledReconnectDelay: TimeInterval = 6

  override init() {
    super.init()
    networkQueue.setSpecific(key: networkQueueKey, value: 1)
  }

  deinit {
    watchdog?.cancel()
    listener?.cancel()
    activeConnection?.cancel()
    invalidateDecoder()
  }

  func start() {
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.wantsToRun = true
      self.startWatchdogIfNeeded()
      self.startListenerIfNeeded()
    }
  }

  func stop() {
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.wantsToRun = false
      self.transportConnected = false
      self.streamIsStalled = false
      self.lastAccessUnitWallTime = nil
      self.lastAccessUnitTimestamp = nil
      self.watchdog?.cancel()
      self.watchdog = nil
      self.listener?.cancel()
      self.listener = nil
      self.activeConnection?.cancel()
      self.activeConnection = nil
      self.packetAccumulator.reset()
      self.replayBuffer.reset()
      self.replayClockAnchorBuffer.reset()
      self.activeVideoOrientation = .degrees0
      self.pendingPreviewSlot?.cancel()
      self.pendingPreviewSlot = nil
      self.invalidateDecoder()
      self.resetMetrics()
      self.publishState(.stopped)
      DispatchQueue.main.async { [weak self] in
        self?.videoOrientation = .degrees0
        self?.presentedVideoOrientation = .degrees0
      }
    }
  }

  /// A preview view calls this from the main queue. Decoding itself stays off
  /// main, then enqueues a display-ready sample buffer back on main.
  func attachPreviewLayer(_ layer: AVSampleBufferDisplayLayer?) {
    displayLayer = layer
    layer?.videoGravity = .resizeAspect
  }

  private func handleListenerState(
    _ listenerState: NWListener.State,
    sourceListener: NWListener
  ) {
    guard listener === sourceListener else { return }

    switch listenerState {
    case .ready:
      publishState(transportConnected ? (streamIsStalled ? .stalled : .connected) : .advertising)
    case .failed(let error):
      sourceListener.cancel()
      listener = nil
      print("[GolfTrace] High-speed listener failed: \(error)")
      if !transportConnected {
        publishState(.failed("ช่องรับภาพบน Mac สะดุด — ระบบกำลังเปิดใหม่"))
      }
      scheduleListenerRestart()
    case .cancelled:
      if listener == nil, !wantsToRun {
        publishState(.stopped)
      }
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection, sourceListener: NWListener) {
    guard wantsToRun, listener === sourceListener else {
      connection.cancel()
      return
    }

    activeConnection?.cancel()
    activeConnection = connection
    packetAccumulator.reset()
    replayBuffer.reset()
    replayClockAnchorBuffer.reset()
    activeVideoOrientation = .degrees0
    transportConnected = false
    streamIsStalled = false
    lastAccessUnitWallTime = nil
    lastAccessUnitTimestamp = nil
    pendingPreviewSlot?.cancel()
    pendingPreviewSlot = nil
    invalidateDecoder()
    resetMetrics()
    notifyAnalysisReset()
    DispatchQueue.main.async { [weak self] in
      self?.hasReceivedPracticeSettings = false
      self?.videoOrientation = .degrees0
      self?.presentedVideoOrientation = .degrees0
    }

    connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
      guard let self, let connection, self.activeConnection === connection else { return }
      self.handleConnectionState(connectionState, connection: connection)
    }
    connection.start(queue: networkQueue)
  }

  private func handleConnectionState(
    _ connectionState: NWConnection.State, connection: NWConnection
  ) {
    switch connectionState {
    case .ready:
      transportConnected = true
      streamIsStalled = false
      lastAccessUnitWallTime = ProcessInfo.processInfo.systemUptime
      publishState(.connected)
      receiveNext(from: connection)
    case .failed(let error):
      connection.cancel()
      if activeConnection === connection {
        activeConnection = nil
        transportConnected = false
        streamIsStalled = false
        lastAccessUnitWallTime = nil
        lastAccessUnitTimestamp = nil
        packetAccumulator.reset()
        invalidateDecoder()
        publishState(.advertising)
      }
      print("[GolfTrace] High-speed iPhone connection failed: \(error)")
    case .cancelled:
      if activeConnection === connection {
        activeConnection = nil
        transportConnected = false
        streamIsStalled = false
        lastAccessUnitWallTime = nil
        lastAccessUnitTimestamp = nil
        packetAccumulator.reset()
        invalidateDecoder()
        publishState(listener == nil ? .stopped : .advertising)
      }
    default:
      break
    }
  }

  private func receiveNext(from connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024 * 1_024) {
      [weak self, weak connection] content, _, isComplete, error in
      guard let self, let connection, self.activeConnection === connection else { return }

      if let content, !content.isEmpty {
        let packets = self.packetAccumulator.append(content)
        packets.forEach(self.handle)
      }

      if isComplete || error != nil {
        connection.cancel()
        return
      }

      self.receiveNext(from: connection)
    }
  }

  private func handle(_ packet: GolfTraceWirePacket) {
    switch packet.kind {
    case .hello:
      print("[GolfTrace] High-speed sender connected (sequence \(packet.sequence)).")
    case .h264Configuration:
      guard let configuration = GolfTraceH264Configuration.decode(packet.payload) else {
        decoderDrops += 1
        publishMetrics()
        return
      }
      replayBuffer.updateConfiguration(configuration)
      configureDecoder(with: configuration)
    case .h264AccessUnit:
      let timestamp = CMTime(
        value: packet.presentationTimeMicroseconds,
        timescale: 1_000_000
      )
      if let lastAccessUnitTimestamp,
        CMTimeCompare(timestamp, lastAccessUnitTimestamp) <= 0
      {
        handleTimestampDiscontinuity()
      }
      lastAccessUnitTimestamp = timestamp
      noteAccessUnitArrival()
      replayBuffer.append(packet)
      recordReceivedFrame(packet)
      decode(packet)
    case .requestKeyFrame:
      // The iPhone is the encoder owner. It sends configuration plus an IDR
      // after any reconnect, so the receiver never needs to synthesize one.
      break
    case .practiceSettings:
      guard let settings = GolfPracticeSettings.decode(packet.payload) else {
        print("[GolfTrace] Ignored unsupported practice settings packet.")
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.practiceSettings = settings
        self?.hasReceivedPracticeSettings = true
      }
    case .videoOrientation:
      guard let orientation = GolfTraceVideoOrientation.decode(packet.payload) else {
        print("[GolfTrace] Ignored unsupported video orientation packet.")
        return
      }
      guard orientation != activeVideoOrientation else { return }
      activeVideoOrientation = orientation
      // A single MOV transform cannot truthfully describe frames from two
      // orientation epochs. Start the compressed replay chain at the next IDR;
      // the sender includes fresh H.264 configuration with every keyframe.
      replayBuffer.reset()
      replayClockAnchorBuffer.reset()
      pendingPreviewSlot?.cancel()
      pendingPreviewSlot = nil
      // Any VideoToolbox callback already in flight belongs to the previous
      // geometry epoch. Advancing generation drops it before it can enter the
      // freshly reset pose/swing analyzers.
      decoderGeneration &+= 1
      notifyAnalysisReset()
      DispatchQueue.main.async { [weak self] in
        self?.videoOrientation = orientation
      }
    }
  }

  /// Creates a replay of the latest completed swing without re-encoding H.264.
  /// The selection happens on the receiver queue; file writing happens on a
  /// separate queue so live receive/decode is never blocked.
  func exportReplay(
    swingStart: CMTime,
    swingEnd: CMTime,
    preRoll: TimeInterval = 0.75,
    rotationDegrees: Double = 0,
    completion: @escaping @Sendable (Result<URL, Error>) -> Void
  ) {
    exportCameraMaster(
      swingStart: swingStart,
      swingEnd: swingEnd,
      preRoll: preRoll,
      rotationDegrees: rotationDegrees
    ) { result in
      completion(result.map(\.url))
    }
  }

  /// Persists one complete camera interval and carries its original clock into
  /// the result. If either requested edge has expired/not arrived, this reports
  /// a coverage error instead of silently exporting a shorter clip.
  func exportCameraMaster(
    swingStart: CMTime,
    swingEnd: CMTime,
    preRoll: TimeInterval = 0.75,
    rotationDegrees: Double = 0,
    completion: @escaping @Sendable (Result<CameraMasterReplayExportResult, Error>) -> Void
  ) {
    networkQueue.async { [weak self] in
      guard let self else { return }
      let requestedStart =
        swingStart
        - CMTime(
          seconds: max(0, preRoll),
          preferredTimescale: 1_000_000
        )
      let segment: H264ReplaySegment
      switch self.replayBuffer.segmentResult(
        requestedStart: requestedStart,
        requestedEnd: swingEnd
      ) {
      case .success(let selectedSegment):
        segment = selectedSegment
      case .failure(let error):
        DispatchQueue.main.async {
          completion(.failure(error))
        }
        return
      }

      let sourceClockAnchors = self.replayClockAnchorBuffer.snapshot()
      let videoDimensions = self.videoFormatDescription.map(
        CMVideoFormatDescriptionGetDimensions
      )
      let format = CameraMasterReplayFormat(
        codec: "h264",
        encodedPixelWidth: videoDimensions.flatMap { $0.width > 0 ? Int($0.width) : nil },
        encodedPixelHeight: videoDimensions.flatMap { $0.height > 0 ? Int($0.height) : nil },
        nominalFrameRate: Self.estimatedNominalFrameRate(for: segment.frames),
        rotationDegrees: rotationDegrees
      )
      let counters = CameraMasterReplayCounters(
        selectedFrames: segment.frames.count,
        selectedBytes: segment.frames.reduce(into: 0) { $0 += $1.payload.count },
        receiverReceivedFrames: self.receivedFrameCount,
        receiverDecodedFrames: self.decodedFrameCount,
        decoderDrops: self.decoderDrops,
        renderDrops: self.renderDrops
      )
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("GolfTrace-วงล่าสุด-\(UUID().uuidString)")
        .appendingPathExtension("mov")
      self.replayExportQueue.async {
        SwingReplayWriter.writeWithMetadata(
          segment,
          to: outputURL,
          rotationDegrees: rotationDegrees
        ) { writeResult in
          let result = writeResult.map { written in
            CameraMasterReplayExportResult(
              url: written.url,
              sourcePTSOrigin: written.sourcePTSOrigin,
              durationSeconds: written.durationSeconds,
              fileClockAnchors: Self.rebasedClockAnchors(
                sourceClockAnchors,
                sourcePTSOrigin: written.sourcePTSOrigin,
                sourcePTSEnd: written.sourcePTSEnd
              ),
              format: format,
              counters: counters
            )
          }
          DispatchQueue.main.async {
            completion(result)
          }
        }
      }
    }
  }

  /// Snapshot of the current iPhone media clock observed against Mac uptime.
  /// The buffer is thread-safe, so stage finalization can read it without
  /// blocking the receiver's latency-sensitive network queue.
  func replayClockAnchorsSnapshot() -> [SwingReplayClockAnchor] {
    replayClockAnchorBuffer.snapshot()
  }

  /// Snapshots the compressed camera segment as soon as a swing record gets an
  /// ID. All MOV/JPEG work starts only after the value-type segment has left
  /// `networkQueue`, so the rolling buffer may continue expiring
  /// without invalidating this Storyboard export.
  func exportStoryboardArtifacts(
    swingStart: CMTime,
    swingEnd: CMTime,
    phaseMarkers: [SwingStoryboardPhaseMarker],
    preRoll: TimeInterval = 0.75,
    captureOrientation: SwingStoryboardCaptureOrientation,
    completion: @escaping @Sendable (Result<CameraStoryboardArtifactExportResult, Error>) -> Void
  ) {
    networkQueue.async { [weak self] in
      guard let self else { return }
      let requestedStart =
        swingStart
        - CMTime(
          seconds: max(0, preRoll),
          preferredTimescale: 1_000_000
        )
      let segment: H264ReplaySegment
      switch self.replayBuffer.segmentResult(
        requestedStart: requestedStart,
        requestedEnd: swingEnd
      ) {
      case .success(let selectedSegment):
        segment = selectedSegment
      case .failure(let error):
        DispatchQueue.main.async {
          completion(.failure(error))
        }
        return
      }

      // Snapshot wire orientation on the same serial queue as the access
      // units. The caller may add only the app's explicit 180-degree mount
      // correction; a quarter-turn mismatch means the source changed.
      let wireOrientation = SwingStoryboardCaptureOrientation(self.activeVideoOrientation)
      guard captureOrientation.isSameOrManualHalfTurn(from: wireOrientation),
        let rotationDegrees = captureOrientation.clockwiseDegrees
      else {
        DispatchQueue.main.async {
          completion(.failure(CameraStoryboardArtifactExporterError.captureOrientationChanged))
        }
        return
      }
      CameraStoryboardArtifactExporter.export(
        segment: segment,
        swingStart: swingStart,
        phaseMarkers: phaseMarkers,
        rotationDegrees: rotationDegrees
      ) { result in
        DispatchQueue.main.async {
          completion(result)
        }
      }
    }
  }

  private func configureDecoder(with configuration: GolfTraceH264Configuration) {
    if decoderConfiguration == configuration, decompressionSession != nil {
      return
    }
    let replacesActiveGeometry = decoderConfiguration != nil || decompressionSession != nil
    invalidateDecoder()
    if replacesActiveGeometry {
      notifyAnalysisReset()
    }

    var formatDescription: CMFormatDescription?
    let status = configuration.sequenceParameterSet.withUnsafeBytes { spsBuffer in
      configuration.pictureParameterSet.withUnsafeBytes { ppsBuffer in
        guard let sps = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
          let pps = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else {
          return OSStatus(paramErr)
        }
        var parameterSets = [sps, pps]
        var parameterSetSizes = [
          configuration.sequenceParameterSet.count, configuration.pictureParameterSet.count,
        ]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: parameterSets.count,
          parameterSetPointers: &parameterSets,
          parameterSetSizes: &parameterSetSizes,
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &formatDescription
        )
      }
    }

    guard status == noErr, let formatDescription else {
      decoderDrops += 1
      publishMetrics()
      return
    }

    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: golfTraceDecompressionOutputCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    let pixelBufferAttributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var session: VTDecompressionSession?
    let sessionStatus = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: nil,
      imageBufferAttributes: pixelBufferAttributes as CFDictionary,
      outputCallback: &callback,
      decompressionSessionOut: &session
    )

    guard sessionStatus == noErr, let session else {
      decoderDrops += 1
      publishMetrics()
      return
    }

    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    videoFormatDescription = formatDescription
    decoderConfiguration = configuration
    decompressionSession = session
  }

  private func startListenerIfNeeded() {
    guard wantsToRun, listener == nil else { return }

    do {
      let parameters = NWParameters.tcp
      parameters.includePeerToPeer = true
      let listener = try NWListener(using: parameters)
      listener.service = NWListener.Service(name: "GolfTrace Mac", type: Self.bonjourServiceType)
      listener.stateUpdateHandler = { [weak self, weak listener] listenerState in
        guard let listener else { return }
        self?.handleListenerState(listenerState, sourceListener: listener)
      }
      listener.newConnectionHandler = { [weak self, weak listener] connection in
        guard let self, let listener else {
          connection.cancel()
          return
        }
        self.accept(connection, sourceListener: listener)
      }
      self.listener = listener
      listener.start(queue: networkQueue)
    } catch {
      print("[GolfTrace] Unable to create high-speed listener: \(error)")
      publishState(.failed("เปิดช่องรอรับภาพบน Mac ไม่สำเร็จ — ระบบกำลังลองใหม่"))
      scheduleListenerRestart()
    }
  }

  private func scheduleListenerRestart() {
    guard wantsToRun else { return }
    networkQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.startListenerIfNeeded()
    }
  }

  private func startWatchdogIfNeeded() {
    guard watchdog == nil else { return }
    let watchdog = DispatchSource.makeTimerSource(queue: networkQueue)
    watchdog.schedule(deadline: .now() + 0.5, repeating: 0.5)
    watchdog.setEventHandler { [weak self] in
      self?.checkStreamHealth()
    }
    self.watchdog = watchdog
    watchdog.resume()
  }

  private func noteAccessUnitArrival() {
    lastAccessUnitWallTime = ProcessInfo.processInfo.systemUptime
    if streamIsStalled {
      streamIsStalled = false
      publishState(.connected)
    }
  }

  private func checkStreamHealth() {
    guard transportConnected,
      let lastAccessUnitWallTime
    else {
      return
    }

    let idleDuration = ProcessInfo.processInfo.systemUptime - lastAccessUnitWallTime
    guard idleDuration >= stalledWarningDelay else { return }

    if idleDuration >= stalledReconnectDelay, let connection = activeConnection {
      print("[GolfTrace] ภาพหยุดเกิน 6 วินาที — ยกเลิกการเชื่อมต่อเดิมเพื่อให้ iPhone ต่อใหม่")
      activeConnection = nil
      transportConnected = false
      streamIsStalled = false
      self.lastAccessUnitWallTime = nil
      self.lastAccessUnitTimestamp = nil
      packetAccumulator.reset()
      invalidateDecoder()
      connection.cancel()
      publishState(.advertising)
      return
    }

    guard !streamIsStalled else { return }
    streamIsStalled = true
    decoderGeneration &+= 1
    publishState(.stalled)
    notifyAnalysisReset()
  }

  private func handleTimestampDiscontinuity() {
    print("[GolfTrace] เวลาเฟรมเริ่มใหม่ — ล้างสถานะวิเคราะห์ก่อนรับภาพชุดใหม่")
    decoderGeneration &+= 1
    replayClockAnchorBuffer.reset()
    resetMetrics()
    notifyAnalysisReset()
  }

  private static func estimatedNominalFrameRate(
    for frames: [H264ReplayFrame]
  ) -> Double? {
    let intervals = zip(frames, frames.dropFirst()).compactMap { first, second -> Double? in
      let seconds = CMTimeGetSeconds(second.timestamp - first.timestamp)
      return seconds.isFinite && seconds > 0 ? seconds : nil
    }.sorted()
    guard !intervals.isEmpty else { return nil }
    let framesPerSecond = 1 / intervals[intervals.count / 2]
    return framesPerSecond.isFinite && framesPerSecond > 0 ? framesPerSecond : nil
  }

  private static func rebasedClockAnchors(
    _ anchors: [SwingReplayClockAnchor],
    sourcePTSOrigin: CMTime,
    sourcePTSEnd: CMTime
  ) -> [SwingReplayClockAnchor] {
    let originSeconds = CMTimeGetSeconds(sourcePTSOrigin)
    let endSeconds = CMTimeGetSeconds(sourcePTSEnd)
    guard originSeconds.isFinite, endSeconds.isFinite, endSeconds >= originSeconds else {
      return []
    }
    return anchors.compactMap { anchor in
      guard anchor.isValid,
        anchor.mediaTimeSeconds >= originSeconds,
        anchor.mediaTimeSeconds <= endSeconds
      else {
        return nil
      }
      return SwingReplayClockAnchor(
        mediaTimeSeconds: anchor.mediaTimeSeconds - originSeconds,
        monotonicTimeSeconds: anchor.monotonicTimeSeconds
      )
    }
  }

  private func notifyAnalysisReset() {
    if Thread.isMainThread {
      onStreamReset?()
    } else {
      DispatchQueue.main.sync { [weak self] in
        self?.onStreamReset?()
      }
    }
  }

  private func decode(_ packet: GolfTraceWirePacket) {
    guard let decompressionSession, let videoFormatDescription else {
      decoderDrops += 1
      publishMetrics()
      return
    }

    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: packet.payload.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: packet.payload.count,
        flags: 0,
        blockBufferOut: &blockBuffer
      ) == noErr,
      let blockBuffer
    else {
      decoderDrops += 1
      publishMetrics()
      return
    }

    let copyStatus = packet.payload.withUnsafeBytes { payloadBuffer in
      guard let baseAddress = payloadBuffer.baseAddress else { return OSStatus(paramErr) }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: packet.payload.count
      )
    }
    guard copyStatus == noErr else {
      decoderDrops += 1
      publishMetrics()
      return
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(
        value: packet.presentationTimeMicroseconds, timescale: 1_000_000),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = packet.payload.count
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: videoFormatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      decoderDrops += 1
      publishMetrics()
      return
    }

    var decodeInfoFlags = VTDecodeInfoFlags()
    let frameContext = GolfTraceDecodedFrameContext(
      generation: decoderGeneration,
      videoOrientation: activeVideoOrientation
    )
    let decodeStatus = VTDecompressionSessionDecodeFrame(
      decompressionSession,
      sampleBuffer: sampleBuffer,
      flags: [],
      frameRefcon: frameContext.opaquePointer,
      infoFlagsOut: &decodeInfoFlags
    )
    if decodeStatus != noErr {
      decoderDrops += 1
      publishMetrics()
    }
  }

  fileprivate func enqueueDecoded(
    imageBuffer: CVImageBuffer,
    presentationTimeStamp: CMTime,
    generation: UInt64,
    videoOrientation: GolfTraceVideoOrientation
  ) {
    // Synchronous VideoToolbox decode normally invokes this callback on the
    // receiver queue. Continue inline in that common case instead of retaining
    // the image in a transfer box and dispatching back to the same queue.
    if DispatchQueue.getSpecific(key: networkQueueKey) == 1 {
      didDecode(
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        generation: generation,
        videoOrientation: videoOrientation
      )
      return
    }

    let transfer = DecodedImageTransfer(
      imageBuffer: imageBuffer,
      presentationTimeStamp: presentationTimeStamp,
      generation: generation,
      videoOrientation: videoOrientation
    )
    networkQueue.async { [weak self] in
      self?.didDecode(
        imageBuffer: transfer.imageBuffer,
        presentationTimeStamp: transfer.presentationTimeStamp,
        generation: transfer.generation,
        videoOrientation: transfer.videoOrientation
      )
    }
  }

  private func didDecode(
    imageBuffer: CVImageBuffer,
    presentationTimeStamp: CMTime,
    generation: UInt64,
    videoOrientation: GolfTraceVideoOrientation
  ) {
    guard transportConnected, generation == decoderGeneration else { return }
    _ = replayClockAnchorBuffer.append(mediaTime: presentationTimeStamp)

    let formatKey = DecodedOutputFormatKey(
      width: CVPixelBufferGetWidth(imageBuffer),
      height: CVPixelBufferGetHeight(imageBuffer),
      pixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer)
    )
    let formatDescription: CMVideoFormatDescription
    if decodedOutputFormatKey == formatKey,
      let cached = decodedOutputFormatDescription
    {
      formatDescription = cached
    } else {
      var createdDescription: CMVideoFormatDescription?
      guard
        CMVideoFormatDescriptionCreateForImageBuffer(
          allocator: kCFAllocatorDefault,
          imageBuffer: imageBuffer,
          formatDescriptionOut: &createdDescription
        ) == noErr,
        let createdDescription
      else {
        return
      }
      decodedOutputFormatKey = formatKey
      decodedOutputFormatDescription = createdDescription
      formatDescription = createdDescription
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: presentationTimeStamp,
      decodeTimeStamp: .invalid
    )
    var outputSampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: imageBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &outputSampleBuffer
      ) == noErr,
      let outputSampleBuffer
    else {
      return
    }

    // The capture timestamp originates on the iPhone, so it does not share the
    // Mac's host clock. Ask AVSampleBufferDisplayLayer to present immediately
    // instead of treating that foreign PTS as a future display deadline. Vision
    // still receives the original, monotonic capture timestamp for its local
    // motion calculations.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      outputSampleBuffer,
      createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let firstAttachment = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        firstAttachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }

    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    recordDecodedFrame(timestamp: presentationTimeStamp, width: width, height: height)

    // Run analysis immediately from the serial decoder queue. It has its own
    // latest-frame gate, so a 60 Hz display never becomes the limiting factor
    // for the Mac's high-speed inference path.
    onSampleBuffer?(outputSampleBuffer, videoOrientation)
    schedulePreview(
      outputSampleBuffer,
      generation: generation,
      videoOrientation: videoOrientation
    )
  }

  private func schedulePreview(
    _ sampleBuffer: CMSampleBuffer,
    generation: UInt64,
    videoOrientation: GolfTraceVideoOrientation
  ) {
    let frame = DecodedPreviewFrame(
      sampleBuffer: sampleBuffer,
      generation: generation,
      videoOrientation: videoOrientation
    )
    if let pendingPreviewSlot {
      if pendingPreviewSlot.offer(frame) {
        renderDrops += 1
        publishMetrics()
      }
      return
    }

    let slot = GolfTraceLatestValueSlot(frame)
    pendingPreviewSlot = slot
    dispatchPreviewDrain(for: slot)
  }

  private func dispatchPreviewDrain(
    for slot: GolfTraceLatestValueSlot<DecodedPreviewFrame>
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let frame = slot.takeLatest() {
        if self.displayLayer?.status == .failed {
          self.displayLayer?.flushAndRemoveImage()
        }
        if let displayLayer = self.displayLayer,
          displayLayer.isReadyForMoreMediaData
        {
          // The display layer consumes frames directly; publishing an unchanged
          // orientation here would invalidate the whole SwiftUI stage at video
          // frame rate without changing anything on screen.
          if self.presentedVideoOrientation != frame.videoOrientation {
            self.presentedVideoOrientation = frame.videoOrientation
          }
          displayLayer.enqueue(frame.sampleBuffer)
        } else if self.displayLayer != nil {
          self.recordRenderDrop()
        }
      }
      self.networkQueue.async { [weak self] in
        guard let self, self.pendingPreviewSlot === slot else { return }
        if slot.hasPendingValue {
          self.dispatchPreviewDrain(for: slot)
        } else {
          self.pendingPreviewSlot = nil
        }
      }
    }
  }

  private func recordDecodedFrame(timestamp: CMTime, width: Int, height: Int) {
    decodedFrameCount += 1
    decodedDimensions = CGSize(width: width, height: height)
    decodeTimestamps.append(timestamp)
    if let newest = decodeTimestamps.last {
      while let oldest = decodeTimestamps.first,
        CMTimeGetSeconds(newest - oldest) > 2
      {
        decodeTimestamps.removeFirst()
      }
    }
    publishMetrics(dimensions: CGSize(width: width, height: height))
  }

  private func recordReceivedFrame(_ packet: GolfTraceWirePacket) {
    receivedFrameCount += 1
    let timestamp = CMTime(value: packet.presentationTimeMicroseconds, timescale: 1_000_000)
    receivedTimestamps.append(timestamp)
    trim(&receivedTimestamps)
  }

  private func trim(_ timestamps: inout [CMTime]) {
    guard let newest = timestamps.last else { return }
    while let oldest = timestamps.first,
      CMTimeGetSeconds(newest - oldest) > 2
    {
      timestamps.removeFirst()
    }
  }

  private func measuredFrameRate(from timestamps: [CMTime]) -> Double {
    guard let first = timestamps.first,
      let last = timestamps.last,
      timestamps.count > 1
    else {
      return 0
    }
    let elapsed = CMTimeGetSeconds(last - first)
    return elapsed > 0 ? Double(timestamps.count - 1) / elapsed : 0
  }

  private func publishMetrics(dimensions: CGSize? = nil, force: Bool = false) {
    let now = ProcessInfo.processInfo.systemUptime
    guard force || lastMetricsPublishedAt == 0 || now - lastMetricsPublishedAt >= 0.1 else {
      return
    }
    lastMetricsPublishedAt = now

    let receivedFPS = measuredFrameRate(from: receivedTimestamps)
    let decodedFPS = measuredFrameRate(from: decodeTimestamps)
    let snapshot = HighSpeedReceiverMetrics(
      dimensions: dimensions ?? decodedDimensions,
      decodedFrames: decodedFrameCount,
      decodedFPS: decodedFPS,
      decoderDrops: decoderDrops,
      renderDrops: renderDrops,
      receivedFrames: receivedFrameCount,
      receivedFPS: receivedFPS
    )
    if receivedFPS > 0,
      lastMetricsLoggedAt == 0 || now - lastMetricsLoggedAt >= 2
    {
      lastMetricsLoggedAt = now
      print(
        "[GolfTrace] Direct pipeline receive \(String(format: "%.1f", receivedFPS)) → "
          + "decode \(String(format: "%.1f", decodedFPS)) fps · "
          + "\(Int(snapshot.dimensions.width))×\(Int(snapshot.dimensions.height)) · "
          + "ถอดไม่สำเร็จ \(decoderDrops) · ข้ามบนจอ \(renderDrops)"
      )
    }
    DispatchQueue.main.async { [weak self] in
      self?.metrics = snapshot
    }
  }

  private func resetMetrics() {
    receivedTimestamps.removeAll(keepingCapacity: true)
    decodeTimestamps.removeAll(keepingCapacity: true)
    receivedFrameCount = 0
    decodedFrameCount = 0
    decoderDrops = 0
    renderDrops = 0
    decodedDimensions = .zero
    pendingPreviewSlot?.cancel()
    pendingPreviewSlot = nil
    lastMetricsPublishedAt = 0
    lastMetricsLoggedAt = 0
    DispatchQueue.main.async { [weak self] in
      self?.metrics = HighSpeedReceiverMetrics()
    }
  }

  private func publishState(_ newState: HighSpeedReceiverState) {
    print("[GolfTrace] สถานะภาพความเร็วสูง: \(newState.title)")
    DispatchQueue.main.async { [weak self] in
      self?.state = newState
    }
  }

  private func recordRenderDrop() {
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.renderDrops += 1
      self.publishMetrics()
    }
  }

  private func invalidateDecoder() {
    decoderGeneration &+= 1
    pendingPreviewSlot?.cancel()
    pendingPreviewSlot = nil
    if let decompressionSession {
      VTDecompressionSessionInvalidate(decompressionSession)
    }
    decompressionSession = nil
    videoFormatDescription = nil
    decodedOutputFormatDescription = nil
    decodedOutputFormatKey = nil
    decoderConfiguration = nil
  }
}

private struct DecodedOutputFormatKey: Equatable {
  let width: Int
  let height: Int
  let pixelFormat: OSType
}

/// CoreMedia/CoreVideo buffers are retained reference types. These immutable
/// transfer boxes make the intentional hand-off between VideoToolbox's callback,
/// the receiver serial queue, and the main rendering queue explicit to Swift 6.
private final class DecodedImageTransfer: @unchecked Sendable {
  let imageBuffer: CVImageBuffer
  let presentationTimeStamp: CMTime
  let generation: UInt64
  let videoOrientation: GolfTraceVideoOrientation

  init(
    imageBuffer: CVImageBuffer,
    presentationTimeStamp: CMTime,
    generation: UInt64,
    videoOrientation: GolfTraceVideoOrientation
  ) {
    self.imageBuffer = imageBuffer
    self.presentationTimeStamp = presentationTimeStamp
    self.generation = generation
    self.videoOrientation = videoOrientation
  }
}

private final class DecodedPreviewFrame: @unchecked Sendable {
  let sampleBuffer: CMSampleBuffer
  let generation: UInt64
  let videoOrientation: GolfTraceVideoOrientation

  init(
    sampleBuffer: CMSampleBuffer,
    generation: UInt64,
    videoOrientation: GolfTraceVideoOrientation
  ) {
    self.sampleBuffer = sampleBuffer
    self.generation = generation
    self.videoOrientation = videoOrientation
  }
}

private func golfTraceDecompressionOutputCallback(
  decompressionOutputRefCon: UnsafeMutableRawPointer?,
  sourceFrameRefCon: UnsafeMutableRawPointer?,
  status: OSStatus,
  infoFlags: VTDecodeInfoFlags,
  imageBuffer: CVImageBuffer?,
  presentationTimeStamp: CMTime,
  presentationDuration: CMTime
) {
  guard status == noErr,
    !infoFlags.contains(.frameDropped),
    let decompressionOutputRefCon,
    let sourceFrameRefCon,
    let imageBuffer
  else {
    return
  }
  let receiver = Unmanaged<HighSpeedVideoReceiver>.fromOpaque(decompressionOutputRefCon)
    .takeUnretainedValue()
  guard let frameContext = GolfTraceDecodedFrameContext(opaquePointer: sourceFrameRefCon) else {
    return
  }
  receiver.enqueueDecoded(
    imageBuffer: imageBuffer,
    presentationTimeStamp: presentationTimeStamp,
    generation: frameContext.generation,
    videoOrientation: frameContext.videoOrientation
  )
}
