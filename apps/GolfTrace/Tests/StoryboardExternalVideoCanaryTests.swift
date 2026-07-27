import AVFoundation
import CoreVideo
import Foundation
import XCTest

@testable import GolfTrace

/// Opt-in canary for external-file ingestion, native timing, and orientation.
/// Phase extraction quality is covered separately and is not proven here.
final class StoryboardExternalVideoIngestionCanaryTests: XCTestCase {
  func testManifestKeepsEveryStoryboardWithinOneClipAndOneAngle() throws {
    let manifest = try loadManifest()

    XCTAssertEqual(manifest.schemaVersion, 1)
    XCTAssertEqual(manifest.sourcePolicy.scope, "one-clip-one-angle")
    XCTAssertFalse(manifest.sourcePolicy.allowCrossClipPhaseMixing)
    XCTAssertEqual(manifest.clips.count, 4)
    XCTAssertEqual(Set(manifest.clips.map(\.id)).count, manifest.clips.count)
    XCTAssertTrue(manifest.clips.allSatisfy { !$0.cameraView.isEmpty })

    let multiAngleSource = try XCTUnwrap(
      manifest.clips.first(where: { $0.id == "oandn2z-KwA" })
    )
    let safeFrontViewSegment = try XCTUnwrap(multiAngleSource.segment)
    XCTAssertEqual(safeFrontViewSegment.startSeconds, 0, accuracy: 0.001)
    XCTAssertLessThanOrEqual(safeFrontViewSegment.endSeconds, 24.0)
    XCTAssertEqual(
      multiAngleSource.expected.durationSeconds,
      safeFrontViewSegment.endSeconds - safeFrontViewSegment.startSeconds,
      accuracy: 0.001
    )
  }

  func testPartialDrillsAreNeverForcedIntoEightPhases() throws {
    let manifest = try loadManifest()
    let partialClips = manifest.clips.filter {
      $0.validationRole.contains("partial") || $0.validationRole.contains("drill")
    }

    XCTAssertFalse(partialClips.isEmpty)
    XCTAssertTrue(partialClips.allSatisfy { !$0.requiresEightPhases })
  }

  func testOptInVideoIngestionKeepsBoundedSourceTimingAndOrientation() async throws {
    let validationRoot = try validationVideoRoot()
    let manifest = try loadManifest()

    for clip in manifest.clips {
      let sourceURL =
        validationRoot
        .appendingPathComponent(clip.id, isDirectory: true)
        .appendingPathComponent("source.mp4", isDirectory: false)
      guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
        throw ExternalVideoValidationConfigurationError.missingClip(sourceURL)
      }

      let segmentStart = clip.segment.map {
        CMTime(seconds: $0.startSeconds, preferredTimescale: 60_000)
      }
      let segmentEnd = clip.segment.map {
        CMTime(seconds: $0.endSeconds, preferredTimescale: 60_000)
      }
      let reader = try await OfflineVideoFrameReader(
        url: sourceURL,
        startTime: segmentStart,
        endTime: segmentEnd
      )
      let metadata = await reader.metadata
      assertMetadata(metadata, matches: clip, file: #filePath, line: #line)

      var frameCount = 0
      var firstPTS: Double?
      var previousPTS: Double?
      var lastPTS: Double?

      while let frame = try await reader.nextFrame() {
        let pts = CMTimeGetSeconds(frame.presentationTime)
        XCTAssertTrue(pts.isFinite, "\(clip.id) emitted a non-finite PTS")
        XCTAssertEqual(frame.sourceFrameIndex, frameCount)
        if let previousPTS {
          XCTAssertGreaterThan(
            pts,
            previousPTS,
            "\(clip.id) frames must remain in strictly increasing source PTS order"
          )
        } else {
          firstPTS = pts
          XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), clip.expected.pixelWidth)
          XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), clip.expected.pixelHeight)
        }
        previousPTS = pts
        lastPTS = pts
        frameCount += 1
      }

      XCTAssertGreaterThan(frameCount, 1, "\(clip.id) did not decode enough frames")
      if let segment = clip.segment {
        XCTAssertGreaterThanOrEqual(
          try XCTUnwrap(firstPTS),
          segment.startSeconds - (1 / clip.expected.framesPerSecond),
          "\(clip.id) must not emit frames before its configured single-angle segment"
        )
        XCTAssertLessThanOrEqual(
          try XCTUnwrap(lastPTS),
          segment.endSeconds,
          "\(clip.id) must stop before the configured hard cut"
        )
      }
      let decodedSpan = try XCTUnwrap(lastPTS) - (try XCTUnwrap(firstPTS))
      let observedFPS = Double(frameCount - 1) / decodedSpan
      XCTAssertEqual(
        observedFPS,
        clip.expected.framesPerSecond,
        accuracy: 0.6,
        "\(clip.id) ingestion must keep native timing instead of being resampled"
      )
      let effectiveDuration = decodedSpan + (1 / clip.expected.framesPerSecond)
      XCTAssertEqual(
        effectiveDuration,
        clip.expected.durationSeconds,
        accuracy: 0.15,
        "\(clip.id) effective duration must come from decoded PTS, not container edits"
      )
      let decodedDurationValue = await reader.decodedDuration
      let decodedDuration = try XCTUnwrap(decodedDurationValue)
      XCTAssertEqual(
        CMTimeGetSeconds(decodedDuration),
        effectiveDuration,
        accuracy: 1 / clip.expected.framesPerSecond,
        "\(clip.id) ingestion reader must expose the same decoded timeline"
      )
    }
  }

  func testPreferredTransformDeterministicallyChangesDisplayOrientation() {
    let naturalSize = CGSize(width: 1_920, height: 1_080)
    let quarterTurn = CGAffineTransform(rotationAngle: .pi / 2)

    let displaySize = OfflineVideoGeometry.displaySize(
      naturalSize: naturalSize,
      preferredTransform: quarterTurn
    )

    XCTAssertEqual(displaySize.width, 1_080, accuracy: 0.001)
    XCTAssertEqual(displaySize.height, 1_920, accuracy: 0.001)
    XCTAssertEqual(OfflineVideoOrientation(displaySize: displaySize), .portrait)
  }

  func testOptInVideosReachProductionPoseAndHandMotionPipeline() async throws {
    let validationRoot = try validationVideoRoot()
    let manifest = try loadManifest()

    for clip in manifest.clips {
      let sourceURL =
        validationRoot
        .appendingPathComponent(clip.id, isDirectory: true)
        .appendingPathComponent("source.mp4", isDirectory: false)
      guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
        throw ExternalVideoValidationConfigurationError.missingClip(sourceURL)
      }

      let reader = try await OfflineVideoFrameReader(
        url: sourceURL,
        startTime: clip.segment.map {
          CMTime(seconds: $0.startSeconds, preferredTimescale: 60_000)
        },
        endTime: clip.segment.map {
          CMTime(seconds: $0.endSeconds, preferredTimescale: 60_000)
        }
      )
      let metadata = await reader.metadata
      let orientation = videoOrientation(for: metadata.preferredTransform)
      let sampleStride = max(
        1,
        Int((Double(metadata.nominalFrameRate) / 10).rounded())
      )
      let detector = PoseDetector()
      let motionAnalyzer = SwingMotionAnalyzer(positionSmoothingTimeConstant: 0)
      var analyzedFrameCount = 0
      var detectedBodyCount = 0
      var detectedHandCenterCount = 0

      while let frame = try await reader.nextFrame() {
        guard frame.sourceFrameIndex.isMultiple(of: sampleStride) else { continue }
        let sampleBuffer = try makeSampleBuffer(from: frame)
        let pose = await analyze(
          sampleBuffer,
          orientation: orientation,
          using: detector
        )
        analyzedFrameCount += 1
        if pose?.joints.isEmpty == false {
          detectedBodyCount += 1
        }
        if motionAnalyzer.consume(pose, materializePointHistory: false).handCenter != nil {
          detectedHandCenterCount += 1
        }
      }

      XCTAssertGreaterThan(
        analyzedFrameCount,
        20,
        "\(clip.id) did not provide enough sampled frames to exercise production Vision"
      )
      XCTAssertGreaterThanOrEqual(
        detectedBodyCount,
        max(5, analyzedFrameCount / 4),
        "\(clip.id) body-pose visibility is too low for storyboard phase evidence"
      )
      XCTAssertGreaterThanOrEqual(
        detectedHandCenterCount,
        max(5, analyzedFrameCount / 5),
        "\(clip.id) wrist visibility is too low for the production hand-motion analyzer"
      )
    }
  }

  private func validationVideoRoot() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    guard
      let rawPath = environment["GOLFTRACE_VALIDATION_VIDEO_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawPath.isEmpty
    else {
      throw XCTSkip(
        "Set GOLFTRACE_VALIDATION_VIDEO_DIR to run local external-video canaries"
      )
    }
    let url = URL(fileURLWithPath: rawPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: url.path)
    else {
      throw ExternalVideoValidationConfigurationError.invalidRoot(url)
    }
    return url
  }

  private func loadManifest() throws -> ExternalVideoManifest {
    let testBundle = Bundle(for: Self.self)
    guard
      let fixtureURL = testBundle.url(
        forResource: "storyboard-external-videos",
        withExtension: "json"
      )
    else {
      XCTFail("Missing storyboard-external-videos.json in the test bundle")
      throw CocoaError(.fileNoSuchFile)
    }
    return try JSONDecoder().decode(
      ExternalVideoManifest.self,
      from: Data(contentsOf: fixtureURL)
    )
  }

  private func assertMetadata(
    _ metadata: OfflineVideoMetadata,
    matches clip: ExternalVideoManifest.Clip,
    file: StaticString,
    line: UInt
  ) {
    XCTAssertEqual(
      Int(metadata.naturalSize.width.rounded()),
      clip.expected.pixelWidth,
      file: file,
      line: line
    )
    XCTAssertEqual(
      Int(metadata.naturalSize.height.rounded()),
      clip.expected.pixelHeight,
      file: file,
      line: line
    )
    XCTAssertEqual(
      metadata.orientation.rawValue,
      clip.expected.orientation,
      file: file,
      line: line
    )
    XCTAssertEqual(
      Double(metadata.nominalFrameRate),
      clip.expected.framesPerSecond,
      accuracy: 0.1,
      file: file,
      line: line
    )
    XCTAssertTrue(metadata.assetDuration.isNumeric, file: file, line: line)
    XCTAssertGreaterThan(metadata.assetDuration, .zero, file: file, line: line)
    XCTAssertGreaterThan(metadata.displaySize.width, 0, file: file, line: line)
    XCTAssertGreaterThan(metadata.displaySize.height, 0, file: file, line: line)
    let transformedBounds = CGRect(origin: .zero, size: metadata.naturalSize)
      .applying(metadata.preferredTransform)
      .standardized
    XCTAssertEqual(
      metadata.displaySize.width,
      abs(transformedBounds.width),
      accuracy: 0.5,
      file: file,
      line: line
    )
    XCTAssertEqual(
      metadata.displaySize.height,
      abs(transformedBounds.height),
      accuracy: 0.5,
      file: file,
      line: line
    )
  }

  private func analyze(
    _ sampleBuffer: CMSampleBuffer,
    orientation: GolfTraceVideoOrientation,
    using detector: PoseDetector
  ) async -> PoseFrame? {
    await withCheckedContinuation { continuation in
      detector.onPose = { pose, _ in
        continuation.resume(returning: pose)
      }
      detector.analyze(sampleBuffer, videoOrientation: orientation)
    }
  }

  private func makeSampleBuffer(from frame: OfflineVideoFrame) throws -> CMSampleBuffer {
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: frame.pixelBuffer,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(formatStatus))
    }
    var timing = CMSampleTimingInfo(
      duration: frame.duration,
      presentationTimeStamp: frame.presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: frame.pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(sampleStatus))
    }
    return sampleBuffer
  }

  private func videoOrientation(
    for preferredTransform: CGAffineTransform
  ) -> GolfTraceVideoOrientation {
    let rawDegrees = Int((atan2(preferredTransform.b, preferredTransform.a) * 180 / .pi).rounded())
    let normalized = ((rawDegrees % 360) + 360) % 360
    switch normalized {
    case 90: return .degrees90
    case 180: return .degrees180
    case 270: return .degrees270
    default: return .degrees0
    }
  }
}

private struct ExternalVideoManifest: Decodable {
  struct SourcePolicy: Decodable {
    let scope: String
    let allowCrossClipPhaseMixing: Bool
  }

  struct Clip: Decodable {
    struct Segment: Decodable {
      let startSeconds: Double
      let endSeconds: Double
    }

    struct Expected: Decodable {
      let pixelWidth: Int
      let pixelHeight: Int
      let orientation: String
      let framesPerSecond: Double
      let durationSeconds: Double
    }

    let id: String
    let url: URL
    let validationRole: String
    let cameraView: String
    let requiresEightPhases: Bool
    let segment: Segment?
    let expected: Expected
  }

  let schemaVersion: Int
  let sourcePolicy: SourcePolicy
  let clips: [Clip]
}

private enum ExternalVideoValidationConfigurationError: LocalizedError {
  case invalidRoot(URL)
  case missingClip(URL)

  var errorDescription: String? {
    switch self {
    case .invalidRoot(let url):
      return "Configured GOLFTRACE_VALIDATION_VIDEO_DIR is not readable: \(url.path)"
    case .missingClip(let url):
      return "Configured external-video set is incomplete; missing: \(url.path)"
    }
  }
}
