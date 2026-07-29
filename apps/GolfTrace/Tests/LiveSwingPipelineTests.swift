import CoreMedia
import Foundation
import Vision
import XCTest

@testable import GolfTrace

final class LiveSwingPipelineTests: XCTestCase {
  private let sessionConfiguration = SwingSessionDetectorConfiguration(
    stillSpeedThreshold: 0.10,
    swingStartSpeedThreshold: 0.75,
    armStillnessDuration: 0.20,
    startConfirmationDuration: 0.05,
    endStillnessDuration: 0.10,
    maximumSwingDuration: 0.50,
    preRollDuration: 0.10
  )

  func testConsumesEveryPoseWhileCoalescingLiveSnapshots() async {
    let recorder = PipelineRecorder()
    let finalSnapshot = expectation(description: "latest analyzed pose reaches the UI")
    let poseCount = 240
    recorder.expectSnapshot(processedPoseCount: poseCount, expectation: finalSnapshot)
    let pipeline = makePipeline(recorder: recorder)
    let token = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )

    for index in 0..<poseCount {
      pipeline.consume(
        pose(at: Double(index) / 120, handCenterX: 0.25),
        sourceGeneration: token.sourceGeneration
      )
    }

    await fulfillment(of: [finalSnapshot], timeout: 2)

    let snapshots = recorder.snapshots
    let latest = try? XCTUnwrap(snapshots.last)
    XCTAssertNotNil(latest)
    XCTAssertEqual(latest?.epoch, token.epoch)
    XCTAssertEqual(latest?.processedPoseCount, poseCount)
    XCTAssertEqual(
      latest?.pose?.timestamp,
      CMTime(seconds: Double(poseCount - 1) / 120, preferredTimescale: 1_000)
    )
    XCTAssertLessThan(snapshots.count, poseCount)
    XCTAssertTrue(
      zip(snapshots, snapshots.dropFirst()).allSatisfy {
        $0.processedPoseCount < $1.processedPoseCount
      }
    )
  }

  func testNeutralSkeletonWindowRetainsOnlyLatestSixSecondsAtThirtyFPS() {
    let recorder = PipelineRecorder()
    let pipeline = makePipeline(recorder: recorder)
    let token = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )

    for index in 0..<240 {
      pipeline.consume(
        pose(
          timestamp: CMTime(value: CMTimeValue(index), timescale: 30),
          handCenterX: 0.25
        ),
        sourceGeneration: token.sourceGeneration
      )
    }

    let snapshot = pipeline.motionSkeletonSnapshot()

    XCTAssertEqual(snapshot.streamSessionID, token.streamSessionID)
    XCTAssertEqual(snapshot.maximumDurationSeconds, 6)
    XCTAssertEqual(snapshot.capacity, 720)
    XCTAssertEqual(snapshot.frames.count, 181)
    XCTAssertEqual(
      snapshot.frames.first?.context.sourceTimeSeconds ?? 0,
      59.0 / 30.0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      snapshot.latestFrame?.context.sourceTimeSeconds ?? 0,
      239.0 / 30.0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(pipeline.latestMotionSkeletonFrame, snapshot.latestFrame)
    XCTAssertTrue(
      snapshot.frames.allSatisfy {
        $0.context.streamSessionID == token.streamSessionID
      }
    )
  }

  func testNeutralSkeletonWindowUsesHardCapacityForRepeatedTimestampsAndSkipsInvalidTime() {
    let recorder = PipelineRecorder()
    let pipeline = makePipeline(recorder: recorder)
    let token = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )

    for index in 0..<730 {
      pipeline.consume(
        pose(
          timestamp: CMTime(seconds: 1, preferredTimescale: 1_000),
          handCenterX: CGFloat(index) / 1_000
        ),
        sourceGeneration: token.sourceGeneration
      )
    }
    pipeline.consume(
      pose(timestamp: .invalid, handCenterX: 0.99),
      sourceGeneration: token.sourceGeneration
    )
    pipeline.consume(
      pose(
        timestamp: CMTime(seconds: 0.5, preferredTimescale: 1_000),
        handCenterX: 0.99
      ),
      sourceGeneration: token.sourceGeneration
    )

    let snapshot = pipeline.motionSkeletonSnapshot()
    let leftWrist = MotionJointID(rawValue: "left_wrist")

    XCTAssertEqual(snapshot.frames.count, 720)
    XCTAssertEqual(
      snapshot.frames.first?.joints[leftWrist]?.position.x ?? 0,
      0,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      snapshot.latestFrame?.joints[leftWrist]?.position.x ?? 0,
      0.719,
      accuracy: 0.000_001
    )
    XCTAssertTrue(
      snapshot.frames.allSatisfy {
        $0.context.sourceTimeSeconds == 1
      }
    )
  }

  func testResetRejectsWorkFromAnOlderSourceGeneration() async {
    let recorder = PipelineRecorder()
    let currentSnapshot = expectation(description: "new generation publishes one accepted pose")
    let pipeline = makePipeline(recorder: recorder)
    let firstToken = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    pipeline.consume(
      pose(at: 0.10, handCenterX: 0.20),
      sourceGeneration: firstToken.sourceGeneration
    )

    let secondToken = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    recorder.expectSnapshot(
      epoch: secondToken.epoch,
      processedPoseCount: 1,
      expectation: currentSnapshot
    )
    pipeline.consume(
      pose(at: 0.20, handCenterX: 0.40),
      sourceGeneration: firstToken.sourceGeneration
    )
    pipeline.consume(
      pose(at: 0.30, handCenterX: 0.80),
      sourceGeneration: secondToken.sourceGeneration
    )

    await fulfillment(of: [currentSnapshot], timeout: 2)

    let currentEpochSnapshots = recorder.snapshots.filter { $0.epoch == secondToken.epoch }
    let latest = try? XCTUnwrap(currentEpochSnapshots.last)
    XCTAssertNotNil(latest)
    XCTAssertEqual(latest?.processedPoseCount, 1)
    XCTAssertEqual(
      CMTimeGetSeconds(latest?.pose?.timestamp ?? .invalid),
      0.30,
      accuracy: 0.000_001
    )
    XCTAssertEqual(latest?.motion.pointHistory.count, 1)
  }

  func testNeutralResetChangesSessionIdentityClearsFramesAndRejectsStaleGeneration() {
    let recorder = PipelineRecorder()
    let pipeline = makePipeline(recorder: recorder)
    let firstToken = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    pipeline.consume(
      pose(at: 0.10, handCenterX: 0.20),
      sourceGeneration: firstToken.sourceGeneration
    )

    let firstSnapshot = pipeline.motionSkeletonSnapshot()
    XCTAssertEqual(firstSnapshot.streamSessionID, firstToken.streamSessionID)
    XCTAssertEqual(firstSnapshot.frames.count, 1)

    let secondToken = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    let clearedSnapshot = pipeline.motionSkeletonSnapshot()
    XCTAssertNotEqual(secondToken.streamSessionID, firstToken.streamSessionID)
    XCTAssertEqual(clearedSnapshot.streamSessionID, secondToken.streamSessionID)
    XCTAssertTrue(clearedSnapshot.frames.isEmpty)
    XCTAssertNil(pipeline.latestMotionSkeletonFrame)

    pipeline.consume(
      pose(at: 0.20, handCenterX: 0.40),
      sourceGeneration: firstToken.sourceGeneration
    )
    pipeline.consume(
      pose(at: 0.30, handCenterX: 0.80),
      sourceGeneration: secondToken.sourceGeneration
    )

    let currentSnapshot = pipeline.motionSkeletonSnapshot()
    XCTAssertEqual(currentSnapshot.frames.count, 1)
    XCTAssertEqual(
      currentSnapshot.latestFrame?.context.sourceTimeSeconds ?? 0,
      0.30,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      currentSnapshot.latestFrame?.context.streamSessionID,
      secondToken.streamSessionID
    )
  }

  func testNeutralSourceChangeRotatesSessionBeforeMixingProvenance() {
    let recorder = PipelineRecorder()
    let pipeline = makePipeline(recorder: recorder)
    let token = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    pipeline.updateCaptureContext(
      LiveSwingCaptureContext(
        captureFPS: 120,
        poseAnalysisFPS: 30,
        cameraView: "faceOn",
        sourceID: "camera.face-on.a",
        isMirrored: false
      )
    )
    pipeline.consume(
      pose(at: 1, handCenterX: 0.25),
      sourceGeneration: token.sourceGeneration
    )

    let firstSnapshot = pipeline.motionSkeletonSnapshot()
    XCTAssertEqual(firstSnapshot.streamSessionID, token.streamSessionID)
    XCTAssertEqual(firstSnapshot.frames.count, 1)

    pipeline.updateCaptureContext(
      LiveSwingCaptureContext(
        captureFPS: 120,
        poseAnalysisFPS: 30,
        cameraView: "downTheLine",
        sourceID: "camera.dtl.b",
        isMirrored: true
      )
    )
    pipeline.consume(
      pose(at: 2, handCenterX: 0.75),
      sourceGeneration: token.sourceGeneration
    )

    let secondSnapshot = pipeline.motionSkeletonSnapshot()
    XCTAssertNotEqual(secondSnapshot.streamSessionID, firstSnapshot.streamSessionID)
    XCTAssertEqual(secondSnapshot.frames.count, 1)
    XCTAssertEqual(
      secondSnapshot.latestFrame?.context.streamSessionID,
      secondSnapshot.streamSessionID
    )
    XCTAssertEqual(
      secondSnapshot.latestFrame?.context.sourceID.rawValue,
      "camera.dtl.b"
    )
    XCTAssertEqual(secondSnapshot.latestFrame?.context.viewpoint, .downTheLine)
    XCTAssertEqual(secondSnapshot.latestFrame?.context.isMirrored, true)
  }

  func testNeutralFramePropagatesSourceViewpointOrientationAndMirroring() {
    struct ContextCase {
      let sourceID: String
      let cameraView: String
      let viewpoint: MotionCameraViewpoint
      let orientation: GolfTraceVideoOrientation
      let isMirrored: Bool
    }

    let cases = [
      ContextCase(
        sourceID: "camera.face-on.a",
        cameraView: "faceOn",
        viewpoint: .faceOn,
        orientation: .degrees90,
        isMirrored: true
      ),
      ContextCase(
        sourceID: "camera.dtl.b",
        cameraView: "downTheLine",
        viewpoint: .downTheLine,
        orientation: .degrees270,
        isMirrored: false
      ),
      ContextCase(
        sourceID: "camera.future.overhead",
        cameraView: "overhead",
        viewpoint: MotionCameraViewpoint(rawValue: "overhead"),
        orientation: .degrees180,
        isMirrored: true
      ),
    ]

    let recorder = PipelineRecorder()
    let pipeline = makePipeline(recorder: recorder)
    var sessionIDs = Set<UUID>()

    for (index, testCase) in cases.enumerated() {
      let token = pipeline.reset(
        resetMotionAndMetrics: true,
        preservingLastCompletion: false
      )
      sessionIDs.insert(token.streamSessionID)
      pipeline.updateCaptureContext(
        LiveSwingCaptureContext(
          captureFPS: 120,
          poseAnalysisFPS: 30,
          cameraView: testCase.cameraView,
          sourceID: testCase.sourceID,
          orientation: SwingStoryboardCaptureOrientation(testCase.orientation),
          isMirrored: testCase.isMirrored,
          encodedPixelWidth: 1_920,
          encodedPixelHeight: 1_080
        )
      )
      pipeline.consume(
        pose(
          at: 4 + Double(index),
          handCenterX: 0.45,
          videoOrientation: testCase.orientation
        ),
        sourceGeneration: token.sourceGeneration
      )

      let snapshot = pipeline.motionSkeletonSnapshot()
      let frame = snapshot.latestFrame

      XCTAssertEqual(snapshot.frames.count, 1)
      XCTAssertEqual(frame?.context.sourceID.rawValue, testCase.sourceID)
      XCTAssertEqual(frame?.context.streamSessionID, token.streamSessionID)
      XCTAssertEqual(frame?.context.viewpoint, testCase.viewpoint)
      XCTAssertEqual(
        frame?.context.sourceTimeSeconds ?? 0,
        4 + Double(index),
        accuracy: 0.000_001
      )
      XCTAssertEqual(frame?.context.coordinateSpace, .normalizedImage2D)
      XCTAssertEqual(frame?.context.rotationDegrees, Int(testCase.orientation.rawValue))
      XCTAssertEqual(frame?.context.isMirrored, testCase.isMirrored)
    }

    XCTAssertEqual(sessionIDs.count, cases.count)
  }

  func testCompletionOrderedBeforeResetIsReliablyRedeliveredInNewEpoch() async {
    let recorder = PipelineRecorder()
    let completionDelivered = expectation(description: "completion survives preserving reset")
    let pipeline = makePipeline(recorder: recorder)
    let firstToken = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    pipeline.updateCaptureContext(
      LiveSwingCaptureContext(
        captureFPS: 120,
        poseAnalysisFPS: 30,
        cameraView: "faceOn",
        sourceID: "iphone.camera.k",
        orientation: .degrees90,
        encodedPixelWidth: 1_920,
        encodedPixelHeight: 1_080
      ))

    let samples: [(time: Double, x: CGFloat)] = [
      (0.00, 0.20),
      (0.10, 0.20),
      (0.20, 0.20),
      (0.30, 0.20),
      (0.40, 0.30),
      (0.46, 0.40),
      (0.56, 0.65),
      (0.66, 0.70),
      (0.77, 0.70),
      (0.88, 0.70),
    ]
    for sample in samples {
      if sample.time == 0.56 {
        pipeline.updateCaptureContext(
          LiveSwingCaptureContext(
            captureFPS: 30,
            poseAnalysisFPS: 15,
            cameraView: "downTheLine",
            sourceID: "mac.camera.changed-mid-swing",
            orientation: .degrees0
          )
        )
      }
      pipeline.consume(
        pose(at: sample.time, handCenterX: sample.x),
        sourceGeneration: firstToken.sourceGeneration
      )
    }

    let expectedSecondEpoch = firstToken.epoch &+ 1
    recorder.expectCompletion(epoch: expectedSecondEpoch, expectation: completionDelivered)
    let secondToken = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: true
    )
    XCTAssertEqual(secondToken.epoch, expectedSecondEpoch)

    await fulfillment(of: [completionDelivered], timeout: 2)

    let completion = try? XCTUnwrap(
      recorder.completions.last(where: { $0.epoch == secondToken.epoch })
    )
    XCTAssertNotNil(completion)
    XCTAssertEqual(
      CMTimeGetSeconds(completion?.session.endTimestamp ?? .invalid),
      0.88,
      accuracy: 0.000_001
    )
    XCTAssertEqual(completion?.result.evidencePacket.captureFPS, 120)
    XCTAssertEqual(
      completion?.result.evidencePacket.poseAnalysisFPS ?? 0,
      10.42,
      accuracy: 0.01
    )
    XCTAssertEqual(completion?.result.evidencePacket.cameraView, "faceOn")
    XCTAssertEqual(completion?.captureContext.sourceID, "iphone.camera.k")
    XCTAssertEqual(completion?.captureContext.orientation, .degrees90)
    XCTAssertEqual(completion?.captureContext.encodedPixelWidth, 1_920)
    XCTAssertTrue(completion?.result.evidencePacket.validationIssues().isEmpty == true)
  }

  func testNeutralShadowLeavesLegacySessionAndEvidenceOutputUnchanged() async throws {
    let recorder = PipelineRecorder()
    let completionDelivered = expectation(description: "legacy completion remains authoritative")
    let pipeline = makePipeline(recorder: recorder)
    let token = pipeline.reset(
      resetMotionAndMetrics: true,
      preservingLastCompletion: false
    )
    let context = LiveSwingCaptureContext(
      captureFPS: 120,
      poseAnalysisFPS: 30,
      cameraView: "faceOn",
      sourceID: "iphone.camera.regression",
      orientation: .degrees90,
      isMirrored: true
    )
    pipeline.updateCaptureContext(context)

    let poses = [
      pose(at: 0.00, handCenterX: 0.20, videoOrientation: .degrees90),
      pose(at: 0.10, handCenterX: 0.20, videoOrientation: .degrees90),
      pose(at: 0.20, handCenterX: 0.20, videoOrientation: .degrees90),
      pose(at: 0.30, handCenterX: 0.20, videoOrientation: .degrees90),
      pose(at: 0.40, handCenterX: 0.30, videoOrientation: .degrees90),
      pose(at: 0.46, handCenterX: 0.40, videoOrientation: .degrees90),
      pose(at: 0.56, handCenterX: 0.65, videoOrientation: .degrees90),
      pose(at: 0.66, handCenterX: 0.70, videoOrientation: .degrees90),
      pose(at: 0.77, handCenterX: 0.70, videoOrientation: .degrees90),
      pose(at: 0.88, handCenterX: 0.70, videoOrientation: .degrees90),
    ]
    let legacy = try legacyAnalysis(for: poses, context: context)
    recorder.expectCompletion(epoch: token.epoch, expectation: completionDelivered)

    for pose in poses {
      pipeline.consume(pose, sourceGeneration: token.sourceGeneration)
    }

    await fulfillment(of: [completionDelivered], timeout: 2)

    let completion = try XCTUnwrap(
      recorder.completions.last(where: { $0.epoch == token.epoch })
    )
    XCTAssertEqual(completion.session, legacy.session)
    XCTAssertEqual(completion.result, legacy.result)
    XCTAssertEqual(completion.captureContext, context)
    XCTAssertEqual(pipeline.motionSkeletonSnapshot().frames.count, poses.count)
  }

  private func makePipeline(recorder: PipelineRecorder) -> LiveSwingPipeline {
    LiveSwingPipeline(
      maximumLivePublicationFPS: 30,
      sessionConfiguration: sessionConfiguration,
      positionSmoothingTimeConstant: 0,
      onSnapshot: { snapshot in
        recorder.record(snapshot)
      },
      onCompletion: { completion in
        recorder.record(completion)
      }
    )
  }

  private func pose(
    at seconds: Double,
    handCenterX: CGFloat,
    videoOrientation: GolfTraceVideoOrientation = .degrees0
  ) -> PoseFrame {
    pose(
      timestamp: CMTime(seconds: seconds, preferredTimescale: 1_000),
      handCenterX: handCenterX,
      videoOrientation: videoOrientation
    )
  }

  private func pose(
    timestamp: CMTime,
    handCenterX: CGFloat,
    videoOrientation: GolfTraceVideoOrientation = .degrees0
  ) -> PoseFrame {
    return PoseFrame(
      joints: [
        .leftWrist: PoseJoint(
          id: "left-wrist",
          location: CGPoint(x: handCenterX - 0.01, y: 0.50),
          confidence: 0.95
        ),
        .rightWrist: PoseJoint(
          id: "right-wrist",
          location: CGPoint(x: handCenterX + 0.01, y: 0.50),
          confidence: 0.95
        ),
      ],
      timestamp: timestamp,
      videoOrientation: videoOrientation
    )
  }

  private func legacyAnalysis(
    for poses: [PoseFrame],
    context: LiveSwingCaptureContext
  ) throws -> (session: SwingSessionSummary, result: SwingAnalysisResult) {
    let motionAnalyzer = SwingMotionAnalyzer(positionSmoothingTimeConstant: 0)
    let sessionDetector = SwingSessionDetector(configuration: sessionConfiguration)
    let metricsAnalyzer = SwingMetricsAnalyzer()

    for pose in poses {
      let motion = motionAnalyzer.consume(pose, materializePointHistory: false)
      metricsAnalyzer.consume(pose: pose, motion: motion)
      _ = sessionDetector.consume(motion)
    }

    let session = try XCTUnwrap(sessionDetector.lastCompletedSummary)
    return (
      session,
      metricsAnalyzer.finalizeWithEvidence(
        session: session,
        captureFPS: context.captureFPS,
        poseAnalysisFPS: context.poseAnalysisFPS,
        cameraView: context.cameraView
      )
    )
  }
}

private final class PipelineRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedSnapshots: [LiveSwingSnapshot] = []
  private var recordedCompletions: [LiveSwingCompletion] = []
  private var snapshotTarget: (epoch: UInt64?, count: Int, expectation: XCTestExpectation)?
  private var completionTarget: (epoch: UInt64, expectation: XCTestExpectation)?

  var snapshots: [LiveSwingSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return recordedSnapshots
  }

  var completions: [LiveSwingCompletion] {
    lock.lock()
    defer { lock.unlock() }
    return recordedCompletions
  }

  func expectSnapshot(
    epoch: UInt64? = nil,
    processedPoseCount: Int,
    expectation: XCTestExpectation
  ) {
    lock.lock()
    snapshotTarget = (epoch, processedPoseCount, expectation)
    lock.unlock()
  }

  func expectCompletion(epoch: UInt64, expectation: XCTestExpectation) {
    lock.lock()
    completionTarget = (epoch, expectation)
    lock.unlock()
  }

  func record(_ snapshot: LiveSwingSnapshot) {
    let fulfilledExpectation: XCTestExpectation?
    lock.lock()
    recordedSnapshots.append(snapshot)
    if let target = snapshotTarget,
      target.epoch == nil || target.epoch == snapshot.epoch,
      snapshot.processedPoseCount >= target.count
    {
      fulfilledExpectation = target.expectation
      snapshotTarget = nil
    } else {
      fulfilledExpectation = nil
    }
    lock.unlock()
    fulfilledExpectation?.fulfill()
  }

  func record(_ completion: LiveSwingCompletion) {
    let fulfilledExpectation: XCTestExpectation?
    lock.lock()
    recordedCompletions.append(completion)
    if let target = completionTarget, target.epoch == completion.epoch {
      fulfilledExpectation = target.expectation
      completionTarget = nil
    } else {
      fulfilledExpectation = nil
    }
    lock.unlock()
    fulfilledExpectation?.fulfill()
  }
}
