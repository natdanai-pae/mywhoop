import CoreMedia
import Foundation

/// One compressed H.264 access unit retained for the short replay window.
struct H264ReplayFrame: Equatable, @unchecked Sendable {
  let timestamp: CMTime
  let payload: Data
  let isKeyFrame: Bool
}

/// A self-contained compressed segment. Its first frame is always a key frame,
/// so VideoToolbox and AVAssetWriter can start without earlier video data.
struct H264ReplaySegment: Equatable, @unchecked Sendable {
  let configuration: GolfTraceH264Configuration
  let frames: [H264ReplayFrame]

  var startTimestamp: CMTime { frames.first?.timestamp ?? .invalid }
  var endTimestamp: CMTime { frames.last?.timestamp ?? .invalid }

  var duration: TimeInterval {
    guard startTimestamp.isValid, endTimestamp.isValid else { return 0 }
    return max(0, CMTimeGetSeconds(endTimestamp - startTimestamp))
  }
}

enum H264ReplaySegmentError: LocalizedError, Equatable {
  case missingConfiguration
  case invalidRequestedRange
  case missingFrames
  case requestedStartNotCovered(requested: CMTime, earliestRetained: CMTime)
  case requestedEndNotCovered(requested: CMTime, latestRetainedFrameEnd: CMTime)

  var errorDescription: String? {
    switch self {
    case .missingConfiguration:
      return "ยังไม่ได้รับรูปแบบวิดีโอ H.264 สำหรับสร้างคลิปย้อนหลัง"
    case .invalidRequestedRange:
      return "ช่วงเวลาที่ขอสร้างคลิปย้อนหลังไม่ถูกต้อง"
    case .missingFrames:
      return "ข้อมูลภาพย้อนหลังไม่ครบ"
    case .requestedStartNotCovered(let requested, let earliestRetained):
      return
        "ภาพย้อนหลังช่วงต้นถูกตัดออกจาก buffer แล้ว "
        + "(ต้องการ \(Self.seconds(requested)) วินาที, มีตั้งแต่ \(Self.seconds(earliestRetained)) วินาที)"
    case .requestedEndNotCovered(let requested, let latestRetainedFrameEnd):
      return
        "ภาพย้อนหลังช่วงท้ายยังมาไม่ครบ "
        + "(ต้องการถึง \(Self.seconds(requested)) วินาที, มีถึง \(Self.seconds(latestRetainedFrameEnd)) วินาที)"
    }
  }

  private static func seconds(_ time: CMTime) -> String {
    let value = CMTimeGetSeconds(time)
    return value.isFinite ? String(format: "%.3f", value) : "-"
  }
}

/// Keeps only a bounded window of the already-compressed live stream.
///
/// This type is deliberately independent of Network and AVAssetWriter so its
/// key-frame selection and memory bounds can be tested deterministically.
struct H264ReplayBuffer {
  /// The iPhone encoder is capped at 80 Mbps. Eleven seconds plus a 128 MiB
  /// byte ceiling retains an eight-second take, 0.75-second pre-roll and the
  /// preceding one-second IDR even after trimming advances to the next keyframe.
  static let defaultMaximumDuration: TimeInterval = 11
  static let defaultMaximumBytes = 128 * 1_024 * 1_024
  static let supportedMaximumBitRateBitsPerSecond = 80_000_000

  let maximumDuration: TimeInterval
  let maximumBytes: Int

  private(set) var configuration: GolfTraceH264Configuration?
  private(set) var retainedBytes = 0
  private var storage: [H264ReplayFrame] = []
  private var headIndex = 0

  /// Materialized only for diagnostics and tests. The receive hot path uses an
  /// indexed window so expiring one 120 FPS frame never shifts the whole array.
  var frames: [H264ReplayFrame] {
    guard headIndex < storage.count else { return [] }
    return Array(storage[headIndex...])
  }

  init(
    maximumDuration: TimeInterval = Self.defaultMaximumDuration,
    maximumBytes: Int = Self.defaultMaximumBytes
  ) {
    self.maximumDuration = max(1, maximumDuration)
    self.maximumBytes = max(1_024, maximumBytes)
  }

  mutating func reset() {
    configuration = nil
    storage.removeAll(keepingCapacity: true)
    headIndex = 0
    retainedBytes = 0
  }

  mutating func updateConfiguration(_ newConfiguration: GolfTraceH264Configuration) {
    if let configuration, configuration != newConfiguration {
      storage.removeAll(keepingCapacity: true)
      headIndex = 0
      retainedBytes = 0
    }
    configuration = newConfiguration
  }

  mutating func append(_ packet: GolfTraceWirePacket) {
    guard packet.kind == .h264AccessUnit,
      packet.presentationTimeMicroseconds >= 0,
      !packet.payload.isEmpty
    else {
      return
    }

    let timestamp = CMTime(
      value: packet.presentationTimeMicroseconds,
      timescale: 1_000_000
    )
    guard timestamp.isValid else { return }

    if let last = storage.last, CMTimeCompare(timestamp, last.timestamp) <= 0 {
      // A reconnect or profile change can restart the iPhone timestamp. The
      // previous compressed chain cannot be mixed with the new one.
      storage.removeAll(keepingCapacity: true)
      headIndex = 0
      retainedBytes = 0
    }

    storage.append(
      H264ReplayFrame(
        timestamp: timestamp,
        payload: packet.payload,
        isKeyFrame: packet.flags.contains(.keyFrame)
      )
    )
    retainedBytes += packet.payload.count
    trimToBounds()
  }

  /// Selects a playable segment beginning at the latest key frame at or before
  /// `requestedStart`, and ending no later than `requestedEnd`.
  func segment(requestedStart: CMTime, requestedEnd: CMTime) -> H264ReplaySegment? {
    guard
      case .success(let segment) = segmentResult(
        requestedStart: requestedStart,
        requestedEnd: requestedEnd
      )
    else { return nil }
    return segment
  }

  /// Coverage-aware selection used by persisted masters. Unlike the legacy
  /// optional API, this never substitutes the first retained IDR when the
  /// requested beginning has already expired, and reports which edge is absent.
  func segmentResult(
    requestedStart: CMTime,
    requestedEnd: CMTime
  ) -> Result<H264ReplaySegment, H264ReplaySegmentError> {
    guard let configuration else { return .failure(.missingConfiguration) }
    guard requestedStart.isValid,
      requestedEnd.isValid,
      CMTimeCompare(requestedEnd, requestedStart) > 0
    else {
      return .failure(.invalidRequestedRange)
    }
    guard let firstIndex = activeIndices.first, let newestIndex = activeIndices.last else {
      return .failure(.missingFrames)
    }

    let estimatedFrameDuration = estimatedFrameDuration(in: activeIndices)
    let latestRetainedFrameEnd = storage[newestIndex].timestamp + estimatedFrameDuration
    guard CMTimeCompare(latestRetainedFrameEnd, requestedEnd) >= 0 else {
      return .failure(
        .requestedEndNotCovered(
          requested: requestedEnd,
          latestRetainedFrameEnd: latestRetainedFrameEnd
        )
      )
    }
    guard
      let endIndex = activeIndices.reversed().first(where: {
        CMTimeCompare(storage[$0].timestamp, requestedEnd) <= 0
      })
    else {
      return .failure(.missingFrames)
    }

    var latestKeyFrameBeforeStart: Int?
    for index in headIndex...endIndex where storage[index].isKeyFrame {
      if CMTimeCompare(storage[index].timestamp, requestedStart) <= 0 {
        latestKeyFrameBeforeStart = index
      }
    }
    guard let startIndex = latestKeyFrameBeforeStart else {
      return .failure(
        .requestedStartNotCovered(
          requested: requestedStart,
          earliestRetained: storage[firstIndex].timestamp
        )
      )
    }

    let selectedFrames = Array(storage[startIndex...endIndex])
    guard selectedFrames.count >= 2 else { return .failure(.missingFrames) }
    return .success(H264ReplaySegment(configuration: configuration, frames: selectedFrames))
  }

  private mutating func trimToBounds() {
    guard let newest = storage.last else { return }

    while headIndex < storage.count {
      let oldest = storage[headIndex]
      let duration = CMTimeGetSeconds(newest.timestamp - oldest.timestamp)
      let exceedsDuration = duration.isFinite && duration > maximumDuration
      let exceedsBytes = retainedBytes > maximumBytes
      guard exceedsDuration || exceedsBytes else { break }

      retainedBytes -= oldest.payload.count
      headIndex += 1
    }

    // P-frames before the first retained IDR cannot be decoded. Dropping them
    // also guarantees every exported segment starts from a clean chain.
    while headIndex < storage.count, !storage[headIndex].isKeyFrame {
      let first = storage[headIndex]
      retainedBytes -= first.payload.count
      headIndex += 1
    }

    // Compact only occasionally, amortizing removal instead of doing an O(n)
    // shift for every expired frame once the replay window is full.
    if headIndex == storage.count {
      storage.removeAll(keepingCapacity: true)
      headIndex = 0
    } else if headIndex >= 256, headIndex * 2 >= storage.count {
      storage.removeFirst(headIndex)
      headIndex = 0
    }
  }

  private var activeIndices: Range<Int> {
    headIndex..<storage.count
  }

  private func estimatedFrameDuration(in indices: Range<Int>) -> CMTime {
    guard indices.count >= 2 else { return .zero }
    let intervals = zip(indices, indices.dropFirst()).compactMap { first, second -> Double? in
      let seconds = CMTimeGetSeconds(storage[second].timestamp - storage[first].timestamp)
      return seconds.isFinite && seconds > 0 ? seconds : nil
    }.sorted()
    guard !intervals.isEmpty else { return .zero }
    return CMTime(
      seconds: intervals[intervals.count / 2],
      preferredTimescale: 1_000_000
    )
  }
}
