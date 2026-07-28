import CoreMedia
import Foundation
import Vision
import XCTest

@testable import GolfTrace

final class MotionAnalysisContractsTests: XCTestCase {
  func testCanonicalPhasesHaveStableChronologicalOrder() {
    XCTAssertEqual(
      GolfSwingPhase.allCases,
      [
        .address,
        .takeaway,
        .p2,
        .p3,
        .top,
        .transition,
        .p6,
        .impact,
        .release,
        .finish,
      ]
    )
    XCTAssertEqual(GolfSwingPhase.allCases.map(\.chronologicalIndex), Array(0..<10))
  }

  func testCameraAndMetricIdentifiersRemainOpenForFutureImplementations() throws {
    let customView = MotionCameraViewpoint(rawValue: "overhead")
    let customMetric = MotionMetricID(rawValue: "lead_wrist_flexion")

    XCTAssertEqual(try roundTrip(customView), customView)
    XCTAssertEqual(try roundTrip(customMetric), customMetric)
    XCTAssertNotEqual(customView, .faceOn)
    XCTAssertNotEqual(customMetric, .shoulderTurn)
  }

  func testResultKeepsMetricsAccessibleByPhase() {
    let source = MotionCameraSourceID(rawValue: "iphone-17-pro")
    let topShoulderTurn = MotionMetricReading(
      metricID: .shoulderTurn,
      value: 82,
      unit: .degrees,
      phase: .top,
      sourceID: source,
      viewpoint: .downTheLine,
      timeRange: MotionTimeRange(startSeconds: 1.1, endSeconds: 1.2),
      provenance: .derived2D,
      confidence: 0.84,
      limitations: ["Projected 2D proxy; not a 3D torso rotation."]
    )
    let impactSway = MotionMetricReading(
      metricID: .sway,
      value: 0.12,
      unit: .normalizedBodyLength,
      phase: .impact,
      sourceID: source,
      viewpoint: .downTheLine,
      timeRange: MotionTimeRange(startSeconds: 1.6, endSeconds: 1.7),
      provenance: .derived2D,
      confidence: 0.72
    )
    let result = MotionAnalysisResult(
      swingID: UUID(),
      skeletonFrames: [],
      phaseObservations: [],
      metrics: [topShoulderTurn, impactSway]
    )

    XCTAssertEqual(result.metrics(for: .top), [topShoulderTurn])
    XCTAssertEqual(result.metric(.sway, at: .impact), impactSway)
    XCTAssertNil(result.metric(.earlyExtension, at: .impact))
    XCTAssertTrue(result.metrics(for: .p6).isEmpty)
  }

  func testSkeletonFramesKeepIndependentCameraProvenance() throws {
    let swingID = UUID()
    let sessionID = UUID()
    let faceOnFrame = frame(
      sourceID: "face-on-phone",
      sessionID: sessionID,
      viewpoint: .faceOn,
      time: 0.5
    )
    let downTheLineFrame = frame(
      sourceID: "dtl-phone",
      sessionID: UUID(),
      viewpoint: .downTheLine,
      time: 0.48
    )
    let result = MotionAnalysisResult(
      swingID: swingID,
      skeletonFrames: [faceOnFrame, downTheLineFrame],
      phaseObservations: [],
      metrics: []
    )

    let decoded = try roundTrip(result)
    XCTAssertEqual(decoded.skeletonFrames.count, 2)
    XCTAssertEqual(decoded.skeletonFrames[0].context.sourceID.rawValue, "face-on-phone")
    XCTAssertEqual(decoded.skeletonFrames[1].context.sourceID.rawValue, "dtl-phone")
    XCTAssertNotEqual(
      decoded.skeletonFrames[0].context.streamSessionID,
      decoded.skeletonFrames[1].context.streamSessionID
    )
  }

  func testCanonicalVocabularyDoesNotFabricateUnobservedPhases() {
    let result = MotionAnalysisResult(
      swingID: UUID(),
      skeletonFrames: [],
      phaseObservations: [],
      metrics: []
    )

    XCTAssertTrue(result.phaseObservations.isEmpty)
    XCTAssertEqual(GolfSwingPhase.allCases.count, 10)
  }

  func testUnavailableMetricRetainsReasonWithoutFabricatingValue() throws {
    let reading = MotionMetricReading(
      metricID: .xFactor,
      value: nil,
      unit: .degrees,
      phase: .top,
      sourceID: MotionCameraSourceID(rawValue: "single-camera"),
      viewpoint: .faceOn,
      timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
      provenance: .derived2D,
      availability: .unavailable,
      confidence: 0,
      unavailableReason: "Calibrated 3D or validated multi-view evidence is required."
    )

    let decoded = try roundTrip(reading)
    XCTAssertNil(decoded.value)
    XCTAssertEqual(decoded.availability, .unavailable)
    XCTAssertNotNil(decoded.unavailableReason)
  }

  func testAppleVisionAdapterStopsVisionNamesAtBoundary() {
    let pose = PoseFrame(
      joints: [
        .leftShoulder: PoseJoint(
          id: "vision-left-shoulder",
          location: CGPoint(x: 0.25, y: 0.75),
          confidence: 0.9
        )
      ],
      timestamp: CMTime(seconds: 0.5, preferredTimescale: 600)
    )
    let context = MotionFrameContext(
      sourceID: MotionCameraSourceID(rawValue: "camera-a"),
      streamSessionID: UUID(),
      viewpoint: .faceOn,
      sourceTimeSeconds: 0.5,
      coordinateSpace: .normalizedImage2D,
      rotationDegrees: 0,
      isMirrored: false
    )

    let skeleton = AppleVisionMotionSkeletonAdapter().skeleton(from: pose, context: context)
    let shoulder = skeleton.joints[MotionJointID(rawValue: "left_shoulder")]

    XCTAssertEqual(shoulder?.position.x, 0.25)
    XCTAssertEqual(shoulder?.position.y, 0.75)
    XCTAssertEqual(shoulder?.confidence ?? 0, 0.9, accuracy: 0.000_001)
    XCTAssertEqual(skeleton.context.sourceID.rawValue, "camera-a")
  }

  private func frame(
    sourceID: String,
    sessionID: UUID,
    viewpoint: MotionCameraViewpoint,
    time: Double
  ) -> MotionSkeletonFrame {
    MotionSkeletonFrame(
      context: MotionFrameContext(
        sourceID: MotionCameraSourceID(rawValue: sourceID),
        streamSessionID: sessionID,
        viewpoint: viewpoint,
        sourceTimeSeconds: time,
        coordinateSpace: .normalizedImage2D,
        rotationDegrees: 0,
        isMirrored: false
      ),
      joints: [
        MotionJointID(rawValue: "left_shoulder"): MotionJointSample(
          position: MotionPoint(x: 0.4, y: 0.7),
          confidence: 0.9
        )
      ]
    )
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
  }
}
