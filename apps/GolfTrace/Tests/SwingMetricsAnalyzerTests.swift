import CoreMedia
import Vision
import XCTest

@testable import GolfTrace

final class SwingMetricsAnalyzerTests: XCTestCase {
  func testBodyNormalizedMotionIsInvariantToScaleAndTranslation() throws {
    let original = analyzeStandardSwing(scale: 1, translation: .zero)
    let transformed = analyzeStandardSwing(
      scale: 0.55,
      translation: CGPoint(x: 0.18, y: 0.12)
    )

    XCTAssertEqual(
      try XCTUnwrap(original.handPathBodyLengths.value),
      try XCTUnwrap(transformed.handPathBodyLengths.value),
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      try XCTUnwrap(original.peakHandSpeedBodyLengthsPerSecond.value),
      try XCTUnwrap(transformed.peakHandSpeedBodyLengthsPerSecond.value),
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      try XCTUnwrap(original.addressTorsoTiltDegrees.value),
      try XCTUnwrap(transformed.addressTorsoTiltDegrees.value),
      accuracy: 0.000_001
    )
  }

  func testLowConfidenceJointsDoNotProduceGuessedMetrics() {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.6, by: 0.1).map { $0 }
    let points = feed(
      analyzer,
      times: times,
      confidence: 0.54,
      handPosition: { CGPoint(x: 0.4 + 0.12 * $0, y: 0.5) }
    )

    let summary = analyzer.finalize(
      session: session(
        start: 0.6, end: 1.6,
        points: points.filter {
          seconds($0.timestamp) >= 0.6
        })
    )

    XCTAssertEqual(summary.quality, .unavailable)
    XCTAssertEqual(summary.trackedFraction, 0)
    XCTAssertNil(summary.handPathBodyLengths.value)
    XCTAssertNil(summary.peakHandSpeedBodyLengthsPerSecond.value)
    XCTAssertNil(summary.addressTorsoTiltDegrees.value)
    XCTAssertNil(summary.torsoTiltChangeDegrees.value)
    XCTAssertNil(summary.shoulderSpanReductionPercent.value)
    XCTAssertNil(summary.hipSpanReductionPercent.value)
    XCTAssertTrue(summary.reason.contains("55%"))
  }

  func testProjectedSpanReductionUsesRobustBaseline() throws {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.6, by: 0.1).map { $0 }
    let points = feed(
      analyzer,
      times: times,
      poseGeometry: { time in
        if time < 0.6 {
          return Geometry(shoulderSpan: 0.30, hipSpan: 0.22, torsoTiltDegrees: 0)
        }
        let progress = min(1, max(0, (time - 0.6) / 0.5))
        return Geometry(
          shoulderSpan: 0.30 - 0.15 * progress,
          hipSpan: 0.22 - 0.09 * progress,
          torsoTiltDegrees: 0
        )
      },
      handPosition: { CGPoint(x: 0.42 + 0.12 * $0, y: 0.48) }
    )
    let result = analyzer.finalize(
      session: session(start: 0.6, end: 1.6, points: swingPoints(points, start: 0.6))
    )

    XCTAssertGreaterThan(try XCTUnwrap(result.shoulderSpanReductionPercent.value), 40)
    XCTAssertGreaterThan(try XCTUnwrap(result.hipSpanReductionPercent.value), 30)
    XCTAssertEqual(result.shoulderSpanReductionPercent.quality, .good)
    XCTAssertTrue(result.shoulderSpanReductionPercent.reason.contains("สองมิติ"))
  }

  func testProjectedTorsoTiltAndChangeAreMeasuredRelativeToAddress() throws {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.6, by: 0.1).map { $0 }
    let points = feed(
      analyzer,
      times: times,
      poseGeometry: { time in
        Geometry(
          shoulderSpan: 0.30,
          hipSpan: 0.22,
          torsoTiltDegrees: time < 0.6 ? 10 : 25
        )
      },
      handPosition: { CGPoint(x: 0.42 + 0.10 * $0, y: 0.48) }
    )
    let result = analyzer.finalize(
      session: session(start: 0.6, end: 1.6, points: swingPoints(points, start: 0.6))
    )

    XCTAssertEqual(try XCTUnwrap(result.addressTorsoTiltDegrees.value), 10, accuracy: 0.01)
    XCTAssertEqual(try XCTUnwrap(result.torsoTiltChangeDegrees.value), 15, accuracy: 0.01)
  }

  func testTempoIsUnavailableWhenHandPathHasNoClearTransition() {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.8, by: 0.1).map { $0 }
    let points = feed(
      analyzer,
      times: times,
      handPosition: { time in
        CGPoint(x: 0.35 + 0.18 * time, y: 0.48 + 0.02 * time)
      }
    )
    let result = analyzer.finalize(
      session: session(start: 0.6, end: 1.8, points: swingPoints(points, start: 0.6))
    )

    XCTAssertNil(result.backswingSeconds.value)
    XCTAssertNil(result.downswingSeconds.value)
    XCTAssertNil(result.handTempoRatio.value)
    XCTAssertEqual(result.handTempoRatio.quality, .unavailable)
    XCTAssertTrue(result.handTempoRatio.reason.contains("จุดเปลี่ยน"))
  }

  func testClearHandTransitionProducesApproximateTempo() throws {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.8, by: 0.1).map { $0 }
    let handX: [Double] = [
      0.40, 0.40, 0.40, 0.40, 0.40, 0.40,
      0.40, 0.44, 0.49, 0.55, 0.62, 0.70, 0.76,
      0.70, 0.61, 0.52, 0.45, 0.41, 0.40,
    ]
    let points = feed(
      analyzer,
      times: times,
      handPosition: { time in
        let index = Int((time * 10).rounded())
        return CGPoint(x: handX[index], y: 0.48)
      }
    )
    let result = analyzer.finalize(
      session: session(start: 0.6, end: 1.8, points: swingPoints(points, start: 0.6))
    )

    XCTAssertNotNil(result.backswingSeconds.value)
    XCTAssertNotNil(result.downswingSeconds.value)
    XCTAssertGreaterThan(try XCTUnwrap(result.handTempoRatio.value), 0.5)
    XCTAssertTrue(result.handTempoRatio.reason.contains("ประมาณ"))
  }

  func testReturnedToStillnessAddsEvidenceBackedFinishMarker() throws {
    let packet = evidencePacket(completionReason: .returnedToStillness)
    let finish = try XCTUnwrap(
      packet.phases.first { $0.id == "finish_returned_to_stillness" }
    )

    XCTAssertEqual(finish.tMs, packet.durationMs)
    XCTAssertEqual(finish.sourceType, .macDerived2D)
    XCTAssertTrue(finish.limitation?.contains("กลับมานิ่ง") == true)
  }

  func testTimedOutSessionDoesNotFabricateFinishMarker() {
    let packet = evidencePacket(completionReason: .timedOut)

    XCTAssertFalse(packet.phases.contains { $0.id == "finish_returned_to_stillness" })
  }

  func testRollingWindowKeepsOnlyLatestSixSeconds() {
    let analyzer = SwingMetricsAnalyzer(maximumHistoryDuration: 6)
    let times = stride(from: 0.0, through: 10.0, by: 1.0).map { $0 }
    _ = feed(
      analyzer,
      times: times,
      handPosition: { CGPoint(x: 0.4 + 0.01 * $0, y: 0.48) }
    )

    // Inclusive cutoff keeps samples at 4, 5, ... 10 seconds.
    XCTAssertEqual(analyzer.bufferedFrameCount, 7)
  }

  private struct Geometry {
    var shoulderSpan = 0.30
    var hipSpan = 0.22
    var torsoTiltDegrees = 0.0
  }

  private func analyzeStandardSwing(
    scale: CGFloat,
    translation: CGPoint
  ) -> SwingAnalysisSummary {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.6, by: 0.1).map { $0 }
    let localHandX: [Double] = [
      0.40, 0.40, 0.40, 0.40, 0.40, 0.40,
      0.40, 0.45, 0.52, 0.60, 0.69, 0.76,
      0.67, 0.57, 0.49, 0.43, 0.40,
    ]
    let points = feed(
      analyzer,
      times: times,
      scale: scale,
      translation: translation,
      handPosition: { time in
        let index = Int((time * 10).rounded())
        return CGPoint(x: localHandX[index], y: 0.48)
      }
    )
    return analyzer.finalize(
      session: session(start: 0.6, end: 1.6, points: swingPoints(points, start: 0.6))
    )
  }

  private func evidencePacket(
    completionReason: SwingSessionCompletionReason
  ) -> SwingEvidencePacket {
    let analyzer = SwingMetricsAnalyzer()
    let times = stride(from: 0.0, through: 1.8, by: 0.1).map { $0 }
    let points = feed(
      analyzer,
      times: times,
      handPosition: { time in
        let progress = max(0, min(1, (time - 0.6) / 1.2))
        let excursion = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
        return CGPoint(x: 0.40 + 0.30 * excursion, y: 0.48)
      }
    )
    let swingPoints = swingPoints(points, start: 0.6)
    let session = SwingSessionSummary(
      duration: 1.2,
      peakNormalizedHandSpeed: 1,
      pathLength: 1,
      sampleCount: swingPoints.count,
      pointHistory: swingPoints,
      completionReason: completionReason,
      startTimestamp: cmTime(0.6),
      endTimestamp: cmTime(1.8)
    )
    return analyzer.finalizeWithEvidence(
      session: session,
      captureFPS: 120,
      poseAnalysisFPS: 30,
      cameraView: "downTheLine"
    ).evidencePacket
  }

  @discardableResult
  private func feed(
    _ analyzer: SwingMetricsAnalyzer,
    times: [Double],
    scale: CGFloat = 1,
    translation: CGPoint = .zero,
    confidence: Float = 0.90,
    poseGeometry: (Double) -> Geometry = { _ in Geometry() },
    handPosition: (Double) -> CGPoint
  ) -> [SwingMotionPoint] {
    var result: [SwingMotionPoint] = []
    var previousPoint: CGPoint?
    var previousTime: Double?

    for time in times {
      let localHand = handPosition(time)
      let hand = transform(localHand, scale: scale, translation: translation)
      let timestamp = cmTime(time)
      let speed: Double?
      if let previousPoint, let previousTime {
        speed = distance(previousPoint, hand) / (time - previousTime)
      } else {
        speed = nil
      }
      let point = SwingMotionPoint(normalizedLocation: hand, timestamp: timestamp)
      result.append(point)
      let motion = SwingMotionFrame(
        handCenter: hand,
        pointHistory: [point],
        normalizedHandSpeed: speed,
        state: .tracking,
        timestamp: timestamp,
        diagnosticText: "เฟรมทดสอบ"
      )
      let pose = pose(
        at: time,
        geometry: poseGeometry(time),
        scale: scale,
        translation: translation,
        confidence: confidence
      )
      analyzer.consume(pose: pose, motion: motion)
      previousPoint = hand
      previousTime = time
    }
    return result
  }

  private func pose(
    at time: Double,
    geometry: Geometry,
    scale: CGFloat,
    translation: CGPoint,
    confidence: Float
  ) -> PoseFrame {
    let angle = geometry.torsoTiltDegrees * .pi / 180
    let hipCenter = CGPoint(x: 0.50, y: 0.38)
    let shoulderCenter = CGPoint(
      x: Double(hipCenter.x) + sin(angle) * 0.30,
      y: Double(hipCenter.y) + cos(angle) * 0.30
    )
    let localJoints: [(VNHumanBodyPoseObservation.JointName, CGPoint)] = [
      (
        .leftShoulder,
        CGPoint(x: shoulderCenter.x - geometry.shoulderSpan / 2, y: shoulderCenter.y)
      ),
      (
        .rightShoulder,
        CGPoint(x: shoulderCenter.x + geometry.shoulderSpan / 2, y: shoulderCenter.y)
      ),
      (.leftHip, CGPoint(x: hipCenter.x - geometry.hipSpan / 2, y: hipCenter.y)),
      (.rightHip, CGPoint(x: hipCenter.x + geometry.hipSpan / 2, y: hipCenter.y)),
    ]
    let joints = Dictionary(
      uniqueKeysWithValues: localJoints.map { name, point in
        (
          name,
          PoseJoint(
            id: String(describing: name),
            location: transform(point, scale: scale, translation: translation),
            confidence: confidence
          )
        )
      })
    return PoseFrame(joints: joints, timestamp: cmTime(time))
  }

  private func session(
    start: Double,
    end: Double,
    points: [SwingMotionPoint]
  ) -> SwingSessionSummary {
    SwingSessionSummary(
      duration: end - start,
      peakNormalizedHandSpeed: 1,
      pathLength: 1,
      sampleCount: points.count,
      pointHistory: points,
      completionReason: .returnedToStillness,
      startTimestamp: cmTime(start),
      endTimestamp: cmTime(end)
    )
  }

  private func swingPoints(
    _ points: [SwingMotionPoint],
    start: Double
  ) -> [SwingMotionPoint] {
    points.filter { seconds($0.timestamp) >= start }
  }

  private func transform(
    _ point: CGPoint,
    scale: CGFloat,
    translation: CGPoint
  ) -> CGPoint {
    CGPoint(
      x: translation.x + point.x * scale,
      y: translation.y + point.y * scale
    )
  }

  private func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
    let x = Double(second.x - first.x)
    let y = Double(second.y - first.y)
    return (x * x + y * y).squareRoot()
  }

  private func cmTime(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000)
  }

  private func seconds(_ timestamp: CMTime) -> Double {
    CMTimeGetSeconds(timestamp)
  }
}
