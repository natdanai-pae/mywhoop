import Foundation
import XCTest

@testable import GolfTrace

final class GolfTraceSingleInstanceGuardTests: XCTestCase {
  func testSecondGuardIsBlockedUntilFirstGuardReleasesLock() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "GolfTraceSingleInstanceGuardTests-\(UUID().uuidString)", isDirectory: true)
    let lockURL = directory.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = GolfTraceSingleInstanceGuard(lockURL: lockURL)
    let second = GolfTraceSingleInstanceGuard(lockURL: lockURL)

    XCTAssertEqual(first.acquire(), .acquired)
    XCTAssertEqual(second.acquire(), .anotherInstanceRunning)

    first.release()

    XCTAssertEqual(second.acquire(), .acquired)
  }

  func testAcquiringTwiceKeepsTheHeldLock() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "GolfTraceSingleInstanceGuardTests-\(UUID().uuidString)", isDirectory: true)
    let guardUnderTest = GolfTraceSingleInstanceGuard(
      lockURL: directory.appendingPathComponent("instance.lock")
    )
    defer {
      guardUnderTest.release()
      try? FileManager.default.removeItem(at: directory)
    }

    XCTAssertEqual(guardUnderTest.acquire(), .acquired)
    XCTAssertEqual(guardUnderTest.acquire(), .acquired)
  }
}
