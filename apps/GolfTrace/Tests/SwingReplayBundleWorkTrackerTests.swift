import XCTest

@testable import GolfTrace

@MainActor
final class SwingReplayBundleWorkTrackerTests: XCTestCase {
  func testFlushWaitsForAlreadyStartedWorkAndTerminationRejectsNewWork() async {
    let tracker = SwingReplayBundleWorkTracker()
    let gate = AsyncGate()

    XCTAssertTrue(
      tracker.start {
        await gate.wait()
      }
    )
    XCTAssertTrue(tracker.hasPendingWork)

    tracker.prepareForTermination()
    XCTAssertFalse(tracker.start {})

    let flush = Task { @MainActor in
      await tracker.flushPendingWork()
    }
    await Task.yield()
    XCTAssertFalse(flush.isCancelled)
    XCTAssertTrue(tracker.hasPendingWork)

    await gate.open()
    await flush.value
    XCTAssertFalse(tracker.hasPendingWork)
    XCTAssertEqual(tracker.pendingWorkCount, 0)
  }
}

private actor AsyncGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
