import AVFoundation
import Combine
import CoreMedia
import ImageIO

extension GolfTraceVideoOrientation {
  fileprivate var visionOrientation: CGImagePropertyOrientation {
    switch self {
    case .degrees0: return .up
    case .degrees90: return .right
    case .degrees180: return .down
    case .degrees270: return .left
    }
  }
}

struct CameraDeviceOption: Identifiable, Equatable {
  let id: String
  let name: String
  let isContinuityCamera: Bool
}

struct CameraCaptureSourceContext: Equatable {
  let sourceID: String
  let orientation: GolfTraceVideoOrientation
}

enum CameraCaptureSourceContextResolver {
  static let fallbackSourceID = "mac.camera.fallback"

  static func resolve(
    usesDirectIPhoneInput: Bool,
    receivedDirectOrientation: GolfTraceVideoOrientation,
    directHalfTurn: VideoHalfTurn,
    fallbackHalfTurn: VideoHalfTurn,
    activeFallbackSourceID: String?
  ) -> CameraCaptureSourceContext {
    if usesDirectIPhoneInput {
      return CameraCaptureSourceContext(
        sourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
        orientation: receivedDirectOrientation.addingHalfTurn(directHalfTurn.isEnabled)
      )
    }

    return CameraCaptureSourceContext(
      sourceID: activeFallbackSourceID ?? fallbackSourceID,
      orientation: GolfTraceVideoOrientation.degrees0.addingHalfTurn(
        fallbackHalfTurn.isEnabled
      )
    )
  }
}

struct FrameMetrics: Equatable {
  var dimensions = CGSize.zero
  var measuredFPS = 0.0
  var receivedFrames = 0
  var droppedFrames = 0
  var lastTimestamp: CMTime?

  var resolutionText: String {
    guard dimensions != .zero else { return "กำลังรอภาพ" }
    return "\(Int(dimensions.width)) × \(Int(dimensions.height))"
  }

  var fpsText: String {
    measuredFPS > 0 ? String(format: "%.1f FPS", measuredFPS) : "กำลังวัด FPS"
  }
}

/// High-frequency capture and overlay state observed only by the live stage and
/// diagnostics. Keeping it separate prevents every pose from invalidating the
/// root dashboard that owns `CameraCaptureModel`.
struct CameraLivePresentation: Equatable {
  var pose: PoseFrame?
  var swingMotion: SwingMotionFrame?
  var swingSessionStatus: String

  static let initial = CameraLivePresentation(
    pose: nil,
    swingMotion: nil,
    swingSessionStatus: SwingSessionDetectorState.waitingForStillness.displayName
  )
}

@MainActor
final class CameraLiveState: ObservableObject {
  @Published fileprivate(set) var frameMetrics = FrameMetrics()
  @Published fileprivate(set) var poseMetrics = PoseMetrics()
  @Published fileprivate(set) var presentation = CameraLivePresentation.initial

  var pose: PoseFrame? { presentation.pose }
  var swingMotion: SwingMotionFrame? { presentation.swingMotion }
  var swingSessionStatus: String { presentation.swingSessionStatus }

  fileprivate func apply(_ snapshot: LiveSwingSnapshot) {
    let nextPresentation = CameraLivePresentation(
      pose: snapshot.pose,
      swingMotion: snapshot.motion,
      swingSessionStatus: snapshot.sessionStatus
    )
    guard presentation != nextPresentation else { return }
    presentation = nextPresentation
  }

  fileprivate func resetPresentation(
    clearsPose: Bool,
    resetMotion: Bool
  ) {
    var nextPresentation = presentation
    if clearsPose {
      nextPresentation.pose = nil
    }
    if resetMotion {
      nextPresentation.swingMotion = LiveSwingPipeline.resetMotionSnapshot
    }
    nextPresentation.swingSessionStatus =
      SwingSessionDetectorState
      .waitingForStillness.displayName
    guard presentation != nextPresentation else { return }
    presentation = nextPresentation
  }
}

@MainActor
final class CameraCaptureModel: NSObject, ObservableObject {
  @Published private(set) var devices: [CameraDeviceOption] = []
  @Published var selectedDeviceID: String?
  @Published private(set) var isRunning = false
  @Published private(set) var status = "เปิดแอปกล้องวงสวิงบน iPhone ระบบจะเชื่อมผ่านเครือข่ายให้อัตโนมัติ"
  @Published private(set) var requestedFrameRate = 0.0
  @Published private(set) var activeFormatSummary = "ยังไม่มีกล้องที่กำลังทำงาน"
  @Published private(set) var swingSessionState: SwingSessionDetectorState = .waitingForStillness
  @Published private(set) var lastSwingSummary: SwingSessionSummary?
  @Published private(set) var lastSwingAnalysis: SwingAnalysisSummary?
  @Published private(set) var lastSwingEvidencePacket: SwingEvidencePacket?
  private(set) var lastSwingCaptureContext: LiveSwingCaptureContext?
  private(set) var currentLiveSwingCaptureContext = LiveSwingCaptureContext.initial
  @Published private(set) var videoHalfTurn: VideoHalfTurn
  private(set) var videoHalfTurnSource: VideoHalfTurnSource
  @Published private(set) var receivedVideoOrientation = GolfTraceVideoOrientation.degrees0

  let session = AVCaptureSession()
  let highSpeedReceiver = HighSpeedVideoReceiver()
  let liveState = CameraLiveState()

  var frameMetrics: FrameMetrics { liveState.frameMetrics }
  var pose: PoseFrame? { liveState.pose }
  var poseMetrics: PoseMetrics { liveState.poseMetrics }
  var swingMotion: SwingMotionFrame? { liveState.swingMotion }
  var swingSessionStatus: String { liveState.swingSessionStatus }

  private let videoOutput = AVCaptureVideoDataOutput()
  private let frameCollector = FrameCollector()
  private let poseDetector = PoseDetector()
  private let videoHalfTurnPreference: VideoHalfTurnPreference
  private var directIPhoneHalfTurn: VideoHalfTurn
  private var appleFallbackHalfTurn: VideoHalfTurn
  private var liveSwingPipeline: LiveSwingPipeline!
  private var liveSwingEpoch: UInt64 = 0
  private var currentInput: AVCaptureDeviceInput?
  private var deviceLookup: [String: AVCaptureDevice] = [:]
  private var cancellables = Set<AnyCancellable>()

  override convenience init() {
    self.init(
      videoHalfTurnPreference: VideoHalfTurnPreference(),
      automaticallyStartsHighSpeedInput: true
    )
  }

  init(
    videoHalfTurnPreference: VideoHalfTurnPreference,
    automaticallyStartsHighSpeedInput: Bool
  ) {
    self.videoHalfTurnPreference = videoHalfTurnPreference
    directIPhoneHalfTurn = videoHalfTurnPreference.load(for: .directIPhone)
    appleFallbackHalfTurn = videoHalfTurnPreference.load(for: .appleFallback)
    videoHalfTurnSource = .directIPhone
    videoHalfTurn = directIPhoneHalfTurn
    super.init()
    liveSwingPipeline = LiveSwingPipeline(
      onSnapshot: { [weak self] snapshot in
        self?.applyLiveSwingSnapshot(snapshot)
      },
      onCompletion: { [weak self] completion in
        self?.applyLiveSwingCompletion(completion)
      }
    )
    frameCollector.onMetrics = { [weak self] metrics in
      Task { @MainActor in
        guard let self else { return }
        self.liveState.frameMetrics = metrics
        self.updateLiveSwingCaptureContext()
      }
    }
    frameCollector.onSampleBuffer = { [weak poseDetector] sampleBuffer in
      poseDetector?.analyze(sampleBuffer)
    }
    poseDetector.onPose = { [weak liveSwingPipeline] pose, generation in
      liveSwingPipeline?.consume(pose, sourceGeneration: generation)
    }
    poseDetector.onMetrics = { [weak self, weak poseDetector] metrics, generation in
      Task { @MainActor in
        guard let self, poseDetector?.isGenerationCurrent(generation) == true else { return }
        self.liveState.poseMetrics = metrics
        self.updateLiveSwingCaptureContext()
      }
    }
    highSpeedReceiver.onSampleBuffer = { [weak poseDetector] sampleBuffer, orientation in
      poseDetector?.analyze(sampleBuffer, videoOrientation: orientation)
    }
    highSpeedReceiver.onStreamReset = { [weak self] in
      self?.prepareForNewHighSpeedStream()
    }
    highSpeedReceiver.$videoOrientation
      .removeDuplicates()
      .sink { [weak self] orientation in
        Task { @MainActor in
          self?.applyReceivedVideoOrientation(orientation)
        }
      }
      .store(in: &cancellables)
    highSpeedReceiver.$metrics
      .combineLatest(highSpeedReceiver.$practiceSettings)
      .sink { [weak self] _, _ in
        Task { @MainActor in
          self?.updateLiveSwingCaptureContext()
        }
      }
      .store(in: &cancellables)
    poseDetector.setVideoHalfTurn(videoHalfTurn.isEnabled)
    updateLiveSwingCaptureContext()
    if automaticallyStartsHighSpeedInput {
      startHighSpeedInput()
    }
  }

  var videoOrientation: GolfTraceVideoOrientation {
    let sourceOrientation: GolfTraceVideoOrientation =
      videoHalfTurnSource == .directIPhone ? receivedVideoOrientation : .degrees0
    return sourceOrientation.addingHalfTurn(videoHalfTurn == .rotated180)
  }

  var videoRotationDegrees: Double { videoOrientation.clockwiseDegrees }

  var videoRotationSwapsDimensions: Bool { videoOrientation.swapsDimensions }

  var selectedDevice: AVCaptureDevice? {
    guard let selectedDeviceID else { return nil }
    return deviceLookup[selectedDeviceID]
  }

  /// อุปกรณ์ที่กำลังส่งเฟรม fallback จริง อาจยังไม่ใช่ค่าที่ผู้ใช้เพิ่งเลือก
  /// จนกว่าจะหยุดและสร้าง capture session ใหม่
  var activeFallbackDevice: AVCaptureDevice? {
    currentInput?.device
  }

  func refreshDevices() {
    guard cameraPermissionIsAvailable else { return }

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
      mediaType: .video,
      position: .unspecified
    )

    deviceLookup = Dictionary(uniqueKeysWithValues: discovery.devices.map { ($0.uniqueID, $0) })
    devices = discovery.devices.map {
      CameraDeviceOption(
        id: $0.uniqueID,
        name: $0.localizedName,
        isContinuityCamera: $0.isContinuityCamera
      )
    }

    if let selectedDeviceID, deviceLookup[selectedDeviceID] != nil {
      return
    }

    selectedDeviceID = devices.first(where: \.isContinuityCamera)?.id ?? devices.first?.id

    if let selected = selectedDevice {
      status =
        selected.isContinuityCamera
        ? "กล้อง iPhone ผ่านระบบของ Apple พร้อมใช้: \(selected.localizedName)"
        : "กล้องพร้อมใช้: \(selected.localizedName)"
    } else {
      status = "ไม่พบกล้อง โปรดปลดล็อก iPhone กดเชื่อถือ แล้วต่อ USB-C หรือใช้ระบบกล้องของ Apple"
    }
  }

  func start() {
    guard cameraPermissionIsAvailable, let device = selectedDevice else { return }
    restoreVideoHalfTurn(for: .appleFallback)

    // A direct companion stream owns the same iPhone rear sensor. Stop the
    // Bonjour listener before asking Continuity Camera to take that sensor.
    if highSpeedReceiver.state != .stopped {
      highSpeedReceiver.stop()
    }

    do {
      let input = try AVCaptureDeviceInput(device: device)

      session.beginConfiguration()
      session.sessionPreset = .high

      if let currentInput {
        session.removeInput(currentInput)
      }
      if session.canAddInput(input) {
        session.addInput(input)
        currentInput = input
      }

      if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
        videoOutput.videoSettings = [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(frameCollector, queue: frameCollector.queue)
        session.addOutput(videoOutput)
      }
      session.commitConfiguration()

      frameCollector.reset()
      resetLiveSwingAnalysis(
        resetMotionAndMetrics: true,
        preservingLastCompletion: true,
        clearsLiveOverlay: true
      )
      poseDetector.setImageOrientation(.up)
      poseDetector.setVideoHalfTurn(videoHalfTurn == .rotated180)
      session.startRunning()
      configurePreferredFormat(for: device)
      frameCollector.reset()
      isRunning = true
      status =
        "กำลังใช้ทางสำรอง 60 FPS — \(device.isContinuityCamera ? "กล้อง iPhone ผ่านระบบของ Apple" : device.localizedName)"

      Task { @MainActor [weak self, weak device] in
        try? await Task.sleep(for: .milliseconds(750))
        guard let self, let device, self.isRunning,
          self.currentInput?.device.uniqueID == device.uniqueID
        else {
          return
        }
        self.configurePreferredFormat(for: device)
        self.frameCollector.reset()
      }
    } catch {
      print("[GolfTrace] Unable to start camera: \(error)")
      status = "เปิดกล้องไม่สำเร็จ โปรดลองค้นหากล้องใหม่แล้วเริ่มอีกครั้ง"
    }
  }

  func stop() {
    session.stopRunning()
    isRunning = false
    resetLiveSwingAnalysis(
      resetMotionAndMetrics: true,
      preservingLastCompletion: true,
      clearsLiveOverlay: true
    )
    status = "หยุดรับภาพสดแล้ว"
  }

  func startHighSpeedInput() {
    restoreVideoHalfTurn(for: .directIPhone)
    // The companion app needs the iPhone's physical rear camera. Releasing a
    // simultaneous Continuity session avoids two Mac/iPhone capture clients
    // competing for it and makes the on-screen preview unambiguously remote.
    if isRunning {
      session.stopRunning()
      isRunning = false
    }
    frameCollector.reset()
    resetLiveSwingAnalysis(
      resetMotionAndMetrics: true,
      preservingLastCompletion: true,
      clearsLiveOverlay: true
    )
    highSpeedReceiver.start()
    status =
      "Mac พร้อมรับภาพความเร็วสูงแล้ว — เปิดแอป “กล้องวงสวิง” บน iPhone ระบบจะเชื่อมผ่านเครือข่ายให้อัตโนมัติ ไม่ต้องต่อสาย"
  }

  func stopHighSpeedInput() {
    highSpeedReceiver.stop()
    resetLiveSwingAnalysis(
      resetMotionAndMetrics: false,
      preservingLastCompletion: true,
      clearsLiveOverlay: false
    )
    status = "หยุดรับภาพความเร็วสูงจาก iPhone แล้ว"
  }

  /// หมุนภาพทางหลัก 180° พร้อมกันทั้งภาพ, Vision และเส้นทับภาพ
  /// เพื่อไม่ให้แก้เฉพาะหน้าจอจนโครงกระดูกเหลื่อมจากคนจริง
  func toggleVideoHalfTurn() {
    videoHalfTurn = videoHalfTurn.toggled
    cache(videoHalfTurn, for: videoHalfTurnSource)
    videoHalfTurnPreference.save(videoHalfTurn, for: videoHalfTurnSource)
    poseDetector.setVideoHalfTurn(videoHalfTurn.isEnabled)
    resetLiveSwingAnalysis(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false,
      clearsLiveOverlay: true
    )
    updateLiveSwingCaptureContext()
  }

  private func restoreVideoHalfTurn(for source: VideoHalfTurnSource) {
    videoHalfTurnSource = source
    let restoredHalfTurn = videoHalfTurnPreference.load(for: source)
    cache(restoredHalfTurn, for: source)
    videoHalfTurn = restoredHalfTurn
    poseDetector.setVideoHalfTurn(videoHalfTurn.isEnabled)
  }

  private func cache(_ halfTurn: VideoHalfTurn, for source: VideoHalfTurnSource) {
    switch source {
    case .directIPhone:
      directIPhoneHalfTurn = halfTurn
    case .appleFallback:
      appleFallbackHalfTurn = halfTurn
    }
  }

  private func applyReceivedVideoOrientation(_ orientation: GolfTraceVideoOrientation) {
    guard receivedVideoOrientation != orientation else { return }
    receivedVideoOrientation = orientation
    // This default is used by the fallback camera path. Direct iPhone frames
    // carry their own orientation snapshot into PoseDetector.
    poseDetector.setImageOrientation(orientation.visionOrientation)
    resetLiveSwingAnalysis(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false,
      clearsLiveOverlay: true
    )
  }

  private func prepareForNewHighSpeedStream() {
    resetLiveSwingAnalysis(
      resetMotionAndMetrics: true,
      preservingLastCompletion: true,
      clearsLiveOverlay: true
    )
    poseDetector.setImageOrientation(receivedVideoOrientation.visionOrientation)
    poseDetector.setVideoHalfTurn(videoHalfTurn == .rotated180)
    status = "พบการเชื่อมต่อ iPhone ใหม่ — กำลังรอภาพและเริ่มจับวงใหม่อัตโนมัติ"
  }

  private func resetLiveSwingAnalysis(
    resetMotionAndMetrics: Bool,
    preservingLastCompletion: Bool,
    clearsLiveOverlay: Bool
  ) {
    poseDetector.reset()
    let token = liveSwingPipeline.reset(
      resetMotionAndMetrics: resetMotionAndMetrics,
      preservingLastCompletion: preservingLastCompletion
    )
    liveSwingEpoch = token.epoch

    liveState.resetPresentation(
      clearsPose: clearsLiveOverlay,
      resetMotion: resetMotionAndMetrics
    )
    if swingSessionState != .waitingForStillness {
      swingSessionState = .waitingForStillness
    }

    if !preservingLastCompletion {
      lastSwingSummary = nil
      lastSwingAnalysis = nil
      lastSwingEvidencePacket = nil
      lastSwingCaptureContext = nil
    }
  }

  private func applyLiveSwingSnapshot(_ snapshot: LiveSwingSnapshot) {
    guard snapshot.epoch == liveSwingEpoch else { return }
    liveState.apply(snapshot)
    if swingSessionState != snapshot.sessionState {
      swingSessionState = snapshot.sessionState
    }
  }

  private func applyLiveSwingCompletion(_ completion: LiveSwingCompletion) {
    guard completion.epoch == liveSwingEpoch else { return }
    lastSwingAnalysis = completion.result.summary
    lastSwingEvidencePacket = completion.result.evidencePacket
    lastSwingCaptureContext = completion.captureContext
    if lastSwingSummary != completion.session {
      lastSwingSummary = completion.session
    }
  }

  private func updateLiveSwingCaptureContext() {
    let directInput: Bool = {
      guard highSpeedReceiver.metrics.decodedFrames > 0 else { return false }
      switch highSpeedReceiver.state {
      case .connected, .stalled: return true
      case .stopped, .advertising, .failed: return false
      }
    }()
    let directFPS = highSpeedReceiver.metrics.decodedFPS
    let fallbackFPS = liveState.frameMetrics.measuredFPS
    let captureFPS =
      directInput && directFPS > 0
      ? directFPS
      : (fallbackFPS > 0 ? fallbackFPS : nil)
    let analysisFPS = liveState.poseMetrics.analysisFPS
    let dimensions =
      directInput ? highSpeedReceiver.metrics.dimensions : liveState.frameMetrics.dimensions
    let sourceContext = CameraCaptureSourceContextResolver.resolve(
      usesDirectIPhoneInput: directInput,
      receivedDirectOrientation: receivedVideoOrientation,
      directHalfTurn: directIPhoneHalfTurn,
      fallbackHalfTurn: appleFallbackHalfTurn,
      activeFallbackSourceID: activeFallbackDevice?.uniqueID
    )
    let context = LiveSwingCaptureContext(
      captureFPS: captureFPS,
      poseAnalysisFPS: analysisFPS > 0 ? analysisFPS : nil,
      cameraView: highSpeedReceiver.practiceSettings.cameraView.rawValue,
      sourceID: sourceContext.sourceID,
      orientation: SwingStoryboardCaptureOrientation(sourceContext.orientation),
      encodedPixelWidth: dimensions.width > 0 ? Int(dimensions.width.rounded()) : nil,
      encodedPixelHeight: dimensions.height > 0 ? Int(dimensions.height.rounded()) : nil
    )
    currentLiveSwingCaptureContext = context
    liveSwingPipeline.updateCaptureContext(context)
  }

  private var cameraPermissionIsAvailable: Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .notDetermined:
      status = "กำลังขอสิทธิ์ใช้กล้อง…"
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in
          guard let self else { return }
          self.status =
            granted
            ? "อนุญาตใช้กล้องแล้ว กรุณากดค้นหาใหม่"
            : "โปรดอนุญาตให้แอปใช้กล้องในหน้าการตั้งค่าระบบ"
          if granted { self.refreshDevices() }
        }
      }
      return false
    default:
      status = "โปรดอนุญาตให้แอปใช้กล้องในหน้าการตั้งค่าระบบ"
      return false
    }
  }

  private func configurePreferredFormat(for device: AVCaptureDevice) {
    let targetFPS = 60.0
    let targetDimensions = CMVideoDimensions(width: 1920, height: 1080)
    let candidates = device.formats.compactMap {
      format -> (AVCaptureDevice.Format, Double, CMVideoDimensions)? in
      guard
        let range = format.videoSupportedFrameRateRanges.first(where: {
          $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate
        })
      else {
        return nil
      }
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return (format, min(range.maxFrameRate, targetFPS), dimensions)
    }

    guard
      let preferred = candidates.min(by: { lhs, rhs in
        let leftDistance =
          abs(Int(lhs.2.width) - Int(targetDimensions.width))
          + abs(Int(lhs.2.height) - Int(targetDimensions.height))
        let rightDistance =
          abs(Int(rhs.2.width) - Int(targetDimensions.width))
          + abs(Int(rhs.2.height) - Int(targetDimensions.height))
        return leftDistance < rightDistance
      })
    else {
      activeFormatSummary = "กล้องไม่มีรูปแบบวิดีโอที่ใช้งานได้"
      return
    }

    do {
      try device.lockForConfiguration()
      device.activeFormat = preferred.0
      let timescale = CMTimeScale(max(1, Int32(preferred.1.rounded())))
      let duration = CMTime(value: 1, timescale: timescale)
      device.activeVideoMinFrameDuration = duration
      device.activeVideoMaxFrameDuration = duration
      device.unlockForConfiguration()

      let activeDimensions = CMVideoFormatDescriptionGetDimensions(
        device.activeFormat.formatDescription)
      let activeDuration = device.activeVideoMinFrameDuration
      let activeFrameRate =
        activeDuration.isValid && activeDuration.value != 0
        ? Double(activeDuration.timescale) / Double(activeDuration.value)
        : preferred.1
      requestedFrameRate = preferred.1
      activeFormatSummary =
        "กำลังใช้ \(Int(activeDimensions.width)) × \(Int(activeDimensions.height)) ที่ \(String(format: "%.0f", activeFrameRate)) FPS"
    } catch {
      requestedFrameRate = 0
      print("[GolfTrace] Unable to apply preferred camera format: \(error)")
      activeFormatSummary = "ใช้รูปแบบภาพที่ระบบเลือกให้"
    }
  }
}

/// AVCapture invokes this delegate on `queue`; all frame counters and timestamp
/// state stay on that serial queue. The explicit annotation documents the
/// ownership boundary for Swift 6's Dispatch concurrency checks.
final class FrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  let queue = DispatchQueue(label: "com.bda.golftrace.frame-collector", qos: .userInteractive)
  var onMetrics: ((FrameMetrics) -> Void)?
  var onSampleBuffer: ((CMSampleBuffer) -> Void)?

  private var timestamps: [CMTime] = []
  private var receivedFrames = 0
  private var droppedFrames = 0
  private var lastMetricsPublishedAt: TimeInterval = 0
  private var lastPublishedDimensions = CGSize.zero
  private var lastPublishedDropCount = 0

  func reset() {
    queue.async { [weak self] in
      self?.timestamps = []
      self?.receivedFrames = 0
      self?.droppedFrames = 0
      self?.lastMetricsPublishedAt = 0
      self?.lastPublishedDimensions = .zero
      self?.lastPublishedDropCount = 0
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    onSampleBuffer?(sampleBuffer)
    receivedFrames += 1
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    timestamps.append(timestamp)
    if timestamps.count > 60 { timestamps.removeFirst(timestamps.count - 60) }

    let measuredFPS: Double
    if let first = timestamps.first, timestamps.count > 1 {
      let duration = CMTimeGetSeconds(timestamp - first)
      measuredFPS = duration > 0 ? Double(timestamps.count - 1) / duration : 0
    } else {
      measuredFPS = 0
    }

    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let frameDimensions = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    let now = ProcessInfo.processInfo.systemUptime
    let mustPublish =
      lastMetricsPublishedAt == 0
      || frameDimensions != lastPublishedDimensions
      || droppedFrames != lastPublishedDropCount
    guard mustPublish || now - lastMetricsPublishedAt >= 0.1 else { return }
    lastMetricsPublishedAt = now
    lastPublishedDimensions = frameDimensions
    lastPublishedDropCount = droppedFrames
    onMetrics?(
      FrameMetrics(
        dimensions: frameDimensions,
        measuredFPS: measuredFPS,
        receivedFrames: receivedFrames,
        droppedFrames: droppedFrames,
        lastTimestamp: timestamp
      )
    )
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    droppedFrames += 1
  }
}
