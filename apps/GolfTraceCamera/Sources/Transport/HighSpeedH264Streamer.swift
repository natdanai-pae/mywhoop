import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Network
import VideoToolbox

enum HighSpeedStreamState: Equatable {
  case stopped
  case discoveringMac
  case connecting
  case streaming
  case failed(String)

  var title: String {
    switch self {
    case .stopped:
      return "หยุดส่งภาพไปยัง Mac แล้ว"
    case .discoveringMac:
      return "กำลังค้นหาแอปวิเคราะห์วงสวิงบน Mac"
    case .connecting:
      return "กำลังเชื่อมต่อ Mac"
    case .streaming:
      return "กำลังส่งวิดีโอ H.264 ไปยัง Mac"
    case .failed(let message):
      return "ส่งภาพไปยัง Mac ไม่สำเร็จ: \(message)"
    }
  }

  var isStreaming: Bool {
    if case .streaming = self {
      return true
    }
    return false
  }

  var isActive: Bool {
    switch self {
    case .discoveringMac, .connecting, .streaming:
      return true
    case .stopped, .failed:
      return false
    }
  }
}

struct HighSpeedStreamMetrics: Equatable {
  var encodedFrames = 0
  var sentFrames = 0
  var transportDrops = 0
  var sentFramesPerSecond = 0.0
  var captureFramesPerSecond = 0.0
  var encodedFramesPerSecond = 0.0
  var encoderBusyDrops = 0
  var encoderFailures = 0
  var backpressureResets = 0

  var fpsText: String {
    sentFramesPerSecond > 0
      ? String(format: "%.1f FPS", sentFramesPerSecond)
      : "กำลังรอภาพที่บีบอัดแล้ว"
  }
}

/// Hardware-encodes the active rear-camera frames and sends a bounded,
/// low-latency H.264 stream to the paired Mac. The camera's capture queue keeps
/// ownership of incoming frames; frames are discarded before encoding if work
/// cannot be scheduled immediately, so old video never accumulates.
final class HighSpeedH264Streamer: NSObject, @unchecked Sendable {
  var onUpdate: ((HighSpeedStreamState, HighSpeedStreamMetrics) -> Void)?

  private let encoderQueue = DispatchQueue(
    label: "com.bda.golftrace.h264-encoder", qos: .userInteractive)
  private let networkQueue = DispatchQueue(
    label: "com.bda.golftrace.h264-network", qos: .userInteractive)
  private let schedulingLock = NSLock()
  private let sequenceLock = NSLock()

  private var compressionSession: VTCompressionSession?
  private var encoderConfiguration: EncoderConfiguration?
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var discoveredEndpoint: NWEndpoint?
  private var transportReady = false
  private var forceNextKeyFrame = true
  private var isEncodeScheduled = false
  private var streamEnabled = false
  private var nextSequence: UInt64 = 1
  private var pendingWrites: [WriteBatch] = []
  private var writeInFlight = false
  private var waitingForKeyFrame = true
  private var latestPracticeSettings = GolfPracticeSettings.default
  private var latestVideoOrientation = GolfTraceVideoOrientation.degrees0
  private var encodedFrames = 0
  private var sentFrames = 0
  private var transportDrops = 0
  private var sentTimestamps: [CMTime] = []
  private var encodedTimestamps: [CMTime] = []
  private var captureFramesPerSecond = 0.0
  private var encoderBusyDrops = 0
  private var encoderFailures = 0
  private var backpressureResets = 0
  private var lastPipelineLoggedAt: TimeInterval = 0

  deinit {
    browser?.cancel()
    connection?.cancel()
    if let compressionSession {
      VTCompressionSessionInvalidate(compressionSession)
    }
  }

  func configure(width: Int, height: Int, framesPerSecond: Double) {
    let configuration = EncoderConfiguration(
      width: width,
      height: height,
      framesPerSecond: max(1, framesPerSecond),
      averageBitRate: Self.averageBitRate(
        width: width, height: height, framesPerSecond: framesPerSecond)
    )
    encoderQueue.async { [weak self] in
      guard let self else { return }
      guard self.encoderConfiguration != configuration else { return }
      self.invalidateCompressionSession()
      self.encoderConfiguration = configuration
      self.forceNextKeyFrame = true
      self.networkQueue.async { [weak self] in
        self?.waitingForKeyFrame = true
      }
      self.createCompressionSessionIfPossible()
    }
  }

  func updateCaptureFrameRate(_ framesPerSecond: Double) {
    networkQueue.async { [weak self] in
      self?.captureFramesPerSecond = framesPerSecond
    }
  }

  /// ส่งค่าที่ผู้เล่นเลือกไป Mac โดยไม่ต้องรอให้วิดีโอเริ่มวงใหม่
  /// ค่านี้มีขนาดเล็กและจะส่งซ้ำหลังเชื่อมต่อหรือเมื่อมี key frame ใหม่
  /// เพื่อไม่ให้การตัดเฟรมจากความหนาแน่นของเครือข่ายทำให้ค่าหาย
  func updatePracticeSettings(_ settings: GolfPracticeSettings) {
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.latestPracticeSettings = settings
      self.enqueuePracticeSettingsIfPossible()
    }
  }

  /// ส่งเฉพาะองศา 2 ไบต์ ไม่หมุนพิกเซล 120 FPS บน iPhone
  func updateVideoOrientation(_ orientation: GolfTraceVideoOrientation) {
    networkQueue.async { [weak self] in
      guard let self, self.latestVideoOrientation != orientation else { return }
      self.latestVideoOrientation = orientation
      self.enqueueVideoOrientationIfPossible()
    }
  }

  func start() {
    schedulingLock.lock()
    streamEnabled = true
    schedulingLock.unlock()
    encoderQueue.async { [weak self] in
      // A restart must also recover from a transient VideoToolbox failure,
      // not only restart Bonjour discovery.
      self?.createCompressionSessionIfPossible()
    }
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.startDiscoveryIfNeeded(resetMetrics: true)
    }
  }

  func stop() {
    schedulingLock.lock()
    streamEnabled = false
    schedulingLock.unlock()
    encoderQueue.async { [weak self] in
      guard let self else { return }
      // VideoToolbox sessions do not survive an iOS background transition
      // reliably. Release this hardware resource on every intentional stop so
      // the next foreground start prepares a fresh encoder instead of reusing
      // a non-nil session that rejects every resumed frame.
      self.invalidateCompressionSession(completePendingFrames: false)
      self.forceNextKeyFrame = true
    }
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.browser?.cancel()
      self.browser = nil
      self.connection?.cancel()
      self.connection = nil
      self.discoveredEndpoint = nil
      self.transportReady = false
      self.pendingWrites.removeAll(keepingCapacity: true)
      self.writeInFlight = false
      self.waitingForKeyFrame = true
      self.publish(state: .stopped)
      self.encoderQueue.async { [weak self] in
        self?.forceNextKeyFrame = true
      }
    }
  }

  /// Called from `AVCaptureVideoDataOutput`'s serial callback queue.
  func append(_ sampleBuffer: CMSampleBuffer) {
    schedulingLock.lock()
    let wasEnabled = streamEnabled
    guard wasEnabled, !isEncodeScheduled else {
      schedulingLock.unlock()
      if wasEnabled {
        recordTransportDrop(.encoderBusy)
      }
      return
    }
    isEncodeScheduled = true
    schedulingLock.unlock()

    encoderQueue.async { [weak self] in
      defer {
        self?.schedulingLock.lock()
        self?.isEncodeScheduled = false
        self?.schedulingLock.unlock()
      }
      self?.encode(sampleBuffer)
    }
  }

  private func handleBrowserState(_ browserState: NWBrowser.State, sourceBrowser: NWBrowser) {
    // A cancelled browser can report its final state after a replacement has
    // started. Do not let that stale callback modify the new attempt.
    guard browser === sourceBrowser else { return }

    switch browserState {
    case .ready:
      print("[GolfTraceCamera] Mac discovery ready")
      publish(state: .discoveringMac)
    case .failed(let error):
      sourceBrowser.cancel()
      browser = nil
      print("[GolfTraceCamera] Mac discovery failed: \(error)")
      if !transportReady {
        publish(state: .failed("ค้นหา Mac ไม่สำเร็จ — ระบบกำลังลองใหม่ โปรดตรวจสิทธิ์เครือข่ายภายใน"))
      }
      scheduleDiscoveryRestart()
    case .cancelled:
      if browser == nil, !isStreamEnabled() {
        publish(state: .stopped)
      }
    default:
      break
    }
  }

  private func startDiscoveryIfNeeded(resetMetrics shouldResetMetrics: Bool = false) {
    guard isStreamEnabled(), browser == nil else { return }
    if shouldResetMetrics {
      resetMetrics()
    }

    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: GolfTraceWireService.bonjourType, domain: nil),
      using: parameters
    )
    browser.stateUpdateHandler = { [weak self, weak browser] state in
      guard let browser else { return }
      self?.handleBrowserState(state, sourceBrowser: browser)
    }
    browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
      guard let self, let browser, self.browser === browser else { return }
      self.discoveredEndpoint = results.first?.endpoint
      self.connectIfPossible()
    }
    self.browser = browser
    if !transportReady {
      publish(state: .discoveringMac)
    }
    print("[GolfTraceCamera] Starting Mac discovery")
    browser.start(queue: networkQueue)
  }

  private func scheduleDiscoveryRestart() {
    guard isStreamEnabled() else { return }
    networkQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.startDiscoveryIfNeeded()
    }
  }

  private func isStreamEnabled() -> Bool {
    schedulingLock.lock()
    defer { schedulingLock.unlock() }
    return streamEnabled
  }

  private func connectIfPossible() {
    guard connection == nil, let discoveredEndpoint else { return }

    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let connection = NWConnection(to: discoveredEndpoint, using: parameters)
    self.connection = connection
    publish(state: .connecting)
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, self.connection === connection else { return }
      self.handleConnectionState(state, connection: connection)
    }
    connection.start(queue: networkQueue)
  }

  private func handleConnectionState(
    _ connectionState: NWConnection.State, connection: NWConnection
  ) {
    switch connectionState {
    case .ready:
      transportReady = true
      waitingForKeyFrame = true
      sendHello()
      encoderQueue.async { [weak self] in
        self?.forceNextKeyFrame = true
      }
      print("[GolfTraceCamera] Connected to Mac")
      publish(state: .streaming)
    case .failed(let error):
      handleDisconnected(connection: connection)
      print("[GolfTraceCamera] Mac stream connection failed: \(error)")
    case .cancelled:
      handleDisconnected(connection: connection)
    default:
      break
    }
  }

  private func handleDisconnected(connection: NWConnection) {
    guard self.connection === connection else { return }
    connection.cancel()
    self.connection = nil
    transportReady = false
    pendingWrites.removeAll(keepingCapacity: true)
    writeInFlight = false
    waitingForKeyFrame = true
    encoderQueue.async { [weak self] in
      self?.forceNextKeyFrame = true
    }
    print("[GolfTraceCamera] Mac disconnected; reconnecting automatically")
    publish(state: browser == nil ? .stopped : .discoveringMac)

    guard browser != nil, discoveredEndpoint != nil else { return }
    networkQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.connectIfPossible()
    }
  }

  private func createCompressionSessionIfPossible() {
    guard compressionSession == nil, let configuration = encoderConfiguration else { return }

    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(configuration.width),
      height: Int32(configuration.height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: golfTraceCompressionOutputCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &session
    )
    guard status == noErr, let session else {
      publish(state: .failed("สร้างระบบบีบอัด H.264 ด้วยชิปในเครื่องไม่สำเร็จ (รหัส \(status))"))
      return
    }

    let frameRate = NSNumber(value: configuration.framesPerSecond)
    let bitRate = NSNumber(value: configuration.averageBitRate)
    let keyFrameInterval = NSNumber(value: max(1, Int(configuration.framesPerSecond.rounded())))
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(
      session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(
      session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate)
    VTSessionSetProperty(
      session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval)
    VTSessionSetProperty(
      session, key: kVTCompressionPropertyKey_ProfileLevel,
      value: kVTProfileLevel_H264_High_AutoLevel)

    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else {
      VTCompressionSessionInvalidate(session)
      publish(state: .failed("เตรียมระบบบีบอัด H.264 ไม่สำเร็จ (รหัส \(prepareStatus))"))
      return
    }
    compressionSession = session
    print(
      "[GolfTraceCamera] H.264 ready \(configuration.width)×\(configuration.height) "
        + "@ \(String(format: "%.0f", configuration.framesPerSecond)) fps, "
        + "\(configuration.averageBitRate / 1_000_000) Mbps target"
    )
  }

  private func encode(_ sampleBuffer: CMSampleBuffer) {
    guard let compressionSession,
      CMSampleBufferDataIsReady(sampleBuffer),
      let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      return
    }

    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard presentationTime.isValid else { return }

    let frameProperties: CFDictionary?
    if forceNextKeyFrame {
      frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
      forceNextKeyFrame = false
    } else {
      frameProperties = nil
    }

    var infoFlags = VTEncodeInfoFlags()
    let status = VTCompressionSessionEncodeFrame(
      compressionSession,
      imageBuffer: imageBuffer,
      presentationTimeStamp: presentationTime,
      duration: .invalid,
      frameProperties: frameProperties,
      sourceFrameRefcon: nil,
      infoFlagsOut: &infoFlags
    )
    if status != noErr {
      forceNextKeyFrame = true
      recordTransportDrop(.encoderFailure)
    }
  }

  fileprivate func handleCompressedSampleBuffer(_ sampleBuffer: CMSampleBuffer, status: OSStatus) {
    guard status == noErr,
      CMSampleBufferDataIsReady(sampleBuffer),
      let payload = avccPayload(from: sampleBuffer),
      !payload.isEmpty
    else {
      recordTransportDrop(.encoderFailure)
      return
    }

    let isKeyFrame = Self.isKeyFrame(sampleBuffer)
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let packet = GolfTraceWirePacket(
      kind: .h264AccessUnit,
      flags: isKeyFrame ? [.keyFrame] : [],
      sequence: takeNextSequence(),
      presentationTimeMicroseconds: Self.microseconds(for: presentationTime),
      payload: payload
    )

    let configurationPacket: GolfTraceWirePacket?
    if isKeyFrame, let configuration = h264Configuration(from: sampleBuffer),
      let configurationPayload = configuration.encoded()
    {
      configurationPacket = GolfTraceWirePacket(
        kind: .h264Configuration,
        flags: [],
        sequence: takeNextSequence(),
        presentationTimeMicroseconds: packet.presentationTimeMicroseconds,
        payload: configurationPayload
      )
    } else {
      configurationPacket = nil
    }

    let batch = WriteBatch(
      data: ([configurationPacket, packet].compactMap { $0?.encoded() }).reduce(into: Data()) {
        data, encoded in
        data.append(encoded)
      },
      isKeyFrame: isKeyFrame,
      isPracticeSettings: false,
      isVideoOrientation: false,
      presentationTime: presentationTime
    )
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.recordEncoded(presentationTime)
      self.enqueue(batch)
    }
  }

  private func enqueue(_ batch: WriteBatch) {
    guard transportReady, connection != nil else { return }

    if waitingForKeyFrame {
      guard batch.isKeyFrame else { return }
      waitingForKeyFrame = false
    }

    if pendingWrites.count >= 3 {
      // Dropping encoded P-frames would invalidate later P-frames. Clear
      // the small backlog, wait for a fresh IDR, and start a clean chain.
      pendingWrites.removeAll(keepingCapacity: true)
      waitingForKeyFrame = true
      recordTransportDrop(.backpressure)
      encoderQueue.async { [weak self] in
        self?.forceNextKeyFrame = true
      }
      guard batch.isKeyFrame else { return }
      waitingForKeyFrame = false
    }

    if batch.isKeyFrame {
      // A new IDR may safely supersede stale packets that have not gone
      // into TCP yet; it carries a configuration packet immediately before it.
      pendingWrites.removeAll(keepingCapacity: true)
      if let settingsBatch = practiceSettingsBatch() {
        pendingWrites.append(settingsBatch)
      }
      pendingWrites.append(videoOrientationBatch())
    }

    pendingWrites.append(batch)
    sendNextBatchIfPossible()
  }

  private func sendHello() {
    let payload = Data("GolfTraceCamera".utf8)
    let packet = GolfTraceWirePacket(
      kind: .hello,
      flags: [],
      sequence: takeNextSequence(),
      presentationTimeMicroseconds: 0,
      payload: payload
    )
    pendingWrites.append(
      WriteBatch(
        data: packet.encoded(),
        isKeyFrame: false,
        isPracticeSettings: false,
        isVideoOrientation: false,
        presentationTime: .invalid
      )
    )
    if let settingsBatch = practiceSettingsBatch() {
      pendingWrites.append(settingsBatch)
    }
    pendingWrites.append(videoOrientationBatch())
    sendNextBatchIfPossible()
  }

  private func enqueuePracticeSettingsIfPossible() {
    guard transportReady, connection != nil, let batch = practiceSettingsBatch() else { return }
    pendingWrites.removeAll(where: \.isPracticeSettings)
    pendingWrites.append(batch)
    sendNextBatchIfPossible()
  }

  private func practiceSettingsBatch() -> WriteBatch? {
    guard let payload = latestPracticeSettings.encoded() else { return nil }
    let packet = GolfTraceWirePacket(
      kind: .practiceSettings,
      flags: [],
      sequence: takeNextSequence(),
      presentationTimeMicroseconds: 0,
      payload: payload
    )
    return WriteBatch(
      data: packet.encoded(),
      isKeyFrame: false,
      isPracticeSettings: true,
      isVideoOrientation: false,
      presentationTime: .invalid
    )
  }

  private func enqueueVideoOrientationIfPossible() {
    guard transportReady, connection != nil else { return }
    pendingWrites.removeAll(where: \.isVideoOrientation)
    pendingWrites.append(videoOrientationBatch())
    sendNextBatchIfPossible()
  }

  private func videoOrientationBatch() -> WriteBatch {
    let packet = GolfTraceWirePacket(
      kind: .videoOrientation,
      flags: [],
      sequence: takeNextSequence(),
      presentationTimeMicroseconds: 0,
      payload: latestVideoOrientation.encoded()
    )
    return WriteBatch(
      data: packet.encoded(),
      isKeyFrame: false,
      isPracticeSettings: false,
      isVideoOrientation: true,
      presentationTime: .invalid
    )
  }

  private func sendNextBatchIfPossible() {
    guard !writeInFlight,
      let connection,
      !pendingWrites.isEmpty
    else {
      return
    }

    let batch = pendingWrites.removeFirst()
    writeInFlight = true
    connection.send(
      content: batch.data,
      completion: .contentProcessed { [weak self, weak connection] error in
        guard let self else { return }
        self.networkQueue.async {
          guard let connection, self.connection === connection else { return }
          self.writeInFlight = false
          if error == nil {
            self.recordSent(batch)
          } else {
            self.handleDisconnected(connection: connection)
            return
          }
          self.sendNextBatchIfPossible()
        }
      })
  }

  private func recordSent(_ batch: WriteBatch) {
    guard batch.presentationTime.isValid else { return }
    sentFrames += 1
    sentTimestamps.append(batch.presentationTime)
    if let newest = sentTimestamps.last {
      while let oldest = sentTimestamps.first,
        CMTimeGetSeconds(newest - oldest) > 2
      {
        sentTimestamps.removeFirst()
      }
    }
    publishMetrics()
  }

  private func recordEncoded(_ presentationTime: CMTime) {
    encodedFrames += 1
    guard presentationTime.isValid else { return }
    encodedTimestamps.append(presentationTime)
    trim(&encodedTimestamps)
  }

  private func recordTransportDrop(_ reason: StreamDropReason) {
    networkQueue.async { [weak self] in
      guard let self else { return }
      self.transportDrops += 1
      switch reason {
      case .encoderBusy:
        self.encoderBusyDrops += 1
      case .encoderFailure:
        self.encoderFailures += 1
      case .backpressure:
        self.backpressureResets += 1
      }
      self.publishMetrics()
    }
  }

  private func publishMetrics() {
    schedulingLock.lock()
    let enabled = streamEnabled
    schedulingLock.unlock()
    // Before the Mac accepts the TCP connection, encoded frames have no
    // useful consumer. Do not let a late encoder callback overwrite the
    // visible "discovering" / "stopped" state with a false streaming UI.
    guard enabled, transportReady else { return }

    let encodedFramesPerSecond = measuredFrameRate(from: encodedTimestamps)
    let sentFramesPerSecond = measuredFrameRate(from: sentTimestamps)

    let metrics = HighSpeedStreamMetrics(
      encodedFrames: encodedFrames,
      sentFrames: sentFrames,
      transportDrops: transportDrops,
      sentFramesPerSecond: sentFramesPerSecond,
      captureFramesPerSecond: captureFramesPerSecond,
      encodedFramesPerSecond: encodedFramesPerSecond,
      encoderBusyDrops: encoderBusyDrops,
      encoderFailures: encoderFailures,
      backpressureResets: backpressureResets
    )
    let now = CFAbsoluteTimeGetCurrent()
    if lastPipelineLoggedAt == 0 || now - lastPipelineLoggedAt >= 2 {
      lastPipelineLoggedAt = now
      print(
        "[GolfTraceCamera] Direct pipeline capture "
          + "\(String(format: "%.1f", captureFramesPerSecond)) → encode "
          + "\(String(format: "%.1f", encodedFramesPerSecond)) → send "
          + "\(String(format: "%.1f", sentFramesPerSecond)) fps; "
          + "drops busy \(encoderBusyDrops), encode \(encoderFailures), "
          + "backpressure \(backpressureResets); "
          + "queued \(pendingWrites.count) + inflight \(writeInFlight ? 1 : 0)"
      )
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.onUpdate?(.streaming, metrics)
    }
  }

  private func publish(state: HighSpeedStreamState) {
    let metrics = HighSpeedStreamMetrics(
      encodedFrames: encodedFrames,
      sentFrames: sentFrames,
      transportDrops: transportDrops,
      sentFramesPerSecond: 0,
      captureFramesPerSecond: captureFramesPerSecond,
      encodedFramesPerSecond: measuredFrameRate(from: encodedTimestamps),
      encoderBusyDrops: encoderBusyDrops,
      encoderFailures: encoderFailures,
      backpressureResets: backpressureResets
    )
    DispatchQueue.main.async { [weak self] in
      self?.onUpdate?(state, metrics)
    }
  }

  private func invalidateCompressionSession(completePendingFrames: Bool = true) {
    if let compressionSession {
      if completePendingFrames {
        VTCompressionSessionCompleteFrames(
          compressionSession,
          untilPresentationTimeStamp: .invalid
        )
      }
      VTCompressionSessionInvalidate(compressionSession)
    }
    compressionSession = nil
  }

  private func resetMetrics() {
    encodedFrames = 0
    sentFrames = 0
    transportDrops = 0
    sentTimestamps.removeAll(keepingCapacity: true)
    encodedTimestamps.removeAll(keepingCapacity: true)
    captureFramesPerSecond = 0
    encoderBusyDrops = 0
    encoderFailures = 0
    backpressureResets = 0
    lastPipelineLoggedAt = 0
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

  private func takeNextSequence() -> UInt64 {
    sequenceLock.lock()
    defer { sequenceLock.unlock() }
    let sequence = nextSequence
    nextSequence &+= 1
    return sequence
  }

  private func h264Configuration(from sampleBuffer: CMSampleBuffer) -> GolfTraceH264Configuration? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      return nil
    }
    var spsPointer: UnsafePointer<UInt8>?
    var spsSize = 0
    var parameterSetCount = 0
    var nalHeaderLength: Int32 = 0
    let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription,
      parameterSetIndex: 0,
      parameterSetPointerOut: &spsPointer,
      parameterSetSizeOut: &spsSize,
      parameterSetCountOut: &parameterSetCount,
      nalUnitHeaderLengthOut: &nalHeaderLength
    )
    var ppsPointer: UnsafePointer<UInt8>?
    var ppsSize = 0
    let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription,
      parameterSetIndex: 1,
      parameterSetPointerOut: &ppsPointer,
      parameterSetSizeOut: &ppsSize,
      parameterSetCountOut: nil,
      nalUnitHeaderLengthOut: nil
    )
    guard spsStatus == noErr,
      ppsStatus == noErr,
      parameterSetCount >= 2,
      let spsPointer,
      let ppsPointer,
      spsSize > 0,
      ppsSize > 0
    else {
      return nil
    }
    return GolfTraceH264Configuration(
      sequenceParameterSet: Data(bytes: spsPointer, count: spsSize),
      pictureParameterSet: Data(bytes: ppsPointer, count: ppsSize)
    )
  }

  private func avccPayload(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    guard length > 0 else { return nil }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { destination in
      guard let baseAddress = destination.baseAddress else { return OSStatus(-50) }
      return CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: length,
        destination: baseAddress
      )
    }
    return status == noErr ? data : nil
  }

  private static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
      let first = attachments.first
    else {
      return false
    }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }

  private static func microseconds(for time: CMTime) -> Int64 {
    guard time.isValid else { return 0 }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite else { return 0 }
    return Int64((seconds * 1_000_000).rounded())
  }

  private static func averageBitRate(width: Int, height: Int, framesPerSecond: Double) -> Int {
    let rawEstimate = Double(width * height) * framesPerSecond * 0.18
    return min(80_000_000, max(24_000_000, Int(rawEstimate.rounded())))
  }
}

private struct EncoderConfiguration: Equatable {
  let width: Int
  let height: Int
  let framesPerSecond: Double
  let averageBitRate: Int
}

private struct WriteBatch {
  let data: Data
  let isKeyFrame: Bool
  let isPracticeSettings: Bool
  let isVideoOrientation: Bool
  let presentationTime: CMTime
}

private enum StreamDropReason {
  case encoderBusy
  case encoderFailure
  case backpressure
}

private func golfTraceCompressionOutputCallback(
  outputCallbackRefCon: UnsafeMutableRawPointer?,
  sourceFrameRefCon: UnsafeMutableRawPointer?,
  status: OSStatus,
  infoFlags: VTEncodeInfoFlags,
  sampleBuffer: CMSampleBuffer?
) {
  guard let outputCallbackRefCon, let sampleBuffer else { return }
  let streamer = Unmanaged<HighSpeedH264Streamer>.fromOpaque(outputCallbackRefCon)
    .takeUnretainedValue()
  streamer.handleCompressedSampleBuffer(sampleBuffer, status: status)
}
