import Foundation

/// จับคู่ผลลูกจาก MLM2PRO กับวงสวิงด้วยเวลาจริงของเครื่อง (`Date`)
///
/// ข้อมูลทั้งสองฝั่งอาจมาถึงก่อนหรือหลังกันได้ ตัวจับคู่จึงพักรายการที่ยังไม่มีคู่
/// ไว้คนละคิว แล้วเลือกคู่ที่เวลาใกล้ที่สุดภายในช่วงที่กำหนด หากใกล้เท่ากันจึงใช้
/// รายการที่มาถึงก่อน ผลลัพธ์จึงเหมือนเดิมทุกครั้งและไม่เปลี่ยนตามเวลาที่งานเขียนไฟล์ใช้
@MainActor
final class ShotSwingMatchController {
  struct Match: Equatable, Sendable {
    let recordID: UUID
    let swingOccurredAt: Date
    let shot: LaunchMonitorShot
    let matchedAt: Date
    let matchingWindowSeconds: TimeInterval

    var persistentMetadata: LaunchMonitorMatch {
      LaunchMonitorMatch(
        shot: shot,
        swingOccurredAt: swingOccurredAt,
        matchedAt: matchedAt,
        matchingWindowSeconds: matchingWindowSeconds
      )
    }
  }

  private struct PendingSwing: Equatable, Sendable {
    let recordID: UUID
    let occurredAt: Date
  }

  nonisolated static let defaultMatchingWindowSeconds: TimeInterval = 8
  nonisolated static let defaultMaximumPendingCount = 64

  let matchingWindowSeconds: TimeInterval
  let maximumPendingCount: Int

  private let clock: () -> Date
  private var pendingShots: [LaunchMonitorShot] = []
  private var pendingSwings: [PendingSwing] = []
  private var seenShotIDs: Set<UUID> = []
  private var seenDeviceShotIDsThisRun: Set<UInt64> = []
  private var seenRecordIDs: Set<UUID> = []

  var pendingShotCount: Int { pendingShots.count }
  var pendingSwingCount: Int { pendingSwings.count }

  init(
    matchingWindowSeconds: TimeInterval = ShotSwingMatchController
      .defaultMatchingWindowSeconds,
    maximumPendingCount: Int = ShotSwingMatchController.defaultMaximumPendingCount,
    restoredPendingShots: [LaunchMonitorShot] = [],
    restoredSeenShotIDs: Set<UUID> = [],
    clock: @escaping () -> Date = Date.init
  ) {
    precondition(matchingWindowSeconds >= 0, "matchingWindowSeconds must not be negative")
    self.matchingWindowSeconds = matchingWindowSeconds
    self.maximumPendingCount = max(1, maximumPendingCount)
    self.clock = clock

    var uniqueRestoredShots: [LaunchMonitorShot] = []
    var restoredIDs = restoredSeenShotIDs
    for shot in restoredPendingShots.sorted(by: Self.shotSortOrder) {
      guard restoredIDs.insert(shot.id).inserted else {
        continue
      }
      uniqueRestoredShots.append(shot)
    }
    pendingShots = Array(uniqueRestoredShots.suffix(self.maximumPendingCount))
    seenShotIDs = restoredIDs
  }

  /// รับค่าลูกหนึ่งครั้งและกัน packet ซ้ำด้วยรหัสลูกที่ MLM2PRO ส่งมา
  ///
  /// คืนคู่ทันทีเมื่อมีวงสวิงที่รออยู่ หรือพักค่าลูกไว้จนกว่าวงสวิงจะมาถึง
  @discardableResult
  func registerShot(_ shot: LaunchMonitorShot) -> Match? {
    guard !seenShotIDs.contains(shot.id),
      !seenDeviceShotIDsThisRun.contains(shot.deviceShotID)
    else { return nil }
    seenShotIDs.insert(shot.id)
    seenDeviceShotIDsThisRun.insert(shot.deviceShotID)

    if let swingIndex = closestPendingSwingIndex(to: shot.receivedAt) {
      let swing = pendingSwings.remove(at: swingIndex)
      return makeMatch(swing: swing, shot: shot)
    }

    pendingShots.append(shot)
    trimOldestItemsIfNeeded(&pendingShots)
    return nil
  }

  /// รับวงสวิงหนึ่งครั้งด้วยเวลาจริงที่บันทึกใน record
  ///
  /// คืนคู่ทันทีเมื่อมีค่าลูกที่รออยู่ หรือพักรหัสวงไว้จนกว่าค่าลูกจะมาถึง
  @discardableResult
  func registerSwing(_ record: SwingRecord) -> Match? {
    registerSwing(recordID: record.id, occurredAt: record.createdAt)
  }

  @discardableResult
  func registerSwing(recordID: UUID, occurredAt: Date) -> Match? {
    guard seenRecordIDs.insert(recordID).inserted else { return nil }

    let swing = PendingSwing(recordID: recordID, occurredAt: occurredAt)
    if let shotIndex = closestPendingShotIndex(to: occurredAt) {
      let shot = pendingShots.remove(at: shotIndex)
      return makeMatch(swing: swing, shot: shot)
    }

    pendingSwings.append(swing)
    trimOldestItemsIfNeeded(&pendingSwings)
    return nil
  }

  private func makeMatch(swing: PendingSwing, shot: LaunchMonitorShot) -> Match {
    Match(
      recordID: swing.recordID,
      swingOccurredAt: swing.occurredAt,
      shot: shot,
      matchedAt: clock(),
      matchingWindowSeconds: matchingWindowSeconds
    )
  }

  private func isWithinWindow(_ first: Date, _ second: Date) -> Bool {
    abs(first.timeIntervalSince(second)) <= matchingWindowSeconds
  }

  private func closestPendingSwingIndex(to shotDate: Date) -> Int? {
    closestIndex(in: pendingSwings.map(\.occurredAt), to: shotDate)
  }

  private func closestPendingShotIndex(to swingDate: Date) -> Int? {
    closestIndex(in: pendingShots.map(\.receivedAt), to: swingDate)
  }

  /// `min` เก็บสมาชิกตัวแรกเมื่อระยะเท่ากัน จึงใช้ลำดับ FIFO เป็นตัวตัดสินเสมอ
  private func closestIndex(in dates: [Date], to target: Date) -> Int? {
    dates.enumerated()
      .filter { isWithinWindow($0.element, target) }
      .min {
        let leftDistance = abs($0.element.timeIntervalSince(target))
        let rightDistance = abs($1.element.timeIntervalSince(target))
        if leftDistance != rightDistance { return leftDistance < rightDistance }
        return $0.offset < $1.offset
      }?
      .offset
  }

  private func trimOldestItemsIfNeeded<Element>(_ items: inout [Element]) {
    let overflow = items.count - maximumPendingCount
    if overflow > 0 {
      items.removeFirst(overflow)
    }
  }

  private static func shotSortOrder(_ lhs: LaunchMonitorShot, _ rhs: LaunchMonitorShot) -> Bool {
    if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt < rhs.receivedAt }
    if lhs.deviceShotID != rhs.deviceShotID { return lhs.deviceShotID < rhs.deviceShotID }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
