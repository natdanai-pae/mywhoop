@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation

/// เหตุการณ์เสียงเชิงความหมาย แยกจากรูปคลื่นเพื่อให้ทดสอบได้โดยไม่เปิดลำโพงจริง
enum SwingCueEvent: String, CaseIterable, Equatable, Sendable {
  case tempoStart
  case tempoTop
  case tempoImpact
  case tempoFinish
  case armed
  case completed
  case guidelinePositive
  case guidelineNegative
  case guidelineNeutral

  var displayName: String {
    switch self {
    case .tempoStart: return "เริ่มขึ้นไม้"
    case .tempoTop: return "ถึงจุดบนสุด"
    case .tempoImpact: return "จังหวะผ่านลูก"
    case .tempoFinish: return "จบท่า"
    case .armed: return "พร้อมจับวงสวิง"
    case .completed: return "บันทึกวงสวิงแล้ว"
    case .guidelinePositive: return "อยู่ในแนวทาง"
    case .guidelineNegative: return "ออกจากแนวทาง"
    case .guidelineNeutral: return "ข้อมูลยังไม่พอ"
    }
  }
}

/// ตัวเล่นเสียงที่ฉีดแทนได้ในการทดสอบ จึงไม่ผูก controller เข้ากับลำโพงจริง
@MainActor
protocol SwingCuePlaying: AnyObject {
  func schedule(_ event: SwingCueEvent, after delay: TimeInterval, volume: Float)
  func cancelAll()
}

/// จังหวะฝึกเป็นเสียงอ้างอิงที่ผู้ใช้กดเริ่มเอง ไม่ได้อ้างว่าเป็น impact ที่กล้องตรวจพบ
struct SwingTempoTrainerConfiguration: Equatable, Sendable {
  let backswingSeconds: TimeInterval
  let downswingSeconds: TimeInterval
  let finishDelaySeconds: TimeInterval

  init(
    backswingSeconds: TimeInterval = 1.2,
    downswingSeconds: TimeInterval = 0.4,
    finishDelaySeconds: TimeInterval = 0.4
  ) {
    self.backswingSeconds = Self.validDuration(backswingSeconds, fallback: 1.2)
    self.downswingSeconds = Self.validDuration(downswingSeconds, fallback: 0.4)
    self.finishDelaySeconds = Self.validDuration(finishDelaySeconds, fallback: 0.4)
  }

  var targetRatio: Double { backswingSeconds / downswingSeconds }
  var impactDelaySeconds: TimeInterval { backswingSeconds + downswingSeconds }
  var totalDurationSeconds: TimeInterval { impactDelaySeconds + finishDelaySeconds }

  private static func validDuration(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
    guard value.isFinite, value > 0 else { return fallback }
    return value
  }
}

struct SwingPostureGuidelineTarget: Equatable, Sendable {
  let addressTorsoTiltDegrees: Double
  let toleranceDegrees: Double
}

/// เกณฑ์ที่ผู้เรียกเลือกในรอบนั้น ค่า posture ไม่มีค่าเริ่มต้นเพราะต้องมาจากแนวทางที่ผู้ใช้เลือกจริง
struct SwingGuidelineEvaluationConfiguration: Equatable, Sendable {
  let tempoTargetRatio: Double
  let tempoTolerance: Double
  let postureTarget: SwingPostureGuidelineTarget?

  init(
    tempoTargetRatio: Double = 3.0,
    tempoTolerance: Double = 0.4,
    postureTarget: SwingPostureGuidelineTarget? = nil
  ) {
    self.tempoTargetRatio = tempoTargetRatio
    self.tempoTolerance = tempoTolerance
    self.postureTarget = postureTarget
  }
}

enum SwingGuidelineFeedbackStatus: String, Equatable, Sendable {
  case within
  case outside
  case unavailable

  var displayName: String {
    switch self {
    case .within: return "อยู่ในแนวทาง"
    case .outside: return "ออกจากแนวทาง"
    case .unavailable: return "ข้อมูลยังไม่พอ"
    }
  }
}

/// ผลนี้บอกเพียงว่า metric ที่วัดได้อยู่ในช่วงที่ผู้ใช้เลือกหรือไม่ ไม่ใช่คะแนนคุณภาพวงสวิง
struct SwingGuidelineFeedback: Equatable, Sendable {
  let guideline: GolfGuideline
  let status: SwingGuidelineFeedbackStatus
  let metricName: String?
  let measuredValue: Double?
  let targetValue: Double?
  let tolerance: Double?
  let quality: SwingMetricQuality?
  let message: String
}

/// ประสานเสียงฝึกจังหวะ เสียงสถานะ session และเสียงผล guideline โดยไม่แก้ detector
@MainActor
final class SwingCueCoordinator: ObservableObject {
  @Published private(set) var isTempoTrainerRunning = false
  @Published private(set) var statusText = "เสียงช่วยฝึกพร้อมใช้งาน"
  @Published private(set) var lastGuidelineFeedback: SwingGuidelineFeedback?

  let readyDebounceSeconds: TimeInterval

  private let player: any SwingCuePlaying
  private let currentTime: () -> TimeInterval
  private var tempoCompletionTask: Task<Void, Never>?
  private var preservesTempoDuringActiveSwing = false
  private var lastSessionState: SwingSessionDetectorState?
  private var armedCueHandledForCurrentRound = false
  private var lastArmedCueTime: TimeInterval?
  private var lastCompletedEndTimestamp: CMTime?

  init(
    player: (any SwingCuePlaying)? = nil,
    readyDebounceSeconds: TimeInterval = 5.0,
    currentTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.player = player ?? AVFoundationSwingCuePlayer()
    self.readyDebounceSeconds = max(5.0, readyDebounceSeconds)
    self.currentTime = currentTime
  }

  deinit {
    tempoCompletionTask?.cancel()
  }

  /// เริ่มเสียงฝึก 4 จุด: เริ่มขึ้นไม้ → จุดบนสุด → ผ่านลูก → จบท่า
  ///
  /// ค่าเริ่มต้น 1.2/0.4 วินาทีคือเป้าหมาย 3:1 และเป็นเพียง metronome ที่ผู้ใช้กดเอง
  func startTempoTrainer(
    configuration: SwingTempoTrainerConfiguration = SwingTempoTrainerConfiguration(),
    volume: Float = 0.75,
    preserveDuringActiveSwing: Bool = false
  ) {
    guard lastSessionState != .confirmingSwing, lastSessionState != .swinging else {
      cancelAllCues(updateStatus: false)
      statusText = "กำลังจับวงจริง จึงยังไม่เริ่มเสียงฝึกจังหวะ"
      return
    }
    cancelAllCues(updateStatus: false)
    preservesTempoDuringActiveSwing = preserveDuringActiveSwing
    let safeVolume = min(1, max(0, volume))

    player.schedule(.tempoStart, after: 0, volume: safeVolume)
    player.schedule(.tempoTop, after: configuration.backswingSeconds, volume: safeVolume)
    player.schedule(.tempoImpact, after: configuration.impactDelaySeconds, volume: safeVolume)
    player.schedule(.tempoFinish, after: configuration.totalDurationSeconds, volume: safeVolume)

    isTempoTrainerRunning = true
    statusText = String(
      format: "กำลังฝึกจังหวะ %.1f : 1",
      locale: Locale(identifier: "th_TH"),
      configuration.targetRatio
    )

    tempoCompletionTask = Task { @MainActor [weak self] in
      let nanoseconds = Self.nanoseconds(for: configuration.totalDurationSeconds + 0.35)
      do {
        try await Task.sleep(nanoseconds: nanoseconds)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      self.isTempoTrainerRunning = false
      self.statusText = "ฝึกจังหวะครบหนึ่งรอบ"
      self.tempoCompletionTask = nil
    }
  }

  func cancelAllCues() {
    cancelAllCues(updateStatus: true)
  }

  /// รับเฉพาะสถานะที่ detector สรุปแล้ว ไม่มีการเดา impact จาก phase ระหว่างตี
  func handleSessionState(
    _ state: SwingSessionDetectorState,
    completedSummary: SwingSessionSummary? = nil,
    volume: Float = 0.75,
    playCompletedCue: Bool = true
  ) {
    defer { lastSessionState = state }
    let safeVolume = min(1, max(0, volume))

    switch state {
    case .waitingForStillness:
      statusText = state.displayName

    case .armed:
      handleArmedState(volume: safeVolume)

    case .confirmingSwing, .swinging:
      // ไม่ให้ metronome หรือเสียงเก่าดังรบกวนระหว่างวงจริง
      // ยกเว้น one-take ที่ผู้ใช้ขอ Tempo ไว้โดยตรงหลังนับถอยหลัง
      if !preservesTempoDuringActiveSwing {
        cancelAllCues(updateStatus: false)
      }
      statusText = state.displayName

    case .completed:
      handleCompletedState(
        completedSummary,
        volume: safeVolume,
        playCue: playCompletedCue
      )
    }
  }

  /// ประเมินหลังวงจาก metric ที่มี provenance อยู่แล้ว และเล่นเสียงตามผล
  @discardableResult
  func provideGuidelineFeedback(
    analysis: SwingAnalysisSummary,
    guideline: GolfGuideline,
    configuration: SwingGuidelineEvaluationConfiguration = SwingGuidelineEvaluationConfiguration(),
    volume: Float = 0.75
  ) -> SwingGuidelineFeedback {
    let feedback = evaluateGuideline(
      analysis: analysis,
      guideline: guideline,
      configuration: configuration
    )
    lastGuidelineFeedback = feedback
    statusText = feedback.message

    let event: SwingCueEvent
    switch feedback.status {
    case .within:
      event = .guidelinePositive
    case .outside:
      event = .guidelineNegative
    case .unavailable:
      // หลักฐานไม่พอไม่ควรใช้เสียงลบ เพราะไม่ได้แปลว่าวงผิด
      event = .guidelineNeutral
    }
    if lastSessionState != .confirmingSwing, lastSessionState != .swinging {
      player.schedule(event, after: 0, volume: min(1, max(0, volume)))
    }
    return feedback
  }

  func evaluateGuideline(
    analysis: SwingAnalysisSummary,
    guideline: GolfGuideline,
    configuration: SwingGuidelineEvaluationConfiguration = SwingGuidelineEvaluationConfiguration()
  ) -> SwingGuidelineFeedback {
    switch guideline {
    case .tempo:
      return evaluateTempo(analysis.handTempoRatio, configuration: configuration)

    case .posture:
      return evaluatePosture(analysis.addressTorsoTiltDegrees, configuration: configuration)

    case .personalBaseline:
      return unavailable(
        guideline: guideline,
        message: "ยังไม่มี baseline ส่วนตัวที่เทียบแบบ metric เดียวกัน จึงยังไม่ตัดสินวงนี้"
      )

    case .swingPlane:
      return unavailable(
        guideline: guideline,
        message: "ภาพร่างกายสองมิติยังไม่ใช่ข้อมูลหัวไม้ จึงยังไม่ตัดสินแนวสวิง"
      )

    case .rotation:
      return unavailable(
        guideline: guideline,
        message: "ค่าความกว้างไหล่และสะโพกในภาพสองมิติยังไม่ใช่มุมหมุนสามมิติ จึงยังไม่ตัดสินการหมุน"
      )

    case .none:
      return unavailable(
        guideline: guideline,
        message: "รอบนี้ไม่ได้เลือกแนวทางสำหรับเปรียบเทียบ"
      )
    }
  }

  /// ใช้เมื่อเริ่ม stream หรือ session ใหม่โดยเจตนา ไม่ได้ผูกกับ reconnect อัตโนมัติ
  func resetRoundTracking() {
    cancelAllCues(updateStatus: false)
    lastSessionState = nil
    armedCueHandledForCurrentRound = false
    lastArmedCueTime = nil
    lastCompletedEndTimestamp = nil
    lastGuidelineFeedback = nil
    statusText = "เสียงช่วยฝึกพร้อมใช้งาน"
  }

  private func handleArmedState(volume: Float) {
    guard lastSessionState != .armed, !armedCueHandledForCurrentRound else {
      statusText = SwingSessionDetectorState.armed.displayName
      return
    }

    armedCueHandledForCurrentRound = true
    let now = currentTime()
    let mayPlay = lastArmedCueTime.map { now - $0 >= readyDebounceSeconds } ?? true
    if mayPlay {
      player.schedule(.armed, after: 0, volume: volume)
      lastArmedCueTime = now
    }
    statusText = SwingSessionDetectorState.armed.displayName
  }

  private func handleCompletedState(
    _ summary: SwingSessionSummary?,
    volume: Float,
    playCue: Bool
  ) {
    if isTempoTrainerRunning {
      cancelAllCues(updateStatus: false)
    }
    guard let summary, summary.endTimestamp.isValid, summary.endTimestamp.isNumeric else {
      statusText = "บันทึกจบแล้ว แต่ไม่มีเวลาจบที่ใช้ยืนยันเสียงได้"
      return
    }

    if let lastCompletedEndTimestamp,
      CMTimeCompare(lastCompletedEndTimestamp, summary.endTimestamp) == 0
    {
      statusText = SwingSessionDetectorState.completed.displayName
      return
    }

    if playCue {
      player.schedule(.completed, after: 0, volume: volume)
    }
    lastCompletedEndTimestamp = summary.endTimestamp
    armedCueHandledForCurrentRound = false
    statusText = SwingSessionDetectorState.completed.displayName
  }

  private func evaluateTempo(
    _ reading: SwingMetricReading,
    configuration: SwingGuidelineEvaluationConfiguration
  ) -> SwingGuidelineFeedback {
    guard configuration.tempoTargetRatio.isFinite,
      configuration.tempoTargetRatio > 0,
      configuration.tempoTolerance.isFinite,
      configuration.tempoTolerance >= 0
    else {
      return unavailable(guideline: .tempo, message: "ช่วงจังหวะที่เลือกไม่ถูกต้อง จึงยังไม่เปรียบเทียบ")
    }
    guard let value = usableValue(reading) else {
      return unavailable(
        guideline: .tempo,
        quality: reading.quality,
        message: "ติดตามจังหวะมือไม่ต่อเนื่องพอ จึงยังไม่บอกว่าเร็วหรือช้า"
      )
    }

    let difference = abs(value - configuration.tempoTargetRatio)
    let status: SwingGuidelineFeedbackStatus =
      difference <= configuration.tempoTolerance
      ? .within
      : .outside
    let message =
      status == .within
      ? String(format: "จังหวะมือ %.2f : 1 อยู่ในช่วงเป้าหมาย", value)
      : String(format: "จังหวะมือ %.2f : 1 อยู่นอกช่วงเป้าหมาย ลองปรับทีละน้อย", value)
    return SwingGuidelineFeedback(
      guideline: .tempo,
      status: status,
      metricName: "อัตราจังหวะมือ",
      measuredValue: value,
      targetValue: configuration.tempoTargetRatio,
      tolerance: configuration.tempoTolerance,
      quality: reading.quality,
      message: message
    )
  }

  private func evaluatePosture(
    _ reading: SwingMetricReading,
    configuration: SwingGuidelineEvaluationConfiguration
  ) -> SwingGuidelineFeedback {
    guard let target = configuration.postureTarget,
      target.addressTorsoTiltDegrees.isFinite,
      target.toleranceDegrees.isFinite,
      target.toleranceDegrees >= 0
    else {
      return unavailable(
        guideline: .posture,
        quality: reading.quality,
        message: "ยังไม่ได้เลือกค่าท่าเตรียมและช่วงยอมรับ จึงยังไม่เปรียบเทียบ"
      )
    }
    guard let value = usableValue(reading) else {
      return unavailable(
        guideline: .posture,
        quality: reading.quality,
        message: "มุมลำตัวตอนท่าเตรียมมีข้อมูลไม่พอ จึงยังไม่ตัดสินท่านี้"
      )
    }

    let difference = abs(value - target.addressTorsoTiltDegrees)
    let status: SwingGuidelineFeedbackStatus =
      difference <= target.toleranceDegrees
      ? .within
      : .outside
    let message =
      status == .within
      ? String(format: "มุมลำตัว %.1f° อยู่ในช่วงท่าเตรียมที่เลือก", value)
      : String(format: "มุมลำตัว %.1f° อยู่นอกช่วงท่าเตรียมที่เลือก", value)
    return SwingGuidelineFeedback(
      guideline: .posture,
      status: status,
      metricName: "มุมลำตัวตอนท่าเตรียมจากภาพสองมิติ",
      measuredValue: value,
      targetValue: target.addressTorsoTiltDegrees,
      tolerance: target.toleranceDegrees,
      quality: reading.quality,
      message: message
    )
  }

  private func usableValue(_ reading: SwingMetricReading) -> Double? {
    guard reading.quality != .unavailable,
      let value = reading.value,
      value.isFinite
    else { return nil }
    return value
  }

  private func unavailable(
    guideline: GolfGuideline,
    quality: SwingMetricQuality? = nil,
    message: String
  ) -> SwingGuidelineFeedback {
    SwingGuidelineFeedback(
      guideline: guideline,
      status: .unavailable,
      metricName: nil,
      measuredValue: nil,
      targetValue: nil,
      tolerance: nil,
      quality: quality,
      message: message
    )
  }

  private func cancelAllCues(updateStatus: Bool) {
    tempoCompletionTask?.cancel()
    tempoCompletionTask = nil
    player.cancelAll()
    isTempoTrainerRunning = false
    preservesTempoDuringActiveSwing = false
    if updateStatus {
      statusText = "หยุดเสียงช่วยฝึกแล้ว"
    }
  }

  fileprivate static func nanoseconds(for duration: TimeInterval) -> UInt64 {
    let bounded = min(max(0, duration), 60 * 60)
    return UInt64(bounded * 1_000_000_000)
  }
}

/// สร้าง tone ในหน่วยความจำด้วย AVFoundation จึงไม่ต้องมีไฟล์เสียง binary ในแอป
@MainActor
final class AVFoundationSwingCuePlayer: SwingCuePlaying {
  private struct Note {
    let frequency: Double
    let duration: TimeInterval
    let silenceAfter: TimeInterval
    let amplitude: Float
  }

  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let sampleRate = 44_100.0
  private var scheduledTasks: [UUID: Task<Void, Never>] = [:]

  init() {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    engine.prepare()
  }

  func schedule(_ event: SwingCueEvent, after delay: TimeInterval, volume: Float) {
    let safeDelay = delay.isFinite ? max(0, delay) : 0
    let safeVolume = min(1, max(0, volume))
    if safeDelay == 0 {
      playNow(event, volume: safeVolume)
      return
    }

    let id = UUID()
    let task = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: SwingCueCoordinator.nanoseconds(for: safeDelay))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      self.playNow(event, volume: safeVolume)
      self.scheduledTasks[id] = nil
    }
    scheduledTasks[id] = task
  }

  func cancelAll() {
    for task in scheduledTasks.values {
      task.cancel()
    }
    scheduledTasks.removeAll()
    playerNode.stop()
  }

  private func playNow(_ event: SwingCueEvent, volume: Float) {
    do {
      if !engine.isRunning {
        try engine.start()
      }
    } catch {
      return
    }

    for note in notes(for: event) {
      guard let buffer = buffer(for: note, volume: volume) else { continue }
      playerNode.scheduleBuffer(buffer)
    }
    if !playerNode.isPlaying {
      playerNode.play()
    }
  }

  private func notes(for event: SwingCueEvent) -> [Note] {
    switch event {
    case .tempoStart:
      return [Note(frequency: 523.25, duration: 0.10, silenceAfter: 0.02, amplitude: 0.70)]
    case .tempoTop:
      return [Note(frequency: 659.25, duration: 0.12, silenceAfter: 0.02, amplitude: 0.70)]
    case .tempoImpact:
      return [Note(frequency: 987.77, duration: 0.07, silenceAfter: 0.02, amplitude: 0.92)]
    case .tempoFinish:
      return [Note(frequency: 392.00, duration: 0.18, silenceAfter: 0.02, amplitude: 0.62)]
    case .armed:
      return [
        Note(frequency: 659.25, duration: 0.08, silenceAfter: 0.04, amplitude: 0.60),
        Note(frequency: 783.99, duration: 0.10, silenceAfter: 0.02, amplitude: 0.64),
      ]
    case .completed:
      return [
        Note(frequency: 783.99, duration: 0.08, silenceAfter: 0.04, amplitude: 0.62),
        Note(frequency: 1046.50, duration: 0.14, silenceAfter: 0.02, amplitude: 0.68),
      ]
    case .guidelinePositive:
      return [
        Note(frequency: 880.00, duration: 0.09, silenceAfter: 0.04, amplitude: 0.62),
        Note(frequency: 1174.66, duration: 0.16, silenceAfter: 0.02, amplitude: 0.70),
      ]
    case .guidelineNegative:
      return [
        Note(frequency: 440.00, duration: 0.11, silenceAfter: 0.04, amplitude: 0.54),
        Note(frequency: 329.63, duration: 0.16, silenceAfter: 0.02, amplitude: 0.58),
      ]
    case .guidelineNeutral:
      return [Note(frequency: 587.33, duration: 0.14, silenceAfter: 0.02, amplitude: 0.48)]
    }
  }

  private func buffer(for note: Note, volume: Float) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      return nil
    }
    let toneFrameCount = max(1, Int((note.duration * sampleRate).rounded()))
    let silenceFrameCount = max(0, Int((note.silenceAfter * sampleRate).rounded()))
    let totalFrameCount = toneFrameCount + silenceFrameCount
    guard totalFrameCount <= Int(AVAudioFrameCount.max),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(totalFrameCount)
      ),
      let samples = buffer.floatChannelData?[0]
    else {
      return nil
    }
    buffer.frameLength = AVAudioFrameCount(totalFrameCount)

    let attackFrames = max(1, Int(0.008 * sampleRate))
    let releaseFrames = max(1, Int(0.025 * sampleRate))
    for frame in 0..<toneFrameCount {
      let attack = min(1, Float(frame) / Float(attackFrames))
      let remaining = toneFrameCount - frame
      let release = min(1, Float(remaining) / Float(releaseFrames))
      let envelope = min(attack, release)
      let phase = 2 * Double.pi * note.frequency * Double(frame) / sampleRate
      samples[frame] = Float(sin(phase)) * note.amplitude * volume * envelope
    }
    if silenceFrameCount > 0 {
      for frame in toneFrameCount..<totalFrameCount {
        samples[frame] = 0
      }
    }
    return buffer
  }
}
