import CoreMedia
import XCTest

@testable import GolfTrace

final class H264ReplayBufferTests: XCTestCase {
  private let configuration = GolfTraceH264Configuration(
    sequenceParameterSet: Data([1, 2, 3]),
    pictureParameterSet: Data([4, 5])
  )

  func testDefaultCapacityCoversMaximumBitRateTakePreRollAndPrecedingIDR() {
    let requiredSeconds = 8.0 + 0.75 + 1.0
    let requiredBytes = Int(
      ceil(
        Double(H264ReplayBuffer.supportedMaximumBitRateBitsPerSecond)
          / 8 * requiredSeconds
      )
    )

    XCTAssertGreaterThanOrEqual(H264ReplayBuffer.defaultMaximumDuration, requiredSeconds)
    XCTAssertGreaterThanOrEqual(H264ReplayBuffer.defaultMaximumBytes, requiredBytes)
  }

  func testSegmentStartsAtLatestKeyFrameBeforeRequestedStart() throws {
    var buffer = H264ReplayBuffer(maximumDuration: 8, maximumBytes: 1_000_000)
    buffer.updateConfiguration(configuration)
    for frame in 0...240 {
      buffer.append(packet(frame: frame, framesPerSecond: 120, isKeyFrame: frame % 120 == 0))
    }

    let segment = try XCTUnwrap(
      buffer.segment(requestedStart: time(1.2), requestedEnd: time(1.8))
    )
    XCTAssertTrue(try XCTUnwrap(segment.frames.first).isKeyFrame)
    XCTAssertEqual(CMTimeGetSeconds(segment.startTimestamp), 1, accuracy: 0.000_001)
    XCTAssertLessThanOrEqual(CMTimeGetSeconds(segment.endTimestamp), 1.8)
  }

  func testDurationLimitTrimsToNextPlayableKeyFrame() throws {
    var buffer = H264ReplayBuffer(maximumDuration: 1, maximumBytes: 1_000_000)
    buffer.updateConfiguration(configuration)
    for frame in 0...240 {
      buffer.append(packet(frame: frame, framesPerSecond: 120, isKeyFrame: frame % 60 == 0))
    }

    let first = try XCTUnwrap(buffer.frames.first)
    XCTAssertTrue(first.isKeyFrame)
    XCTAssertLessThanOrEqual(
      CMTimeGetSeconds(try XCTUnwrap(buffer.frames.last).timestamp - first.timestamp),
      1.0
    )
  }

  func testSegmentResultRejectsExpiredRequestedStart() throws {
    var buffer = H264ReplayBuffer(maximumDuration: 1, maximumBytes: 1_000_000)
    buffer.updateConfiguration(configuration)
    for frame in 0...360 {
      buffer.append(packet(frame: frame, framesPerSecond: 120, isKeyFrame: frame % 60 == 0))
    }

    let result = buffer.segmentResult(
      requestedStart: time(1.75),
      requestedEnd: time(2.8)
    )
    guard
      case .failure(
        .requestedStartNotCovered(let requested, let earliestRetained)
      ) = result
    else {
      return XCTFail("Expected an explicit missing-start coverage error")
    }
    XCTAssertEqual(CMTimeGetSeconds(requested), 1.75, accuracy: 0.000_001)
    XCTAssertGreaterThan(CMTimeGetSeconds(earliestRetained), 1.75)
    XCTAssertNil(buffer.segment(requestedStart: time(1.75), requestedEnd: time(2.8)))
  }

  func testSegmentResultRejectsRequestedEndThatHasNotArrived() throws {
    var buffer = H264ReplayBuffer(maximumDuration: 8, maximumBytes: 1_000_000)
    buffer.updateConfiguration(configuration)
    for frame in 0...120 {
      buffer.append(packet(frame: frame, framesPerSecond: 120, isKeyFrame: frame % 120 == 0))
    }

    let result = buffer.segmentResult(
      requestedStart: time(0.2),
      requestedEnd: time(1.2)
    )
    guard
      case .failure(
        .requestedEndNotCovered(let requested, let latestRetainedFrameEnd)
      ) = result
    else {
      return XCTFail("Expected an explicit missing-end coverage error")
    }
    XCTAssertEqual(CMTimeGetSeconds(requested), 1.2, accuracy: 0.000_001)
    XCTAssertLessThan(CMTimeGetSeconds(latestRetainedFrameEnd), 1.2)
  }

  func testByteLimitNeverLeavesUndecodableLeadingPFrame() throws {
    var buffer = H264ReplayBuffer(maximumDuration: 8, maximumBytes: 1_024)
    buffer.updateConfiguration(configuration)
    for frame in 0...40 {
      buffer.append(
        packet(
          frame: frame,
          framesPerSecond: 20,
          isKeyFrame: frame % 10 == 0,
          payloadSize: 220
        )
      )
    }

    XCTAssertLessThanOrEqual(buffer.retainedBytes, 1_024)
    if let first = buffer.frames.first {
      XCTAssertTrue(first.isKeyFrame)
    }
  }

  func testConfigurationChangeClearsOldCompressedChain() {
    var buffer = H264ReplayBuffer()
    buffer.updateConfiguration(configuration)
    buffer.append(packet(frame: 0, framesPerSecond: 120, isKeyFrame: true))

    buffer.updateConfiguration(
      GolfTraceH264Configuration(
        sequenceParameterSet: Data([9]),
        pictureParameterSet: Data([8])
      )
    )

    XCTAssertTrue(buffer.frames.isEmpty)
    XCTAssertEqual(buffer.retainedBytes, 0)
  }

  func testLongRunningWindowKeepsOnlyBoundedPlayableFrames() throws {
    var buffer = H264ReplayBuffer(maximumDuration: 1, maximumBytes: 1_000_000)
    buffer.updateConfiguration(configuration)
    for frame in 0..<20_000 {
      buffer.append(packet(frame: frame, framesPerSecond: 120, isKeyFrame: frame % 60 == 0))
    }

    let frames = buffer.frames
    XCTAssertLessThanOrEqual(frames.count, 121)
    XCTAssertTrue(try XCTUnwrap(frames.first).isKeyFrame)
    XCTAssertEqual(buffer.retainedBytes, frames.reduce(0) { $0 + $1.payload.count })
  }

  private func packet(
    frame: Int,
    framesPerSecond: Int,
    isKeyFrame: Bool,
    payloadSize: Int = 20
  ) -> GolfTraceWirePacket {
    GolfTraceWirePacket(
      kind: .h264AccessUnit,
      flags: isKeyFrame ? [.keyFrame] : [],
      sequence: UInt64(frame + 1),
      presentationTimeMicroseconds: Int64(frame * 1_000_000 / framesPerSecond),
      payload: Data(repeating: UInt8(frame % 255), count: payloadSize)
    )
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }
}
