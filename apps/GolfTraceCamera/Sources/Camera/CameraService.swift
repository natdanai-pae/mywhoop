import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation

final class CameraService: NSObject, ObservableObject {
  enum CaptureState: Equatable {
    case idle
    case requestingPermission
    case preparing
    case running
    case stopped
    case denied
    case restricted
    case unavailable
    case failed(String)

    var title: String {
      switch self {
      case .idle:
        return "พร้อมเริ่ม"
      case .requestingPermission:
        return "กำลังขอสิทธิ์ใช้กล้อง"
      case .preparing:
        return "กำลังเตรียมกล้องหลัง"
      case .running:
        return "กำลังแสดงภาพสด"
      case .stopped:
        return "หยุดภาพสดแล้ว"
      case .denied:
        return "ไม่ได้รับอนุญาตให้ใช้กล้อง"
      case .restricted:
        return "อุปกรณ์จำกัดการใช้กล้อง"
      case .unavailable:
        return "ไม่พบกล้องหลัง"
      case .failed:
        return "ตั้งค่ากล้องไม่สำเร็จ"
      }
    }

    var detail: String? {
      switch self {
      case .denied:
        return "โปรดอนุญาตให้แอปใช้กล้องในหน้าการตั้งค่า เพื่อเปิดภาพสด"
      case .restricted:
        return "อุปกรณ์หรือข้อกำหนดการจัดการเครื่องนี้จำกัดการใช้กล้อง"
      case .unavailable:
        return "ไม่พบกล้องวิดีโอด้านหลังบนอุปกรณ์นี้"
      case .failed(let message):
        return message
      default:
        return nil
      }
    }

    var isRunning: Bool {
      if case .running = self {
        return true
      }
      return false
    }

    var needsSettings: Bool {
      switch self {
      case .denied, .restricted:
        return true
      default:
        return false
      }
    }

    var canStart: Bool {
      switch self {
      case .requestingPermission, .preparing, .denied, .restricted, .unavailable:
        return false
      default:
        return true
      }
    }
  }

  struct FrameRateRange: Identifiable, Hashable {
    let minimum: Double
    let maximum: Double

    var id: String {
      "\(minimum)-\(maximum)"
    }

    var displayText: String {
      if abs(maximum - minimum) < 0.01 {
        return "\(Self.format(minimum)) FPS"
      }
      return "\(Self.format(minimum))–\(Self.format(maximum)) FPS"
    }

    private static func format(_ value: Double) -> String {
      String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }
  }

  struct CameraFormatInfo: Identifiable, Hashable {
    let index: Int
    let width: Int
    let height: Int
    let frameRateRanges: [FrameRateRange]

    var id: Int {
      index
    }

    var resolutionText: String {
      "\(width)×\(height)"
    }

    var capabilityText: String {
      frameRateRanges.map(\.displayText).joined(separator: ", ")
    }

    var maximumFrameRate: Double {
      frameRateRanges.map(\.maximum).max() ?? 0
    }
  }

  struct CaptureProfile: Identifiable, Hashable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let framesPerSecond: Double

    var displayText: String {
      "\(width)×\(height) ที่ \(Self.format(framesPerSecond)) FPS"
    }

    private static func format(_ value: Double) -> String {
      String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }
  }

  struct ActiveCaptureConfiguration: Equatable {
    let width: Int
    let height: Int
    let configuredFrameRate: Double?
    let supportedFrameRateRanges: [FrameRateRange]

    var displayText: String {
      "\(width)×\(height) ที่ \(frameRateText)"
    }

    var frameRateText: String {
      guard let configuredFrameRate else { return "FPS ที่ระบบเลือก" }
      return "\(Self.format(configuredFrameRate)) FPS"
    }

    var supportedFrameRateText: String {
      supportedFrameRateRanges.map(\.displayText).joined(separator: ", ")
    }

    func matches(_ profile: CaptureProfile) -> Bool {
      width == profile.width
        && height == profile.height
        && configuredFrameRate.map { abs($0 - profile.framesPerSecond) < 0.5 } == true
    }

    private static func format(_ value: Double) -> String {
      String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }
  }

  let session = AVCaptureSession()

  @Published private(set) var state: CaptureState = .idle
  @Published private(set) var cameraName: String?
  @Published private(set) var activeFormatFrameRates: [FrameRateRange] = []
  @Published private(set) var rearCameraFormats: [CameraFormatInfo] = []
  @Published private(set) var availableProfiles: [CaptureProfile] = []
  @Published private(set) var requestedProfile: CaptureProfile?
  @Published private(set) var activeConfiguration: ActiveCaptureConfiguration?
  @Published private(set) var deliveredFrameRate: Double?
  @Published private(set) var droppedFrameCount = 0
  @Published private(set) var macStreamState: HighSpeedStreamState = .stopped
  @Published private(set) var macStreamMetrics = HighSpeedStreamMetrics()
  @Published private(set) var practiceSettings = GolfPracticeSettings.default

  private let sessionQueue = DispatchQueue(label: "com.bda.golftrace.camera-session")
  private let frameProbeQueue = DispatchQueue(
    label: "com.bda.golftrace.frame-probe", qos: .userInteractive)
  private let videoOutput = AVCaptureVideoDataOutput()
  private let highSpeedStreamer = HighSpeedH264Streamer()
  private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
  private var captureRotationObservation: NSKeyValueObservation?

  private var configuredDevice: AVCaptureDevice?
  private var isConfigured = false
  private var isTransitioning = false
  private var profileCandidates: [String: ProfileCandidate] = [:]
  private var selectedProfileID: String?
  private var discoveredFormats: [CameraFormatInfo] = []
  private var discoveredProfiles: [CaptureProfile] = []

  private var recentPresentationTimes: [CMTime] = []
  private var lastPublishedProbeSeconds: Double?
  private var lastLoggedProbeSeconds: Double?
  private var droppedFrames = 0

  override init() {
    super.init()
    if let data = UserDefaults.standard.data(forKey: Self.practiceSettingsKey),
      let saved = GolfPracticeSettings.decode(data)
    {
      practiceSettings = saved
    }
    highSpeedStreamer.updatePracticeSettings(practiceSettings)
    highSpeedStreamer.onUpdate = { [weak self] state, metrics in
      self?.macStreamState = state
      self?.macStreamMetrics = metrics
    }
  }

  deinit {
    captureRotationObservation?.invalidate()
  }

  func selectClub(_ club: GolfClub) {
    updatePracticeSettings { $0.club = club }
  }

  func selectCameraView(_ cameraView: GolfCameraView) {
    updatePracticeSettings { $0.cameraView = cameraView }
  }

  func selectGuideline(_ guideline: GolfGuideline) {
    updatePracticeSettings { $0.guideline = guideline }
  }

  func selectCoach(_ coach: GolfCoachProfileID) {
    updatePracticeSettings { $0.coach = coach }
  }

  func selectCoachAudioDevice(_ audioDevice: GolfCoachAudioDevice) {
    updatePracticeSettings { $0.audioDevice = audioDevice }
  }

  private func updatePracticeSettings(_ update: (inout GolfPracticeSettings) -> Void) {
    var next = practiceSettings
    update(&next)
    guard next != practiceSettings else { return }
    practiceSettings = next
    if let data = next.encoded() {
      UserDefaults.standard.set(data, forKey: Self.practiceSettingsKey)
    }
    highSpeedStreamer.updatePracticeSettings(next)
  }

  private static let practiceSettingsKey = "GolfTrace.practiceSettings.v1"

  private static let profileTargets = [
    ProfileTarget(
      id: "1080p120",
      title: "1080p 120 FPS (แนะนำ)",
      width: 1_920,
      height: 1_080,
      framesPerSecond: 120
    ),
    ProfileTarget(
      id: "1080p60",
      title: "1080p 60 FPS",
      width: 1_920,
      height: 1_080,
      framesPerSecond: 60
    ),
    ProfileTarget(
      id: "1080p240",
      title: "1080p 240 FPS",
      width: 1_920,
      height: 1_080,
      framesPerSecond: 240
    ),
    ProfileTarget(
      id: "4k120",
      title: "4K 120 FPS",
      width: 3_840,
      height: 2_160,
      framesPerSecond: 120
    ),
  ]

  func startPreview() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureAndStartPreview()

    case .notDetermined:
      guard state != .requestingPermission else { return }
      state = .requestingPermission
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          self.configureAndStartPreview()
        } else {
          self.publishState(.denied)
        }
      }

    case .denied:
      state = .denied

    case .restricted:
      state = .restricted

    @unknown default:
      state = .denied
    }
  }

  func stopPreview() {
    highSpeedStreamer.stop()
    sessionQueue.async { [weak self] in
      guard let self else { return }

      if self.session.isRunning {
        self.session.stopRunning()
      }
      self.resetFrameProbe()
      self.publishState(.stopped)
    }
  }

  func selectProfile(_ profile: CaptureProfile) {
    sessionQueue.async { [weak self] in
      guard let self, !self.isTransitioning else { return }
      self.isTransitioning = true
      self.publishState(.preparing)

      defer { self.isTransitioning = false }

      do {
        try self.configureSessionIfNeeded()

        guard let candidate = self.profileCandidates[profile.id] else {
          throw CameraError.profileNoLongerAvailable(profile.title)
        }

        try self.apply(candidate)
        self.selectedProfileID = candidate.profile.id
        self.resetFrameProbe()

        if !self.session.isRunning {
          self.session.startRunning()
        }

        self.publishRuntimeSnapshot(state: .running)
      } catch {
        self.publishConfigurationError(error)
      }
    }
  }

  func startMacStream() {
    sessionQueue.async { [weak self] in
      self?.startMacStreamForActiveConfiguration()
    }
  }

  func stopMacStream() {
    highSpeedStreamer.stop()
  }

  private func configureAndStartPreview() {
    sessionQueue.async { [weak self] in
      guard let self, !self.isTransitioning else { return }

      if self.isConfigured && self.session.isRunning {
        self.publishRuntimeSnapshot(state: .running)
        self.startMacStreamForActiveConfiguration()
        return
      }

      self.isTransitioning = true
      self.publishState(.preparing)

      defer { self.isTransitioning = false }

      do {
        try self.configureSessionIfNeeded()

        if let candidate = self.selectedOrPreferredProfile() {
          try self.apply(candidate)
          self.selectedProfileID = candidate.profile.id
        }

        self.resetFrameProbe()

        if !self.session.isRunning {
          self.session.startRunning()
        }

        self.publishRuntimeSnapshot(state: .running)
        self.startMacStreamForActiveConfiguration()
      } catch {
        self.publishConfigurationError(error)
      }
    }
  }

  /// The companion has one job: feed the paired Mac. Start discovery as soon
  /// as the rear camera is ready so a normal launch needs no extra tap.
  private func startMacStreamForActiveConfiguration() {
    guard let device = configuredDevice else { return }
    let active = activeConfiguration(for: device)
    guard let framesPerSecond = active.configuredFrameRate else { return }

    highSpeedStreamer.configure(
      width: active.width,
      height: active.height,
      framesPerSecond: framesPerSecond
    )
    highSpeedStreamer.start()
  }

  private func configureSessionIfNeeded() throws {
    guard !isConfigured else { return }
    guard let device = rearVideoDevice() else {
      throw CameraError.noRearCamera
    }

    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()

    var didAddInput = false
    var didAddOutput = false
    var completed = false

    defer {
      if !completed {
        if didAddOutput {
          session.removeOutput(videoOutput)
        }
        if didAddInput {
          session.removeInput(input)
        }
      }
      session.commitConfiguration()
    }

    guard session.canAddInput(input) else {
      throw CameraError.cannotAddInput
    }
    session.addInput(input)
    didAddInput = true

    guard session.canSetSessionPreset(.inputPriority) else {
      throw CameraError.inputPriorityUnsupported
    }
    session.sessionPreset = .inputPriority

    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    videoOutput.setSampleBufferDelegate(self, queue: frameProbeQueue)

    guard session.canAddOutput(videoOutput) else {
      throw CameraError.cannotAddVideoOutput
    }
    session.addOutput(videoOutput)
    didAddOutput = true

    configuredDevice = device
    configureOrientationMetadata(for: device)
    discoveredFormats = formatCatalog(for: device)
    profileCandidates = makeProfileCandidates(for: device)
    discoveredProfiles = Self.profileTargets.compactMap { self.profileCandidates[$0.id]?.profile }
    isConfigured = true
    completed = true

    let detectedProfiles = discoveredProfiles.map(\.displayText).joined(separator: " | ")
    print(
      "[GolfTraceCamera] Rear camera \(device.localizedName): \(discoveredFormats.count) formats; "
        + "detected profiles: \(detectedProfiles.isEmpty ? "none" : detectedProfiles)"
    )
  }

  /// ใช้องศาจากระบบกล้องของ Apple แต่ส่งเป็น metadata เท่านั้น
  /// จึงไม่เพิ่มภาระหมุนพิกเซลทุกเฟรมในเส้นทาง 120 FPS
  private func configureOrientationMetadata(for device: AVCaptureDevice) {
    captureRotationObservation?.invalidate()
    let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    captureRotationCoordinator = coordinator
    captureRotationObservation = coordinator.observe(
      \.videoRotationAngleForHorizonLevelCapture,
      options: [.initial, .new]
    ) { [weak self] coordinator, _ in
      let orientation = GolfTraceVideoOrientation.nearest(
        to: Double(coordinator.videoRotationAngleForHorizonLevelCapture)
      )
      self?.highSpeedStreamer.updateVideoOrientation(orientation)
    }
  }

  private func selectedOrPreferredProfile() -> ProfileCandidate? {
    if let selectedProfileID, let candidate = profileCandidates[selectedProfileID] {
      return candidate
    }

    return Self.profileTargets.lazy.compactMap { self.profileCandidates[$0.id] }.first
  }

  private func apply(_ candidate: ProfileCandidate) throws {
    guard let device = configuredDevice else {
      throw CameraError.noRearCamera
    }
    guard formatSupports(candidate.format, profile: candidate.profile) else {
      throw CameraError.profileNoLongerAvailable(candidate.profile.title)
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    guard session.canSetSessionPreset(.inputPriority) else {
      throw CameraError.inputPriorityUnsupported
    }
    session.sessionPreset = .inputPriority

    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }

    device.activeFormat = candidate.format
    let frameDuration = CMTime(
      value: 1,
      timescale: Int32(candidate.profile.framesPerSecond.rounded())
    )
    device.activeVideoMinFrameDuration = frameDuration
    device.activeVideoMaxFrameDuration = frameDuration

    let active = activeConfiguration(for: device)
    if let framesPerSecond = active.configuredFrameRate {
      highSpeedStreamer.configure(
        width: active.width,
        height: active.height,
        framesPerSecond: framesPerSecond
      )
    }
    print(
      "[GolfTraceCamera] Requested \(candidate.profile.displayText); active \(active.displayText); "
        + "active capability \(active.supportedFrameRateText)"
    )
  }

  private func rearVideoDevice() -> AVCaptureDevice? {
    if let wideAngleCamera = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: .back
    ) {
      return wideAngleCamera
    }

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInDualCamera,
        .builtInDualWideCamera,
        .builtInTripleCamera,
      ],
      mediaType: .video,
      position: .back
    )
    return discovery.devices.first
  }

  private func formatCatalog(for device: AVCaptureDevice) -> [CameraFormatInfo] {
    var catalog: [CameraFormatInfo] = []

    for (index, format) in device.formats.enumerated() {
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      catalog.append(
        CameraFormatInfo(
          index: index,
          width: Int(dimensions.width),
          height: Int(dimensions.height),
          frameRateRanges: frameRateRanges(for: format)
        ))
    }

    return catalog.sorted {
      let leftPixels = $0.width * $0.height
      let rightPixels = $1.width * $1.height

      if leftPixels != rightPixels {
        return leftPixels > rightPixels
      }
      if $0.maximumFrameRate != $1.maximumFrameRate {
        return $0.maximumFrameRate > $1.maximumFrameRate
      }
      return $0.index < $1.index
    }
  }

  private func makeProfileCandidates(for device: AVCaptureDevice) -> [String: ProfileCandidate] {
    var candidates: [String: ProfileCandidate] = [:]

    for target in Self.profileTargets {
      guard let format = device.formats.first(where: { self.formatSupports($0, target: target) })
      else {
        continue
      }

      let profile = CaptureProfile(
        id: target.id,
        title: target.title,
        width: target.width,
        height: target.height,
        framesPerSecond: target.framesPerSecond
      )
      candidates[target.id] = ProfileCandidate(profile: profile, format: format)
    }

    return candidates
  }

  private func formatSupports(_ format: AVCaptureDevice.Format, target: ProfileTarget) -> Bool {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    guard Int(dimensions.width) == target.width, Int(dimensions.height) == target.height else {
      return false
    }

    return format.videoSupportedFrameRateRanges.contains {
      $0.minFrameRate <= target.framesPerSecond && target.framesPerSecond <= $0.maxFrameRate
    }
  }

  private func formatSupports(_ format: AVCaptureDevice.Format, profile: CaptureProfile) -> Bool {
    formatSupports(
      format,
      target: ProfileTarget(
        id: profile.id,
        title: profile.title,
        width: profile.width,
        height: profile.height,
        framesPerSecond: profile.framesPerSecond
      )
    )
  }

  private func activeConfiguration(for device: AVCaptureDevice) -> ActiveCaptureConfiguration {
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let ranges = frameRateRanges(for: device.activeFormat)

    return ActiveCaptureConfiguration(
      width: Int(dimensions.width),
      height: Int(dimensions.height),
      configuredFrameRate: framesPerSecond(for: device.activeVideoMinFrameDuration),
      supportedFrameRateRanges: ranges
    )
  }

  private func frameRateRanges(for format: AVCaptureDevice.Format) -> [FrameRateRange] {
    let ranges = format.videoSupportedFrameRateRanges.map {
      FrameRateRange(minimum: $0.minFrameRate, maximum: $0.maxFrameRate)
    }

    return ranges.sorted {
      if $0.maximum == $1.maximum {
        return $0.minimum < $1.minimum
      }
      return $0.maximum < $1.maximum
    }
  }

  private func framesPerSecond(for frameDuration: CMTime) -> Double? {
    guard frameDuration.isValid, frameDuration.value > 0, frameDuration.timescale > 0 else {
      return nil
    }
    return Double(frameDuration.timescale) / Double(frameDuration.value)
  }

  private func resetFrameProbe() {
    frameProbeQueue.async { [weak self] in
      guard let self else { return }
      self.recentPresentationTimes.removeAll(keepingCapacity: true)
      self.lastPublishedProbeSeconds = nil
      self.lastLoggedProbeSeconds = nil
      self.droppedFrames = 0

      DispatchQueue.main.async { [weak self] in
        self?.deliveredFrameRate = nil
        self?.droppedFrameCount = 0
      }
    }
  }

  private func publishRuntimeSnapshot(state: CaptureState) {
    let active = configuredDevice.map(activeConfiguration(for:))
    let requested = selectedProfileID.flatMap { profileCandidates[$0]?.profile }
    let cameraName = configuredDevice?.localizedName
    let activeFrameRates = active?.supportedFrameRateRanges ?? []
    let allFormats = discoveredFormats
    let profiles = discoveredProfiles

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.state = state
      self.cameraName = cameraName
      self.activeConfiguration = active
      self.activeFormatFrameRates = activeFrameRates
      self.rearCameraFormats = allFormats
      self.availableProfiles = profiles
      self.requestedProfile = requested
    }
  }

  private func publishState(_ state: CaptureState) {
    DispatchQueue.main.async { [weak self] in
      self?.state = state
    }
  }

  private func publishConfigurationError(_ error: Error) {
    if case CameraError.noRearCamera = error {
      publishState(.unavailable)
    } else if let message = (error as? CameraError)?.errorDescription {
      publishState(.failed(message))
    } else {
      print("[GolfTraceCamera] Camera configuration failed: \(error)")
      publishState(.failed("ตั้งค่ากล้องไม่สำเร็จ โปรดลองหยุดแล้วเริ่มภาพสดอีกครั้ง"))
    }
  }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    highSpeedStreamer.append(sampleBuffer)
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard presentationTime.isValid else { return }

    let presentationSeconds = CMTimeGetSeconds(presentationTime)
    guard presentationSeconds.isFinite else { return }

    recentPresentationTimes.append(presentationTime)
    while let first = recentPresentationTimes.first,
      presentationSeconds - CMTimeGetSeconds(first) > 2
    {
      recentPresentationTimes.removeFirst()
    }

    guard recentPresentationTimes.count > 1,
      let first = recentPresentationTimes.first
    else {
      return
    }

    let elapsed = presentationSeconds - CMTimeGetSeconds(first)
    guard elapsed >= 1 else { return }

    let framesPerSecond = Double(recentPresentationTimes.count - 1) / elapsed
    guard
      lastPublishedProbeSeconds == nil
        || presentationSeconds - (lastPublishedProbeSeconds ?? presentationSeconds) >= 0.5
    else {
      return
    }
    lastPublishedProbeSeconds = presentationSeconds
    highSpeedStreamer.updateCaptureFrameRate(framesPerSecond)

    if lastLoggedProbeSeconds == nil
      || presentationSeconds - (lastLoggedProbeSeconds ?? presentationSeconds) >= 5
    {
      lastLoggedProbeSeconds = presentationSeconds
      print(
        "[GolfTraceCamera] Delivered \(String(format: "%.1f", framesPerSecond)) fps; "
          + "callback drops \(droppedFrames)"
      )
    }

    DispatchQueue.main.async { [weak self] in
      self?.deliveredFrameRate = framesPerSecond
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    droppedFrames += 1
    let currentDrops = droppedFrames

    DispatchQueue.main.async { [weak self] in
      self?.droppedFrameCount = currentDrops
    }
  }
}

private struct ProfileTarget {
  let id: String
  let title: String
  let width: Int
  let height: Int
  let framesPerSecond: Double
}

private struct ProfileCandidate {
  let profile: CameraService.CaptureProfile
  let format: AVCaptureDevice.Format
}

private enum CameraError: LocalizedError {
  case noRearCamera
  case cannotAddInput
  case cannotAddVideoOutput
  case inputPriorityUnsupported
  case profileNoLongerAvailable(String)

  var errorDescription: String? {
    switch self {
    case .noRearCamera:
      return "อุปกรณ์นี้ไม่มีกล้องวิดีโอด้านหลังที่ใช้งานได้"
    case .cannotAddInput:
      return "เพิ่มกล้องหลังเข้าสู่ระบบรับภาพไม่สำเร็จ"
    case .cannotAddVideoOutput:
      return "เพิ่มตัวตรวจวัด FPS เข้าสู่ระบบรับภาพไม่สำเร็จ"
    case .inputPriorityUnsupported:
      return "ระบบกล้องไม่สามารถคงรูปแบบภาพที่เลือกไว้ได้"
    case .profileNoLongerAvailable(let profile):
      return "กล้องหลังที่ใช้อยู่ไม่รองรับโหมด \(profile) แล้ว"
    }
  }
}
