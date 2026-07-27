import Foundation
import XCTest

@testable import GolfTrace

final class SwingReplayFileIOTests: XCTestCase {
  func testExecutorCommitsCopyAtomicallyAndPreservesDestinationOnCopyFailure() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = directory.appendingPathComponent("source.mov")
    let destination = directory.appendingPathComponent("destination.mov")
    let staging = directory.appendingPathComponent(".staging.mov")
    let expected = Data([1, 2, 3, 4, 5])
    try expected.write(to: source)
    try Data([9, 9]).write(to: destination)

    let executor = SwingReplayFileIOExecutor()
    try await executor.exportReplay(from: source, to: destination, stagingAt: staging)

    XCTAssertEqual(try Data(contentsOf: destination), expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

    let missingSource = directory.appendingPathComponent("missing.mov")
    do {
      try await executor.exportReplay(
        from: missingSource,
        to: destination,
        stagingAt: staging
      )
      XCTFail("A missing source must fail without touching the destination")
    } catch {}

    XCTAssertEqual(try Data(contentsOf: destination), expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
  }

  @MainActor
  func testUserSaveRunsOffMainAndLateCompletionDoesNotOverwriteNewReplayStatus() async throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recoveryDirectory = directory.appendingPathComponent("recovery", isDirectory: true)
    try FileManager.default.createDirectory(
      at: recoveryDirectory,
      withIntermediateDirectories: true
    )

    let firstReplay = directory.appendingPathComponent("first.mov")
    let newerReplay = directory.appendingPathComponent("newer.mov")
    let destination = directory.appendingPathComponent("saved.mov")
    try Data([1, 2, 3]).write(to: firstReplay)
    try Data([4, 5, 6]).write(to: newerReplay)

    let executor = BlockingReplayFileIOExecutor(blockExport: true)
    let controller = SwingReplayController(
      recoveryDirectory: recoveryDirectory,
      fileIOExecutor: executor
    )
    let firstRecordID = UUID()
    let newerRecordID = UUID()
    controller.showStoredReplay(firstReplay, recordID: firstRecordID)
    controller.saveReplay(to: destination)
    await executor.waitForExportStart()

    XCTAssertTrue(controller.isSavingReplay)
    XCTAssertTrue(controller.hasPendingExportWork)
    XCTAssertFalse(controller.canSaveReplay)

    controller.showStoredReplay(newerReplay, recordID: newerRecordID)
    await executor.releaseExport()
    await waitUntil { !controller.hasPendingExportWork }

    XCTAssertFalse(controller.isSavingReplay)
    XCTAssertTrue(controller.canSaveReplay)
    XCTAssertEqual(controller.replayURL, newerReplay)
    XCTAssertEqual(controller.replayRecordID, newerRecordID)
    XCTAssertEqual(controller.statusText, "กำลังแสดงคลิปจากประวัติ")
    XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
  }

  @MainActor
  func testCrossVolumeRecoveryCopiesInBackgroundAndFlushWaitsForIt() async throws {
    let recoveryDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let source = try makeManagedReplayFile(named: "cross-volume")
    defer { try? FileManager.default.removeItem(at: source) }

    let executor = BlockingReplayFileIOExecutor(blockRecovery: true)
    let controller = SwingReplayController(
      recoveryDirectory: recoveryDirectory,
      fileIOExecutor: executor,
      recoveryMover: { _, _ in throw ForcedMoveError() }
    )
    let recordID = UUID()
    let deliveredURL = controller.acceptStageRecording(source, recordID: recordID)

    XCTAssertEqual(deliveredURL, source)
    XCTAssertEqual(controller.replayURL, source)
    XCTAssertEqual(controller.replayRecordID, recordID)
    XCTAssertEqual(controller.currentReplayURL(for: recordID), source)
    XCTAssertTrue(controller.hasPendingExportWork)
    XCTAssertTrue(controller.isPreparingReplay)
    await executor.waitForRecoveryStart()

    var didFlush = false
    let flushTask = Task { @MainActor in
      await controller.flushPendingExports()
      didFlush = true
    }
    await Task.yield()
    XCTAssertFalse(didFlush)

    await executor.releaseRecovery()
    await waitUntil {
      controller.replayURL?.deletingLastPathComponent() == recoveryDirectory
        && !controller.hasPendingExportWork
    }
    await flushTask.value

    let recoveredURL = try XCTUnwrap(controller.replayURL)
    XCTAssertTrue(didFlush)
    XCTAssertEqual(controller.replayRecordID, recordID)
    XCTAssertEqual(controller.currentReplayURL(for: recordID), recoveredURL)
    XCTAssertEqual(try Data(contentsOf: recoveredURL), Data([0, 1, 2, 3]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

    // History received the original source before recovery finished. Its
    // callback must resolve through the alias and only then release that source.
    controller.acknowledgePersistence(of: deliveredURL, succeeded: true)
    await waitUntil { !controller.hasPendingExportWork }

    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
  }

  @MainActor
  func testSameVolumeRecoveryKeepsImmediateMoveFastPath() async throws {
    let recoveryDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let source = try makeManagedReplayFile(named: "same-volume")
    defer { try? FileManager.default.removeItem(at: source) }
    let executor = BlockingReplayFileIOExecutor(blockRecovery: true)

    let controller = SwingReplayController(
      recoveryDirectory: recoveryDirectory,
      fileIOExecutor: executor
    )
    let managedURL = controller.acceptStageRecording(source, recordID: UUID())

    XCTAssertEqual(managedURL.deletingLastPathComponent(), recoveryDirectory)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertFalse(controller.hasPendingExportWork)
    let recoveryCallCount = await executor.recoveryCallCount()
    XCTAssertEqual(recoveryCallCount, 0)
  }

  @MainActor
  func testFailedHistoryDuringFallbackLeavesRecoveryReplayForRelaunch() async throws {
    let recoveryDirectory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let source = try makeManagedReplayFile(named: "failed-history")
    defer { try? FileManager.default.removeItem(at: source) }
    let executor = BlockingReplayFileIOExecutor(blockRecovery: true)
    let recordID = UUID()

    let controller = SwingReplayController(
      recoveryDirectory: recoveryDirectory,
      fileIOExecutor: executor,
      recoveryMover: { _, _ in throw ForcedMoveError() }
    )
    let deliveredURL = controller.acceptStageRecording(source, recordID: recordID)
    await executor.waitForRecoveryStart()
    controller.acknowledgePersistence(of: deliveredURL, succeeded: false)

    await executor.releaseRecovery()
    await waitUntil { !controller.hasPendingExportWork }
    let recoveredURL = try XCTUnwrap(controller.replayURL)

    XCTAssertEqual(recoveredURL.deletingLastPathComponent(), recoveryDirectory)
    XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

    let relaunchedController = SwingReplayController(recoveryDirectory: recoveryDirectory)
    relaunchedController.cleanStaleTemporaryReplaysAfterExclusiveLaunch()
    var recovered: CompletedSwingReplay?
    relaunchedController.recoverPendingPersistence { recovered = $0 }

    XCTAssertEqual(recovered?.recordID, recordID)
    XCTAssertEqual(recovered?.url, recoveredURL)
    relaunchedController.acknowledgePersistence(of: recoveredURL, succeeded: true)
  }

  @MainActor
  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<500 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for replay file I/O", file: file, line: line)
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-ReplayIOTests-\(UUID().uuidString)", isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeManagedReplayFile(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-วงล่าสุด-\(name)-\(UUID().uuidString)")
      .appendingPathExtension("mov")
      .standardizedFileURL
    try Data([0, 1, 2, 3]).write(to: url)
    return url
  }
}

private struct ForcedMoveError: Error {}

private actor BlockingReplayFileIOExecutor: SwingReplayFileIOExecuting {
  private let fileManager = FileManager()
  private var shouldBlockExport: Bool
  private var shouldBlockRecovery: Bool
  private var exportCalls = 0
  private var recoveryCalls = 0
  private var exportStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var recoveryStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var exportRelease: CheckedContinuation<Void, Never>?
  private var recoveryRelease: CheckedContinuation<Void, Never>?

  init(blockExport: Bool = false, blockRecovery: Bool = false) {
    shouldBlockExport = blockExport
    shouldBlockRecovery = blockRecovery
  }

  func exportReplay(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) async throws {
    exportCalls += 1
    let waiters = exportStartWaiters
    exportStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if shouldBlockExport {
      await withCheckedContinuation { exportRelease = $0 }
    }
    try copyAtomically(from: sourceURL, to: destinationURL, stagingAt: stagingURL)
  }

  func recoverReplay(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) async throws {
    recoveryCalls += 1
    let waiters = recoveryStartWaiters
    recoveryStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if shouldBlockRecovery {
      await withCheckedContinuation { recoveryRelease = $0 }
    }
    try copyAtomically(from: sourceURL, to: destinationURL, stagingAt: stagingURL)
  }

  func removeItems(at urls: [URL]) {
    for url in urls {
      try? fileManager.removeItem(at: url)
    }
  }

  func waitForExportStart() async {
    guard exportCalls == 0 else { return }
    await withCheckedContinuation { exportStartWaiters.append($0) }
  }

  func waitForRecoveryStart() async {
    guard recoveryCalls == 0 else { return }
    await withCheckedContinuation { recoveryStartWaiters.append($0) }
  }

  func releaseExport() {
    shouldBlockExport = false
    exportRelease?.resume()
    exportRelease = nil
  }

  func releaseRecovery() {
    shouldBlockRecovery = false
    recoveryRelease?.resume()
    recoveryRelease = nil
  }

  func recoveryCallCount() -> Int {
    recoveryCalls
  }

  private func copyAtomically(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) throws {
    try Task.checkCancellation()
    try? fileManager.removeItem(at: stagingURL)
    defer { try? fileManager.removeItem(at: stagingURL) }
    try fileManager.copyItem(at: sourceURL, to: stagingURL)
    try Task.checkCancellation()
    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
    } else {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
  }
}
