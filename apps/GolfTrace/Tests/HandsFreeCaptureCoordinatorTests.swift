import Foundation
import XCTest

@testable import GolfTrace

@MainActor
final class HandsFreeCaptureCoordinatorTests: XCTestCase {
  private let takeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let otherTakeID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

  func testAcknowledgementCountsDownThreeTwoOneThenTimesOutAndListensAgain() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    XCTAssertEqual(coordinator.startOneTake(), takeID)
    XCTAssertEqual(coordinator.state, .acknowledged)
    XCTAssertEqual(coordinator.activeTakeID, takeID)
    XCTAssertEqual(
      events,
      [
        .stopSpeech(takeID: takeID),
        .prepareStageRecording(takeID: takeID),
        .speak(cue: .acknowledged, takeID: takeID),
      ])
    XCTAssertNil(coordinator.startOneTake())
    XCTAssertEqual(events.filter { $0 == .prepareStageRecording(takeID: takeID) }.count, 1)

    XCTAssertEqual(scheduler.runNext(), .milliseconds(10))
    XCTAssertEqual(coordinator.state, .countdown(3))
    XCTAssertEqual(scheduler.runNext(), .milliseconds(20))
    XCTAssertEqual(coordinator.state, .countdown(2))
    XCTAssertEqual(scheduler.runNext(), .milliseconds(20))
    XCTAssertEqual(coordinator.state, .countdown(1))
    XCTAssertEqual(scheduler.runNext(), .milliseconds(20))
    XCTAssertEqual(coordinator.state, .armed)
    XCTAssertEqual(events.filter { $0 == .startStageRecording(takeID: takeID) }.count, 1)
    XCTAssertEqual(events.filter { $0 == .startTempo(takeID: takeID) }.count, 1)

    XCTAssertEqual(scheduler.runNext(), .milliseconds(30))
    XCTAssertEqual(coordinator.state, .timedOut(.waitingForSwing))
    XCTAssertNil(coordinator.handleSwingCompleted(for: takeID))
    XCTAssertEqual(
      events.suffix(4),
      [
        .stopSpeech(takeID: takeID),
        .cancelTempo(takeID: takeID),
        .cancelStageRecording(takeID: takeID),
        .speak(cue: .timedOut(.waitingForSwing), takeID: takeID),
      ])

    XCTAssertEqual(scheduler.runNext(), .milliseconds(60))
    XCTAssertEqual(coordinator.state, .listening)
    XCTAssertNil(coordinator.activeTakeID)
    XCTAssertFalse(coordinator.isActive)
  }

  func testDetectorCannotConsumeTakeUntilCountdownHasFinished() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    scheduler.runNext()
    XCTAssertEqual(coordinator.state, .countdown(3))

    XCTAssertFalse(coordinator.handleDetectorStarted(for: takeID))
    XCTAssertNil(coordinator.handleSwingCompleted(for: takeID))
    XCTAssertEqual(coordinator.state, .countdown(3))
    XCTAssertEqual(events.filter { $0 == .startStageRecording(takeID: takeID) }.count, 0)
    XCTAssertFalse(events.contains(.startTempo(takeID: takeID)))

    for _ in 0..<3 {
      XCTAssertEqual(scheduler.runNext(), .milliseconds(20))
    }
    XCTAssertEqual(coordinator.state, .armed)
    XCTAssertTrue(coordinator.handleDetectorStarted(for: takeID))
    XCTAssertEqual(coordinator.state, .capturing)
  }

  func testSlowFinalizationKeepsRecorderAliveAndAcceptsLateReplay() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    advanceToArmed(scheduler)
    XCTAssertNil(coordinator.handleSwingCompleted(for: otherTakeID))

    XCTAssertEqual(coordinator.handleSwingCompleted(for: takeID), takeID)
    XCTAssertEqual(coordinator.state, .finalizing)
    XCTAssertTrue(events.contains(.speak(cue: .finalizing, takeID: takeID)))
    XCTAssertNil(coordinator.handleSwingCompleted(for: takeID))
    XCTAssertEqual(events.filter { $0 == .startStageRecording(takeID: takeID) }.count, 1)
    XCTAssertEqual(scheduler.activeDelays, [.milliseconds(50)])

    XCTAssertEqual(scheduler.runNext(), .milliseconds(50))
    XCTAssertEqual(coordinator.state, .timedOut(.finalizing))
    XCTAssertFalse(events.contains(.cancelStageRecording(takeID: takeID)))
    XCTAssertTrue(
      events.contains(.speak(cue: .timedOut(.finalizing), takeID: takeID))
    )
    XCTAssertTrue(coordinator.isActive)
    XCTAssertTrue(coordinator.handleReplayReady(for: takeID))
    XCTAssertEqual(coordinator.state, .replayReady)
    XCTAssertEqual(scheduler.runNext(), .milliseconds(60))
    XCTAssertEqual(coordinator.state, .listening)
  }

  func testCancelAfterSwingCompletionCannotDiscardCommittedRecorder() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    advanceToArmed(scheduler)
    XCTAssertEqual(coordinator.handleSwingCompleted(for: takeID), takeID)

    XCTAssertFalse(coordinator.cancel(for: takeID))
    XCTAssertEqual(coordinator.state, .finalizing)
    XCTAssertFalse(events.contains(.cancelStageRecording(takeID: takeID)))
  }

  func testOnlyMatchingFinalizedTakeCanBecomeReplayReady() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    advanceToArmed(scheduler)
    XCTAssertTrue(coordinator.handleDetectorStarted(for: takeID))
    XCTAssertEqual(coordinator.handleSwingCompleted(for: takeID), takeID)

    XCTAssertFalse(coordinator.handleReplayReady(for: otherTakeID))
    XCTAssertTrue(coordinator.handleReplayReady(for: takeID))
    XCTAssertEqual(coordinator.state, .replayReady)
    XCTAssertEqual(events.filter { $0 == .startTempo(takeID: takeID) }.count, 1)
    XCTAssertEqual(events.filter { $0 == .cancelTempo(takeID: takeID) }.count, 1)
    XCTAssertFalse(events.contains(.cancelStageRecording(takeID: takeID)))

    XCTAssertEqual(scheduler.runNext(), .milliseconds(60))
    XCTAssertEqual(coordinator.state, .listening)
    XCTAssertNil(coordinator.activeTakeID)
  }

  func testCancelDuringCountdownDiscardsPreparedRecordingAndIgnoresOldTimer() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    scheduler.runNext()
    XCTAssertEqual(coordinator.state, .countdown(3))

    XCTAssertTrue(coordinator.cancel(for: takeID))
    XCTAssertEqual(coordinator.state, .cancelled)
    XCTAssertFalse(coordinator.cancel(for: takeID))
    XCTAssertEqual(events.filter { $0 == .cancelStageRecording(takeID: takeID) }.count, 1)
    XCTAssertFalse(events.contains(.startStageRecording(takeID: takeID)))

    XCTAssertEqual(scheduler.runNext(), .milliseconds(60))
    XCTAssertEqual(coordinator.state, .listening)
    XCTAssertFalse(events.contains(.speak(cue: .countdown(2), takeID: takeID)))
  }

  func testErrorRejectsWrongTakeAndNormalizesEmptyMessage() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    XCTAssertFalse(coordinator.handleError("stale", for: otherTakeID))
    XCTAssertEqual(coordinator.state, .acknowledged)

    XCTAssertTrue(coordinator.handleError("  \n ", for: takeID))
    XCTAssertEqual(coordinator.state, .error("ไม่สามารถบันทึกวงสวิงได้"))
    XCTAssertTrue(
      events.contains(
        .speak(cue: .error("ไม่สามารถบันทึกวงสวิงได้"), takeID: takeID)
      )
    )
    XCTAssertEqual(events.filter { $0 == .cancelStageRecording(takeID: takeID) }.count, 1)
  }

  func testTempoCanBeDisabledWithoutChangingCaptureProgression() {
    let scheduler = ManualHandsFreeCaptureScheduler()
    var events: [HandsFreeCaptureEvent] = []
    let coordinator = makeCoordinator(
      scheduler: scheduler,
      configuration: configuration(tempoEnabled: false),
      eventHandler: { events.append($0) }
    )

    coordinator.startOneTake()
    advanceToArmed(scheduler)
    XCTAssertEqual(coordinator.state, .armed)
    XCTAssertFalse(events.contains(.startTempo(takeID: takeID)))

    XCTAssertTrue(coordinator.handleDetectorStarted(for: takeID))
    XCTAssertEqual(coordinator.handleSwingCompleted(for: takeID), takeID)
    XCTAssertFalse(events.contains(.cancelTempo(takeID: takeID)))
  }

  private func makeCoordinator(
    scheduler: ManualHandsFreeCaptureScheduler,
    configuration: HandsFreeCaptureConfiguration? = nil,
    eventHandler: @escaping HandsFreeCaptureCoordinator.EventHandler
  ) -> HandsFreeCaptureCoordinator {
    HandsFreeCaptureCoordinator(
      configuration: configuration ?? self.configuration(),
      scheduler: scheduler,
      makeTakeID: { self.takeID },
      eventHandler: eventHandler
    )
  }

  private func configuration(tempoEnabled: Bool = true) -> HandsFreeCaptureConfiguration {
    HandsFreeCaptureConfiguration(
      acknowledgementDelay: .milliseconds(10),
      countdownInterval: .milliseconds(20),
      swingStartTimeout: .milliseconds(30),
      captureTimeout: .milliseconds(40),
      finalizationTimeout: .milliseconds(50),
      terminalStateDuration: .milliseconds(60),
      tempoEnabled: tempoEnabled
    )
  }

  private func advanceToArmed(_ scheduler: ManualHandsFreeCaptureScheduler) {
    for _ in 0..<4 {
      XCTAssertNotNil(scheduler.runNext())
    }
  }
}

@MainActor
private final class ManualHandsFreeCaptureScheduler: HandsFreeCaptureScheduling {
  @MainActor
  private final class ScheduledTask: HandsFreeCaptureScheduledTask {
    let delay: Duration
    let action: @MainActor @Sendable () -> Void
    private(set) var isCancelled = false

    init(delay: Duration, action: @escaping @MainActor @Sendable () -> Void) {
      self.delay = delay
      self.action = action
    }

    func cancel() {
      isCancelled = true
    }
  }

  private var tasks: [ScheduledTask] = []

  var activeDelays: [Duration] {
    tasks.filter { !$0.isCancelled }.map(\.delay)
  }

  func schedule(
    after delay: Duration,
    action: @escaping @MainActor @Sendable () -> Void
  ) -> any HandsFreeCaptureScheduledTask {
    let task = ScheduledTask(delay: delay, action: action)
    tasks.append(task)
    return task
  }

  @discardableResult
  func runNext() -> Duration? {
    while !tasks.isEmpty {
      let task = tasks.removeFirst()
      guard !task.isCancelled else { continue }
      task.action()
      return task.delay
    }
    return nil
  }
}
