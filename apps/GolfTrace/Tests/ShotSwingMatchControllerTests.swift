import Foundation
import XCTest

@testable import GolfTrace

@MainActor
final class ShotSwingMatchControllerTests: XCTestCase {
  func testShotCanArriveBeforeSwingAndKeepsSignedWallClockOffset() throws {
    let matchedAt = date(500)
    let matcher = ShotSwingMatchController(clock: { matchedAt })
    let shot = makeShot(deviceShotID: 11, receivedAt: date(97))

    XCTAssertNil(matcher.registerShot(shot))
    let match = try XCTUnwrap(
      matcher.registerSwing(makeRecord(id: uuid(1), createdAt: date(100)))
    )

    XCTAssertEqual(match.recordID, uuid(1))
    XCTAssertEqual(match.shot, shot)
    XCTAssertEqual(match.matchedAt, matchedAt)
    XCTAssertEqual(match.persistentMetadata.timeOffsetSeconds, -3, accuracy: 0.000_001)
    XCTAssertEqual(matcher.pendingShotCount, 0)
    XCTAssertEqual(matcher.pendingSwingCount, 0)
  }

  func testSwingCanArriveBeforeShot() throws {
    let matcher = ShotSwingMatchController(clock: { self.date(600) })
    let record = makeRecord(id: uuid(2), createdAt: date(100))

    XCTAssertNil(matcher.registerSwing(record))
    let match = try XCTUnwrap(
      matcher.registerShot(makeShot(deviceShotID: 12, receivedAt: date(105)))
    )

    XCTAssertEqual(match.recordID, record.id)
    XCTAssertEqual(match.persistentMetadata.timeOffsetSeconds, 5, accuracy: 0.000_001)
    XCTAssertEqual(match.persistentMetadata.matchingWindowSeconds, 8)
    XCTAssertEqual(match.persistentMetadata.method, LaunchMonitorMatch.currentMethod)
  }

  func testEightSecondBoundaryMatchesButAnythingBeyondItDoesNot() {
    let matcher = ShotSwingMatchController()
    let boundaryRecord = makeRecord(id: uuid(3), createdAt: date(100))
    XCTAssertNil(matcher.registerSwing(boundaryRecord))

    let boundaryMatch = matcher.registerShot(
      makeShot(deviceShotID: 13, receivedAt: date(108))
    )
    XCTAssertEqual(boundaryMatch?.recordID, boundaryRecord.id)

    XCTAssertNil(matcher.registerSwing(makeRecord(id: uuid(4), createdAt: date(200))))
    XCTAssertNil(
      matcher.registerShot(
        makeShot(deviceShotID: 14, receivedAt: date(208.000_1))
      )
    )
    XCTAssertEqual(matcher.pendingSwingCount, 1)
    XCTAssertEqual(matcher.pendingShotCount, 1)
  }

  func testDuplicateDeviceShotIDIsIgnoredEvenWhenPacketHasAnotherUUID() {
    let matcher = ShotSwingMatchController()
    let original = makeShot(id: uuid(20), deviceShotID: 55, receivedAt: date(100))
    let duplicate = makeShot(id: uuid(21), deviceShotID: 55, receivedAt: date(101))

    XCTAssertNil(matcher.registerShot(original))
    XCTAssertNil(matcher.registerShot(duplicate))
    XCTAssertEqual(matcher.pendingShotCount, 1)

    let firstMatch = matcher.registerSwing(makeRecord(id: uuid(5), createdAt: date(100)))
    XCTAssertEqual(firstMatch?.shot.id, original.id)

    XCTAssertNil(matcher.registerSwing(makeRecord(id: uuid(6), createdAt: date(101))))
    XCTAssertEqual(matcher.pendingSwingCount, 1)
  }

  func testMultipleEligibleItemsUseNearestTimestamp() {
    let matcher = ShotSwingMatchController()
    let first = makeRecord(id: uuid(7), createdAt: date(100))
    let second = makeRecord(id: uuid(8), createdAt: date(101))
    XCTAssertNil(matcher.registerSwing(first))
    XCTAssertNil(matcher.registerSwing(second))

    let firstMatch = matcher.registerShot(makeShot(deviceShotID: 70, receivedAt: date(104)))
    let secondMatch = matcher.registerShot(makeShot(deviceShotID: 71, receivedAt: date(105)))

    XCTAssertEqual(firstMatch?.recordID, second.id)
    XCTAssertEqual(secondMatch?.recordID, first.id)
  }

  func testMissedSwingPairsWithNearestShotInsteadOfOldestEligibleShot() throws {
    let matcher = ShotSwingMatchController()
    let older = makeShot(deviceShotID: 72, receivedAt: date(100))
    let nearest = makeShot(deviceShotID: 73, receivedAt: date(105))
    XCTAssertNil(matcher.registerShot(older))
    XCTAssertNil(matcher.registerShot(nearest))

    let match = try XCTUnwrap(
      matcher.registerSwing(makeRecord(id: uuid(10), createdAt: date(105)))
    )
    XCTAssertEqual(match.shot, nearest)
    XCTAssertEqual(matcher.pendingShotCount, 1)
  }

  func testEqualTimestampDistanceUsesFIFOAsTieBreaker() throws {
    let matcher = ShotSwingMatchController()
    let first = makeShot(deviceShotID: 74, receivedAt: date(97))
    let second = makeShot(deviceShotID: 75, receivedAt: date(103))
    XCTAssertNil(matcher.registerShot(first))
    XCTAssertNil(matcher.registerShot(second))

    let match = try XCTUnwrap(
      matcher.registerSwing(makeRecord(id: uuid(11), createdAt: date(100)))
    )
    XCTAssertEqual(match.shot, first)
  }

  func testRestoredPendingShotAllowsNewSessionCounterCollisionButKeepsUUIDDeduplication() throws {
    let pending = makeShot(deviceShotID: 80, receivedAt: date(100))
    let alreadyMatchedID = uuid(22)
    let matcher = ShotSwingMatchController(
      restoredPendingShots: [pending],
      restoredSeenShotIDs: [alreadyMatchedID]
    )

    XCTAssertNil(
      matcher.registerShot(
        makeShot(id: alreadyMatchedID, deviceShotID: 79, receivedAt: date(100))
      )
    )
    let newSessionShot = makeShot(deviceShotID: 80, receivedAt: date(101))
    XCTAssertNil(matcher.registerShot(newSessionShot))
    XCTAssertNil(
      matcher.registerShot(makeShot(deviceShotID: 80, receivedAt: date(102)))
    )
    XCTAssertEqual(matcher.pendingShotCount, 2)

    let match = try XCTUnwrap(
      matcher.registerSwing(makeRecord(id: uuid(9), createdAt: date(103)))
    )
    XCTAssertEqual(match.shot, newSessionShot)
    XCTAssertEqual(matcher.pendingShotCount, 1)
  }

  private func makeRecord(id: UUID, createdAt: Date) -> SwingRecord {
    SwingRecord(
      id: id,
      createdAt: createdAt,
      sessionSummary: SwingRecord.SessionSummary(
        durationSeconds: 1,
        peakNormalizedHandSpeed: 2,
        normalizedPathLength: 0.5,
        sampleCount: 2,
        completionReason: "returnedToStillness",
        sourceStartTimestampSeconds: 10,
        sourceEndTimestampSeconds: 11
      ),
      tracePoints: []
    )
  }

  private func makeShot(
    id: UUID = UUID(),
    deviceShotID: UInt64,
    receivedAt: Date
  ) -> LaunchMonitorShot {
    LaunchMonitorShot(
      id: id,
      receivedAt: receivedAt,
      deviceShotID: deviceShotID,
      clubHeadSpeedMetersPerSecond: 42,
      ballSpeedMetersPerSecond: 61,
      horizontalLaunchAngleDegrees: -1.5,
      verticalLaunchAngleDegrees: 12.4,
      spinAxisDegrees: -3.2,
      totalSpinRPM: 2_450,
      rawMeasurement: Data([0x01, 0x02])
    )
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }

  private func uuid(_ suffix: UInt8) -> UUID {
    UUID(
      uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, suffix
      )
    )
  }
}
