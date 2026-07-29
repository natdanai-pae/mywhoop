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

  func testResultKeepsMetricsAccessibleByPhaseAndSource() throws {
    let source = MotionCameraSourceID(rawValue: "iphone-17-pro")
    let secondSource = MotionCameraSourceID(rawValue: "continuity-camera")
    let topShoulderTurn = try MotionMetricReading(
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
    let secondTopShoulderTurn = try MotionMetricReading(
      metricID: .shoulderTurn,
      value: 76,
      unit: .degrees,
      phase: .top,
      sourceID: secondSource,
      viewpoint: .faceOn,
      timeRange: MotionTimeRange(startSeconds: 1.08, endSeconds: 1.18),
      provenance: .derived2D,
      confidence: 0.8
    )
    let impactSway = try MotionMetricReading(
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
      metrics: [topShoulderTurn, secondTopShoulderTurn, impactSway]
    )

    XCTAssertEqual(result.metrics(for: .top), [topShoulderTurn, secondTopShoulderTurn])
    XCTAssertEqual(
      result.metrics(matching: .shoulderTurn, at: .top),
      [topShoulderTurn, secondTopShoulderTurn]
    )
    XCTAssertEqual(
      result.metric(
        .shoulderTurn,
        at: .top,
        from: source,
        viewpoint: .downTheLine
      ),
      topShoulderTurn
    )
    XCTAssertEqual(
      result.metric(
        .shoulderTurn,
        at: .top,
        from: secondSource,
        viewpoint: .faceOn
      ),
      secondTopShoulderTurn
    )
    XCTAssertEqual(
      result.metric(.sway, at: .impact, from: source, viewpoint: .downTheLine),
      impactSway
    )
    XCTAssertNil(
      result.metric(
        .earlyExtension,
        at: .impact,
        from: source,
        viewpoint: .downTheLine
      )
    )
    XCTAssertNil(
      result.metric(.shoulderTurn, at: .top, from: source, viewpoint: .faceOn)
    )
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
    let reading = try MotionMetricReading(
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

  func testMetricReadingRejectsInvalidConstructionStates() {
    assertValidationError(.nonFiniteValue) {
      try makeReading(value: .nan)
    }
    for range in [
      MotionTimeRange(startSeconds: -.infinity, endSeconds: 1),
      MotionTimeRange(startSeconds: -0.1, endSeconds: 1),
      MotionTimeRange(startSeconds: 2, endSeconds: 1),
      MotionTimeRange(startSeconds: 1, endSeconds: .infinity),
    ] {
      assertValidationError(.invalidTimeRange) {
        try makeReading(timeRange: range)
      }
    }
    for confidence in [Double.nan, -.infinity, -0.1, 1.1, .infinity] {
      assertValidationError(.invalidConfidence) {
        try makeReading(confidence: confidence)
      }
    }
    assertValidationError(.valueRequired) {
      try makeReading(value: nil)
    }
    assertValidationError(.valueRequired) {
      try makeReading(value: nil, availability: .limited)
    }
    assertValidationError(.unavailableReasonMustBeAbsent) {
      try makeReading(unavailableReason: "Contradictory reason")
    }
    assertValidationError(.unavailableReasonMustBeAbsent) {
      try makeReading(availability: .limited, unavailableReason: "Contradictory reason")
    }
    assertValidationError(.valueMustBeAbsent) {
      try makeReading(availability: .unavailable, unavailableReason: "No calibrated evidence.")
    }
    for reason in [
      nil,
      "",
      " \n\t ",
      String(repeating: "a", count: MotionMetricReading.maximumUnavailableReasonBytes + 1),
    ] {
      assertValidationError(.invalidUnavailableReason) {
        try makeReading(value: nil, availability: .unavailable, unavailableReason: reason)
      }
    }
  }

  func testMetricReadingAcceptsFiniteBoundaryStates() throws {
    let available = try makeReading(
      timeRange: MotionTimeRange(startSeconds: 0, endSeconds: 0),
      confidence: 0
    )
    let limited = try makeReading(availability: .limited, confidence: 1)
    let unavailable = try makeReading(
      value: nil,
      availability: .unavailable,
      confidence: 0,
      unavailableReason: String(
        repeating: "a",
        count: MotionMetricReading.maximumUnavailableReasonBytes
      )
    )

    XCTAssertEqual(available.timeRange, MotionTimeRange(startSeconds: 0, endSeconds: 0))
    XCTAssertEqual(limited.availability, .limited)
    XCTAssertNil(unavailable.value)
  }

  func testMetricReadingDecodingRejectsContradictoryAndInvalidPayloads() throws {
    let valid = try makeReading()
    let encoded = try JSONEncoder().encode(valid)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    var contradictory = object
    contradictory["availability"] = MotionMetricAvailability.unavailable.rawValue
    assertDecodingRejected(contradictory)

    var invalidConfidence = object
    invalidConfidence["confidence"] = 1.01
    assertDecodingRejected(invalidConfidence)

    var invalidTime = object
    var timeRange = try XCTUnwrap(invalidTime["timeRange"] as? [String: Any])
    timeRange["startSeconds"] = -0.01
    invalidTime["timeRange"] = timeRange
    assertDecodingRejected(invalidTime)

    var nonFinite = object
    nonFinite["value"] = "NaN"
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )
    assertDecodingRejected(nonFinite, decoder: decoder)
  }

  func testAppleVisionAdapterDerivesFrameMetadataAndStopsVisionNamesAtBoundary() throws {
    let pose = PoseFrame(
      joints: [
        .leftShoulder: PoseJoint(
          id: "vision-left-shoulder",
          location: CGPoint(x: 0.25, y: 0.75),
          confidence: 0.9
        )
      ],
      timestamp: CMTime(seconds: 0.5, preferredTimescale: 600),
      videoOrientation: .degrees270
    )
    let sourceContext = MotionFrameSourceContext(
      sourceID: MotionCameraSourceID(rawValue: "camera-a"),
      streamSessionID: UUID(),
      viewpoint: .faceOn,
      isMirrored: true
    )

    let skeleton = try AppleVisionMotionSkeletonAdapter().skeleton(
      from: pose,
      sourceContext: sourceContext
    )
    let shoulder = skeleton.joints[.leftShoulder]

    XCTAssertEqual(shoulder?.position.x, 0.25)
    XCTAssertEqual(shoulder?.position.y, 0.75)
    XCTAssertEqual(shoulder?.confidence ?? 0, 0.9, accuracy: 0.000_001)
    XCTAssertEqual(skeleton.context.sourceID.rawValue, "camera-a")
    XCTAssertEqual(skeleton.context.sourceTimeSeconds, 0.5, accuracy: 0.000_001)
    XCTAssertEqual(skeleton.context.coordinateSpace, .normalizedImage2D)
    XCTAssertEqual(skeleton.context.rotationDegrees, 270)
    XCTAssertTrue(skeleton.context.isMirrored)
  }

  func testAppleVisionAdapterRejectsInvalidFrameTime() {
    let pose = PoseFrame(joints: [:], timestamp: .invalid, videoOrientation: .degrees90)
    let sourceContext = MotionFrameSourceContext(
      sourceID: MotionCameraSourceID(rawValue: "camera-a"),
      streamSessionID: UUID(),
      viewpoint: .faceOn,
      isMirrored: false
    )

    XCTAssertThrowsError(
      try AppleVisionMotionSkeletonAdapter().skeleton(
        from: pose,
        sourceContext: sourceContext
      )
    ) { error in
      XCTAssertEqual(error as? AppleVisionMotionSkeletonAdapterError, .invalidTimestamp)
    }
  }

  func testAppleVisionAdapterUsesVersionedMapAndOmitsUnknownJoints() throws {
    let unknownName = VNHumanBodyPoseObservation.JointName(
      rawValue: VNRecognizedPointKey(rawValue: "future_joint")
    )
    let pose = PoseFrame(
      joints: [
        .leftShoulder: PoseJoint(
          id: "known",
          location: CGPoint(x: 0.25, y: 0.75),
          confidence: 0.9
        ),
        unknownName: PoseJoint(
          id: "unknown",
          location: CGPoint(x: 0.5, y: 0.5),
          confidence: 0.8
        ),
      ],
      timestamp: CMTime(seconds: 0.5, preferredTimescale: 600)
    )
    let adapter = AppleVisionMotionSkeletonAdapter(jointMappingVersion: .vision2DRevision1)

    let skeleton = try adapter.skeleton(
      from: pose,
      sourceContext: MotionFrameSourceContext(
        sourceID: MotionCameraSourceID(rawValue: "camera-a"),
        streamSessionID: UUID(),
        viewpoint: .downTheLine,
        isMirrored: false
      )
    )

    XCTAssertEqual(adapter.jointMappingVersion.rawValue, 1)
    XCTAssertEqual(skeleton.joints.count, 1)
    XCTAssertNotNil(skeleton.joints[.leftShoulder])
    XCTAssertNil(
      AppleVisionMotionSkeletonAdapter.jointID(
        for: unknownName,
        version: .vision2DRevision1
      )
    )
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

  private func makeReading(
    value: Double? = 1,
    timeRange: MotionTimeRange = MotionTimeRange(startSeconds: 1, endSeconds: 1),
    availability: MotionMetricAvailability = .available,
    confidence: Double = 0.8,
    unavailableReason: String? = nil
  ) throws -> MotionMetricReading {
    try MotionMetricReading(
      metricID: .shoulderTurn,
      value: value,
      unit: .degrees,
      phase: .top,
      sourceID: MotionCameraSourceID(rawValue: "test-camera"),
      viewpoint: .faceOn,
      timeRange: timeRange,
      provenance: .derived2D,
      availability: availability,
      confidence: confidence,
      unavailableReason: unavailableReason
    )
  }

  private func assertValidationError(
    _ expected: MotionMetricReadingValidationError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> MotionMetricReading
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      XCTAssertEqual(
        error as? MotionMetricReadingValidationError,
        expected,
        file: file,
        line: line
      )
    }
  }

  private func assertDecodingRejected(
    _ object: [String: Any],
    decoder: JSONDecoder = JSONDecoder(),
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let data = try JSONSerialization.data(withJSONObject: object)
      XCTAssertThrowsError(
        try decoder.decode(MotionMetricReading.self, from: data),
        file: file,
        line: line
      ) { error in
        guard case DecodingError.dataCorrupted = error else {
          return XCTFail("Expected dataCorrupted, got \(error)", file: file, line: line)
        }
      }
    } catch {
      XCTFail("Could not create JSON fixture: \(error)", file: file, line: line)
    }
  }
}
