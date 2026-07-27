import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

struct OfflineVideoMetadata: Equatable, Sendable {
  /// The container duration reported by AVFoundation. Some remuxed sources
  /// report an edit-list duration that differs from the decoded frame timeline.
  let assetDuration: CMTime
  let naturalSize: CGSize
  let displaySize: CGSize
  let nominalFrameRate: Float
  let preferredTransform: CGAffineTransform
  let orientation: OfflineVideoOrientation
}

enum OfflineVideoOrientation: String, Equatable, Sendable {
  case landscape
  case portrait
  case square

  init(displaySize: CGSize) {
    let width = abs(displaySize.width)
    let height = abs(displaySize.height)
    if abs(width - height) < 0.5 {
      self = .square
    } else if width > height {
      self = .landscape
    } else {
      self = .portrait
    }
  }
}

enum OfflineVideoGeometry {
  /// Computes the displayed track size after AVFoundation's preferred transform.
  /// Keeping this pure makes rotation metadata testable without binary fixtures.
  static func displaySize(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
  ) -> CGSize {
    let displayBounds = CGRect(origin: .zero, size: naturalSize)
      .applying(preferredTransform)
      .standardized
    return CGSize(
      width: abs(displayBounds.width),
      height: abs(displayBounds.height)
    )
  }
}

struct OfflineVideoFrame: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  let presentationTime: CMTime
  let duration: CMTime
  let sourceFrameIndex: Int
}

enum OfflineVideoFrameReaderError: Error, Equatable {
  case videoTrackMissing
  case invalidTimeRange(String)
  case cannotCreateReader(String)
  case cannotAddTrackOutput
  case cannotStartReading(String)
  case missingPixelBuffer
  case readingFailed(String)
}

/// Deterministic, serial frame access for opt-in validation videos.
///
/// This reader deliberately does not sample, reorder, normalize timestamps, or
/// apply the preferred transform. Callers receive every decoded frame in source
/// order, while `metadata` preserves the track transform needed to orient Vision
/// input and rendered evidence consistently. Optional read limits use source
/// timeline coordinates; emitted presentation timestamps are never rebased.
actor OfflineVideoFrameReader {
  let metadata: OfflineVideoMetadata

  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let fallbackFrameDuration: CMTime
  private var sourceFrameIndex = 0
  private var firstPresentationTime: CMTime?
  private var lastFrameEndTime: CMTime?

  init(
    url: URL,
    startTime: CMTime? = nil,
    endTime: CMTime? = nil
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw OfflineVideoFrameReaderError.videoTrackMissing
    }

    let duration = try await asset.load(.duration)
    let naturalSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    let nominalFrameRate = try await track.load(.nominalFrameRate)
    let minimumFrameDuration = try await track.load(.minFrameDuration)
    let displaySize = OfflineVideoGeometry.displaySize(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
    metadata = OfflineVideoMetadata(
      assetDuration: duration,
      naturalSize: naturalSize,
      displaySize: displaySize,
      nominalFrameRate: nominalFrameRate,
      preferredTransform: preferredTransform,
      orientation: OfflineVideoOrientation(displaySize: displaySize)
    )
    if minimumFrameDuration.isNumeric && minimumFrameDuration > .zero {
      fallbackFrameDuration = minimumFrameDuration
    } else if nominalFrameRate > 0 {
      fallbackFrameDuration = CMTime(
        seconds: 1 / Double(nominalFrameRate),
        preferredTimescale: 60_000
      )
    } else {
      fallbackFrameDuration = .zero
    }

    let requestedReadRange: CMTimeRange?
    let requestedStart = startTime ?? .zero
    guard requestedStart.isNumeric, requestedStart >= .zero else {
      throw OfflineVideoFrameReaderError.invalidTimeRange(
        "start time must be finite and non-negative"
      )
    }
    if let endTime {
      guard endTime.isNumeric, endTime > requestedStart else {
        throw OfflineVideoFrameReaderError.invalidTimeRange(
          "end time must be finite and greater than start time"
        )
      }
      requestedReadRange = CMTimeRange(start: requestedStart, end: endTime)
    } else if startTime != nil {
      guard duration.isNumeric, duration > requestedStart else {
        throw OfflineVideoFrameReaderError.invalidTimeRange(
          "start time must precede the asset duration"
        )
      }
      requestedReadRange = CMTimeRange(start: requestedStart, end: duration)
    } else {
      requestedReadRange = nil
    }

    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw OfflineVideoFrameReaderError.cannotCreateReader(error.localizedDescription)
    }
    if let requestedReadRange {
      reader.timeRange = requestedReadRange
    }

    output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw OfflineVideoFrameReaderError.cannotAddTrackOutput
    }
    reader.add(output)
    guard reader.startReading() else {
      throw OfflineVideoFrameReaderError.cannotStartReading(
        reader.error?.localizedDescription ?? "Unknown AVAssetReader error"
      )
    }
  }

  func nextFrame() throws -> OfflineVideoFrame? {
    guard let sampleBuffer = output.copyNextSampleBuffer() else {
      if reader.status == .failed {
        throw OfflineVideoFrameReaderError.readingFailed(
          reader.error?.localizedDescription ?? "Unknown AVAssetReader error"
        )
      }
      return nil
    }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      throw OfflineVideoFrameReaderError.missingPixelBuffer
    }

    let frame = OfflineVideoFrame(
      pixelBuffer: pixelBuffer,
      presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
      duration: CMSampleBufferGetDuration(sampleBuffer),
      sourceFrameIndex: sourceFrameIndex
    )
    if firstPresentationTime == nil {
      firstPresentationTime = frame.presentationTime
    }
    let validDuration =
      frame.duration.isNumeric && frame.duration > .zero
      ? frame.duration
      : fallbackFrameDuration
    lastFrameEndTime = frame.presentationTime + validDuration
    sourceFrameIndex += 1
    return frame
  }

  /// Duration of the frames actually emitted by AVAssetReader.
  ///
  /// This is the timing source storyboard validation should use. It is only
  /// available after at least one frame has been read.
  var decodedDuration: CMTime? {
    guard let firstPresentationTime, let lastFrameEndTime else { return nil }
    return lastFrameEndTime - firstPresentationTime
  }
}
