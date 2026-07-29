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

  private func pose(at seconds: Double, handCenterX: CGFloat) -> PoseFrame {
    let timestamp = CMTime(seconds: seconds, preferredTimescale: 1_000)
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
      timestamp: timestamp
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
