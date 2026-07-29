import Foundation
import XCTest

@testable import GolfTrace

final class MotionSkeletonSessionSlicerTests: XCTestCase {
  private let streamSessionID = UUID(uuidString: "9B26A9EF-9B0E-4283-96CD-181671A346C9")!
  private let sourceID = MotionCameraSourceID(rawValue: "iphone-17-pro")

  func testSelectsExactInclusiveRangeWithoutChangingFrameOrder() throws {
    let frames = [
      frame(time: 0, marker: 0),
      frame(time: 1, marker: 1),
      frame(time: 2, marker: 2),
      frame(time: 3, marker: 3),
      frame(time: 4, marker: 4),
    ]

    let slice = try availableSlice(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 3),
        provenance: provenance()
      )
    )

    XCTAssertEqual(slice.timeRange, MotionTimeRange(startSeconds: 1, endSeconds: 3))
    XCTAssertEqual(slice.provenance, provenance())
    XCTAssertEqual(slice.frames, Array(frames[1...3]))
    XCTAssertEqual(slice.frames.map(\.context.sourceTimeSeconds), [1, 2, 3])
    XCTAssertEqual(slice.frames.map(marker), [1, 2, 3])
  }

  func testMissingPartialBoundariesAbstainInsteadOfClampingOrInterpolating() {
    let frames = [
      frame(time: 1, marker: 1),
      frame(time: 2, marker: 2),
      frame(time: 3, marker: 3),
    ]

    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1.5, endSeconds: 3),
        provenance: provenance()
      ),
      .unavailable(.missingStartBoundary)
    )
    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 2.5),
        provenance: provenance()
      ),
      .unavailable(.missingEndBoundary)
    )
  }

  func testSelectedProvenanceMismatchOutranksMissingOldStartBoundary() {
    let replacementSessionID = UUID(uuidString: "44AF7484-3AE0-43FD-957A-2D3B2D46C69B")!
    let frames = [
      frame(time: 2, marker: 2, streamSessionID: replacementSessionID),
      frame(time: 3, marker: 3, streamSessionID: replacementSessionID),
    ]

    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 3),
        provenance: provenance()
      ),
      .unavailable(.streamSessionMismatch(frameIndex: 0))
    )
  }

  func testRejectsInvalidRequestedAndFrameTimes() {
    for timeRange in [
      MotionTimeRange(startSeconds: -.infinity, endSeconds: 1),
      MotionTimeRange(startSeconds: -0.1, endSeconds: 1),
      MotionTimeRange(startSeconds: 2, endSeconds: 1),
      MotionTimeRange(startSeconds: 1, endSeconds: .infinity),
      MotionTimeRange(startSeconds: .nan, endSeconds: 1),
    ] {
      XCTAssertEqual(
        MotionSkeletonSessionSlicer.slice(
          frames: [frame(time: 1, marker: 1)],
          timeRange: timeRange,
          provenance: provenance()
        ),
        .unavailable(.invalidTimeRange)
      )
    }

    for invalidTime in [Double.nan, -.infinity, -0.1, .infinity] {
      XCTAssertEqual(
        MotionSkeletonSessionSlicer.slice(
          frames: [
            frame(time: 0, marker: 0),
            frame(time: invalidTime, marker: 1),
            frame(time: 2, marker: 2),
          ],
          timeRange: MotionTimeRange(startSeconds: 0, endSeconds: 2),
          provenance: provenance()
        ),
        .unavailable(.invalidFrameTime(frameIndex: 1))
      )
    }

    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: [
          frame(time: 0, marker: 0),
          frame(time: 2, marker: 2),
          frame(time: 1, marker: 1),
        ],
        timeRange: MotionTimeRange(startSeconds: 0, endSeconds: 2),
        provenance: provenance()
      ),
      .unavailable(.unorderedFrameTime(frameIndex: 2))
    )
    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: [],
        timeRange: MotionTimeRange(startSeconds: 0, endSeconds: 0),
        provenance: provenance()
      ),
      .unavailable(.noFrames)
    )
  }

  func testRejectsEveryInvalidJointCoordinateAndConfidenceState() {
    let invalidPositions = [
      MotionPoint(x: .nan, y: 0.5),
      MotionPoint(x: .infinity, y: 0.5),
      MotionPoint(x: 0.5, y: -.infinity),
      MotionPoint(x: 0.5, y: 0.5, z: .nan),
      MotionPoint(x: -0.1, y: 0.5),
      MotionPoint(x: 1.1, y: 0.5),
      MotionPoint(x: 0.5, y: -0.1),
      MotionPoint(x: 0.5, y: 1.1),
      MotionPoint(x: 0.5, y: 0.5, z: 0),
    ]
    for position in invalidPositions {
      XCTAssertEqual(
        MotionSkeletonSessionSlicer.slice(
          frames: [frame(time: 1, marker: 1, position: position)],
          timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
          provenance: provenance()
        ),
        .unavailable(
          .invalidJointCoordinates(frameIndex: 0, jointID: .leftWrist)
        )
      )
    }

    for confidence in [Double.nan, -.infinity, -0.1, 1.1, .infinity] {
      XCTAssertEqual(
        MotionSkeletonSessionSlicer.slice(
          frames: [frame(time: 1, marker: 1, confidence: confidence)],
          timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
          provenance: provenance()
        ),
        .unavailable(
          .invalidJointConfidence(frameIndex: 0, jointID: .leftWrist)
        )
      )
    }
  }

  func testRequiresSomeJointEvidenceButPreservesPartialEmptyFrames() throws {
    let emptyStartFrame = frame(time: 1, marker: 10, joints: [:])
    let emptyEndFrame = frame(time: 2, marker: 20, joints: [:])

    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: [emptyStartFrame, emptyEndFrame],
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 2),
        provenance: provenance()
      ),
      .unavailable(.noJointEvidence)
    )

    let observedEndFrame = frame(time: 2, marker: 20)
    let slice = try availableSlice(
      MotionSkeletonSessionSlicer.slice(
        frames: [emptyStartFrame, observedEndFrame],
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 2),
        provenance: provenance()
      )
    )
    XCTAssertEqual(slice.frames, [emptyStartFrame, observedEndFrame])
  }

  func testNonImageCoordinateSpaceAllowsFiniteValuesOutsideUnitSquare() throws {
    let worldFrame = frame(
      time: 1,
      marker: 150,
      coordinateSpace: .bodyLocal3D,
      position: MotionPoint(x: 1.5, y: -0.5, z: 2)
    )
    let slice = try availableSlice(
      MotionSkeletonSessionSlicer.slice(
        frames: [worldFrame],
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
        provenance: provenance(coordinateSpace: .bodyLocal3D)
      )
    )
    XCTAssertEqual(slice.frames, [worldFrame])
  }

  func testSameViewpointFromDifferentSourceIsNotAccepted() {
    let otherSource = MotionCameraSourceID(rawValue: "continuity-camera")
    let sameViewpointFrame = frame(
      time: 1,
      marker: 1,
      sourceID: otherSource,
      viewpoint: .faceOn
    )

    XCTAssertEqual(
      MotionSkeletonSessionSlicer.slice(
        frames: [sameViewpointFrame],
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
        provenance: provenance(sourceID: sourceID, viewpoint: .faceOn)
      ),
      .unavailable(.sourceMismatch(frameIndex: 0))
    )
  }

  func testRejectsEveryExactProvenanceMismatch() {
    let expected = provenance()
    let otherSessionID = UUID(uuidString: "73981E73-02ED-4A5A-9421-9EE4048ED3EF")!

    let cases: [(MotionSkeletonFrame, MotionSkeletonSessionUnavailability)] = [
      (
        frame(time: 1, marker: 1, streamSessionID: otherSessionID),
        .streamSessionMismatch(frameIndex: 0)
      ),
      (
        frame(
          time: 1,
          marker: 1,
          sourceID: MotionCameraSourceID(rawValue: "other-camera")
        ),
        .sourceMismatch(frameIndex: 0)
      ),
      (
        frame(time: 1, marker: 1, viewpoint: .downTheLine),
        .viewpointMismatch(frameIndex: 0)
      ),
      (
        frame(time: 1, marker: 1, coordinateSpace: .bodyLocal3D),
        .coordinateSpaceMismatch(frameIndex: 0)
      ),
      (
        frame(time: 1, marker: 1, rotationDegrees: 180),
        .orientationMismatch(frameIndex: 0)
      ),
      (
        frame(time: 1, marker: 1, isMirrored: true),
        .mirroringMismatch(frameIndex: 0)
      ),
    ]

    for (mismatchedFrame, expectedReason) in cases {
      XCTAssertEqual(
        MotionSkeletonSessionSlicer.slice(
          frames: [mismatchedFrame],
          timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
          provenance: expected
        ),
        .unavailable(expectedReason)
      )
    }
  }

  func testRepeatedBoundaryTimestampsAreRetainedDeterministically() throws {
    let frames = [
      frame(time: 1, marker: 10),
      frame(time: 1, marker: 11),
      frame(time: 2, marker: 20),
      frame(time: 2, marker: 21),
    ]

    let fullSlice = try availableSlice(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 2),
        provenance: provenance()
      )
    )
    XCTAssertEqual(fullSlice.frames, frames)
    XCTAssertEqual(fullSlice.frames.map(marker), [10, 11, 20, 21])

    let singleTimestampSlice = try availableSlice(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 1),
        provenance: provenance()
      )
    )
    XCTAssertEqual(singleTimestampSlice.frames, Array(frames[0...1]))
    XCTAssertEqual(singleTimestampSlice.frames.map(marker), [10, 11])
  }

  func testInvalidJointOutsideCompletionRangeDoesNotFabricateSelectedEvidence() throws {
    let frames = [
      frame(
        time: 0,
        marker: 0,
        position: MotionPoint(x: .nan, y: 0.5)
      ),
      frame(time: 1, marker: 1),
      frame(time: 2, marker: 2),
    ]

    let slice = try availableSlice(
      MotionSkeletonSessionSlicer.slice(
        frames: frames,
        timeRange: MotionTimeRange(startSeconds: 1, endSeconds: 2),
        provenance: provenance()
      )
    )

    XCTAssertEqual(slice.frames, Array(frames[1...2]))
  }

  private func provenance(
    streamSessionID: UUID? = nil,
    sourceID: MotionCameraSourceID? = nil,
    viewpoint: MotionCameraViewpoint = .faceOn,
    coordinateSpace: MotionCoordinateSpaceID = .normalizedImage2D,
    rotationDegrees: Int = 90,
    isMirrored: Bool = false
  ) -> MotionSkeletonSessionProvenance {
    MotionSkeletonSessionProvenance(
      streamSessionID: streamSessionID ?? self.streamSessionID,
      sourceID: sourceID ?? self.sourceID,
      viewpoint: viewpoint,
      coordinateSpace: coordinateSpace,
      rotationDegrees: rotationDegrees,
      isMirrored: isMirrored
    )
  }

  private func frame(
    time: Double,
    marker: Double,
    streamSessionID: UUID? = nil,
    sourceID: MotionCameraSourceID? = nil,
    viewpoint: MotionCameraViewpoint = .faceOn,
    coordinateSpace: MotionCoordinateSpaceID = .normalizedImage2D,
    rotationDegrees: Int = 90,
    isMirrored: Bool = false,
    position: MotionPoint? = nil,
    confidence: Double = 0.95,
    joints: [MotionJointID: MotionJointSample]? = nil
  ) -> MotionSkeletonFrame {
    MotionSkeletonFrame(
      context: MotionFrameContext(
        sourceID: sourceID ?? self.sourceID,
        streamSessionID: streamSessionID ?? self.streamSessionID,
        viewpoint: viewpoint,
        sourceTimeSeconds: time,
        coordinateSpace: coordinateSpace,
        rotationDegrees: rotationDegrees,
        isMirrored: isMirrored
      ),
      joints: joints ?? [
        .leftWrist: MotionJointSample(
          position: position ?? MotionPoint(x: marker / 100, y: 0.5),
          confidence: confidence
        )
      ]
    )
  }

  private func marker(_ frame: MotionSkeletonFrame) -> Double {
    (frame.joints[.leftWrist]?.position.x ?? -0.01) * 100
  }

  private func availableSlice(
    _ evidence: MotionSkeletonSessionEvidence,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> MotionSkeletonSessionSlice {
    guard case .available(let slice) = evidence else {
      XCTFail("Expected available skeleton evidence, got \(evidence)", file: file, line: line)
      throw AvailabilityError.unavailable
    }
    return slice
  }

  private enum AvailabilityError: Error {
    case unavailable
  }
}
