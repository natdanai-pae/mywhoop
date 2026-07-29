import CoreMedia
import Foundation
import XCTest

@testable import GolfTrace

final class SwingSessionDetectorTests: XCTestCase {
  private let configuration = SwingSessionDetectorConfiguration(
    stillSpeedThreshold: 0.10,
    swingStartSpeedThreshold: 0.75,
    armStillnessDuration: 0.20,
    startConfirmationDuration: 0.05,
    endStillnessDuration: 0.10,
    maximumSwingDuration: 0.50,
    preRollDuration: 0.10
  )

  func testOneFrameJitterDoesNotStartSwing() {
    let detector = SwingSessionDetector(configuration: configuration)
    arm(detector)

    XCTAssertEqual(detector.consume(frame(at: 0.30, x: 0.20, speed: 1.20)), .confirmingSwing)
    XCTAssertEqual(detector.consume(frame(at: 0.32, x: 0.20, speed: 0.20)), .armed)
    XCTAssertNil(detector.lastCompletedSummary)
  }

  func testFullSwingCompletesWithDeterministicSummaryAndPreRoll() throws {
    let detector = SwingSessionDetector(configuration: configuration)
    arm(detector)

    detector.consume(frame(at: 0.30, x: 0.20, speed: 1.00))
    XCTAssertEqual(detector.consume(frame(at: 0.36, x: 0.30, speed: 1.50)), .swinging)
    detector.consume(frame(at: 0.46, x: 0.55, speed: 2.00))
    detector.consume(frame(at: 0.60, x: 0.70, speed: 0.05))
    XCTAssertEqual(detector.consume(frame(at: 0.71, x: 0.72, speed: 0.02)), .completed)

    let summary = try XCTUnwrap(detector.lastCompletedSummary)
    XCTAssertEqual(summary.completionReason, .returnedToStillness)
    XCTAssertEqual(summary.duration, 0.41, accuracy: 0.000_001)
    XCTAssertEqual(summary.peakNormalizedHandSpeed, 2.00, accuracy: 0.000_001)
    XCTAssertEqual(summary.sampleCount, summary.pointHistory.count)
    XCTAssertGreaterThanOrEqual(summary.sampleCount, 5)
    XCTAssertGreaterThan(summary.pathLength, 0.5)
    XCTAssertLessThan(CMTimeGetSeconds(summary.pointHistory[0].timestamp), 0.30)
    XCTAssertTrue(detector.statusText.contains("บันทึกวงสวิงแล้ว"))
  }

  func testBriefSlowdownDoesNotFinishSwingEarly() {
    let detector = SwingSessionDetector(configuration: configuration)
    armAndStart(detector)

    XCTAssertEqual(detector.consume(frame(at: 0.40, x: 0.40, speed: 0.05)), .swinging)
    XCTAssertEqual(detector.consume(frame(at: 0.45, x: 0.55, speed: 1.10)), .swinging)
    XCTAssertNil(detector.lastCompletedSummary)

    detector.consume(frame(at: 0.60, x: 0.65, speed: 0.05))
    XCTAssertEqual(detector.consume(frame(at: 0.71, x: 0.66, speed: 0.05)), .completed)
    XCTAssertEqual(detector.lastCompletedSummary?.completionReason, .returnedToStillness)
  }

  func testTimeoutCompletesThenDetectorCanResetForNextSwing() throws {
    let detector = SwingSessionDetector(configuration: configuration)
    armAndStart(detector)

    XCTAssertEqual(detector.consume(frame(at: 0.81, x: 0.80, speed: 1.00)), .completed)
    let summary = try XCTUnwrap(detector.lastCompletedSummary)
    XCTAssertEqual(summary.completionReason, .timedOut)
    XCTAssertEqual(summary.duration, 0.51, accuracy: 0.000_001)

    XCTAssertEqual(detector.consume(frame(at: 0.82, x: 0.80, speed: 0.05)), .waitingForStillness)
    XCTAssertNotNil(detector.lastCompletedSummary)

    detector.reset()
    XCTAssertEqual(detector.state, .waitingForStillness)
    XCTAssertNil(detector.lastCompletedSummary)
    XCTAssertEqual(detector.statusText, SwingSessionDetectorState.waitingForStillness.displayName)
  }

  func testStreamResetCanPreserveSummaryAndAcceptTimestampStartingAtZero() throws {
    let detector = SwingSessionDetector(configuration: configuration)
    armAndStart(detector)
    detector.consume(frame(at: 0.81, x: 0.80, speed: 1.00))
    let completedSummary = try XCTUnwrap(detector.lastCompletedSummary)

    detector.resetActiveSession()

    XCTAssertEqual(detector.state, .waitingForStillness)
    XCTAssertEqual(detector.lastCompletedSummary, completedSummary)
    XCTAssertEqual(detector.consume(frame(at: 0.00, x: 0.20, speed: 0.05)), .waitingForStillness)
    detector.consume(frame(at: 0.10, x: 0.20, speed: 0.05))
    XCTAssertEqual(detector.consume(frame(at: 0.20, x: 0.20, speed: 0.05)), .armed)
    XCTAssertEqual(detector.lastCompletedSummary, completedSummary)
  }

  func testMissingHandDoesNotArmStartOrPrematurelyFinishSwing() {
    let detector = SwingSessionDetector(configuration: configuration)

    detector.consume(frame(at: 0.00, x: 0.20, speed: 0.05))
    detector.consume(missingHandFrame(at: 0.15))
    detector.consume(frame(at: 0.25, x: 0.20, speed: 0.05))
    XCTAssertEqual(detector.state, .waitingForStillness)

    detector.consume(frame(at: 0.46, x: 0.20, speed: 0.05))
    XCTAssertEqual(detector.state, .armed)
    detector.consume(frame(at: 0.50, x: 0.25, speed: 1.00))
    XCTAssertEqual(detector.consume(missingHandFrame(at: 0.54)), .armed)

    detector.consume(frame(at: 0.60, x: 0.30, speed: 1.00))
    XCTAssertEqual(detector.consume(frame(at: 0.66, x: 0.45, speed: 1.20)), .swinging)
    XCTAssertEqual(detector.consume(missingHandFrame(at: 0.75)), .swinging)
    XCTAssertNil(detector.lastCompletedSummary)
  }

  func testUntimestampedMissingHandUsesFriendlyStatusWithoutChangingState() {
    let detector = SwingSessionDetector(configuration: configuration)

    XCTAssertEqual(detector.consume(untimestampedMissingHandFrame()), .waitingForStillness)
    XCTAssertEqual(detector.statusText, "ยังไม่พบมือ — จัดให้เห็นทั้งตัวในภาพ")

    armAndStart(detector)
    XCTAssertEqual(detector.consume(untimestampedMissingHandFrame()), .swinging)
    XCTAssertEqual(detector.statusText, "กำลังบันทึก — หามือไม่พบชั่วคราว")
  }

  private func arm(_ detector: SwingSessionDetector) {
    detector.consume(frame(at: 0.00, x: 0.20, speed: 0.05))
    detector.consume(frame(at: 0.10, x: 0.20, speed: 0.05))
    XCTAssertEqual(detector.consume(frame(at: 0.20, x: 0.20, speed: 0.05)), .armed)
  }

  private func armAndStart(_ detector: SwingSessionDetector) {
    arm(detector)
    detector.consume(frame(at: 0.30, x: 0.25, speed: 1.00))
    XCTAssertEqual(detector.consume(frame(at: 0.36, x: 0.35, speed: 1.20)), .swinging)
  }

  private func frame(at seconds: Double, x: CGFloat, speed: Double?) -> SwingMotionFrame {
    let timestamp = time(seconds)
    let point = SwingMotionPoint(normalizedLocation: CGPoint(x: x, y: 0.50), timestamp: timestamp)
    return SwingMotionFrame(
      handCenter: point.normalizedLocation,
      pointHistory: [point],
      normalizedHandSpeed: speed,
      state: .tracking,
      timestamp: timestamp,
      diagnosticText: "เฟรมทดสอบ"
    )
  }

  private func missingHandFrame(at seconds: Double) -> SwingMotionFrame {
    SwingMotionFrame(
      handCenter: nil,
      pointHistory: [],
      normalizedHandSpeed: nil,
      state: .unavailable,
      timestamp: time(seconds),
      diagnosticText: "ไม่พบมือ"
    )
  }

  private func untimestampedMissingHandFrame() -> SwingMotionFrame {
    SwingMotionFrame(
      handCenter: nil,
      pointHistory: [],
      normalizedHandSpeed: nil,
      state: .unavailable,
      timestamp: nil,
      diagnosticText: "ไม่พบมือ"
    )
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000)
  }
}
