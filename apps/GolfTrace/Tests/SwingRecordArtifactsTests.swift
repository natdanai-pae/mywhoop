import Foundation
import XCTest

@testable import GolfTrace

final class SwingRecordArtifactsTests: XCTestCase {
  func testCanonicalStoryboardHasEightOrderedSlots() {
    XCTAssertEqual(
      SwingStoryboardPhaseSlot.allCases,
      [
        .address, .takeaway, .backswing, .top,
        .downswing, .impact, .followThrough, .finish,
      ]
    )
  }

  func testArtifactsKeepOnlyEvidenceBackedCanonicalMarkersFromOneCapture() throws {
    let packet = makeEvidencePacket()
    let capture = SwingStoryboardCaptureSnapshot(
      sourceID: "iphone-17-pro.back-camera",
      cameraView: "downTheLine",
      orientation: .degrees90,
      encodedPixelWidth: 1920,
      encodedPixelHeight: 1080,
      captureFPS: 120
    )

    let artifacts = try XCTUnwrap(
      SwingRecordArtifacts(evidencePacket: packet, capture: capture)
    )

    XCTAssertEqual(artifacts.capture, capture)
    XCTAssertEqual(artifacts.phaseMarkers.map(\.slot), [.address, .top, .impact, .finish])
    XCTAssertEqual(artifacts.phaseMarkers.map(\.sourceTimestampMs), [0, 420, 610, 1_000])
    XCTAssertTrue(artifacts.phaseMarkers.allSatisfy { $0.replayTimestampMs == nil })
    XCTAssertEqual(
      artifacts.phaseMarkers.first { $0.slot == .top }?.provenance,
      SwingStoryboardPhaseProvenance(
        evidenceMarkerID: "top_estimated_from_hand_reversal",
        sourceType: .macDerived2D
      )
    )
    XCTAssertEqual(artifacts.keyframes.map(\.slot), [.address, .top, .impact, .finish])
    XCTAssertTrue(artifacts.keyframes.allSatisfy { $0.state == .pending })
    XCTAssertTrue(artifacts.validationIssues().isEmpty)
  }

  func testStoryboardAliasesMapWithoutCreatingDuplicateAnglesOrUnknownPhases() {
    XCTAssertEqual(SwingStoryboardPhaseSlot(evidenceMarkerID: "Half Backswing"), .backswing)
    XCTAssertEqual(SwingStoryboardPhaseSlot(evidenceMarkerID: "Impact Window"), .impact)
    XCTAssertEqual(SwingStoryboardPhaseSlot(evidenceMarkerID: "Extension"), .followThrough)
    XCTAssertNil(SwingStoryboardPhaseSlot(evidenceMarkerID: "camera two impact"))
  }

  func testCaptureOrientationAllowsOnlyExactWireRotationOrManualHalfTurn() {
    XCTAssertTrue(
      SwingStoryboardCaptureOrientation.degrees90
        .isSameOrManualHalfTurn(from: .degrees90)
    )
    XCTAssertTrue(
      SwingStoryboardCaptureOrientation.degrees270
        .isSameOrManualHalfTurn(from: .degrees90)
    )
    XCTAssertFalse(
      SwingStoryboardCaptureOrientation.degrees180
        .isSameOrManualHalfTurn(from: .degrees90)
    )
    XCTAssertFalse(
      SwingStoryboardCaptureOrientation.unknown
        .isSameOrManualHalfTurn(from: .degrees90)
    )
  }

  func testArtifactsRejectCaptureFromDifferentCameraAngle() {
    let packet = makeEvidencePacket(cameraView: "downTheLine")
    let mismatchedCapture = SwingStoryboardCaptureSnapshot(
      sourceID: "iphone-17-pro.back-camera",
      cameraView: "faceOn",
      orientation: .degrees0,
      encodedPixelWidth: 1280,
      encodedPixelHeight: 720,
      captureFPS: 60
    )

    XCTAssertNil(
      SwingRecordArtifacts(evidencePacket: packet, capture: mismatchedCapture)
    )
  }

  func testSchemaFourRecordRoundTripsArtifactsEvidenceAndReplayBundle() throws {
    let artifacts = try XCTUnwrap(
      SwingRecordArtifacts(
        evidencePacket: makeEvidencePacket(),
        capture: SwingStoryboardCaptureSnapshot(
          sourceID: "iphone-k.back-camera",
          cameraView: "downTheLine",
          orientation: .degrees270,
          encodedPixelWidth: 1920,
          encodedPixelHeight: 1080,
          captureFPS: 120
        )
      )
    )
    var record = makeRecord(
      schemaVersion: SwingRecord.currentSchemaVersion,
      artifacts: artifacts
    )
    record.replayFilename = "replay.mov"
    record.replayBundle = makeReplayBundle()

    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(SwingRecord.self, from: data)

    XCTAssertEqual(decoded, record)
    XCTAssertEqual(decoded.schemaVersion, SwingRecord.currentSchemaVersion)
    XCTAssertEqual(decoded.artifacts?.evidencePacket, makeEvidencePacket())
    XCTAssertEqual(decoded.artifacts?.capture.sourceID, "iphone-k.back-camera")
    XCTAssertEqual(decoded.replayFilename, "replay.mov")
    XCTAssertTrue(decoded.replayBundle?.isSynchronizedPair == true)
  }

  func testSchemaThreeRecordWithoutReplayBundleKeepsLegacyReplayFilename() throws {
    var legacyRecord = makeRecord(schemaVersion: 3, artifacts: nil)
    legacyRecord.replayFilename = "replay.mov"
    let encoded = try JSONEncoder().encode(legacyRecord)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "replayBundle")

    let decoded = try JSONDecoder().decode(
      SwingRecord.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.schemaVersion, 3)
    XCTAssertEqual(decoded.replayFilename, "replay.mov")
    XCTAssertNil(decoded.replayBundle)
  }

  func testSchemaTwoRecordWithoutArtifactsStillDecodes() throws {
    let legacyRecord = makeRecord(schemaVersion: 2, artifacts: nil)
    let encoded = try JSONEncoder().encode(legacyRecord)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "artifacts")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(SwingRecord.self, from: legacyData)

    XCTAssertEqual(decoded.schemaVersion, 2)
    XCTAssertNil(decoded.artifacts)
    XCTAssertEqual(decoded.id, legacyRecord.id)
    XCTAssertEqual(decoded.sessionSummary, legacyRecord.sessionSummary)
  }

  private func makeRecord(
    schemaVersion: Int,
    artifacts: SwingRecordArtifacts?
  ) -> SwingRecord {
    SwingRecord(
      schemaVersion: schemaVersion,
      id: UUID(uuidString: "55555555-6666-7777-8888-999999999999")!,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      sessionSummary: SwingRecord.SessionSummary(
        durationSeconds: 1,
        peakNormalizedHandSpeed: 2.5,
        normalizedPathLength: 0.8,
        sampleCount: 3,
        completionReason: "returnedToStillness",
        sourceStartTimestampSeconds: 10,
        sourceEndTimestampSeconds: 11
      ),
      tracePoints: [
        SwingRecord.TracePoint(
          normalizedX: 0.25,
          normalizedY: 0.75,
          timeOffsetSeconds: 0
        )
      ],
      artifacts: artifacts
    )
  }

  private func makeEvidencePacket(
    cameraView: String = "downTheLine"
  ) -> SwingEvidencePacket {
    SwingEvidencePacket(
      schema: SwingEvidencePacket.schemaVersion,
      coordinateSpace: "vision_normalized_xy_origin_lower_left",
      contextStartMs: -100,
      durationMs: 1_000,
      cameraView: cameraView,
      captureFPS: 120,
      poseAnalysisFPS: 30,
      analyzedPoseFrameCount: 30,
      sentTimelineFrameCount: 0,
      timeline: [],
      metrics: [],
      phases: [
        SwingEvidencePhaseMarker(
          id: "address",
          tMs: 0,
          sourceType: .macVision2D,
          confidence: 0.92,
          limitation: "session boundary"
        ),
        SwingEvidencePhaseMarker(
          id: "top_estimated_from_hand_reversal",
          tMs: 420,
          sourceType: .macDerived2D,
          confidence: 0.81,
          limitation: "estimated from hand reversal"
        ),
        SwingEvidencePhaseMarker(
          id: "impact_estimated_from_hand_return",
          tMs: 610,
          sourceType: .macDerived2D,
          confidence: 0.74,
          limitation: "camera impact is not confirmed"
        ),
        SwingEvidencePhaseMarker(
          id: "uncategorized_detector_event",
          tMs: 700,
          sourceType: .aiInferred,
          confidence: 0.99,
          limitation: "must not create a storyboard slot"
        ),
        SwingEvidencePhaseMarker(
          id: "finish_returned_to_stillness",
          tMs: 1_000,
          sourceType: .macDerived2D,
          confidence: 0.86,
          limitation: "session end"
        ),
      ],
      auditFrameRequests: [
        SwingAuditFrameRequest(
          role: "top_estimated_from_hand_reversal",
          requestedTMs: 420,
          nearestPoseTMs: 417,
          alignmentDeltaMs: 3,
          imageContentID: nil
        ),
        SwingAuditFrameRequest(
          role: "impact_estimated_from_hand_return",
          requestedTMs: 610,
          nearestPoseTMs: 600,
          alignmentDeltaMs: 10,
          imageContentID: nil
        ),
      ],
      capabilities: [],
      limitations: ["2D camera evidence only"]
    )
  }

  private func makeReplayBundle() -> SwingReplayBundle {
    let cameraClock = SwingReplayAssetClockCalibration(
      scaleToMonotonicClock: 1,
      monotonicClockOffsetSeconds: 100,
      uncertaintyMilliseconds: 4,
      sampleCount: 8,
      mediaRangeSeconds: 0...1
    )
    let rapsodoClock = SwingReplayAssetClockCalibration(
      scaleToMonotonicClock: 1,
      monotonicClockOffsetSeconds: 100.05,
      uncertaintyMilliseconds: 5,
      sampleCount: 8,
      mediaRangeSeconds: 0...1
    )
    return SwingReplayBundle(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      camera: SwingReplayAsset(
        role: .swingCamera,
        filename: "camera.mov",
        sourceKind: "iphone-high-speed-camera",
        contentSHA256: String(repeating: "a", count: 64),
        byteCount: 1_024,
        orientation: .degrees90,
        mediaRangeSeconds: 0...1
      ),
      rapsodo: SwingReplayAsset(
        role: .rapsodoScreen,
        filename: "rapsodo.mp4",
        sourceKind: "rapsodo-screen-capture",
        contentSHA256: String(repeating: "b", count: 64),
        byteCount: 2_048,
        orientation: .degrees0,
        mediaRangeSeconds: 0...1
      ),
      synchronization: SwingReplaySynchronization(
        cameraClock: cameraClock,
        rapsodoClock: rapsodoClock,
        timelineMonotonicRangeSeconds: 100.05...101,
        uncertaintyMilliseconds: 7
      )
    )
  }
}
