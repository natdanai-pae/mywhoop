import CoreMedia
import Foundation

/// One observation of a media clock against the Mac's monotonic clock.
///
/// Camera media time originates on the iPhone, while stage replay time is
/// relative to the first ScreenCaptureKit frame written to the movie. Pairing
/// both with the same Mac clock is the only safe way to translate between
/// those otherwise unrelated timelines.
struct SwingReplayClockAnchor: Codable, Equatable, Sendable {
  var mediaTimeSeconds: Double
  var monotonicTimeSeconds: Double

  var isValid: Bool {
    mediaTimeSeconds.isFinite && monotonicTimeSeconds.isFinite
  }
}

/// A bounded, thread-safe anchor collector suitable for decoder and capture
/// callbacks. It rejects clock regressions rather than silently joining two
/// source generations into one calibration.
final class SwingReplayClockAnchorBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private let minimumMediaInterval: Double
  private var anchors: [SwingReplayClockAnchor] = []

  init(capacity: Int = 240, minimumMediaInterval: Double = 1.0 / 30.0) {
    self.capacity = max(8, capacity)
    self.minimumMediaInterval = max(0, minimumMediaInterval)
    anchors.reserveCapacity(max(8, capacity))
  }

  @discardableResult
  func append(
    mediaTime: CMTime,
    monotonicTimeSeconds: Double = ProcessInfo.processInfo.systemUptime
  ) -> Bool {
    guard mediaTime.isValid else { return false }
    return append(
      SwingReplayClockAnchor(
        mediaTimeSeconds: CMTimeGetSeconds(mediaTime),
        monotonicTimeSeconds: monotonicTimeSeconds
      )
    )
  }

  @discardableResult
  func append(_ anchor: SwingReplayClockAnchor) -> Bool {
    guard anchor.isValid else { return false }
    lock.lock()
    defer { lock.unlock() }

    if let last = anchors.last {
      guard anchor.mediaTimeSeconds > last.mediaTimeSeconds,
        anchor.monotonicTimeSeconds > last.monotonicTimeSeconds
      else {
        return false
      }
      guard anchor.mediaTimeSeconds - last.mediaTimeSeconds >= minimumMediaInterval else {
        return false
      }
    }

    if anchors.count == capacity {
      // Trim in a batch so a high-rate callback never shifts the array for
      // every appended frame.
      anchors.removeFirst(max(1, capacity / 4))
    }
    anchors.append(anchor)
    return true
  }

  func snapshot() -> [SwingReplayClockAnchor] {
    lock.lock()
    defer { lock.unlock() }
    return anchors
  }

  func reset() {
    lock.lock()
    anchors.removeAll(keepingCapacity: true)
    lock.unlock()
  }
}

struct SwingReplayClockMapping: Codable, Equatable, Sendable {
  static let schemaVersion = "golftrace.replay-clock-map.v1"

  var schema: String = Self.schemaVersion
  var scale: Double
  var offsetSeconds: Double
  var uncertaintyMilliseconds: Double
  var cameraSampleCount: Int
  var replaySampleCount: Int
  var cameraMediaRangeSeconds: ClosedRange<Double>
  var replayMediaRangeSeconds: ClosedRange<Double>

  func replayTimeSeconds(forCameraTimeSeconds cameraTimeSeconds: Double) -> Double? {
    guard schema == Self.schemaVersion,
      cameraTimeSeconds.isFinite,
      cameraMediaRangeSeconds.contains(cameraTimeSeconds)
    else {
      return nil
    }
    let replayTime = scale * cameraTimeSeconds + offsetSeconds
    guard replayTime.isFinite,
      replayMediaRangeSeconds.contains(replayTime)
    else {
      return nil
    }
    return replayTime
  }
}

enum SwingReplayClockMapper {
  private struct Fit {
    var slope: Double
    var intercept: Double
    var rootMeanSquareResidual: Double
    var retained: [SwingReplayClockAnchor]
  }

  /// Fits `replay = scale * camera + offset` by composing two independently
  /// observed clocks through Mac monotonic time. A mapping is withheld when
  /// the observations do not span enough time or their measured uncertainty
  /// exceeds the seek-accuracy budget.
  static func makeMapping(
    cameraAnchors: [SwingReplayClockAnchor],
    replayAnchors: [SwingReplayClockAnchor],
    maximumUncertaintyMilliseconds: Double = 100
  ) -> SwingReplayClockMapping? {
    guard maximumUncertaintyMilliseconds.isFinite,
      maximumUncertaintyMilliseconds > 0,
      let cameraFit = robustFit(cameraAnchors),
      let replayFit = robustFit(replayAnchors),
      abs(replayFit.slope) > 0.000_001
    else {
      return nil
    }

    let scale = cameraFit.slope / replayFit.slope
    let offset = (cameraFit.intercept - replayFit.intercept) / replayFit.slope
    guard scale.isFinite,
      offset.isFinite,
      (0.90...1.10).contains(scale)
    else {
      return nil
    }

    let uncertaintySeconds =
      hypot(cameraFit.rootMeanSquareResidual, replayFit.rootMeanSquareResidual)
      / abs(replayFit.slope)
    let uncertaintyMilliseconds = uncertaintySeconds * 1_000
    guard uncertaintyMilliseconds.isFinite,
      uncertaintyMilliseconds <= maximumUncertaintyMilliseconds,
      let firstCamera = cameraFit.retained.first,
      let lastCamera = cameraFit.retained.last,
      let firstReplay = replayFit.retained.first,
      let lastReplay = replayFit.retained.last
    else {
      return nil
    }

    return SwingReplayClockMapping(
      scale: scale,
      offsetSeconds: offset,
      uncertaintyMilliseconds: uncertaintyMilliseconds,
      cameraSampleCount: cameraFit.retained.count,
      replaySampleCount: replayFit.retained.count,
      cameraMediaRangeSeconds: firstCamera.mediaTimeSeconds...lastCamera.mediaTimeSeconds,
      replayMediaRangeSeconds: firstReplay.mediaTimeSeconds...lastReplay.mediaTimeSeconds
    )
  }

  /// Fits one file-local media timeline against the Mac monotonic clock.
  ///
  /// Dual-source replay stores one calibration per independently encoded movie
  /// instead of making either movie the clock authority. This keeps camera-only
  /// persistence valid when Rapsodo is unavailable and lets History verify the
  /// common host-time overlap before enabling PIP.
  static func makeAssetClockCalibration(
    anchors: [SwingReplayClockAnchor],
    maximumUncertaintyMilliseconds: Double = 100
  ) -> SwingReplayAssetClockCalibration? {
    guard maximumUncertaintyMilliseconds.isFinite,
      maximumUncertaintyMilliseconds > 0,
      let fit = robustFit(anchors),
      let first = fit.retained.first,
      let last = fit.retained.last
    else {
      return nil
    }

    let uncertaintyMilliseconds = fit.rootMeanSquareResidual * 1_000
    guard uncertaintyMilliseconds.isFinite,
      uncertaintyMilliseconds <= maximumUncertaintyMilliseconds
    else {
      return nil
    }

    let calibration = SwingReplayAssetClockCalibration(
      scaleToMonotonicClock: fit.slope,
      monotonicClockOffsetSeconds: fit.intercept,
      uncertaintyMilliseconds: uncertaintyMilliseconds,
      sampleCount: fit.retained.count,
      mediaRangeSeconds: first.mediaTimeSeconds...last.mediaTimeSeconds
    )
    return calibration.validationIssues.isEmpty ? calibration : nil
  }

  /// Creates the persisted synchronization contract only when Rapsodo covers
  /// the camera-master interval (within the measured edge tolerance) and their
  /// combined uncertainty is within the product's 100 ms seek budget. A short
  /// overlap is not enough: it would advertise a PIP pair that disappears part
  /// way through the golfer's swing after a cable or mirroring interruption.
  static func makeSynchronization(
    cameraAnchors: [SwingReplayClockAnchor],
    rapsodoAnchors: [SwingReplayClockAnchor],
    maximumUncertaintyMilliseconds: Double = 100
  ) -> SwingReplaySynchronization? {
    guard
      let cameraClock = makeAssetClockCalibration(
        anchors: cameraAnchors,
        maximumUncertaintyMilliseconds: maximumUncertaintyMilliseconds
      ),
      let rapsodoClock = makeAssetClockCalibration(
        anchors: rapsodoAnchors,
        maximumUncertaintyMilliseconds: maximumUncertaintyMilliseconds
      ),
      let cameraHostStart = cameraClock.monotonicTimeSeconds(
        forMediaTimeSeconds: cameraClock.mediaRangeSeconds.lowerBound
      ),
      let cameraHostEnd = cameraClock.monotonicTimeSeconds(
        forMediaTimeSeconds: cameraClock.mediaRangeSeconds.upperBound
      ),
      let rapsodoHostStart = rapsodoClock.monotonicTimeSeconds(
        forMediaTimeSeconds: rapsodoClock.mediaRangeSeconds.lowerBound
      ),
      let rapsodoHostEnd = rapsodoClock.monotonicTimeSeconds(
        forMediaTimeSeconds: rapsodoClock.mediaRangeSeconds.upperBound
      )
    else {
      return nil
    }

    let overlapStart = max(cameraHostStart, rapsodoHostStart)
    let overlapEnd = min(cameraHostEnd, rapsodoHostEnd)
    let combinedUncertainty = hypot(
      cameraClock.uncertaintyMilliseconds,
      rapsodoClock.uncertaintyMilliseconds
    )
    let edgeToleranceSeconds = max(
      0.05,
      maximumSyncEdgeToleranceMilliseconds / 1_000
    )
    guard overlapStart.isFinite,
      overlapEnd.isFinite,
      overlapEnd - overlapStart >= 0.05,
      combinedUncertainty.isFinite,
      combinedUncertainty <= maximumUncertaintyMilliseconds,
      rapsodoHostStart <= cameraHostStart + edgeToleranceSeconds,
      rapsodoHostEnd >= cameraHostEnd - edgeToleranceSeconds
    else {
      return nil
    }

    let synchronization = SwingReplaySynchronization(
      cameraClock: cameraClock,
      rapsodoClock: rapsodoClock,
      timelineMonotonicRangeSeconds: overlapStart...overlapEnd,
      uncertaintyMilliseconds: combinedUncertainty
    )
    return synchronization.validationIssues.isEmpty ? synchronization : nil
  }

  /// Screen capture and camera anchors are sampled on independent callback
  /// queues. Two 100 ms seek budgets cover those two edges without accepting a
  /// materially truncated Rapsodo movie as a full synchronized pair.
  private static let maximumSyncEdgeToleranceMilliseconds = 200.0

  private static func robustFit(_ input: [SwingReplayClockAnchor]) -> Fit? {
    let valid = input.filter(\.isValid)
    let ordered = strictlyIncreasing(valid)
    guard ordered.count >= 4,
      Double(ordered.count) / Double(max(1, valid.count)) >= 0.80,
      let first = ordered.first,
      let last = ordered.last,
      last.mediaTimeSeconds - first.mediaTimeSeconds >= 0.15
    else {
      return nil
    }

    guard let initial = leastSquares(ordered) else { return nil }
    let residuals = ordered.map {
      abs($0.monotonicTimeSeconds - (initial.slope * $0.mediaTimeSeconds + initial.intercept))
    }
    let medianResidual = median(residuals)
    let absoluteDeviations = residuals.map { abs($0 - medianResidual) }
    let scaledMAD = 1.4826 * median(absoluteDeviations)
    // Five milliseconds keeps a perfectly stable short capture from rejecting
    // harmless scheduler noise when MAD is almost zero.
    let threshold = max(0.005, medianResidual + 4 * scaledMAD)
    let retained = zip(ordered, residuals).compactMap { anchor, residual in
      residual <= threshold ? anchor : nil
    }
    guard retained.count >= 4,
      Double(retained.count) / Double(ordered.count) >= 0.60,
      let final = leastSquares(retained),
      (0.85...1.15).contains(final.slope)
    else {
      return nil
    }
    return Fit(
      slope: final.slope,
      intercept: final.intercept,
      rootMeanSquareResidual: final.rootMeanSquareResidual,
      retained: retained
    )
  }

  private static func strictlyIncreasing(
    _ anchors: [SwingReplayClockAnchor]
  ) -> [SwingReplayClockAnchor] {
    var result: [SwingReplayClockAnchor] = []
    result.reserveCapacity(anchors.count)
    for anchor in anchors {
      if let last = result.last,
        anchor.mediaTimeSeconds <= last.mediaTimeSeconds
          || anchor.monotonicTimeSeconds <= last.monotonicTimeSeconds
      {
        continue
      }
      result.append(anchor)
    }
    return result
  }

  private static func leastSquares(_ anchors: [SwingReplayClockAnchor]) -> Fit? {
    guard anchors.count >= 2 else { return nil }
    let count = Double(anchors.count)
    let meanX = anchors.reduce(0) { $0 + $1.mediaTimeSeconds } / count
    let meanY = anchors.reduce(0) { $0 + $1.monotonicTimeSeconds } / count
    var numerator = 0.0
    var denominator = 0.0
    for anchor in anchors {
      let x = anchor.mediaTimeSeconds - meanX
      numerator += x * (anchor.monotonicTimeSeconds - meanY)
      denominator += x * x
    }
    guard denominator > 0 else { return nil }
    let slope = numerator / denominator
    let intercept = meanY - slope * meanX
    guard slope.isFinite, intercept.isFinite else { return nil }
    let squaredResiduals = anchors.reduce(0.0) { partial, anchor in
      let residual = anchor.monotonicTimeSeconds - (slope * anchor.mediaTimeSeconds + intercept)
      return partial + residual * residual
    }
    return Fit(
      slope: slope,
      intercept: intercept,
      rootMeanSquareResidual: sqrt(squaredResiduals / count),
      retained: anchors
    )
  }

  private static func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }
}
