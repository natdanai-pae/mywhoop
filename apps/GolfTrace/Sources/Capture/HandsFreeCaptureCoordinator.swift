import Combine
import Foundation

enum HandsFreeCaptureTimeoutReason: Equatable, Sendable {
  case waitingForSwing
  case capturing
  case finalizing
}

enum HandsFreeCaptureState: Equatable, Sendable {
  case listening
  case acknowledged
  case countdown(Int)
  case armed
  case capturing
  case finalizing
  case replayReady
  case cancelled
  case timedOut(HandsFreeCaptureTimeoutReason)
  case error(String)
}

enum HandsFreeCaptureSpeechCue: Equatable, Sendable {
  case acknowledged
  case countdown(Int)
  case cancelled
  case timedOut(HandsFreeCaptureTimeoutReason)
  case finalizing
  case replayReady
  case error(String)
}

/// Side effects stay semantic so the coordinator can be tested without a recorder,
/// tempo player or speech synthesizer.
enum HandsFreeCaptureEvent: Equatable, Sendable {
  case stopSpeech(takeID: UUID)
  case speak(cue: HandsFreeCaptureSpeechCue, takeID: UUID)
  case prepareStageRecording(takeID: UUID)
  case startStageRecording(takeID: UUID)
  case cancelStageRecording(takeID: UUID)
  case startTempo(takeID: UUID)
  case cancelTempo(takeID: UUID)
}

struct HandsFreeCaptureConfiguration: Equatable, Sendable {
  let acknowledgementDelay: Duration
  let countdownValues: [Int]
  let countdownInterval: Duration
  let swingStartTimeout: Duration
  let captureTimeout: Duration
  let finalizationTimeout: Duration
  let terminalStateDuration: Duration
  let tempoEnabled: Bool

  init(
    acknowledgementDelay: Duration = .milliseconds(1_800),
    countdownValues: [Int] = [3, 2, 1],
    countdownInterval: Duration = .seconds(1),
    swingStartTimeout: Duration = .seconds(15),
    captureTimeout: Duration = .seconds(8),
    finalizationTimeout: Duration = .seconds(45),
    terminalStateDuration: Duration = .milliseconds(2_800),
    tempoEnabled: Bool = true
  ) {
    self.acknowledgementDelay = Self.nonnegative(acknowledgementDelay)
    let validCountdown = countdownValues.filter { $0 > 0 }
    self.countdownValues = validCountdown.isEmpty ? [3, 2, 1] : validCountdown
    self.countdownInterval = Self.nonnegative(countdownInterval)
    self.swingStartTimeout = Self.nonnegative(swingStartTimeout)
    self.captureTimeout = Self.nonnegative(captureTimeout)
    self.finalizationTimeout = Self.nonnegative(finalizationTimeout)
    self.terminalStateDuration = Self.nonnegative(terminalStateDuration)
    self.tempoEnabled = tempoEnabled
  }

  private static func nonnegative(_ duration: Duration) -> Duration {
    max(.zero, duration)
  }
}

@MainActor
protocol HandsFreeCaptureScheduledTask: AnyObject {
  func cancel()
}

@MainActor
protocol HandsFreeCaptureScheduling: AnyObject {
  func schedule(
    after delay: Duration,
    action: @escaping @MainActor @Sendable () -> Void
  ) -> any HandsFreeCaptureScheduledTask
}

@MainActor
final class HandsFreeCaptureTaskScheduler: HandsFreeCaptureScheduling {
  func schedule(
    after delay: Duration,
    action: @escaping @MainActor @Sendable () -> Void
  ) -> any HandsFreeCaptureScheduledTask {
    let scheduledTask = TaskToken()
    scheduledTask.task = Task { @MainActor [weak scheduledTask] in
      do {
        try await Task.sleep(for: max(.zero, delay))
      } catch {
        return
      }
      guard let scheduledTask, !scheduledTask.isCancelled, !Task.isCancelled else {
        return
      }
      scheduledTask.task = nil
      action()
    }
    return scheduledTask
  }

  @MainActor
  private final class TaskToken: HandsFreeCaptureScheduledTask {
    var task: Task<Void, Never>?
    private(set) var isCancelled = false

    func cancel() {
      isCancelled = true
      task?.cancel()
      task = nil
    }
  }
}

/// Owns one hands-free take at a time. All asynchronous callbacks are gated by
/// the take identifier so a late detector or replay callback cannot mutate a new take.
@MainActor
final class HandsFreeCaptureCoordinator: ObservableObject {
  typealias EventHandler = @MainActor (HandsFreeCaptureEvent) -> Void

  @Published private(set) var state: HandsFreeCaptureState = .listening
  @Published private(set) var activeTakeID: UUID?

  var eventHandler: EventHandler?

  private let configuration: HandsFreeCaptureConfiguration
  private let scheduler: any HandsFreeCaptureScheduling
  private let makeTakeID: () -> UUID

  private var transitionTask: (any HandsFreeCaptureScheduledTask)?
  private var timeoutTask: (any HandsFreeCaptureScheduledTask)?
  private var terminalTask: (any HandsFreeCaptureScheduledTask)?
  private var didStartStageRecording = false
  private var didStartTempo = false
  private var didCompleteSwing = false
  private var activeTempoEnabled = false

  init(
    configuration: HandsFreeCaptureConfiguration = HandsFreeCaptureConfiguration(),
    scheduler: (any HandsFreeCaptureScheduling)? = nil,
    makeTakeID: @escaping () -> UUID = UUID.init,
    eventHandler: EventHandler? = nil
  ) {
    self.configuration = configuration
    self.scheduler = scheduler ?? HandsFreeCaptureTaskScheduler()
    self.makeTakeID = makeTakeID
    self.eventHandler = eventHandler
  }

  var isActive: Bool {
    activeTakeID != nil
  }

  /// Starts one take only while command listening is idle.
  @discardableResult
  func startOneTake(tempoEnabled: Bool? = nil) -> UUID? {
    guard state == .listening, activeTakeID == nil else { return nil }

    let takeID = makeTakeID()
    activeTakeID = takeID
    didStartStageRecording = false
    didStartTempo = false
    didCompleteSwing = false
    activeTempoEnabled = tempoEnabled ?? configuration.tempoEnabled
    state = .acknowledged

    emit(.stopSpeech(takeID: takeID))
    emit(.prepareStageRecording(takeID: takeID))
    emit(.speak(cue: .acknowledged, takeID: takeID))
    scheduleCountdown(index: 0, after: configuration.acknowledgementDelay, takeID: takeID)
    return takeID
  }

  /// Detector confirmation is accepted only after the countdown reaches the
  /// armed state; earlier motion belongs to an invalid/previous take.
  @discardableResult
  func handleDetectorStarted(for takeID: UUID? = nil) -> Bool {
    guard let activeTakeID, matches(takeID, activeTakeID: activeTakeID) else { return false }
    switch state {
    case .armed:
      break
    case .listening, .acknowledged, .countdown, .capturing, .finalizing, .replayReady,
      .cancelled, .timedOut, .error:
      return false
    }

    cancelTransitionAndTimeout()
    state = .capturing
    emit(.stopSpeech(takeID: activeTakeID))
    ensureStageRecordingStarted(takeID: activeTakeID)
    scheduleTimeout(
      after: configuration.captureTimeout,
      reason: .capturing,
      expectedState: .capturing,
      takeID: activeTakeID
    )
    return true
  }

  /// Returns the active take exactly once. The caller uses that identifier to
  /// finish its recorder; repeated/coalesced detector completions return `nil`.
  @discardableResult
  func handleSwingCompleted(for takeID: UUID? = nil) -> UUID? {
    guard let activeTakeID,
      matches(takeID, activeTakeID: activeTakeID),
      !didCompleteSwing
    else {
      return nil
    }
    switch state {
    case .armed, .capturing:
      break
    case .listening, .acknowledged, .countdown, .finalizing, .replayReady, .cancelled,
      .timedOut, .error:
      return nil
    }

    didCompleteSwing = true
    cancelTransitionAndTimeout()
    state = .finalizing
    emit(.stopSpeech(takeID: activeTakeID))
    cancelTempoIfNeeded(takeID: activeTakeID)
    ensureStageRecordingStarted(takeID: activeTakeID)
    emit(.speak(cue: .finalizing, takeID: activeTakeID))
    scheduleTimeout(
      after: configuration.finalizationTimeout,
      reason: .finalizing,
      expectedState: .finalizing,
      takeID: activeTakeID
    )
    return activeTakeID
  }

  /// Accepts only the replay produced by the take currently being finalized.
  @discardableResult
  func handleReplayReady(for takeID: UUID) -> Bool {
    guard activeTakeID == takeID else { return false }
    switch state {
    case .finalizing, .timedOut(.finalizing):
      break
    case .listening, .acknowledged, .countdown, .armed, .capturing, .replayReady,
      .cancelled, .timedOut, .error:
      return false
    }
    timeoutTask?.cancel()
    timeoutTask = nil
    terminalTask?.cancel()
    terminalTask = nil
    state = .replayReady
    emit(.stopSpeech(takeID: takeID))
    emit(.speak(cue: .replayReady, takeID: takeID))
    scheduleResetToListening(for: takeID)
    return true
  }

  @discardableResult
  func cancel(for takeID: UUID? = nil) -> Bool {
    guard let activeTakeID, matches(takeID, activeTakeID: activeTakeID) else { return false }
    switch state {
    case .acknowledged, .countdown, .armed, .capturing:
      transitionToTerminal(
        state: .cancelled,
        speechCue: .cancelled,
        takeID: activeTakeID
      )
      return true
    case .listening, .finalizing, .replayReady, .cancelled, .timedOut, .error:
      return false
    }
  }

  @discardableResult
  func handleError(_ message: String, for takeID: UUID? = nil) -> Bool {
    guard let activeTakeID, matches(takeID, activeTakeID: activeTakeID) else { return false }
    switch state {
    case .acknowledged, .countdown, .armed, .capturing, .finalizing,
      .timedOut(.finalizing):
      let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
      let failureMessage =
        normalizedMessage.isEmpty
        ? "ไม่สามารถบันทึกวงสวิงได้"
        : normalizedMessage
      transitionToTerminal(
        state: .error(failureMessage),
        speechCue: .error(failureMessage),
        takeID: activeTakeID
      )
      return true
    case .listening, .replayReady, .cancelled, .timedOut, .error:
      return false
    }
  }

  private func scheduleCountdown(index: Int, after delay: Duration, takeID: UUID) {
    transitionTask?.cancel()
    transitionTask = scheduler.schedule(after: delay) { [weak self] in
      self?.advanceCountdown(index: index, takeID: takeID)
    }
  }

  private func advanceCountdown(index: Int, takeID: UUID) {
    guard activeTakeID == takeID else { return }
    switch state {
    case .acknowledged, .countdown:
      break
    case .listening, .armed, .capturing, .finalizing, .replayReady, .cancelled, .timedOut,
      .error:
      return
    }

    transitionTask = nil
    guard configuration.countdownValues.indices.contains(index) else {
      enterArmed(takeID: takeID)
      return
    }

    let value = configuration.countdownValues[index]
    state = .countdown(value)
    emit(.stopSpeech(takeID: takeID))
    emit(.speak(cue: .countdown(value), takeID: takeID))
    scheduleCountdown(
      index: index + 1,
      after: configuration.countdownInterval,
      takeID: takeID
    )
  }

  private func enterArmed(takeID: UUID) {
    guard activeTakeID == takeID else { return }
    state = .armed
    emit(.stopSpeech(takeID: takeID))
    ensureStageRecordingStarted(takeID: takeID)
    if activeTempoEnabled {
      didStartTempo = true
      emit(.startTempo(takeID: takeID))
    }
    scheduleTimeout(
      after: configuration.swingStartTimeout,
      reason: .waitingForSwing,
      expectedState: .armed,
      takeID: takeID
    )
  }

  private func scheduleTimeout(
    after delay: Duration,
    reason: HandsFreeCaptureTimeoutReason,
    expectedState: HandsFreeCaptureState,
    takeID: UUID
  ) {
    timeoutTask?.cancel()
    timeoutTask = scheduler.schedule(after: delay) { [weak self] in
      guard let self,
        self.activeTakeID == takeID,
        self.state == expectedState
      else {
        return
      }
      self.timeoutTask = nil
      if reason == .finalizing {
        // The swing and its history row are already committed. ScreenCaptureKit
        // can legitimately take longer to close a movie, so keep the recorder
        // completion and raw-camera fallback alive instead of discarding them.
        self.state = .timedOut(.finalizing)
        self.emit(.stopSpeech(takeID: takeID))
        self.emit(.speak(cue: .timedOut(.finalizing), takeID: takeID))
        return
      }
      self.transitionToTerminal(
        state: .timedOut(reason),
        speechCue: .timedOut(reason),
        takeID: takeID
      )
    }
  }

  private func transitionToTerminal(
    state terminalState: HandsFreeCaptureState,
    speechCue: HandsFreeCaptureSpeechCue,
    takeID: UUID
  ) {
    cancelActiveTasks()
    state = terminalState
    emit(.stopSpeech(takeID: takeID))
    cancelTempoIfNeeded(takeID: takeID)
    emit(.cancelStageRecording(takeID: takeID))
    emit(.speak(cue: speechCue, takeID: takeID))
    scheduleResetToListening(for: takeID)
  }

  private func scheduleResetToListening(for takeID: UUID) {
    terminalTask?.cancel()
    terminalTask = scheduler.schedule(after: configuration.terminalStateDuration) { [weak self] in
      guard let self, self.activeTakeID == takeID else { return }
      switch self.state {
      case .replayReady, .cancelled, .timedOut, .error:
        break
      case .listening, .acknowledged, .countdown, .armed, .capturing, .finalizing:
        return
      }

      self.terminalTask = nil
      self.activeTakeID = nil
      self.didStartStageRecording = false
      self.didStartTempo = false
      self.didCompleteSwing = false
      self.activeTempoEnabled = false
      self.state = .listening
    }
  }

  private func ensureStageRecordingStarted(takeID: UUID) {
    guard !didStartStageRecording else { return }
    didStartStageRecording = true
    emit(.startStageRecording(takeID: takeID))
  }

  private func cancelTempoIfNeeded(takeID: UUID) {
    guard didStartTempo else { return }
    didStartTempo = false
    emit(.cancelTempo(takeID: takeID))
  }

  private func cancelTransitionAndTimeout() {
    transitionTask?.cancel()
    transitionTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
  }

  private func cancelActiveTasks() {
    cancelTransitionAndTimeout()
    terminalTask?.cancel()
    terminalTask = nil
  }

  private func matches(_ providedTakeID: UUID?, activeTakeID: UUID) -> Bool {
    providedTakeID == nil || providedTakeID == activeTakeID
  }

  private func emit(_ event: HandsFreeCaptureEvent) {
    eventHandler?(event)
  }
}
