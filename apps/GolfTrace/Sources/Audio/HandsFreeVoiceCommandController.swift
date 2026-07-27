@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

enum HandsFreeVoiceCommand: String, CaseIterable, Equatable, Sendable {
  case startSwing = "กอล์ฟเทรซเริ่มวง"
  case cancel = "กอล์ฟเทรซยกเลิก"

  var feedbackText: String {
    switch self {
    case .startSwing:
      return "รับคำสั่งแล้ว เตรียมตี"
    case .cancel:
      return "ยกเลิกการบันทึกแล้ว"
    }
  }
}

/// Parses only complete Thai command phrases. Whitespace and punctuation are
/// ignored because Speech may insert them, but surrounding words are never
/// accepted as a command.
struct HandsFreeVoiceCommandParser: Sendable {
  static func parse(_ transcript: String) -> HandsFreeVoiceCommand? {
    HandsFreeVoiceCommand(rawValue: normalize(transcript))
  }

  static func normalize(_ transcript: String) -> String {
    let canonical = transcript
      .precomposedStringWithCanonicalMapping
      .lowercased(with: Locale(identifier: "th_TH"))
    let ignored = CharacterSet.whitespacesAndNewlines
      .union(.punctuationCharacters)
      .union(.controlCharacters)

    var normalized = ""
    for scalar in canonical.unicodeScalars where !ignored.contains(scalar) {
      normalized.unicodeScalars.append(scalar)
    }
    return normalized
  }
}

struct HandsFreeVoiceCommandEvent: Identifiable, Equatable, Sendable {
  let id: UUID
  let command: HandsFreeVoiceCommand
  let transcript: String
  let recognizedAt: Date

  init(
    id: UUID = UUID(),
    command: HandsFreeVoiceCommand,
    transcript: String,
    recognizedAt: Date = Date()
  ) {
    self.id = id
    self.command = command
    self.transcript = transcript
    self.recognizedAt = recognizedAt
  }
}

enum HandsFreeVoiceCommandStatus: Equatable, Sendable {
  case idle
  case requestingAuthorization
  case listening
  case restarting
  case suspended
  case speakingFeedback
  case unavailable

  var displayName: String {
    switch self {
    case .idle:
      return "คำสั่งเสียงพร้อมเริ่ม"
    case .requestingAuthorization:
      return "กำลังขอสิทธิ์ไมโครโฟนและการรู้จำเสียง"
    case .listening:
      return "กำลังฟังคำว่า กอล์ฟเทรซ เริ่มวง หรือ กอล์ฟเทรซ ยกเลิก"
    case .restarting:
      return "กำลังเริ่มฟังคำสั่งเสียงใหม่"
    case .suspended:
      return "พักฟังคำสั่งเสียงชั่วคราว"
    case .speakingFeedback:
      return "กำลังยืนยันคำสั่งเสียง"
    case .unavailable:
      return "ใช้คำสั่งเสียงไม่ได้"
    }
  }
}

struct HandsFreeVoiceAuthorization: Equatable, Sendable {
  let microphoneGranted: Bool
  let speechRecognitionGranted: Bool
  let recognizerAvailable: Bool

  static let authorized = HandsFreeVoiceAuthorization(
    microphoneGranted: true,
    speechRecognitionGranted: true,
    recognizerAvailable: true
  )

  var isAuthorized: Bool {
    microphoneGranted && speechRecognitionGranted && recognizerAvailable
  }

  var denialMessage: String? {
    if !microphoneGranted {
      return "ยังไม่ได้รับอนุญาตให้ใช้ไมโครโฟนสำหรับคำสั่งเสียง"
    }
    if !speechRecognitionGranted {
      return "ยังไม่ได้รับอนุญาตให้ใช้การรู้จำเสียงภาษาไทย"
    }
    if !recognizerAvailable {
      return "ระบบรู้จำเสียงภาษาไทยยังไม่พร้อมใช้งาน"
    }
    return nil
  }
}

struct HandsFreeVoiceListenerFailure: Error, Equatable, Sendable {
  let message: String
}

/// The audio tap is invoked by AVFAudio on its realtime service queue. Keep the
/// callback completely independent from the main actor; speech/UI callbacks hop
/// to `MainActor` later, after Speech has produced a recognition result.
protocol HandsFreeVoiceAudioBufferAppending: Sendable {
  func append(_ buffer: AVAudioPCMBuffer)
}

enum HandsFreeVoiceAudioTapFactory {
  static func make<Appender: HandsFreeVoiceAudioBufferAppending>(
    appender: Appender
  ) -> AVAudioNodeTapBlock {
    { @Sendable buffer, _ in
      appender.append(buffer)
    }
  }
}

@MainActor
protocol HandsFreeVoiceListening: AnyObject {
  func requestAuthorization() async -> HandsFreeVoiceAuthorization
  func start(
    onTranscript: @escaping @MainActor @Sendable (_ transcript: String, _ isFinal: Bool) -> Void,
    onTermination: @escaping @MainActor @Sendable (HandsFreeVoiceListenerFailure?) -> Void
  ) throws
  func stop()
}

@MainActor
protocol HandsFreeVoiceFeedbackSpeaking: AnyObject {
  func speak(
    _ text: String,
    completion: @escaping @MainActor @Sendable () -> Void
  )
  func stop()
}

/// Coordinates continuous Thai speech recognition and short confirmation TTS.
/// Recognition is stopped before TTS begins and starts again only after the
/// utterance finishes, preventing the app from recognizing its own voice.
@MainActor
final class HandsFreeVoiceCommandController: ObservableObject {
  private struct FeedbackRequest {
    let text: String
    let completion: @MainActor @Sendable () -> Void
  }

  @Published private(set) var latestCommand: HandsFreeVoiceCommandEvent?
  @Published private(set) var status: HandsFreeVoiceCommandStatus = .idle
  @Published private(set) var errorMessage: String?

  var onCommand: (@MainActor (HandsFreeVoiceCommand) -> Void)?

  var isListening: Bool { status == .listening }
  var isSuspended: Bool { externallySuspended }

  private let listener: any HandsFreeVoiceListening
  private let feedbackSpeaker: any HandsFreeVoiceFeedbackSpeaking
  private let partialResultQuietPeriod: TimeInterval
  private let restartDelay: TimeInterval

  private var authorization: HandsFreeVoiceAuthorization?
  private var authorizationTask: Task<Void, Never>?
  private var transcriptDebounceTask: Task<Void, Never>?
  private var restartTask: Task<Void, Never>?
  private var desiredListening = false
  private var externallySuspended = false
  private var isSpeakingFeedback = false
  private var activeFeedback: FeedbackRequest?
  private var deferredFeedback: FeedbackRequest?
  private var listenerGeneration: UInt64 = 0
  private var feedbackGeneration: UInt64 = 0
  private var pendingTranscript = ""

  init(
    listener: (any HandsFreeVoiceListening)? = nil,
    feedbackSpeaker: (any HandsFreeVoiceFeedbackSpeaking)? = nil,
    partialResultQuietPeriod: TimeInterval = 0.55,
    restartDelay: TimeInterval = 0.15
  ) {
    self.listener = listener ?? AppleThaiSpeechListener()
    self.feedbackSpeaker = feedbackSpeaker ?? AppleHandsFreeFeedbackSpeaker()
    self.partialResultQuietPeriod = max(0.15, partialResultQuietPeriod)
    self.restartDelay = max(0, restartDelay)
  }

  func start() {
    desiredListening = true
    errorMessage = nil
    guard !externallySuspended else {
      status = .suspended
      return
    }
    prepareToListen()
  }

  func stop() {
    desiredListening = false
    externallySuspended = false
    authorizationTask?.cancel()
    authorizationTask = nil
    invalidateListening()
    stopFeedback(clearDeferred: true)
    status = .idle
  }

  /// Stops recognition and confirmation speech until `resume()` is called.
  /// `start()` remains remembered, so resuming does not request a second user action.
  func suspend() {
    externallySuspended = true
    authorizationTask?.cancel()
    authorizationTask = nil
    invalidateListening()
    deferActiveFeedback()
    if externallySuspended {
      status = .suspended
    }
  }

  func resume() {
    guard externallySuspended else { return }
    externallySuspended = false
    if let feedback = deferredFeedback {
      deferredFeedback = nil
      beginFeedback(feedback)
      return
    }
    guard desiredListening else {
      status = .idle
      return
    }
    errorMessage = nil
    prepareToListen()
  }

  func clearLatestCommand() {
    latestCommand = nil
  }

  /// Speaks a short state response while recognition is paused, then resumes
  /// continuous command listening. This remains available even if speech
  /// recognition permission was denied, so the on-screen fallback still talks.
  func speakFeedback(
    _ text: String,
    completion: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      completion()
      return
    }

    let feedback = FeedbackRequest(text: normalized, completion: completion)
    guard !externallySuspended else {
      // Capture/AI owns the microphone while suspended. Keep only the newest
      // state response so stale countdown/status announcements do not queue up.
      replaceDeferredFeedback(with: feedback)
      if externallySuspended {
        status = .suspended
      }
      return
    }

    beginFeedback(feedback)
  }

  private func beginFeedback(_ feedback: FeedbackRequest) {
    guard !externallySuspended else {
      replaceDeferredFeedback(with: feedback)
      if externallySuspended {
        status = .suspended
      }
      return
    }

    invalidateListening()
    stopFeedback(clearDeferred: false)
    isSpeakingFeedback = true
    activeFeedback = feedback
    feedbackGeneration &+= 1
    let generation = feedbackGeneration
    status = .speakingFeedback
    feedbackSpeaker.speak(feedback.text) { [weak self] in
      guard let self, self.feedbackGeneration == generation else { return }
      self.isSpeakingFeedback = false
      self.activeFeedback = nil
      let listenerGenerationBeforeCompletion = self.listenerGeneration
      feedback.completion()
      guard self.feedbackGeneration == generation, !self.isSpeakingFeedback,
        self.listenerGeneration == listenerGenerationBeforeCompletion,
        self.status == .speakingFeedback
      else { return }
      if self.externallySuspended {
        self.status = .suspended
      } else if self.desiredListening {
        self.prepareToListen()
      } else {
        self.status = .idle
      }
    }
  }

  func stopSpeakingFeedback() {
    guard isSpeakingFeedback || deferredFeedback != nil else { return }
    stopFeedback(clearDeferred: true)
    if externallySuspended {
      status = .suspended
    } else if desiredListening {
      prepareToListen()
    } else {
      status = .idle
    }
  }

  private func prepareToListen() {
    guard desiredListening, !externallySuspended, !isSpeakingFeedback else { return }
    if authorization?.isAuthorized == true {
      beginListening()
      return
    }

    authorizationTask?.cancel()
    status = .requestingAuthorization
    authorizationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.listener.requestAuthorization()
      guard !Task.isCancelled, self.desiredListening, !self.externallySuspended else { return }
      self.authorizationTask = nil
      self.authorization = result
      guard result.isAuthorized else {
        self.errorMessage = result.denialMessage
        self.status = .unavailable
        return
      }
      self.beginListening()
    }
  }

  private func beginListening() {
    guard desiredListening, !externallySuspended, !isSpeakingFeedback else { return }
    transcriptDebounceTask?.cancel()
    transcriptDebounceTask = nil
    restartTask?.cancel()
    restartTask = nil
    pendingTranscript = ""

    listenerGeneration &+= 1
    let generation = listenerGeneration
    listener.stop()

    do {
      try listener.start(
        onTranscript: { [weak self] transcript, isFinal in
          guard let self, self.listenerGeneration == generation else { return }
          self.receiveTranscript(transcript, isFinal: isFinal, generation: generation)
        },
        onTermination: { [weak self] failure in
          guard let self, self.listenerGeneration == generation else { return }
          self.handleListenerTermination(failure, generation: generation)
        }
      )
      status = .listening
    } catch {
      errorMessage = "เริ่มฟังคำสั่งเสียงไม่ได้: \(error.localizedDescription)"
      status = .unavailable
    }
  }

  private func receiveTranscript(
    _ transcript: String,
    isFinal: Bool,
    generation: UInt64
  ) {
    pendingTranscript = transcript
    transcriptDebounceTask?.cancel()

    if isFinal {
      evaluatePendingTranscript(generation: generation)
      return
    }

    let delay = partialResultQuietPeriod
    transcriptDebounceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
      } catch {
        return
      }
      guard let self, self.listenerGeneration == generation, !Task.isCancelled else { return }
      self.evaluatePendingTranscript(generation: generation)
    }
  }

  private func evaluatePendingTranscript(generation: UInt64) {
    guard listenerGeneration == generation else { return }
    transcriptDebounceTask?.cancel()
    transcriptDebounceTask = nil
    let transcript = pendingTranscript
    pendingTranscript = ""

    guard let command = HandsFreeVoiceCommandParser.parse(transcript) else {
      scheduleListenerRestart(after: restartDelay, reportTransientError: false)
      return
    }
    handle(command, transcript: transcript)
  }

  private func handle(_ command: HandsFreeVoiceCommand, transcript: String) {
    invalidateListening()
    let generationAfterInvalidation = listenerGeneration
    latestCommand = HandsFreeVoiceCommandEvent(command: command, transcript: transcript)
    onCommand?(command)

    // Most handlers answer synchronously with TTS. If a handler deliberately
    // emits no response, keep the always-on command channel alive instead of
    // leaving recognition stopped forever after a valid command.
    guard listenerGeneration == generationAfterInvalidation, desiredListening,
      !externallySuspended, !isSpeakingFeedback
    else { return }
    scheduleListenerRestart(after: restartDelay, reportTransientError: false)
  }

  private func handleListenerTermination(
    _ failure: HandsFreeVoiceListenerFailure?,
    generation: UInt64
  ) {
    guard listenerGeneration == generation else { return }
    if let failure {
      errorMessage = failure.message
    }
    scheduleListenerRestart(after: max(0.35, restartDelay), reportTransientError: failure != nil)
  }

  private func scheduleListenerRestart(
    after delay: TimeInterval,
    reportTransientError: Bool
  ) {
    invalidateListening()
    guard desiredListening, !externallySuspended, !isSpeakingFeedback else { return }
    if reportTransientError {
      status = .restarting
    }

    restartTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
      } catch {
        return
      }
      guard let self, self.desiredListening, !self.externallySuspended, !self.isSpeakingFeedback,
        !Task.isCancelled
      else { return }
      self.beginListening()
    }
  }

  private func invalidateListening() {
    listenerGeneration &+= 1
    transcriptDebounceTask?.cancel()
    transcriptDebounceTask = nil
    restartTask?.cancel()
    restartTask = nil
    pendingTranscript = ""
    listener.stop()
  }

  private func deferActiveFeedback() {
    let interruptedFeedback = activeFeedback
    stopFeedback(clearDeferred: false)
    if let interruptedFeedback {
      replaceDeferredFeedback(with: interruptedFeedback)
    }
  }

  private func replaceDeferredFeedback(with feedback: FeedbackRequest) {
    let supersededFeedback = deferredFeedback
    deferredFeedback = feedback
    // A latest-only queue deliberately drops stale state copy. Complete the
    // superseded request so callers never wait on speech that will not occur.
    supersededFeedback?.completion()
  }

  private func stopFeedback(clearDeferred: Bool) {
    feedbackGeneration &+= 1
    isSpeakingFeedback = false
    activeFeedback = nil
    if clearDeferred {
      deferredFeedback = nil
    }
    feedbackSpeaker.stop()
  }

  private static func nanoseconds(for duration: TimeInterval) -> UInt64 {
    let bounded = min(max(0, duration), 60)
    return UInt64(bounded * 1_000_000_000)
  }
}

@MainActor
private final class AppleThaiSpeechListener: HandsFreeVoiceListening {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "th_TH"))
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var tapIsInstalled = false
  private var sessionID = UUID()

  func requestAuthorization() async -> HandsFreeVoiceAuthorization {
    let microphoneGranted = await Self.requestMicrophoneAccess()
    let speechRecognitionGranted = await Self.requestSpeechRecognitionAccess()
    return HandsFreeVoiceAuthorization(
      microphoneGranted: microphoneGranted,
      speechRecognitionGranted: speechRecognitionGranted,
      recognizerAvailable: recognizer?.isAvailable == true
    )
  }

  func start(
    onTranscript: @escaping @MainActor @Sendable (String, Bool) -> Void,
    onTermination: @escaping @MainActor @Sendable (HandsFreeVoiceListenerFailure?) -> Void
  ) throws {
    stop()
    guard let recognizer, recognizer.isAvailable else {
      throw AppleThaiSpeechListenerError.recognizerUnavailable
    }

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw AppleThaiSpeechListenerError.microphoneFormatUnavailable
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .confirmation
    request.contextualStrings = ["กอล์ฟเทรซ เริ่มวง", "กอล์ฟเทรซ ยกเลิก"]
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    recognitionRequest = request

    let currentSessionID = UUID()
    sessionID = currentSessionID
    let audioTap = HandsFreeVoiceAudioTapFactory.make(
      appender: AppleSpeechAudioBufferAppender(request: request)
    )
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: audioTap)
    tapIsInstalled = true

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      stop()
      throw error
    }

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let transcript = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failure = error.map {
        HandsFreeVoiceListenerFailure(message: "การฟังคำสั่งเสียงสะดุด: \($0.localizedDescription)")
      }

      Task { @MainActor [weak self] in
        guard let self, self.sessionID == currentSessionID else { return }
        if let transcript {
          onTranscript(transcript, isFinal)
        }
        if let failure {
          self.stop()
          onTermination(failure)
        }
      }
    }
  }

  func stop() {
    sessionID = UUID()
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest?.endAudio()
    recognitionRequest = nil
    if audioEngine.isRunning {
      audioEngine.stop()
    }
    if tapIsInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapIsInstalled = false
    }
  }

  private nonisolated static func requestMicrophoneAccess() async -> Bool {
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

  private nonisolated static func requestSpeechRecognitionAccess() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
          continuation.resume(returning: status == .authorized)
        }
      }
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

/// `append(_:)` is specifically designed by Speech to be called from an audio
/// tap. The weak request preserves the old teardown behavior when `stop()` ends
/// a recognition session while a final tap callback may still be in flight.
private final class AppleSpeechAudioBufferAppender: HandsFreeVoiceAudioBufferAppending,
  @unchecked Sendable
{
  private weak var request: SFSpeechAudioBufferRecognitionRequest?

  init(request: SFSpeechAudioBufferRecognitionRequest) {
    self.request = request
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    request?.append(buffer)
  }
}

private enum AppleThaiSpeechListenerError: LocalizedError {
  case recognizerUnavailable
  case microphoneFormatUnavailable

  var errorDescription: String? {
    switch self {
    case .recognizerUnavailable:
      return "ระบบรู้จำเสียงภาษาไทยยังไม่พร้อมใช้งาน"
    case .microphoneFormatUnavailable:
      return "ไม่พบรูปแบบเสียงจากไมโครโฟนที่ใช้งานได้"
    }
  }
}

@MainActor
private final class AppleHandsFreeFeedbackSpeaker: NSObject, HandsFreeVoiceFeedbackSpeaking {
  private let synthesizer = AVSpeechSynthesizer()
  private var activeUtteranceID: ObjectIdentifier?
  private var completion: (@MainActor @Sendable () -> Void)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(
    _ text: String,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    stop()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "th-TH")
    utterance.rate = 0.48
    utterance.volume = 0.85
    activeUtteranceID = ObjectIdentifier(utterance)
    self.completion = completion
    synthesizer.speak(utterance)
  }

  func stop() {
    activeUtteranceID = nil
    completion = nil
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
  }

  private func finish(_ utteranceID: ObjectIdentifier) {
    guard activeUtteranceID == utteranceID else { return }
    activeUtteranceID = nil
    let completion = completion
    self.completion = nil
    completion?()
  }
}

extension AppleHandsFreeFeedbackSpeaker: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      self?.finish(utteranceID)
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    let utteranceID = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      self?.finish(utteranceID)
    }
  }
}
