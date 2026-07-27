@preconcurrency import AVFoundation
import Combine
import Foundation

enum AIGolfProState: Equatable {
  case idle
  case recording
  case transcribing
  case thinking
  case ready
  case speaking
  case failed(String)

  var title: String {
    switch self {
    case .idle: return "พร้อมรับคำถาม"
    case .recording: return "กำลังฟังคำถาม"
    case .transcribing: return "กำลังถอดเสียงคำถาม"
    case .thinking: return "AI กำลังอ่านข้อมูลวงสวิง"
    case .ready: return "เตรียมคำแนะนำแล้ว"
    case .speaking: return "AI โปรกำลังพูด"
    case .failed(let message): return message
    }
  }

  var isBusy: Bool {
    switch self {
    case .recording, .transcribing, .thinking, .speaking: return true
    case .idle, .ready, .failed: return false
    }
  }

  /// Only these states own the Mac audio path. Network/transcription work must
  /// not block a solo golfer from starting the next take hands-free.
  var isUsingAudio: Bool {
    switch self {
    case .recording, .speaking: return true
    case .idle, .transcribing, .thinking, .ready, .failed: return false
    }
  }
}

private enum AIGolfProRequestError: LocalizedError {
  case blocked(GolfAIRequestGate)

  var errorDescription: String? {
    switch self {
    case .blocked(let gate): return gate.thaiMessage
    }
  }
}

/// ประสานงานไมโครโฟน → Whisper → OpenRouter text model → เสียงตอบบน Mac
/// การวิเคราะห์ภาพ 120 FPS ยังอยู่บน Mac และไม่ผ่านคลาสนี้
@MainActor
final class AIGolfProController: NSObject, ObservableObject {
  static let maximumQuestionDurationSeconds: TimeInterval = 30

  @Published private(set) var state: AIGolfProState = .idle
  @Published private(set) var latestTranscript = ""
  @Published private(set) var advice: GolfCoachAdvice?
  @Published private(set) var lastError: String?

  let settings: GolfAISettings

  private let whisperClient: GX10WhisperClient
  private let coachClient: DSV4GolfCoachClient
  private let speechSynthesizer = AVSpeechSynthesizer()
  private var audioRecorder: AVAudioRecorder?
  private var recordingURL: URL?
  private var activeTask: Task<Void, Never>?
  private var recordingLimitTask: Task<Void, Never>?
  private var operationGeneration: UInt64 = 0
  private var activeUtteranceID: ObjectIdentifier?
  private var activeSpeechGeneration: UInt64?
  private var knowledgeProvider: ((String, GolfPracticeSettings) -> [GolfKnowledgeExcerpt])?

  init(
    settings: GolfAISettings,
    whisperClient: GX10WhisperClient = GX10WhisperClient(),
    coachClient: DSV4GolfCoachClient = DSV4GolfCoachClient()
  ) {
    self.settings = settings
    self.whisperClient = whisperClient
    self.coachClient = coachClient
    super.init()
    speechSynthesizer.delegate = self
    Self.removeStaleQuestionRecordings()
  }

  func setKnowledgeProvider(
    _ provider: @escaping (String, GolfPracticeSettings) -> [GolfKnowledgeExcerpt]
  ) {
    knowledgeProvider = provider
  }

  deinit {
    activeTask?.cancel()
    recordingLimitTask?.cancel()
    audioRecorder?.stop()
    if let recordingURL {
      try? FileManager.default.removeItem(at: recordingURL)
    }
  }

  var isRecording: Bool { state == .recording }
  var canStartRecording: Bool { !state.isBusy || state == .speaking }

  func startQuestionRecording() {
    guard state != .recording else { return }
    let generation = beginNewOperation()
    lastError = nil

    activeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let granted = await Self.requestMicrophoneAccess()
      guard self.isCurrent(generation) else { return }
      guard granted else {
        self.fail(
          "ยังไม่ได้รับอนุญาตให้ใช้ไมโครโฟน กรุณาเปิดสิทธิ์ใน System Settings",
          generation: generation
        )
        return
      }

      var temporaryURL: URL?
      do {
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("GolfTrace-question-\(UUID().uuidString)")
          .appendingPathExtension("wav")
        temporaryURL = url
        let recorder = try AVAudioRecorder(
          url: url,
          settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
          ]
        )
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(),
          recorder.record(forDuration: Self.maximumQuestionDurationSeconds)
        else {
          throw CocoaError(.fileWriteUnknown)
        }
        guard self.isCurrent(generation) else {
          recorder.stop()
          try? FileManager.default.removeItem(at: url)
          return
        }
        self.recordingURL = url
        self.audioRecorder = recorder
        self.state = .recording
        self.startRecordingLimitTimer(generation: generation)
      } catch {
        if let temporaryURL {
          try? FileManager.default.removeItem(at: temporaryURL)
        }
        self.fail("เปิดไมโครโฟนไม่สำเร็จ: \(error.localizedDescription)", generation: generation)
      }
    }
  }

  func finishQuestionRecording(
    practiceSettings: GolfPracticeSettings,
    summary: SwingSessionSummary?,
    analysis: SwingAnalysisSummary?,
    evidencePacket: SwingEvidencePacket?,
    launch: LaunchMonitorShot?
  ) {
    guard state == .recording, let recordingURL else { return }
    audioRecorder?.stop()
    audioRecorder = nil
    self.recordingURL = nil
    recordingLimitTask?.cancel()
    recordingLimitTask = nil

    let generation = advanceGeneration()
    stopSpeaking()
    activeTask = Task { @MainActor [weak self] in
      defer { try? FileManager.default.removeItem(at: recordingURL) }
      guard let self else { return }

      do {
        guard self.isCurrent(generation) else { return }
        self.state = .transcribing
        guard let endpoint = self.settings.whisperURL else {
          throw DSV4GolfCoachError.invalidConfiguration
        }
        let key = try self.settings.loadAPIKey(for: endpoint)
        let transcript = try await self.whisperClient.transcribe(
          audioURL: recordingURL,
          configuration: GX10WhisperConfiguration(
            endpoint: endpoint,
            model: self.settings.whisperModel,
            apiKey: key
          )
        )
        guard self.isCurrent(generation) else { return }
        self.latestTranscript = transcript.text
        await self.requestAdvice(
          question: transcript.text,
          practiceSettings: practiceSettings,
          summary: summary,
          analysis: analysis,
          evidencePacket: evidencePacket,
          launch: launch,
          generation: generation
        )
      } catch {
        self.fail(error.localizedDescription, generation: generation)
      }
    }
  }

  func askWithText(
    _ question: String,
    practiceSettings: GolfPracticeSettings,
    summary: SwingSessionSummary?,
    analysis: SwingAnalysisSummary?,
    evidencePacket: SwingEvidencePacket?,
    launch: LaunchMonitorShot?
  ) {
    let normalized = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    let generation = beginNewOperation()
    latestTranscript = normalized
    activeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.requestAdvice(
        question: normalized,
        practiceSettings: practiceSettings,
        summary: summary,
        analysis: analysis,
        evidencePacket: evidencePacket,
        launch: launch,
        generation: generation
      )
    }
  }

  /// ขอคำแนะนำหลังวงสวิงโดยอัตโนมัติ งานนี้ไม่บล็อก replay หรือการจับวงถัดไป
  func analyzeLatestSwing(
    practiceSettings: GolfPracticeSettings,
    summary: SwingSessionSummary,
    analysis: SwingAnalysisSummary?,
    evidencePacket: SwingEvidencePacket?,
    launch: LaunchMonitorShot?
  ) {
    guard settings.aiEnabled, settings.automaticCoachEnabled else { return }
    askWithText(
      "ช่วยสรุปหนึ่งเรื่องที่ควรโฟกัสในช็อตถัดไปจากข้อมูลวงล่าสุด",
      practiceSettings: practiceSettings,
      summary: summary,
      analysis: analysis,
      evidencePacket: evidencePacket,
      launch: launch
    )
  }

  func cancelListening() {
    guard state == .recording else { return }
    invalidateAllActivity()
  }

  /// เรียกทันทีเมื่อเริ่มจับวงใหม่ เพื่อยกเลิก Whisper/AI/TTS รุ่นก่อนหน้า
  /// แม้ network task จะตอบกลับช้า generation gate จะไม่ยอมให้เสียงเก่าพูดกลางวง
  func invalidateForSwing() {
    invalidateAllActivity()
  }

  /// API ทั่วไปสำหรับยกเลิก recording, network และเสียงพูดทั้งหมด
  func cancelAllActivity() {
    invalidateAllActivity()
  }

  func stopSpeaking() {
    activeUtteranceID = nil
    activeSpeechGeneration = nil
    if speechSynthesizer.isSpeaking {
      speechSynthesizer.stopSpeaking(at: .immediate)
    }
    if state == .speaking {
      state = advice == nil ? .idle : .ready
    }
  }

  private func requestAdvice(
    question: String,
    practiceSettings: GolfPracticeSettings,
    summary: SwingSessionSummary?,
    analysis: SwingAnalysisSummary?,
    evidencePacket: SwingEvidencePacket?,
    launch: LaunchMonitorShot?,
    generation: UInt64
  ) async {
    guard isCurrent(generation) else { return }
    let knowledgeExcerpts = knowledgeProvider?(question, practiceSettings) ?? []
    let context = GolfCoachRequestContext.make(
      question: question,
      settings: practiceSettings,
      summary: summary,
      analysis: analysis,
      evidencePacket: evidencePacket,
      launch: launch,
      knowledgeExcerpts: knowledgeExcerpts
    )
    state = .thinking
    lastError = nil

    do {
      let gate = await settings.prepareForAIRequest()
      guard gate == .allowed else {
        throw AIGolfProRequestError.blocked(gate)
      }
      guard let endpoint = settings.dsv4URL else {
        throw DSV4GolfCoachError.invalidConfiguration
      }
      guard let key = try settings.loadAPIKey(for: endpoint) else {
        throw DSV4GolfCoachError.missingAPIKey
      }
      let result = try await coachClient.requestAdvice(
        context: context,
        configuration: DSV4GolfCoachConfiguration(
          endpoint: endpoint,
          model: settings.dsv4Model,
          apiKey: key,
          employeeCode: settings.employeeCode
        )
      )
      guard isCurrent(generation) else { return }
      settings.recordUsage(result.usage)
      advice = result.advice
      state = .ready
      speakIfNeeded(
        result.advice.speech,
        practiceSettings: practiceSettings,
        generation: generation
      )
    } catch {
      guard isCurrent(generation) else { return }
      let fallback = GolfCoachAdvice.localFallback(for: context)
      advice = fallback
      lastError = error.localizedDescription
      state = .failed("ใช้คำแนะนำสำรอง: \(error.localizedDescription)")
      speakIfNeeded(
        fallback.speech,
        practiceSettings: practiceSettings,
        generation: generation
      )
    }
  }

  private func speakIfNeeded(
    _ text: String,
    practiceSettings: GolfPracticeSettings,
    generation: UInt64
  ) {
    guard practiceSettings.audioDevice == .mac,
      settings.aiVoiceEnabled,
      isCurrent(generation),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }
    stopSpeaking()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "th-TH")
    utterance.rate = Float(settings.aiVoiceRate)
    utterance.volume = Float(settings.aiVoiceVolume)
    utterance.pitchMultiplier = 1
    activeUtteranceID = ObjectIdentifier(utterance)
    activeSpeechGeneration = generation
    state = .speaking
    speechSynthesizer.speak(utterance)
  }

  private func fail(_ message: String, generation: UInt64? = nil) {
    if let generation, !isCurrent(generation) { return }
    lastError = message
    state = .failed(message)
  }

  @discardableResult
  private func advanceGeneration() -> UInt64 {
    operationGeneration &+= 1
    activeTask?.cancel()
    activeTask = nil
    recordingLimitTask?.cancel()
    recordingLimitTask = nil
    return operationGeneration
  }

  private func beginNewOperation() -> UInt64 {
    let generation = advanceGeneration()
    stopAndRemoveRecording()
    stopSpeaking()
    state = .idle
    return generation
  }

  private func invalidateAllActivity() {
    _ = advanceGeneration()
    stopAndRemoveRecording()
    stopSpeaking()
    state = .idle
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    generation == operationGeneration && !Task.isCancelled
  }

  private func stopAndRemoveRecording() {
    audioRecorder?.stop()
    audioRecorder = nil
    if let recordingURL {
      try? FileManager.default.removeItem(at: recordingURL)
    }
    recordingURL = nil
  }

  private func startRecordingLimitTimer(generation: UInt64) {
    recordingLimitTask?.cancel()
    recordingLimitTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(
          nanoseconds: UInt64(Self.maximumQuestionDurationSeconds * 1_000_000_000)
        )
      } catch {
        return
      }
      guard let self, self.isCurrent(generation), self.state == .recording else { return }
      self.invalidateAllActivity()
      self.fail("หยุดบันทึกอัตโนมัติที่ 30 วินาที กรุณาถามใหม่ให้สั้นลง")
    }
  }

  private static func removeStaleQuestionRecordings() {
    let directory = FileManager.default.temporaryDirectory
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }
    let staleBefore = Date().addingTimeInterval(-3_600)
    for url in files
    where url.lastPathComponent.hasPrefix("GolfTrace-question-")
      && url.pathExtension.lowercased() == "wav"
    {
      let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      if modifiedAt.map({ $0 < staleBefore }) ?? true {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  private static func requestMicrophoneAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

extension AIGolfProController: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self,
        self.activeUtteranceID == utteranceID,
        self.activeSpeechGeneration == self.operationGeneration
      else {
        return
      }
      self.activeUtteranceID = nil
      self.activeSpeechGeneration = nil
      self.state = self.advice == nil ? .idle : .ready
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self,
        self.activeUtteranceID == utteranceID,
        self.activeSpeechGeneration == self.operationGeneration
      else {
        return
      }
      self.activeUtteranceID = nil
      self.activeSpeechGeneration = nil
      self.state = self.advice == nil ? .idle : .ready
    }
  }
}
