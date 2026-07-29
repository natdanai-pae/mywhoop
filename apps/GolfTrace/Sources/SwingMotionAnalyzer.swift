import CoreMedia
import Foundation
import Vision

/// A timestamped, Vision-normalized point used to draw the golfer's hand-center path.
///
/// `normalizedLocation` uses Vision's coordinate space: `(0, 0)` is the lower-left
/// corner of the source image and `(1, 1)` is the upper-right corner. It is deliberately
/// named hand-center rather than club head: a body-pose request does not detect the club.
struct SwingMotionPoint: Equatable {
  let normalizedLocation: CGPoint
  let timestamp: CMTime
}

/// A small, local-only classification of the wrist-derived motion currently being tracked.
enum SwingMotionState: String, Equatable {
  case unavailable
  case tracking
  case still
  case moving
  case swinging

  var displayName: String {
    switch self {
    case .unavailable:
      return "ยังไม่พบข้อมือ"
    case .tracking:
      return "กำลังติดตาม"
    case .still:
      return "อยู่นิ่ง"
    case .moving:
      return "กำลังเคลื่อน"
    case .swinging:
      return "กำลังสวิง"
    }
  }
}

/// The local motion result associated with one pose update.
///
/// This is intentionally a wrist/hand-center diagnostic, not a club-head estimate.
struct SwingMotionFrame: Equatable {
  /// The midpoint of the detected left and right wrists, or a single detected wrist.
  let handCenter: CGPoint?

  /// Bounded, timestamped history in Vision-normalized source coordinates.
  let pointHistory: [SwingMotionPoint]

  /// Hand-center distance traveled per second in normalized-image units, if measurable.
  let normalizedHandSpeed: Double?

  let state: SwingMotionState
  let timestamp: CMTime?
  let diagnosticText: String

  /// Suitable for an on-screen label; explicitly avoids implying club tracking.
  let traceLabel = "กึ่งกลางมือ · จุดกึ่งกลางข้อมือ · ยังไม่ใช่หัวไม้"

  var normalizedHandSpeedText: String {
    guard let normalizedHandSpeed else { return "กำลังวัดความเร็วมือ" }
    return String(format: "%.2f หน่วยภาพ/วินาที", normalizedHandSpeed)
  }
}

/// Derives a short, timestamp-bounded hand-center trail from local Vision body-pose data.
///
/// No video frame leaves the Mac: this type only consumes the `PoseFrame` already produced
/// by the app's local `VNDetectHumanBodyPoseRequest` pipeline.
final class SwingMotionAnalyzer {
  private let maximumHistoryDuration: TimeInterval
  private let maximumPointCount: Int
  private let positionSmoothingTimeConstant: TimeInterval
  private var history: [SwingMotionPoint] = []
  private var historyHeadIndex = 0
  private var smoothedHandCenter: CGPoint?
  private var smoothedHandCenterTimestamp: CMTime?
  private var latestHalfWristVector: CGVector?
  private var latestDualWristTimestamp: CMTime?

  private(set) var latestFrame: SwingMotionFrame

  init(
    maximumHistoryDuration: TimeInterval = 2.5,
    maximumPointCount: Int = 180,
    positionSmoothingTimeConstant: TimeInterval = 0.03
  ) {
    self.maximumHistoryDuration = max(0.1, maximumHistoryDuration)
    self.maximumPointCount = max(2, maximumPointCount)
    self.positionSmoothingTimeConstant = max(0, positionSmoothingTimeConstant)
    self.latestFrame = SwingMotionFrame(
      handCenter: nil,
      pointHistory: [],
      normalizedHandSpeed: nil,
      state: .unavailable,
      timestamp: nil,
      diagnosticText: "ยังไม่พบกึ่งกลางมือ — ขณะนี้ใช้จุดกึ่งกลางข้อมือ ไม่ใช่เส้นทางหัวไม้"
    )
  }

  func reset() {
    history.removeAll(keepingCapacity: true)
    historyHeadIndex = 0
    smoothedHandCenter = nil
    smoothedHandCenterTimestamp = nil
    latestHalfWristVector = nil
    latestDualWristTimestamp = nil
    latestFrame = SwingMotionFrame(
      handCenter: nil,
      pointHistory: [],
      normalizedHandSpeed: nil,
      state: .unavailable,
      timestamp: nil,
      diagnosticText: "เริ่มเส้นทางมือใหม่ — ขณะนี้ใช้จุดกึ่งกลางข้อมือ ไม่ใช่เส้นทางหัวไม้"
    )
  }

  /// Incorporates the latest pose and returns a UI-ready local motion diagnostic.
  @discardableResult
  func consume(
    _ pose: PoseFrame?,
    materializePointHistory: Bool = true
  ) -> SwingMotionFrame {
    guard let pose else {
      return publishUnavailable(
        timestamp: nil,
        materializePointHistory: materializePointHistory
      )
    }

    trimHistory(referenceTimestamp: pose.timestamp)

    guard let rawHandCenter = handCenter(in: pose) else {
      return publishUnavailable(
        timestamp: pose.timestamp,
        materializePointHistory: materializePointHistory
      )
    }

    let handCenter = smooth(rawHandCenter, at: pose.timestamp)
    let newPoint = SwingMotionPoint(normalizedLocation: handCenter, timestamp: pose.timestamp)
    let speed = appendAndMeasureSpeed(for: newPoint)
    let state = motionState(for: speed)
    let frame = SwingMotionFrame(
      handCenter: handCenter,
      pointHistory: materializePointHistory ? materializedHistory : [],
      normalizedHandSpeed: speed,
      state: state,
      timestamp: pose.timestamp,
      diagnosticText: diagnosticText(for: state, speed: speed)
    )
    latestFrame = frame
    return frame
  }

  /// An alias that reads naturally at the capture call site.
  @discardableResult
  func analyze(_ pose: PoseFrame?) -> SwingMotionFrame {
    consume(pose)
  }

  /// Produces the UI form only at the display publication boundary. Analysis
  /// can consume lean frames without retaining a copy-on-write history array
  /// for every Vision result.
  func uiSnapshot() -> SwingMotionFrame {
    let frame = latestFrame
    return SwingMotionFrame(
      handCenter: frame.handCenter,
      pointHistory: materializedHistory,
      normalizedHandSpeed: frame.normalizedHandSpeed,
      state: frame.state,
      timestamp: frame.timestamp,
      diagnosticText: frame.diagnosticText
    )
  }

  private func handCenter(in pose: PoseFrame) -> CGPoint? {
    let leftWrist = pose.joints[.leftWrist]?.location
    let rightWrist = pose.joints[.rightWrist]?.location

    switch (leftWrist, rightWrist) {
    case (let left?, let right?):
      let measuredHalfVector = CGVector(
        dx: (right.x - left.x) / 2,
        dy: (right.y - left.y) / 2
      )
      if let previous = latestHalfWristVector {
        // The wrist separation changes more slowly than Vision's occasional one-frame jitter.
        latestHalfWristVector = CGVector(
          dx: previous.dx * 0.7 + measuredHalfVector.dx * 0.3,
          dy: previous.dy * 0.7 + measuredHalfVector.dy * 0.3
        )
      } else {
        latestHalfWristVector = measuredHalfVector
      }
      latestDualWristTimestamp = pose.timestamp
      return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
    case (let left?, nil):
      if let halfVector = recentHalfWristVector(at: pose.timestamp) {
        return CGPoint(x: left.x + halfVector.dx, y: left.y + halfVector.dy)
      }
      return left
    case (nil, let right?):
      if let halfVector = recentHalfWristVector(at: pose.timestamp) {
        return CGPoint(x: right.x - halfVector.dx, y: right.y - halfVector.dy)
      }
      return right
    case (nil, nil):
      return nil
    }
  }

  /// Reconstructs the hand center briefly when Vision loses one wrist.
  /// This prevents the trace from jumping between a two-wrist midpoint and a single wrist.
  private func recentHalfWristVector(at timestamp: CMTime) -> CGVector? {
    guard let vector = latestHalfWristVector,
      let previousTimestamp = latestDualWristTimestamp,
      let currentTime = seconds(for: timestamp),
      let previousTime = seconds(for: previousTimestamp),
      currentTime - previousTime <= 0.25
    else {
      return nil
    }
    return vector
  }

  /// Applies a time-based low-pass filter. It removes frame-to-frame pose noise while
  /// keeping the delay nearly constant when the pose-analysis frame rate changes.
  private func smooth(_ rawPoint: CGPoint, at timestamp: CMTime) -> CGPoint {
    guard positionSmoothingTimeConstant > 0,
      let previousPoint = smoothedHandCenter,
      let previousTimestamp = smoothedHandCenterTimestamp,
      let currentTime = seconds(for: timestamp),
      let previousTime = seconds(for: previousTimestamp)
    else {
      smoothedHandCenter = rawPoint
      smoothedHandCenterTimestamp = timestamp
      return rawPoint
    }

    let elapsed = currentTime - previousTime
    guard elapsed > 0, elapsed <= 0.15 else {
      smoothedHandCenter = rawPoint
      smoothedHandCenterTimestamp = timestamp
      return rawPoint
    }

    let alpha = CGFloat(1 - exp(-elapsed / positionSmoothingTimeConstant))
    let filteredPoint = CGPoint(
      x: previousPoint.x + (rawPoint.x - previousPoint.x) * alpha,
      y: previousPoint.y + (rawPoint.y - previousPoint.y) * alpha
    )
    smoothedHandCenter = filteredPoint
    smoothedHandCenterTimestamp = timestamp
    return filteredPoint
  }

  private func appendAndMeasureSpeed(for newPoint: SwingMotionPoint) -> Double? {
    guard let newTime = seconds(for: newPoint.timestamp) else {
      return nil
    }

    guard let previousPoint = history.last,
      let previousTime = seconds(for: previousPoint.timestamp)
    else {
      history.append(newPoint)
      trimHistory(referenceTimestamp: newPoint.timestamp)
      trimHistoryToPointLimit()
      return nil
    }

    let elapsed = newTime - previousTime
    guard elapsed > 0 else {
      // A duplicate/out-of-order capture timestamp should not create a false speed spike.
      return nil
    }

    let horizontal = Double(newPoint.normalizedLocation.x - previousPoint.normalizedLocation.x)
    let vertical = Double(newPoint.normalizedLocation.y - previousPoint.normalizedLocation.y)
    let speed = (horizontal * horizontal + vertical * vertical).squareRoot() / elapsed
    history.append(newPoint)
    trimHistory(referenceTimestamp: newPoint.timestamp)
    trimHistoryToPointLimit()
    return speed
  }

  private func trimHistory(referenceTimestamp: CMTime) {
    guard let referenceTime = seconds(for: referenceTimestamp) else {
      trimHistoryToPointLimit()
      return
    }

    let cutoff = referenceTime - maximumHistoryDuration
    while historyHeadIndex < history.count {
      guard let pointTime = seconds(for: history[historyHeadIndex].timestamp),
        pointTime >= cutoff
      else {
        historyHeadIndex += 1
        continue
      }
      break
    }
    trimHistoryToPointLimit()
  }

  private func trimHistoryToPointLimit() {
    let activeCount = history.count - historyHeadIndex
    if activeCount > maximumPointCount {
      historyHeadIndex += activeCount - maximumPointCount
    }
    compactHistoryIfNeeded()
  }

  private func compactHistoryIfNeeded() {
    if historyHeadIndex == history.count {
      history.removeAll(keepingCapacity: true)
      historyHeadIndex = 0
    } else if historyHeadIndex >= 128, historyHeadIndex * 2 >= history.count {
      history.removeFirst(historyHeadIndex)
      historyHeadIndex = 0
    }
  }

  private var materializedHistory: [SwingMotionPoint] {
    guard historyHeadIndex < history.count else { return [] }
    return Array(history[historyHeadIndex...])
  }

  private func publishUnavailable(
    timestamp: CMTime?,
    materializePointHistory: Bool
  ) -> SwingMotionFrame {
    let frame = SwingMotionFrame(
      handCenter: nil,
      pointHistory: materializePointHistory ? materializedHistory : [],
      normalizedHandSpeed: nil,
      state: .unavailable,
      timestamp: timestamp,
      diagnosticText: "ยังไม่พบกึ่งกลางมือ — ขณะนี้ใช้จุดกึ่งกลางข้อมือ ไม่ใช่เส้นทางหัวไม้"
    )
    latestFrame = frame
    return frame
  }

  private func motionState(for speed: Double?) -> SwingMotionState {
    guard let speed else { return .tracking }
    switch speed {
    case ..<0.10:
      return .still
    case ..<0.75:
      return .moving
    default:
      return .swinging
    }
  }

  private func diagnosticText(for state: SwingMotionState, speed: Double?) -> String {
    let speedText = speed.map { String(format: "%.2f หน่วยภาพ/วินาที", $0) } ?? "กำลังวัดความเร็ว"
    return "กึ่งกลางมือ (เฉลี่ยข้อมือ ยังไม่ใช่หัวไม้) · \(state.displayName) · \(speedText)"
  }

  private func seconds(for timestamp: CMTime) -> Double? {
    guard timestamp.isValid else { return nil }
    let value = CMTimeGetSeconds(timestamp)
    return value.isFinite ? value : nil
  }
}
