import CoreMedia
import Foundation
import Vision
import XCTest

@testable import GolfTrace

final class SwingEvidencePacketTests: XCTestCase {
  func testPacketIsBoundedTimestampedAndSeparatesCaptureFromPoseFPS() throws {
    let result = makeResult(frameInterval: 0.02)
    let packet = result.evidencePacket

    XCTAssertEqual(packet.schema, SwingEvidencePacket.schemaVersion)
    XCTAssertEqual(packet.captureFPS, 120)
    XCTAssertNotEqual(packet.captureFPS, packet.poseAnalysisFPS)
    XCTAssertLessThanOrEqual(packet.timeline.count, SwingEvidencePacket.maximumTimelineFrames)
    XCTAssertEqual(packet.sentTimelineFrameCount, packet.timeline.count)
    XCTAssertGreaterThan(packet.analyzedPoseFrameCount, packet.timeline.count)
    XCTAssertLessThan(packet.timeline.first?.tMs ?? 0, 0, "ต้องมี context ของท่า address")
    XCTAssertTrue(zip(packet.timeline, packet.timeline.dropFirst()).allSatisfy { $0.tMs < $1.tMs })
    XCTAssertTrue(
      packet.validationIssues().isEmpty, packet.validationIssues().joined(separator: ","))
  }

  func testPacketNeverRelabelsHandCenterAsClubHead() throws {
    let packet = makeResult(frameInterval: 0.04).evidencePacket
    let hand = try XCTUnwrap(packet.capabilities.first { $0.id == "hand_center_path_2d" })
    let club = try XCTUnwrap(packet.capabilities.first { $0.id == "club_head_path_2d" })

    XCTAssertEqual(hand.sourceType, .macDerived2D)
    XCTAssertEqual(hand.availability, .available)
    XCTAssertEqual(club.availability, .unavailable)
    XCTAssertNil(club.sourceType)
    XCTAssertTrue(club.limitation.contains("ไม่สร้างหรือเดา"))
  }

  func testPacketJSONContainsExtractedFeaturesWithoutPixelsOrFilePaths() throws {
    let packet = makeResult(frameInterval: 0.04).evidencePacket
    let data = try JSONEncoder().encode(packet)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertLessThan(data.count, 80_000)
    XCTAssertTrue(text.contains("mac_vision_2d"))
    XCTAssertTrue(text.contains("poseAnalysisFPS"))
    XCTAssertTrue(text.contains("tMs"))
    XCTAssertFalse(text.lowercased().contains("base64"))
    XCTAssertFalse(text.contains("file://"))
    XCTAssertFalse(text.contains("/Users/"))
    XCTAssertTrue(packet.auditFrameRequests.allSatisfy { $0.imageContentID == nil })
  }

  func testCoachContextSendsNumericRowsInsteadOfVerboseTimelineObjects() throws {
    let result = makeResult(frameInterval: 0.04)
    let context = GolfCoachRequestContext.make(
      question: "วงนี้ควรแก้อะไร",
      settings: .default,
      summary: nil,
      analysis: nil,
      evidencePacket: result.evidencePacket,
      launch: nil
    )
    let data = try JSONEncoder().encode(context)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    let numeric = try XCTUnwrap(context.swingEvidenceNumeric)

    XCTAssertEqual(numeric.frameRows.count, result.evidencePacket.timeline.count)
    XCTAssertTrue(text.contains("swingEvidenceNumeric"))
    XCTAssertTrue(text.contains("frameRows"))
    XCTAssertFalse(text.contains("swingEvidencePacket"))
    XCTAssertFalse(text.contains("\"timeline\""))
    XCTAssertFalse(text.contains("ยังไม่มีตัวตรวจหัวไม้บน Mac"))
  }

  func testCoachContextSendsRapsodoAsOneNumericRow() throws {
    let launch = LaunchMonitorShot(
      receivedAt: Date(timeIntervalSince1970: 1_750_000_000.125),
      deviceShotID: 42,
      clubHeadSpeedMetersPerSecond: 45,
      ballSpeedMetersPerSecond: 67,
      horizontalLaunchAngleDegrees: -1.5,
      verticalLaunchAngleDegrees: 12.4,
      spinAxisDegrees: 3.2,
      totalSpinRPM: 2_450,
      rawMeasurement: Data([0x01, 0x02])
    )
    let context = GolfCoachRequestContext.make(
      question: "ลูกนี้เป็นอย่างไร",
      settings: .default,
      summary: nil,
      analysis: nil,
      launch: launch
    )

    let data = try JSONEncoder().encode(context)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let numeric = try XCTUnwrap(object["launchNumeric"] as? [String: Any])
    let row = try XCTUnwrap(numeric["valueRow"] as? [Any])

    XCTAssertNil(object["launch"])
    XCTAssertNil(object["evidence"])
    XCTAssertEqual(numeric["sourceCode"] as? Int, 3)
    XCTAssertEqual(numeric["availabilityCode"] as? Int, 2)
    XCTAssertEqual(row.count, GolfCoachLaunchNumericPacket.valueOrder.count)
    XCTAssertEqual(try XCTUnwrap(row[0] as? Double), 45, accuracy: 0.000_1)
    XCTAssertEqual(try XCTUnwrap(row[5] as? Double), 2_450, accuracy: 0.000_1)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("rawMeasurement"))
    XCTAssertFalse(text.contains("MLM2PRO-BLE"))
    XCTAssertFalse(text.contains("mph"))
  }

  func testValidatorRejectsOutOfOrderTimelineBeforeModelCall() {
    let valid = makeResult(frameInterval: 0.04).evidencePacket
    let invalid = SwingEvidencePacket(
      schema: valid.schema,
      coordinateSpace: valid.coordinateSpace,
      contextStartMs: valid.contextStartMs,
      durationMs: valid.durationMs,
      cameraView: valid.cameraView,
      captureFPS: valid.captureFPS,
      poseAnalysisFPS: valid.poseAnalysisFPS,
      analyzedPoseFrameCount: valid.analyzedPoseFrameCount,
      sentTimelineFrameCount: valid.sentTimelineFrameCount,
      timeline: Array(valid.timeline.reversed()),
      metrics: valid.metrics,
      phases: valid.phases,
      auditFrameRequests: valid.auditFrameRequests,
      capabilities: valid.capabilities,
      limitations: valid.limitations
    )

    XCTAssertTrue(invalid.validationIssues().contains("timeline_not_monotonic"))
  }

  private func makeResult(frameInterval: Double) -> SwingAnalysisResult {
    let analyzer = SwingMetricsAnalyzer()
    let start = 0.6
    let end = 1.8
    var handPoints: [SwingMotionPoint] = []
    var previousPoint: CGPoint?
    var previousTime: Double?

    for time in stride(from: 0.0, through: end, by: frameInterval) {
      let progress = max(0, min(1, (time - start) / (end - start)))
      let excursion = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
      let hand = CGPoint(x: 0.46 + 0.25 * excursion, y: 0.48 + 0.18 * excursion)
      let timestamp = CMTime(seconds: time, preferredTimescale: 10_000)
      let speed: Double?
      if let previousPoint, let previousTime {
        speed =
          hypot(Double(hand.x - previousPoint.x), Double(hand.y - previousPoint.y))
          / (time - previousTime)
      } else {
        speed = nil
      }
      let point = SwingMotionPoint(normalizedLocation: hand, timestamp: timestamp)
      if time >= start { handPoints.append(point) }
      analyzer.consume(
        pose: pose(at: timestamp, hand: hand),
        motion: SwingMotionFrame(
          handCenter: hand,
          pointHistory: [point],
          normalizedHandSpeed: speed,
          state: .tracking,
          timestamp: timestamp,
          diagnosticText: "test"
        )
      )
      previousPoint = hand
      previousTime = time
    }

    let session = SwingSessionSummary(
      duration: end - start,
      peakNormalizedHandSpeed: 1,
      pathLength: 1,
      sampleCount: handPoints.count,
      pointHistory: handPoints,
      completionReason: .returnedToStillness,
      startTimestamp: CMTime(seconds: start, preferredTimescale: 10_000),
      endTimestamp: CMTime(seconds: end, preferredTimescale: 10_000)
    )
    return analyzer.finalizeWithEvidence(
      session: session,
      captureFPS: 120,
      poseAnalysisFPS: 30,
      cameraView: "downTheLine"
    )
  }

  private func pose(at timestamp: CMTime, hand: CGPoint) -> PoseFrame {
    let locations: [(VNHumanBodyPoseObservation.JointName, CGPoint)] = [
      (.nose, CGPoint(x: 0.50, y: 0.88)),
      (.neck, CGPoint(x: 0.50, y: 0.78)),
      (.leftShoulder, CGPoint(x: 0.38, y: 0.70)),
      (.rightShoulder, CGPoint(x: 0.62, y: 0.70)),
      (.leftElbow, CGPoint(x: 0.42, y: 0.60)),
      (.rightElbow, CGPoint(x: 0.58, y: 0.60)),
      (.leftWrist, CGPoint(x: hand.x - 0.015, y: hand.y)),
      (.rightWrist, CGPoint(x: hand.x + 0.015, y: hand.y)),
      (.leftHip, CGPoint(x: 0.42, y: 0.40)),
      (.rightHip, CGPoint(x: 0.58, y: 0.40)),
      (.leftKnee, CGPoint(x: 0.43, y: 0.23)),
      (.rightKnee, CGPoint(x: 0.57, y: 0.23)),
      (.leftAnkle, CGPoint(x: 0.42, y: 0.08)),
      (.rightAnkle, CGPoint(x: 0.58, y: 0.08)),
    ]
    return PoseFrame(
      joints: Dictionary(
        uniqueKeysWithValues: locations.map { name, location in
          (name, PoseJoint(id: String(describing: name), location: location, confidence: 0.95))
        }),
      timestamp: timestamp
    )
  }
}
