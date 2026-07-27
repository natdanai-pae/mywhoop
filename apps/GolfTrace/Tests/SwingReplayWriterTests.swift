@preconcurrency import AVFoundation
import CoreMedia
import XCTest

@testable import GolfTrace

final class SwingReplayWriterTests: XCTestCase {
  func testWritesPlayableMovieAndPersistsHalfTurn() async throws {
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
    let segment = H264ReplaySegment(
      configuration: configuration,
      frames: payloads.enumerated().map { index, payload in
        H264ReplayFrame(
          timestamp: CMTime(seconds: 7 + Double(index) / 30, preferredTimescale: 30_000),
          payload: payload,
          isKeyFrame: true
        )
      }
    )
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-Writer-Test-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let result: Result<SwingReplayWriteResult, Error> = await withCheckedContinuation {
      continuation in
      SwingReplayWriter.writeWithMetadata(
        segment,
        to: outputURL,
        rotationDegrees: 180
      ) { result in
        continuation.resume(returning: result)
      }
    }
    let writeResult = try result.get()
    let writtenURL = writeResult.url

    XCTAssertEqual(CMTimeGetSeconds(writeResult.sourcePTSOrigin), 7, accuracy: 0.000_001)
    XCTAssertEqual(CMTimeGetSeconds(writeResult.sourcePTSEnd), 7 + 2.0 / 30, accuracy: 0.000_001)
    XCTAssertEqual(writeResult.durationSeconds, 2.0 / 30, accuracy: 0.000_001)

    let fileSize = try writtenURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    XCTAssertGreaterThan(fileSize, 0)

    let asset = AVURLAsset(url: writtenURL)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(videoTracks.first)
    let duration = try await asset.load(.duration)
    XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)

    let transform = try await track.load(.preferredTransform)
    XCTAssertEqual(transform.a, -1, accuracy: 0.001)
    XCTAssertEqual(transform.d, -1, accuracy: 0.001)
  }
}
