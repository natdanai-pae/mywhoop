import CoreMedia
import Foundation

/// ค่าที่ใช้ตัดสินว่าเมื่อใดควรเริ่มและจบการบันทึกวงสวิงหนึ่งครั้ง
///
/// ทุกช่วงเวลาอ้างอิงจาก `CMTime` ของเฟรมกล้อง จึงไม่ขึ้นกับเวลาจริงของเครื่อง
/// และสามารถนำลำดับเฟรมเดิมกลับมาทดสอบซ้ำได้อย่างแน่นอน
struct SwingSessionDetectorConfiguration: Equatable {
  var stillSpeedThreshold: Double
  var swingStartSpeedThreshold: Double
  var armStillnessDuration: TimeInterval
  var startConfirmationDuration: TimeInterval
  var endStillnessDuration: TimeInterval
  var maximumSwingDuration: TimeInterval
  var preRollDuration: TimeInterval

  init(
    stillSpeedThreshold: Double = 0.10,
    swingStartSpeedThreshold: Double = 0.75,
    armStillnessDuration: TimeInterval = 0.35,
    startConfirmationDuration: TimeInterval = 0.04,
    endStillnessDuration: TimeInterval = 0.30,
    maximumSwingDuration: TimeInterval = 5.0,
    preRollDuration: TimeInterval = 0.15
  ) {
    self.stillSpeedThreshold = max(0, stillSpeedThreshold)
    self.swingStartSpeedThreshold = max(self.stillSpeedThreshold, swingStartSpeedThreshold)
    self.armStillnessDuration = max(0, armStillnessDuration)
    self.startConfirmationDuration = max(0, startConfirmationDuration)
    self.endStillnessDuration = max(0, endStillnessDuration)
    self.maximumSwingDuration = max(0.01, maximumSwingDuration)
    self.preRollDuration = max(0, preRollDuration)
  }
}

/// เหตุผลที่วงสวิงจบ ใช้แยกการจบตามปกติออกจากการตัดเมื่อใช้เวลานานเกินกำหนด
enum SwingSessionCompletionReason: Equatable {
  case returnedToStillness
  case timedOut

  var displayName: String {
    switch self {
    case .returnedToStillness:
      return "มือกลับมาอยู่นิ่ง"
    case .timedOut:
      return "ครบเวลาสูงสุด"
    }
  }
}

/// สถานะสั้น ๆ สำหรับแสดงบนหน้าจอ Mac
enum SwingSessionDetectorState: Equatable {
  case waitingForStillness
  case armed
  case confirmingSwing
  case swinging
  case completed

  var displayName: String {
    switch self {
    case .waitingForStillness:
      return "วางมือให้นิ่งเพื่อเตรียมจับวงสวิง"
    case .armed:
      return "พร้อมจับวงสวิง"
    case .confirmingSwing:
      return "กำลังตรวจสอบการเริ่มสวิง"
    case .swinging:
      return "กำลังบันทึกวงสวิง"
    case .completed:
      return "บันทึกวงสวิงแล้ว"
    }
  }
}

/// ผลสรุปของวงสวิงล่าสุดที่บันทึกจบแล้ว
struct SwingSessionSummary: Equatable {
  let duration: TimeInterval
  let peakNormalizedHandSpeed: Double
  let pathLength: Double
  let sampleCount: Int
  let pointHistory: [SwingMotionPoint]
  let completionReason: SwingSessionCompletionReason
  let startTimestamp: CMTime
  let endTimestamp: CMTime
}

/// แบ่งข้อมูลการเคลื่อนมือแบบต่อเนื่องออกเป็นวงสวิงทีละหนึ่งครั้ง
///
/// คลาสนี้ไม่มีนาฬิกาหรืองานเบื้องหลังของตัวเอง การเปลี่ยนสถานะทุกครั้งเกิดจาก
/// `SwingMotionFrame` ที่ส่งเข้า `consume(_:)` เท่านั้น
final class SwingSessionDetector {
  private struct Sample {
    let point: SwingMotionPoint
    let speed: Double?
  }

  let configuration: SwingSessionDetectorConfiguration

  private(set) var state: SwingSessionDetectorState = .waitingForStillness
  private(set) var statusText = SwingSessionDetectorState.waitingForStillness.displayName
  private(set) var lastCompletedSummary: SwingSessionSummary?

  private var lastProcessedTimestamp: CMTime?
  private var stillnessStartedAt: CMTime?
  private var fastMotionStartedAt: CMTime?
  private var endingStillnessStartedAt: CMTime?
  private var swingStartedAt: CMTime?
  private var preRollSamples: [Sample] = []
  private var activePoints: [SwingMotionPoint] = []
  private var activePeakSpeed = 0.0

  init(configuration: SwingSessionDetectorConfiguration = .init()) {
    self.configuration = configuration
  }

  /// ล้างทั้งการตรวจจับที่กำลังทำและผลสรุปครั้งก่อน เพื่อเริ่มใหม่จากศูนย์
  func reset() {
    resetActiveSession(preservingLastCompletedSummary: false)
  }

  /// เริ่มการตรวจจับใหม่เมื่อแหล่งภาพหยุดหรือต่อกลับมาอีกครั้ง
  ///
  /// เมื่อต่อสตรีมใหม่ timestamp อาจเริ่มนับจากศูนย์ จึงต้องล้างเวลาของเฟรมก่อนหน้า
  /// ค่าเริ่มต้นจะเก็บผลวงที่บันทึกเสร็จล่าสุดไว้ เพื่อไม่ให้ข้อมูลบนหน้าจอหายไป
  func resetActiveSession(preservingLastCompletedSummary: Bool = true) {
    state = .waitingForStillness
    statusText = state.displayName
    if !preservingLastCompletedSummary {
      lastCompletedSummary = nil
    }
    lastProcessedTimestamp = nil
    clearWorkingState()
  }

  /// รับผลวิเคราะห์การเคลื่อนมือหนึ่งเฟรม และคืนสถานะหลังประมวลผลเฟรมนั้น
  @discardableResult
  func consume(_ frame: SwingMotionFrame) -> SwingSessionDetectorState {
    guard let timestamp = usableTimestamp(frame.timestamp) else {
      if frame.handCenter == nil {
        switch state {
        case .waitingForStillness, .armed, .confirmingSwing:
          statusText = "ยังไม่พบมือ — จัดให้เห็นทั้งตัวในภาพ"
        case .swinging:
          statusText = "กำลังบันทึก — หามือไม่พบชั่วคราว"
        case .completed:
          break
        }
      } else {
        statusText = "กำลังรอเวลาอ้างอิงจากภาพ"
      }
      return state
    }

    if let lastProcessedTimestamp,
      CMTimeCompare(timestamp, lastProcessedTimestamp) <= 0
    {
      statusText = "ข้ามเฟรมที่เวลาซ้ำหรือย้อนกลับ"
      return state
    }
    lastProcessedTimestamp = timestamp

    // ให้สถานะ "บันทึกแล้ว" อยู่ครบหนึ่งเฟรม จากนั้นเตรียมตรวจวงสวิงถัดไปอัตโนมัติ
    // โดยยังเก็บ lastCompletedSummary ไว้ให้หน้าจอใช้งานต่อได้
    if state == .completed {
      state = .waitingForStillness
      clearWorkingState()
    }

    guard let handCenter = frame.handCenter else {
      handleMissingHand(at: timestamp)
      return state
    }

    let sample = Sample(
      point: SwingMotionPoint(normalizedLocation: handCenter, timestamp: timestamp),
      speed: usableSpeed(frame.normalizedHandSpeed)
    )

    switch state {
    case .waitingForStillness:
      appendToPreRoll(sample, referenceTimestamp: timestamp)
      updateWaitingForStillness(with: sample)

    case .armed, .confirmingSwing:
      appendToPreRoll(sample, referenceTimestamp: timestamp)
      updateArmed(with: sample)

    case .swinging:
      updateSwinging(with: sample)

    case .completed:
      // สถานะนี้ถูกเปลี่ยนเป็น waitingForStillness ด้านบนแล้ว
      break
    }

    return state
  }

  private func updateWaitingForStillness(with sample: Sample) {
    guard let speed = sample.speed, speed <= configuration.stillSpeedThreshold else {
      stillnessStartedAt = nil
      statusText = state.displayName
      return
    }

    if stillnessStartedAt == nil {
      stillnessStartedAt = sample.point.timestamp
    }

    guard
      elapsed(from: stillnessStartedAt, to: sample.point.timestamp)
        >= configuration.armStillnessDuration
    else {
      statusText = "กำลังรอให้มือนิ่งต่อเนื่อง"
      return
    }

    state = .armed
    fastMotionStartedAt = nil
    statusText = state.displayName
  }

  private func updateArmed(with sample: Sample) {
    guard let speed = sample.speed,
      speed >= configuration.swingStartSpeedThreshold
    else {
      fastMotionStartedAt = nil
      state = .armed
      statusText = state.displayName
      return
    }

    if fastMotionStartedAt == nil {
      fastMotionStartedAt = sample.point.timestamp
    }

    guard
      elapsed(from: fastMotionStartedAt, to: sample.point.timestamp)
        >= configuration.startConfirmationDuration
    else {
      state = .confirmingSwing
      statusText = state.displayName
      return
    }

    beginSwing(at: fastMotionStartedAt ?? sample.point.timestamp)
  }

  private func beginSwing(at startTimestamp: CMTime) {
    swingStartedAt = startTimestamp
    let retainedSamples = preRollSamples.filter { sample in
      elapsed(from: sample.point.timestamp, to: startTimestamp) <= configuration.preRollDuration
    }
    activePoints = retainedSamples.map(\.point)
    activePeakSpeed = retainedSamples.reduce(0) { currentPeak, sample in
      guard CMTimeCompare(sample.point.timestamp, startTimestamp) >= 0,
        let speed = sample.speed
      else {
        return currentPeak
      }
      return max(currentPeak, speed)
    }
    endingStillnessStartedAt = nil
    state = .swinging
    statusText = state.displayName
  }

  private func updateSwinging(with sample: Sample) {
    appendActivePoint(sample.point)
    if let speed = sample.speed {
      activePeakSpeed = max(activePeakSpeed, speed)
    }

    if elapsed(from: swingStartedAt, to: sample.point.timestamp)
      >= configuration.maximumSwingDuration
    {
      completeSwing(at: sample.point.timestamp, reason: .timedOut)
      return
    }

    guard let speed = sample.speed, speed <= configuration.stillSpeedThreshold else {
      endingStillnessStartedAt = nil
      statusText = state.displayName
      return
    }

    if endingStillnessStartedAt == nil {
      endingStillnessStartedAt = sample.point.timestamp
    }

    guard
      elapsed(from: endingStillnessStartedAt, to: sample.point.timestamp)
        >= configuration.endStillnessDuration
    else {
      statusText = "กำลังตรวจว่าจบวงสวิงแล้วหรือยัง"
      return
    }

    completeSwing(at: sample.point.timestamp, reason: .returnedToStillness)
  }

  private func handleMissingHand(at timestamp: CMTime) {
    switch state {
    case .waitingForStillness:
      stillnessStartedAt = nil
      statusText = "ยังไม่พบมือ — วางตัวให้อยู่ในภาพ"

    case .armed:
      fastMotionStartedAt = nil
      statusText = "พร้อมแล้ว แต่ขณะนี้ยังไม่พบมือ"

    case .confirmingSwing:
      fastMotionStartedAt = nil
      state = .armed
      statusText = "สัญญาณมือขาดช่วง — ยังรอการเริ่มสวิง"

    case .swinging:
      endingStillnessStartedAt = nil
      if elapsed(from: swingStartedAt, to: timestamp) >= configuration.maximumSwingDuration {
        completeSwing(at: timestamp, reason: .timedOut)
      } else {
        statusText = "กำลังบันทึกวงสวิง — หามือไม่พบชั่วคราว"
      }

    case .completed:
      break
    }
  }

  private func completeSwing(at endTimestamp: CMTime, reason: SwingSessionCompletionReason) {
    guard let startTimestamp = swingStartedAt else {
      state = .waitingForStillness
      clearWorkingState()
      statusText = state.displayName
      return
    }

    let duration = max(0, elapsed(from: startTimestamp, to: endTimestamp))
    lastCompletedSummary = SwingSessionSummary(
      duration: duration,
      peakNormalizedHandSpeed: activePeakSpeed,
      pathLength: pathLength(of: activePoints),
      sampleCount: activePoints.count,
      pointHistory: activePoints,
      completionReason: reason,
      startTimestamp: startTimestamp,
      endTimestamp: endTimestamp
    )
    state = .completed
    statusText = "บันทึกวงสวิงแล้ว · \(reason.displayName)"
  }

  private func appendToPreRoll(_ sample: Sample, referenceTimestamp: CMTime) {
    preRollSamples.append(sample)
    // ระหว่างรอยืนยัน ให้ยึดจุดที่เริ่มเคลื่อนเร็วเป็นหลัก เพื่อไม่ให้ pre-roll
    // ถูกตัดทิ้งเพียงเพราะเฟรมยืนยันมาถึงช้ากว่าค่าขั้นต่ำเล็กน้อย
    let trimReference = fastMotionStartedAt ?? referenceTimestamp
    preRollSamples.removeAll { existing in
      elapsed(from: existing.point.timestamp, to: trimReference) > configuration.preRollDuration
    }
  }

  private func appendActivePoint(_ point: SwingMotionPoint) {
    guard activePoints.last?.timestamp != point.timestamp else { return }
    activePoints.append(point)
  }

  private func clearWorkingState() {
    stillnessStartedAt = nil
    fastMotionStartedAt = nil
    endingStillnessStartedAt = nil
    swingStartedAt = nil
    preRollSamples.removeAll(keepingCapacity: true)
    activePoints.removeAll(keepingCapacity: true)
    activePeakSpeed = 0
  }

  private func pathLength(of points: [SwingMotionPoint]) -> Double {
    guard points.count > 1 else { return 0 }
    return zip(points, points.dropFirst()).reduce(0) { total, pair in
      let horizontal = Double(pair.1.normalizedLocation.x - pair.0.normalizedLocation.x)
      let vertical = Double(pair.1.normalizedLocation.y - pair.0.normalizedLocation.y)
      return total + (horizontal * horizontal + vertical * vertical).squareRoot()
    }
  }

  private func usableTimestamp(_ timestamp: CMTime?) -> CMTime? {
    guard let timestamp, timestamp.isValid else { return nil }
    let seconds = CMTimeGetSeconds(timestamp)
    return seconds.isFinite ? timestamp : nil
  }

  private func usableSpeed(_ speed: Double?) -> Double? {
    guard let speed, speed.isFinite, speed >= 0 else { return nil }
    return speed
  }

  private func elapsed(from start: CMTime?, to end: CMTime) -> TimeInterval {
    guard let start else { return 0 }
    let seconds = CMTimeGetSeconds(CMTimeSubtract(end, start))
    return seconds.isFinite ? max(0, seconds) : 0
  }
}
