import CoreMedia
import Foundation

/// Capture metadata sampled independently from the ordered pose stream.
///
/// These values are diagnostic context for the completed evidence packet. They
/// do not participate in motion/session detection, so updating them on the
/// pipeline queue cannot reorder or drop a pose result.
struct LiveSwingCaptureContext: Equatable, Sendable {
  var captureFPS: Double?
  var poseAnalysisFPS: Double?
  var cameraView: String
  var sourceID: String
  var orientation: SwingStoryboardCaptureOrientation
  var encodedPixelWidth: Int?
  var encodedPixelHeight: Int?

  init(
    captureFPS: Double?,
    poseAnalysisFPS: Double?,
    cameraView: String,
    sourceID: String = SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
    orientation: SwingStoryboardCaptureOrientation = .unknown,
    encodedPixelWidth: Int? = nil,
    encodedPixelHeight: Int? = nil
  ) {
    self.captureFPS = captureFPS
    self.poseAnalysisFPS = poseAnalysisFPS
    self.cameraView = cameraView
    self.sourceID = sourceID
    self.orientation = orientation
    self.encodedPixelWidth = encodedPixelWidth
    self.encodedPixelHeight = encodedPixelHeight
  }

  static let initial = LiveSwingCaptureContext(
    captureFPS: nil,
    poseAnalysisFPS: nil,
    cameraView: GolfPracticeSettings.default.cameraView.rawValue,
    sourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID
  )
}

/// Immutable UI projection of one fully analyzed pose. The pipeline processes
/// every pose in order but only materializes this history-bearing form at the
/// coalesced display boundary.
struct LiveSwingSnapshot: @unchecked Sendable {
  let epoch: UInt64
  let processedPoseCount: Int
  let pose: PoseFrame?
  let motion: SwingMotionFrame
  let sessionState: SwingSessionDetectorState
  let sessionStatus: String
}

/// A completed swing is delivered on a separate, non-coalesced channel so a
/// later live pose can never replace a summary or its evidence packet.
struct LiveSwingCompletion: @unchecked Sendable {
  let epoch: UInt64
  let session: SwingSessionSummary
  let result: SwingAnalysisResult
  let captureContext: LiveSwingCaptureContext

  func delivered(in epoch: UInt64) -> LiveSwingCompletion {
    LiveSwingCompletion(
      epoch: epoch,
      session: session,
      result: result,
      captureContext: captureContext
    )
  }
}

struct LiveSwingPipelineResetToken: Equatable, Sendable {
  let epoch: UInt64
  let sourceGeneration: UInt64
}

/// Owns all mutable live swing analyzers on one ordered serial executor.
///
/// `PoseDetector` already produces ordered results, but it can outpace the main
/// actor. This boundary keeps every result for session/metric correctness while
/// allowing the UI projection to replace an older pending projection.
final class LiveSwingPipeline: @unchecked Sendable {
  typealias SnapshotDelivery = @MainActor @Sendable (LiveSwingSnapshot) -> Void
  typealias CompletionDelivery = @MainActor @Sendable (LiveSwingCompletion) -> Void

  static var resetMotionSnapshot: SwingMotionFrame {
    SwingMotionFrame(
      handCenter: nil,
      pointHistory: [],
      normalizedHandSpeed: nil,
      state: .unavailable,
      timestamp: nil,
      diagnosticText: "เริ่มเส้นทางมือใหม่ — ขณะนี้ใช้จุดกึ่งกลางข้อมือ ไม่ใช่เส้นทางหัวไม้"
    )
  }

  private struct ResetRequest: Sendable {
    let token: LiveSwingPipelineResetToken
    let resetMotionAndMetrics: Bool
    let preservesLastCompletion: Bool
  }

  private final class PoseTransfer: @unchecked Sendable {
    let epoch: UInt64
    let sourceGeneration: UInt64
    let pose: PoseFrame?

    init(epoch: UInt64, sourceGeneration: UInt64, pose: PoseFrame?) {
      self.epoch = epoch
      self.sourceGeneration = sourceGeneration
      self.pose = pose
    }
  }

  private struct PendingLiveState: @unchecked Sendable {
    let epoch: UInt64
    let processedPoseCount: Int
    let pose: PoseFrame?
    let sessionState: SwingSessionDetectorState
    let sessionStatus: String
  }

  private let queue = DispatchQueue(
    label: "com.bda.golftrace.live-swing-pipeline",
    qos: .userInitiated
  )
  /// Serializes enqueue order between the pose queue and main-actor resets.
  private let submissionLock = NSLock()
  private var submittedEpoch: UInt64 = 0
  private var expectedSourceGeneration: UInt64 = 0

  // The following state is confined to `queue`.
  private var activeEpoch: UInt64 = 0
  private var activeSourceGeneration: UInt64 = 0
  private let motionAnalyzer: SwingMotionAnalyzer
  private let sessionDetector: SwingSessionDetector
  private let metricsAnalyzer: SwingMetricsAnalyzer
  private var captureContext = LiveSwingCaptureContext.initial
  private var activeSessionCaptureContext: LiveSwingCaptureContext?
  private var processedPoseCount = 0
  private var lastCompletion: LiveSwingCompletion?
  private var pendingLiveState: PendingLiveState?
  private var isLiveSnapshotScheduled = false
  private var liveSnapshotScheduleID: UInt64 = 0
  private var lastLiveSnapshotTime: TimeInterval = 0

  private let livePublisher: MainActorLatestValuePublisher<LiveSwingSnapshot>
  private let completionDelivery: CompletionDelivery
  private let minimumLiveSnapshotInterval: TimeInterval

  init(
    maximumLivePublicationFPS: Double = 30,
    sessionConfiguration: SwingSessionDetectorConfiguration = .init(),
    positionSmoothingTimeConstant: TimeInterval = 0.03,
    onSnapshot: @escaping SnapshotDelivery,
    onCompletion: @escaping CompletionDelivery
  ) {
    motionAnalyzer = SwingMotionAnalyzer(
      positionSmoothingTimeConstant: positionSmoothingTimeConstant
    )
    sessionDetector = SwingSessionDetector(configuration: sessionConfiguration)
    metricsAnalyzer = SwingMetricsAnalyzer()
    minimumLiveSnapshotInterval = 1 / max(1, maximumLivePublicationFPS)
    livePublisher = MainActorLatestValuePublisher(
      delivery: onSnapshot
    )
    completionDelivery = onCompletion
  }

  /// Invalidates all submitted work from the previous epoch and advances the
  /// `PoseDetector` generation expected by the next pose. Call this immediately
  /// after `PoseDetector.reset()` so both generation counters remain paired.
  @discardableResult
  func reset(
    resetMotionAndMetrics: Bool,
    preservingLastCompletion: Bool
  ) -> LiveSwingPipelineResetToken {
    submissionLock.lock()
    submittedEpoch &+= 1
    expectedSourceGeneration &+= 1
    let token = LiveSwingPipelineResetToken(
      epoch: submittedEpoch,
      sourceGeneration: expectedSourceGeneration
    )
    let request = ResetRequest(
      token: token,
      resetMotionAndMetrics: resetMotionAndMetrics,
      preservesLastCompletion: preservingLastCompletion
    )
    queue.async { [weak self] in
      self?.applyReset(request)
    }
    submissionLock.unlock()
    return token
  }

  /// Enqueues one Vision result. No pose within the active generation is
  /// coalesced here; only the UI projection produced after analysis is.
  func consume(_ pose: PoseFrame?, sourceGeneration: UInt64) {
    submissionLock.lock()
    let transfer = PoseTransfer(
      epoch: submittedEpoch,
      sourceGeneration: sourceGeneration,
      pose: pose
    )
    queue.async { [weak self] in
      self?.process(transfer)
    }
    submissionLock.unlock()
  }

  func updateCaptureContext(_ context: LiveSwingCaptureContext) {
    submissionLock.lock()
    queue.async { [weak self] in
      self?.captureContext = context
    }
    submissionLock.unlock()
  }

  /// Test/support hook that runs after all work submitted before this call.
  func whenIdle(_ action: @escaping @Sendable () -> Void) {
    submissionLock.lock()
    queue.async(execute: action)
    submissionLock.unlock()
  }

  private func applyReset(_ request: ResetRequest) {
    activeEpoch = request.token.epoch
    activeSourceGeneration = request.token.sourceGeneration
    pendingLiveState = nil
    isLiveSnapshotScheduled = false
    liveSnapshotScheduleID &+= 1
    lastLiveSnapshotTime = 0
    livePublisher.clearPendingValue()
    processedPoseCount = 0
    activeSessionCaptureContext = nil

    if request.resetMotionAndMetrics {
      motionAnalyzer.reset()
      metricsAnalyzer.reset()
    }

    if request.preservesLastCompletion {
      sessionDetector.resetActiveSession()
    } else {
      sessionDetector.reset()
      lastCompletion = nil
    }

    // A completion that raced a reconnect remains valid when the caller asked
    // to preserve it. Re-delivery in the new epoch prevents the main actor's
    // stale-epoch guard from accidentally losing that result.
    if request.preservesLastCompletion,
      let lastCompletion
    {
      deliverCompletion(lastCompletion.delivered(in: request.token.epoch))
    }
  }

  private func process(_ transfer: PoseTransfer) {
    guard transfer.sourceGeneration == activeSourceGeneration,
      transfer.epoch == activeEpoch
    else {
      return
    }

    let leanMotion = motionAnalyzer.consume(
      transfer.pose,
      materializePointHistory: false
    )
    metricsAnalyzer.consume(pose: transfer.pose, motion: leanMotion)
    let previousState = sessionDetector.state
    let nextState = sessionDetector.consume(leanMotion)
    if previousState != .confirmingSwing && previousState != .swinging,
      nextState == .confirmingSwing || nextState == .swinging
    {
      // Freeze source identity/orientation at the start of this detector
      // session. A reconnect or device turn resets the whole pipeline, so a
      // completed packet can never be relabelled from mutable UI state later.
      activeSessionCaptureContext = captureContext
    }
    let nextStatus = sessionDetector.statusText
    processedPoseCount += 1

    offerLiveState(
      PendingLiveState(
        epoch: transfer.epoch,
        processedPoseCount: processedPoseCount,
        pose: transfer.pose,
        sessionState: nextState,
        sessionStatus: nextStatus
      ))

    guard nextState == .completed,
      let completedSession = sessionDetector.lastCompletedSummary
    else {
      return
    }

    let completedCaptureContext = activeSessionCaptureContext ?? captureContext
    let result = metricsAnalyzer.finalizeWithEvidence(
      session: completedSession,
      captureFPS: completedCaptureContext.captureFPS,
      poseAnalysisFPS: completedCaptureContext.poseAnalysisFPS,
      cameraView: completedCaptureContext.cameraView
    )
    let completion = LiveSwingCompletion(
      epoch: transfer.epoch,
      session: completedSession,
      result: result,
      captureContext: completedCaptureContext
    )
    activeSessionCaptureContext = nil
    lastCompletion = completion
    deliverCompletion(completion)
  }

  private func offerLiveState(_ state: PendingLiveState) {
    pendingLiveState = state
    guard !isLiveSnapshotScheduled else { return }

    let now = ProcessInfo.processInfo.systemUptime
    let delay = max(0, minimumLiveSnapshotInterval - (now - lastLiveSnapshotTime))
    if delay == 0 {
      publishLatestLiveState(scheduleID: liveSnapshotScheduleID)
      return
    }

    isLiveSnapshotScheduled = true
    let scheduleID = liveSnapshotScheduleID
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.publishLatestLiveState(scheduleID: scheduleID)
    }
  }

  private func publishLatestLiveState(scheduleID: UInt64) {
    guard scheduleID == liveSnapshotScheduleID else { return }
    isLiveSnapshotScheduled = false
    guard let state = pendingLiveState else { return }
    pendingLiveState = nil
    guard state.epoch == activeEpoch else { return }

    // This is the only history-materialization point in the steady-state pose
    // path. The analyzers above consume lean frames at the full Vision rate.
    let snapshot = LiveSwingSnapshot(
      epoch: state.epoch,
      processedPoseCount: state.processedPoseCount,
      pose: state.pose,
      motion: motionAnalyzer.uiSnapshot(),
      sessionState: state.sessionState,
      sessionStatus: state.sessionStatus
    )
    lastLiveSnapshotTime = ProcessInfo.processInfo.systemUptime
    livePublisher.offer(snapshot)
  }

  private func deliverCompletion(_ completion: LiveSwingCompletion) {
    let delivery = completionDelivery
    Task { @MainActor in
      delivery(completion)
    }
  }

}

/// A main-actor publisher with exactly one pending value and one outstanding
/// task. If the UI is busy, new values replace the pending value instead of
/// creating an ever-growing queue of stale main-actor jobs.
private final class MainActorLatestValuePublisher<Value>: @unchecked Sendable {
  typealias Delivery = @MainActor @Sendable (Value) -> Void

  private let lock = NSLock()
  private let delivery: Delivery
  private var latestValue: Value?
  private var isDeliveryScheduled = false

  init(delivery: @escaping Delivery) {
    self.delivery = delivery
  }

  func offer(_ value: Value) {
    let shouldSchedule: Bool
    lock.lock()
    latestValue = value
    if isDeliveryScheduled {
      shouldSchedule = false
    } else {
      isDeliveryScheduled = true
      shouldSchedule = true
    }
    lock.unlock()

    if shouldSchedule {
      scheduleDelivery()
    }
  }

  func clearPendingValue() {
    lock.lock()
    latestValue = nil
    lock.unlock()
  }

  private func scheduleDelivery() {
    Task { @MainActor [weak self] in
      self?.deliverLatestValue()
    }
  }

  @MainActor
  private func deliverLatestValue() {
    let value: Value?
    lock.lock()
    value = latestValue
    latestValue = nil
    if value == nil {
      isDeliveryScheduled = false
    }
    lock.unlock()

    guard let value else { return }
    delivery(value)

    let shouldScheduleNext: Bool
    lock.lock()
    if latestValue == nil {
      isDeliveryScheduled = false
      shouldScheduleNext = false
    } else {
      shouldScheduleNext = true
    }
    lock.unlock()

    if shouldScheduleNext {
      scheduleDelivery()
    }
  }
}
