import CoreMedia
import XCTest

@testable import GolfTrace

final class SwingReplayClockMapperTests: XCTestCase {
  func testMapsCameraClockThroughSharedMonotonicClock() throws {
    let camera = anchors(mediaStart: 1_000, hostStart: 20, count: 12, step: 0.05)
    let replay = anchors(mediaStart: 0, hostStart: 19.5, count: 12, step: 0.05)

    let mapping = try XCTUnwrap(
      SwingReplayClockMapper.makeMapping(cameraAnchors: camera, replayAnchors: replay)
    )

    XCTAssertEqual(mapping.scale, 1, accuracy: 0.000_001)
    XCTAssertEqual(
      try XCTUnwrap(mapping.replayTimeSeconds(forCameraTimeSeconds: 1_000.025)),
      0.525,
      accuracy: 0.001
    )
    XCTAssertLessThan(mapping.uncertaintyMilliseconds, 0.001)
  }

  func testAcceptsSmallClockDriftAndSchedulerNoise() throws {
    let camera = (0..<24).map { index in
      let media = 200 + Double(index) * 0.04
      let noise = index.isMultiple(of: 2) ? 0.0015 : -0.0015
      return SwingReplayClockAnchor(
        mediaTimeSeconds: media,
        monotonicTimeSeconds: 50 + (media - 200) * 1.0002 + noise
      )
    }
    let replay = (0..<24).map { index in
      let media = Double(index) * 0.04
      let noise = index.isMultiple(of: 3) ? 0.001 : -0.0005
      return SwingReplayClockAnchor(
        mediaTimeSeconds: media,
        monotonicTimeSeconds: 49.7 + media * 0.9998 + noise
      )
    }

    let mapping = try XCTUnwrap(
      SwingReplayClockMapper.makeMapping(cameraAnchors: camera, replayAnchors: replay)
    )
    XCTAssertEqual(mapping.scale, 1.0004, accuracy: 0.002)
    XCTAssertLessThan(mapping.uncertaintyMilliseconds, 5)
  }

  func testRejectsInsufficientAndHighUncertaintySamples() {
    let tooFew = anchors(mediaStart: 0, hostStart: 0, count: 3, step: 0.05)
    XCTAssertNil(
      SwingReplayClockMapper.makeMapping(cameraAnchors: tooFew, replayAnchors: tooFew)
    )

    let camera = anchors(mediaStart: 10, hostStart: 10, count: 20, step: 0.05)
    let noisyReplay = (0..<20).map { index in
      SwingReplayClockAnchor(
        mediaTimeSeconds: Double(index) * 0.05,
        monotonicTimeSeconds: Double(index) * 0.05 + (index.isMultiple(of: 2) ? 0.2 : -0.2)
      )
    }
    XCTAssertNil(
      SwingReplayClockMapper.makeMapping(
        cameraAnchors: camera,
        replayAnchors: noisyReplay,
        maximumUncertaintyMilliseconds: 100
      )
    )
  }

  func testRejectsExtrapolationOutsideObservedRanges() throws {
    let camera = anchors(mediaStart: 100, hostStart: 10, count: 10, step: 0.05)
    let replay = anchors(mediaStart: 0, hostStart: 9.8, count: 10, step: 0.05)
    let mapping = try XCTUnwrap(
      SwingReplayClockMapper.makeMapping(cameraAnchors: camera, replayAnchors: replay)
    )

    XCTAssertNil(mapping.replayTimeSeconds(forCameraTimeSeconds: 99.99))
    XCTAssertNil(mapping.replayTimeSeconds(forCameraTimeSeconds: 100.51))
  }

  func testBuildsIndependentCalibrationsForSynchronizedReplayBundle() throws {
    let camera = anchors(mediaStart: 0, hostStart: 20, count: 20, step: 0.05)
    let rapsodo = anchors(mediaStart: 0, hostStart: 20.15, count: 16, step: 0.05)

    let synchronization = try XCTUnwrap(
      SwingReplayClockMapper.makeSynchronization(
        cameraAnchors: camera,
        rapsodoAnchors: rapsodo
      )
    )

    XCTAssertEqual(synchronization.method, SwingReplaySynchronization.monotonicReceiptMethod)
    XCTAssertEqual(synchronization.cameraClock.scaleToMonotonicClock, 1, accuracy: 0.000_001)
    XCTAssertEqual(synchronization.rapsodoClock.scaleToMonotonicClock, 1, accuracy: 0.000_001)
    XCTAssertEqual(synchronization.timelineMonotonicRangeSeconds.lowerBound, 20.15, accuracy: 0.001)
    XCTAssertEqual(synchronization.timelineMonotonicRangeSeconds.upperBound, 20.90, accuracy: 0.001)
    XCTAssertTrue(synchronization.validationIssues.isEmpty)
  }

  func testRejectsReplayBundleSynchronizationWithoutHostTimeOverlap() {
    let camera = anchors(mediaStart: 0, hostStart: 10, count: 10, step: 0.05)
    let rapsodo = anchors(mediaStart: 0, hostStart: 20, count: 10, step: 0.05)

    XCTAssertNil(
      SwingReplayClockMapper.makeSynchronization(
        cameraAnchors: camera,
        rapsodoAnchors: rapsodo
      )
    )
  }

  func testRejectsPairWhenRapsodoOnlyCoversPartOfCameraMaster() {
    let camera = anchors(mediaStart: 0, hostStart: 10, count: 20, step: 0.05)
    let lateRapsodo = anchors(mediaStart: 0, hostStart: 10.7, count: 20, step: 0.05)
    let earlyDisconnect = anchors(mediaStart: 0, hostStart: 9.8, count: 10, step: 0.05)

    XCTAssertNil(
      SwingReplayClockMapper.makeSynchronization(
        cameraAnchors: camera,
        rapsodoAnchors: lateRapsodo
      )
    )
    XCTAssertNil(
      SwingReplayClockMapper.makeSynchronization(
        cameraAnchors: camera,
        rapsodoAnchors: earlyDisconnect
      )
    )
  }

  func testAnchorBufferIsBoundedAndResetIsolatesSessions() {
    let buffer = SwingReplayClockAnchorBuffer(capacity: 8, minimumMediaInterval: 0)
    for index in 0..<20 {
      XCTAssertTrue(
        buffer.append(
          SwingReplayClockAnchor(
            mediaTimeSeconds: Double(index),
            monotonicTimeSeconds: 100 + Double(index)
          )
        )
      )
    }
    XCTAssertLessThanOrEqual(buffer.snapshot().count, 8)
    buffer.reset()
    XCTAssertTrue(buffer.snapshot().isEmpty)
    XCTAssertTrue(
      buffer.append(
        SwingReplayClockAnchor(mediaTimeSeconds: 0, monotonicTimeSeconds: 1)
      )
    )
  }

  private func anchors(
    mediaStart: Double,
    hostStart: Double,
    count: Int,
    step: Double
  ) -> [SwingReplayClockAnchor] {
    (0..<count).map { index in
      SwingReplayClockAnchor(
        mediaTimeSeconds: mediaStart + Double(index) * step,
        monotonicTimeSeconds: hostStart + Double(index) * step
      )
    }
  }
}
