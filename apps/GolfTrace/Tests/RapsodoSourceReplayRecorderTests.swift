@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import Foundation
import XCTest

@testable import GolfTrace

final class RapsodoSourceReplayRecorderTests: XCTestCase {
  @MainActor
  func testWritesSourceOnlyMovieAtThirtyFPSWithAnchorsOnlyForAppendedFrames() async throws {
    let outputDirectory = try makeOutputDirectory()
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let recorder = RapsodoSourceReplayRecorder(outputDirectory: outputDirectory)
    let source = RapsodoReplaySourceKind.appleMirroring(windowID: 42)

    try recorder.start(sourceKind: source, generationID: 7)
    XCTAssertTrue(recorder.isRecording)
    XCTAssertTrue(recorder.hasPendingWork)
    XCTAssertEqual(recorder.activeSourceKind, source)

    for frameIndex in 0..<6 {
      recorder.append(
        sampleBuffer: try makeSampleBuffer(
          width: 64,
          height: 48,
          timestamp: CMTime(value: CMTimeValue(frameIndex), timescale: 60)
        ),
        sourceKind: source,
        generationID: 7,
        monotonicTimeSeconds: 100 + Double(frameIndex) / 60
      )
      await recorder.flushPendingFrames()
      try await Task.sleep(for: .milliseconds(12))
    }

    let result = try successValue(await recorder.finish())
    XCTAssertFalse(recorder.isRecording)
    XCTAssertFalse(recorder.isFinalizing)
    XCTAssertFalse(recorder.hasPendingWork)
    XCTAssertNil(recorder.activeSourceKind)
    XCTAssertEqual(result.sourceKind, source)
    XCTAssertEqual(result.generationID, 7)
    XCTAssertEqual(result.format.width, 64)
    XCTAssertEqual(result.format.height, 48)
    XCTAssertEqual(result.format.orientation, .landscape)
    XCTAssertEqual(result.counters.received, 6)
    XCTAssertEqual(result.counters.appended, 3)
    XCTAssertEqual(result.counters.throttleDrops, 3)
    XCTAssertEqual(result.counters.backpressureDrops, 0)
    XCTAssertEqual(result.anchors.count, result.counters.appended)
    XCTAssertEqual(result.duration, 4.0 / 60.0, accuracy: 0.000_001)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))

    let asset = AVURLAsset(url: result.url)
    let isPlayable = try await asset.load(.isPlayable)
    let assetDuration = try await asset.load(.duration)
    XCTAssertTrue(isPlayable)
    XCTAssertGreaterThan(assetDuration.seconds, 0)
  }

  @MainActor
  func testFreezesSourceGenerationFormatAndPixelOrientation() async throws {
    let outputDirectory = try makeOutputDirectory()
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let recorder = RapsodoSourceReplayRecorder(outputDirectory: outputDirectory)
    let source = RapsodoReplaySourceKind.usb(deviceID: "K")

    try recorder.start(sourceKind: source, generationID: 11)
    recorder.append(
      sampleBuffer: try makeSampleBuffer(width: 64, height: 48, timestamp: .zero),
      sourceKind: source,
      generationID: 10,
      monotonicTimeSeconds: 200
    )
    await recorder.flushPendingFrames()

    recorder.append(
      sampleBuffer: try makeSampleBuffer(
        width: 64,
        height: 48,
        timestamp: CMTime(value: 1, timescale: 30)
      ),
      sourceKind: source,
      generationID: 11,
      monotonicTimeSeconds: 200 + 1.0 / 30.0
    )
    await recorder.flushPendingFrames()
    try await Task.sleep(for: .milliseconds(12))

    recorder.append(
      sampleBuffer: try makeSampleBuffer(
        width: 48,
        height: 64,
        timestamp: CMTime(value: 2, timescale: 30)
      ),
      sourceKind: source,
      generationID: 11,
      monotonicTimeSeconds: 200 + 2.0 / 30.0
    )
    await recorder.flushPendingFrames()

    recorder.append(
      sampleBuffer: try makeSampleBuffer(
        width: 64,
        height: 48,
        timestamp: CMTime(value: 3, timescale: 30)
      ),
      sourceKind: source,
      generationID: 11,
      monotonicTimeSeconds: 200 + 3.0 / 30.0
    )
    await recorder.flushPendingFrames()
    try await Task.sleep(for: .milliseconds(12))

    let result = try successValue(await recorder.finish())
    XCTAssertEqual(result.sourceKind, source)
    XCTAssertEqual(result.generationID, 11)
    XCTAssertEqual(result.format.orientation, .landscape)
    XCTAssertEqual(result.counters.sourceMismatchDrops, 1)
    XCTAssertEqual(result.counters.formatMismatchDrops, 1)
    XCTAssertEqual(result.counters.appended, 2)
    XCTAssertEqual(result.anchors.count, result.counters.appended)
  }

  @MainActor
  func testFreshnessRequiresExactSourceAndGenerationAndExpiresDeterministically() async throws {
    let outputDirectory = try makeOutputDirectory()
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let recorder = RapsodoSourceReplayRecorder(outputDirectory: outputDirectory)
    let source = RapsodoReplaySourceKind.usb(deviceID: "K")

    try recorder.start(sourceKind: source, generationID: 11)
    recorder.append(
      sampleBuffer: try makeSampleBuffer(width: 64, height: 48, timestamp: .zero),
      sourceKind: source,
      generationID: 10,
      monotonicTimeSeconds: 100
    )
    recorder.refreshSourceFreshness(nowMonotonicTimeSeconds: 100.1)
    XCTAssertFalse(recorder.isSourceFresh)

    recorder.append(
      sampleBuffer: try makeSampleBuffer(width: 64, height: 48, timestamp: .zero),
      sourceKind: .appleMirroring(windowID: 42),
      generationID: 11,
      monotonicTimeSeconds: 101
    )
    recorder.refreshSourceFreshness(nowMonotonicTimeSeconds: 101.1)
    XCTAssertFalse(recorder.isSourceFresh)

    recorder.append(
      sampleBuffer: try makeSampleBuffer(width: 64, height: 48, timestamp: .zero),
      sourceKind: source,
      generationID: 11,
      monotonicTimeSeconds: 102
    )
    recorder.refreshSourceFreshness(nowMonotonicTimeSeconds: 102.1)
    XCTAssertTrue(recorder.isSourceFresh)

    recorder.refreshSourceFreshness(nowMonotonicTimeSeconds: 102.8)
    XCTAssertFalse(recorder.isSourceFresh)
    recorder.cancel()
  }

  @MainActor
  func testCapsEncodedMovieAt1280PreservingLandscapeAspectAndEvenDimensions() async throws {
    let outputDirectory = try makeOutputDirectory()
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let recorder = RapsodoSourceReplayRecorder(outputDirectory: outputDirectory)
    let source = RapsodoReplaySourceKind.appleMirroring(windowID: 42)

    try recorder.start(sourceKind: source, generationID: 1)
    for frameIndex in 0..<3 {
      recorder.append(
        sampleBuffer: try makeSampleBuffer(
          width: 1_920,
          height: 1_080,
          timestamp: CMTime(value: CMTimeValue(frameIndex), timescale: 30)
        ),
        sourceKind: source,
        generationID: 1,
        monotonicTimeSeconds: 200 + Double(frameIndex) / 30
      )
      await recorder.flushPendingFrames()
      try await Task.sleep(for: .milliseconds(40))
    }

    let result = try successValue(await recorder.finish())
    XCTAssertEqual(result.format.width, 1_280)
    XCTAssertEqual(result.format.height, 720)
    XCTAssertEqual(result.format.width % 2, 0)
    XCTAssertEqual(result.format.height % 2, 0)

    let asset = AVURLAsset(url: result.url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let videoTrack = try XCTUnwrap(videoTracks.first)
    let naturalSize = try await videoTrack.load(.naturalSize)
    XCTAssertEqual(naturalSize.width, 1_280, accuracy: 0.5)
    XCTAssertEqual(naturalSize.height, 720, accuracy: 0.5)
  }

  @MainActor
  func testLifecycleRejectsOverlappingStartAndReportsNoFrames() async throws {
    let outputDirectory = try makeOutputDirectory()
    defer { try? FileManager.default.removeItem(at: outputDirectory) }
    let recorder = RapsodoSourceReplayRecorder(outputDirectory: outputDirectory)
    let source = RapsodoReplaySourceKind.usb(deviceID: "K")

    try recorder.start(sourceKind: source, generationID: 1)
    XCTAssertThrowsError(try recorder.start(sourceKind: source, generationID: 1)) { error in
      XCTAssertEqual(error as? RapsodoSourceReplayRecorderError, .alreadyRecording)
    }

    let result = await recorder.finish()
    guard case .failure(let error) = result else {
      XCTFail("Expected the empty recording to fail")
      return
    }
    XCTAssertEqual(error, .noVideoFrames)
    XCTAssertFalse(recorder.hasPendingWork)
    XCTAssertEqual(recorder.lastStatusText, error.localizedDescription)
  }

  private func makeOutputDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RapsodoSourceReplayRecorderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeSampleBuffer(
    width: Int,
    height: Int,
    timestamp: CMTime
  ) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
          kCVPixelBufferCGImageCompatibilityKey: true,
          kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary,
        &pixelBuffer
      ),
      kCVReturnSuccess
    )
    let resolvedPixelBuffer = try XCTUnwrap(pixelBuffer)

    var formatDescription: CMVideoFormatDescription?
    XCTAssertEqual(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: resolvedPixelBuffer,
        formatDescriptionOut: &formatDescription
      ),
      noErr
    )
    let resolvedFormatDescription = try XCTUnwrap(formatDescription)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 60),
      presentationTimeStamp: timestamp,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: resolvedPixelBuffer,
        formatDescription: resolvedFormatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      ),
      noErr
    )
    return try XCTUnwrap(sampleBuffer)
  }

  private func successValue(
    _ result: Result<RapsodoReplayExportResult, RapsodoSourceReplayRecorderError>,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> RapsodoReplayExportResult {
    switch result {
    case .success(let value):
      return value
    case .failure(let error):
      XCTFail("Expected successful export, received \(error)", file: file, line: line)
      throw error
    }
  }
}
