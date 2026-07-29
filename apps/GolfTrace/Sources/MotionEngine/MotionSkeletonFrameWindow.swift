import Foundation

/// An immutable, detector-neutral batch from one source stream generation.
///
/// The batch is safe to hand to future phase or metric analyzers without
/// exposing the live pipeline's mutable rolling storage.
struct MotionSkeletonFrameSnapshot: Equatable, Sendable {
  let streamSessionID: UUID
  let frames: [MotionSkeletonFrame]
  let maximumDurationSeconds: TimeInterval
  let capacity: Int

  var latestFrame: MotionSkeletonFrame? {
    frames.last
  }
}

/// Fixed-capacity rolling storage for neutral skeleton frames.
///
/// Six seconds matches the existing legacy metrics evidence window. The
/// 720-frame capacity is only an absolute safety ceiling for a source that can
/// approach 120 analyzed frames per second; source timestamps normally trim the
/// window before that ceiling is reached.
final class MotionSkeletonFrameWindow {
  static let defaultMaximumDurationSeconds: TimeInterval = 6
  static let defaultCapacity = 6 * 120

  let maximumDurationSeconds: TimeInterval
  let capacity: Int
  private(set) var streamSessionID: UUID

  private var storage: [MotionSkeletonFrame?]
  private var headIndex = 0
  private var frameCount = 0
  private var latestSourceTimeSeconds: Double?

  init(
    streamSessionID: UUID,
    maximumDurationSeconds: TimeInterval = defaultMaximumDurationSeconds,
    capacity: Int = defaultCapacity
  ) {
    self.streamSessionID = streamSessionID
    self.maximumDurationSeconds = max(0.1, maximumDurationSeconds)
    self.capacity = max(1, capacity)
    storage = Array(repeating: nil, count: self.capacity)
  }

  func reset(streamSessionID: UUID) {
    self.streamSessionID = streamSessionID
    storage = Array(repeating: nil, count: capacity)
    headIndex = 0
    frameCount = 0
    latestSourceTimeSeconds = nil
  }

  /// Returns `false` when a caller attempts to mix source generations or
  /// append an invalid/out-of-order source timestamp.
  @discardableResult
  func append(_ frame: MotionSkeletonFrame) -> Bool {
    let sourceTimeSeconds = frame.context.sourceTimeSeconds
    guard
      frame.context.streamSessionID == streamSessionID,
      sourceTimeSeconds.isFinite,
      sourceTimeSeconds >= 0,
      latestSourceTimeSeconds.map({ sourceTimeSeconds >= $0 }) ?? true
    else {
      return false
    }

    let insertionIndex = (headIndex + frameCount) % capacity
    if frameCount == capacity {
      storage[headIndex] = frame
      headIndex = (headIndex + 1) % capacity
    } else {
      storage[insertionIndex] = frame
      frameCount += 1
    }

    latestSourceTimeSeconds = sourceTimeSeconds
    trimBySourceTime(referenceTime: sourceTimeSeconds)
    return true
  }

  var latestFrame: MotionSkeletonFrame? {
    guard frameCount > 0 else { return nil }
    let index = (headIndex + frameCount - 1) % capacity
    return storage[index]
  }

  func snapshot() -> MotionSkeletonFrameSnapshot {
    var frames: [MotionSkeletonFrame] = []
    frames.reserveCapacity(frameCount)
    for offset in 0..<frameCount {
      let index = (headIndex + offset) % capacity
      if let frame = storage[index] {
        frames.append(frame)
      }
    }
    return MotionSkeletonFrameSnapshot(
      streamSessionID: streamSessionID,
      frames: frames,
      maximumDurationSeconds: maximumDurationSeconds,
      capacity: capacity
    )
  }

  private func trimBySourceTime(referenceTime: Double) {
    guard referenceTime.isFinite else { return }
    let cutoff = referenceTime - maximumDurationSeconds
    let boundaryTolerance = 0.000_000_001

    while frameCount > 0 {
      guard let oldestFrame = storage[headIndex] else {
        removeOldestFrame()
        continue
      }
      let oldestTime = oldestFrame.context.sourceTimeSeconds
      guard !oldestTime.isFinite || oldestTime < cutoff - boundaryTolerance else { return }
      removeOldestFrame()
    }
  }

  private func removeOldestFrame() {
    storage[headIndex] = nil
    headIndex = (headIndex + 1) % capacity
    frameCount -= 1
  }
}
