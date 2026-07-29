import CoreMedia
import Foundation
import XCTest

@testable import GolfTrace

@MainActor
final class SwingCueCoordinatorTests: XCTestCase {
  func testTempoTrainerSchedulesFourSemanticEventsAtThreeToOneTiming() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)
    let configuration = SwingTempoTrainerConfiguration(
      backswingSeconds: 1.2,
      downswingSeconds: 0.4,
      finishDelaySeconds: 0.5
    )

    coordinator.startTempoTrainer(configuration: configuration, volume: 0.65)

    XCTAssertEqual(configuration.targetRatio, 3.0, accuracy: 0.000_001)
    XCTAssertEqual(
      player.scheduled.map(\.event),
      [
        .tempoStart,
        .tempoTop,
        .tempoImpact,
        .tempoFinish,
      ])
    let delays = player.scheduled.map(\.delay)
    XCTAssertEqual(delays[0], 0, accuracy: 0.000_001)
    XCTAssertEqual(delays[1], 1.2, accuracy: 0.000_001)
    XCTAssertEqual(delays[2], 1.6, accuracy: 0.000_001)
    XCTAssertEqual(delays[3], 2.1, accuracy: 0.000_001)
    XCTAssertTrue(player.scheduled.allSatisfy { abs($0.volume - 0.65) < 0.000_001 })
    XCTAssertTrue(coordinator.isTempoTrainerRunning)

    coordinator.cancelAllCues()
  }

  func testConfirmingAndSwingingCancelEveryPendingCue() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)

    coordinator.startTempoTrainer()
    coordinator.handleSessionState(.confirmingSwing)

    XCTAssertFalse(coordinator.isTempoTrainerRunning)
    XCTAssertGreaterThanOrEqual(player.cancelCount, 2)
    XCTAssertEqual(coordinator.statusText, SwingSessionDetectorState.confirmingSwing.displayName)

    coordinator.startTempoTrainer()
    let countBeforeSwinging = player.cancelCount
    coordinator.handleSessionState(.swinging)

    XCTAssertFalse(coordinator.isTempoTrainerRunning)
    XCTAssertEqual(player.cancelCount, countBeforeSwinging + 1)
    XCTAssertEqual(coordinator.statusText, SwingSessionDetectorState.swinging.displayName)
  }

  func testOneTakeTempoCanContinueAcrossDetectedSwing() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)

    coordinator.startTempoTrainer(preserveDuringActiveSwing: true)
    let cancelCountBeforeSwing = player.cancelCount
    coordinator.handleSessionState(.confirmingSwing)
    coordinator.handleSessionState(.swinging)

    XCTAssertTrue(coordinator.isTempoTrainerRunning)
    XCTAssertEqual(player.cancelCount, cancelCountBeforeSwing)

    coordinator.cancelAllCues()
  }

  func testArmedCueIsOncePerRoundAndNeverRepeatsAfterConfirmationJitter() {
    let player = RecordingSwingCuePlayer()
    var now = 100.0
    let coordinator = SwingCueCoordinator(player: player, currentTime: { now })

    coordinator.handleSessionState(.armed)
    coordinator.handleSessionState(.armed)
    coordinator.handleSessionState(.confirmingSwing)
    now += 1
    coordinator.handleSessionState(.armed)

    XCTAssertEqual(player.events.filter { $0 == .armed }.count, 1)
  }

  func testReadyDebounceHasFiveSecondFloorAcrossRounds() {
    let player = RecordingSwingCuePlayer()
    var now = 100.0
    let coordinator = SwingCueCoordinator(
      player: player,
      readyDebounceSeconds: 0.1,
      currentTime: { now }
    )

    XCTAssertEqual(coordinator.readyDebounceSeconds, 5.0)
    coordinator.handleSessionState(.armed)
    coordinator.handleSessionState(.completed, completedSummary: sessionSummary(end: 1.0))
    coordinator.handleSessionState(.waitingForStillness)

    now = 103.0
    coordinator.handleSessionState(.armed)
    XCTAssertEqual(player.events.filter { $0 == .armed }.count, 1)

    coordinator.handleSessionState(.completed, completedSummary: sessionSummary(end: 2.0))
    coordinator.handleSessionState(.waitingForStillness)
    now = 106.0
    coordinator.handleSessionState(.armed)
    XCTAssertEqual(player.events.filter { $0 == .armed }.count, 2)
  }

  func testCompletedCueDeduplicatesUsingEndTimestamp() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)
    let first = sessionSummary(end: 1.25)

    coordinator.handleSessionState(.completed, completedSummary: first)
    coordinator.handleSessionState(.completed, completedSummary: first)
    coordinator.handleSessionState(.completed, completedSummary: sessionSummary(end: 2.50))

    XCTAssertEqual(player.events.filter { $0 == .completed }.count, 2)
  }

  func testSessionVolumeIsClampedAndCompletedCueCanBeSuppressedWithoutBreakingDedupe() {
    let player = RecordingSwingCuePlayer()
    var now = 0.0
    let coordinator = SwingCueCoordinator(player: player, currentTime: { now })

    coordinator.handleSessionState(.armed, volume: 0)
    XCTAssertEqual(player.scheduled.last?.event, .armed)
    XCTAssertEqual(player.scheduled.last?.volume, 0)

    let summary = sessionSummary(end: 3.0)
    coordinator.handleSessionState(
      .completed,
      completedSummary: summary,
      volume: 2,
      playCompletedCue: false
    )
    XCTAssertFalse(player.events.contains(.completed))

    // เวลาจบเดียวกันถูกใช้ไปแล้ว แม้รอบแรกตั้งใจเงียบ จึงต้องไม่ดังซ้ำภายหลัง
    coordinator.handleSessionState(
      .completed,
      completedSummary: summary,
      volume: 2,
      playCompletedCue: true
    )
    XCTAssertFalse(player.events.contains(.completed))

    coordinator.handleSessionState(.waitingForStillness)
    now = 6.0
    coordinator.handleSessionState(.armed, volume: 2)
    XCTAssertEqual(player.scheduled.last?.event, .armed)
    XCTAssertEqual(player.scheduled.last?.volume, 1)
  }

  func testTempoGuidelineUsesHandTempoQualityAndCorrectFeedbackSounds() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)

    let within = coordinator.provideGuidelineFeedback(
      analysis: analysis(handTempo: reading(3.25, quality: .limited)),
      guideline: .tempo
    )
    let outside = coordinator.provideGuidelineFeedback(
      analysis: analysis(handTempo: reading(3.75, quality: .good)),
      guideline: .tempo
    )
    let unavailable = coordinator.provideGuidelineFeedback(
      analysis: analysis(handTempo: reading(nil, quality: .unavailable)),
      guideline: .tempo
    )

    XCTAssertEqual(within.status, .within)
    XCTAssertEqual(within.metricName, "อัตราจังหวะมือ")
    XCTAssertEqual(within.quality, .limited)
    XCTAssertEqual(outside.status, .outside)
    XCTAssertEqual(unavailable.status, .unavailable)
    XCTAssertEqual(
      Array(player.events.suffix(3)),
      [.guidelinePositive, .guidelineNegative, .guidelineNeutral]
    )
  }

  func testPostureRequiresCallerTargetToleranceAndAvailableMetric() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)
    let summary = analysis(addressTilt: reading(34.0, quality: .good))

    let withoutTarget = coordinator.provideGuidelineFeedback(
      analysis: summary,
      guideline: .posture
    )
    let withTarget = coordinator.provideGuidelineFeedback(
      analysis: summary,
      guideline: .posture,
      configuration: SwingGuidelineEvaluationConfiguration(
        postureTarget: SwingPostureGuidelineTarget(
          addressTorsoTiltDegrees: 35.0,
          toleranceDegrees: 2.0
        )
      )
    )

    XCTAssertEqual(withoutTarget.status, .unavailable)
    XCTAssertEqual(withTarget.status, .within)
    XCTAssertEqual(withTarget.measuredValue, 34.0)
    XCTAssertEqual(Array(player.events.suffix(2)), [.guidelineNeutral, .guidelinePositive])
  }

  func testUnsupportedTwoDimensionalGuidelinesRemainUnavailableAndNeverPlayNegative() {
    let player = RecordingSwingCuePlayer()
    let coordinator = SwingCueCoordinator(player: player)
    let summary = analysis()

    for guideline in [
      GolfGuideline.personalBaseline,
      .swingPlane,
      .rotation,
    ] {
      let feedback = coordinator.provideGuidelineFeedback(
        analysis: summary,
        guideline: guideline
      )
      XCTAssertEqual(feedback.status, .unavailable)
    }

    XCTAssertFalse(player.events.contains(.guidelineNegative))
    XCTAssertEqual(player.events.filter { $0 == .guidelineNeutral }.count, 3)
  }

  private func sessionSummary(end: Double) -> SwingSessionSummary {
    SwingSessionSummary(
      duration: 1.0,
      peakNormalizedHandSpeed: 2.0,
      pathLength: 1.0,
      sampleCount: 0,
      pointHistory: [],
      completionReason: .returnedToStillness,
      startTimestamp: CMTime(seconds: max(0, end - 1), preferredTimescale: 1_000),
      endTimestamp: CMTime(seconds: end, preferredTimescale: 1_000)
    )
  }

  private func analysis(
    addressTilt: SwingMetricReading? = nil,
    handTempo: SwingMetricReading? = nil
  ) -> SwingAnalysisSummary {
    let unavailable = reading(nil, quality: .unavailable)
    return SwingAnalysisSummary(
      handPathBodyLengths: unavailable,
      peakHandSpeedBodyLengthsPerSecond: unavailable,
      addressTorsoTiltDegrees: addressTilt ?? unavailable,
      torsoTiltChangeDegrees: unavailable,
      shoulderSpanReductionPercent: unavailable,
      hipSpanReductionPercent: unavailable,
      backswingSeconds: unavailable,
      downswingSeconds: unavailable,
      handTempoRatio: handTempo ?? unavailable,
      quality: .limited,
      trackedFraction: 0.8,
      reason: "ข้อมูลทดสอบ"
    )
  }

  private func reading(
    _ value: Double?,
    quality: SwingMetricQuality
  ) -> SwingMetricReading {
    SwingMetricReading(
      value: value,
      quality: quality,
      trackedFraction: value == nil ? 0 : 0.8,
      reason: value == nil ? "ข้อมูลไม่พอ" : "ค่าทดสอบ"
    )
  }
}

@MainActor
private final class RecordingSwingCuePlayer: SwingCuePlaying {
  struct Scheduled: Equatable {
    let event: SwingCueEvent
    let delay: TimeInterval
    let volume: Float
  }

  private(set) var scheduled: [Scheduled] = []
  private(set) var cancelCount = 0
  var events: [SwingCueEvent] { scheduled.map(\.event) }

  func schedule(_ event: SwingCueEvent, after delay: TimeInterval, volume: Float) {
    scheduled.append(Scheduled(event: event, delay: delay, volume: volume))
  }

  func cancelAll() {
    cancelCount += 1
  }
}
