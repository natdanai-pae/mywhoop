import CoreMedia
import Foundation
import XCTest

@testable import GolfTrace

final class CameraStoryboardArtifactExporterTests: XCTestCase {
  func testAssetTimestampUsesExactCompressedSegmentStartOffset() throws {
    let mapped = try XCTUnwrap(
      CameraStoryboardArtifactExporter.assetTimestamp(
        sourceTimestampMs: 420,
        swingStart: CMTime(seconds: 9.75, preferredTimescale: 1_000_000),
        segmentStart: CMTime(seconds: 9, preferredTimescale: 1_000_000)
      )
    )

    XCTAssertEqual(CMTimeGetSeconds(mapped), 1.17, accuracy: 0.000_001)
    XCTAssertNil(
      CameraStoryboardArtifactExporter.assetTimestamp(
        sourceTimestampMs: -1,
        swingStart: CMTime(seconds: 9.75, preferredTimescale: 1_000_000),
        segmentStart: CMTime(seconds: 9, preferredTimescale: 1_000_000)
      )
    )
  }

  func testExporterWritesJPEGForEveryRequestedMarkerAndRemovesTemporaryMovie() async throws {
    let segment = try makePlayableSegment()
    let markers = [
      marker(.address, timestampMs: 0),
      marker(.top, timestampMs: 16),
    ]

    let result = try await withCheckedThrowingContinuation { continuation in
      CameraStoryboardArtifactExporter.export(
        segment: segment,
        swingStart: segment.startTimestamp,
        phaseMarkers: markers,
        rotationDegrees: 90
      ) { result in
        continuation.resume(with: result)
      }
    }
    defer { result.removeTemporaryFiles() }

    XCTAssertEqual(result.keyframes.map(\.slot), [.address, .top])
    XCTAssertEqual(result.keyframes.map(\.state), [.available, .available])
    XCTAssertEqual(result.swingStartOffsetMs, 0)
    XCTAssertEqual(result.rotationDegrees, 90)
    XCTAssertEqual(result.sourceID, SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID)
    XCTAssertEqual(result.captureOrientation, .degrees90)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: result.temporaryDirectoryURL.appendingPathComponent("camera-segment.mov").path
      )
    )

    for keyframe in result.keyframes {
      let url = try XCTUnwrap(keyframe.temporaryJPEGURL)
      let data = try Data(contentsOf: url)
      XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
      XCTAssertGreaterThan(keyframe.pixelWidth ?? 0, 0)
      XCTAssertGreaterThan(keyframe.pixelHeight ?? 0, 0)
      XCTAssertEqual(keyframe.byteCount, data.count)
      XCTAssertEqual(keyframe.contentSHA256?.count, 64)
      XCTAssertNotNil(keyframe.extractedSourceTimestampMs)
    }
  }

  func testMarkerOutsideSnapshottedSegmentIsUnavailableWithoutFakeJPEG() async throws {
    let segment = try makePlayableSegment()
    let marker = marker(.finish, timestampMs: 2_000)

    let result = try await withCheckedThrowingContinuation { continuation in
      CameraStoryboardArtifactExporter.export(
        segment: segment,
        swingStart: segment.startTimestamp,
        phaseMarkers: [marker],
        rotationDegrees: 0
      ) { result in
        continuation.resume(with: result)
      }
    }
    defer { result.removeTemporaryFiles() }

    let keyframe = try XCTUnwrap(result.keyframes.first)
    XCTAssertEqual(keyframe.state, .unavailable)
    XCTAssertNil(keyframe.temporaryJPEGURL)
    XCTAssertTrue(keyframe.limitation?.contains("นอกช่วง") == true)
  }

  private func marker(
    _ slot: SwingStoryboardPhaseSlot,
    timestampMs: Int
  ) -> SwingStoryboardPhaseMarker {
    SwingStoryboardPhaseMarker(
      slot: slot,
      sourceTimestampMs: timestampMs,
      replayTimestampMs: nil,
      provenance: SwingStoryboardPhaseProvenance(
        evidenceMarkerID: slot.rawValue,
        sourceType: .macVision2D
      ),
      confidence: 0.9,
      limitation: nil
    )
  }

  private func makePlayableSegment() throws -> H264ReplaySegment {
    let configuration = GolfTraceH264Configuration(
      sequenceParameterSet: try XCTUnwrap(
        Data(base64Encoded: "Z2QQDay4KD9gIgAAAwACAAADAHgI")
      ),
      pictureParameterSet: try XCTUnwrap(
        Data(base64Encoded: "aO4PLIs=")
      )
    )
    let payloads = try [
      "AAAAQmWIhAS//ujJ/MsrL+PUN7NGKbNJpxzCPR0w6vUco+Q2jEXlEQwABgIooSPDbIiL1TsDkAAAImD/ji2UyWbxYSTmcQ==",
      "AAAAQmWIggEf/ufj/AprKxHEv01QKM3ptdyoujXh1cYhTyC6Mxkf19QAF7xKsX1bfTg8l/gUUAABCgiEzWymSzeLCSczgA==",
    ].map { try XCTUnwrap(Data(base64Encoded: $0)) }
    let start = CMTime(seconds: 10, preferredTimescale: 1_000_000)
    return H264ReplaySegment(
      configuration: configuration,
      frames: payloads.enumerated().map { index, payload in
        H264ReplayFrame(
          timestamp: start + CMTime(value: CMTimeValue(index), timescale: 30),
          payload: payload,
          isKeyFrame: true
        )
      }
    )
  }
}
