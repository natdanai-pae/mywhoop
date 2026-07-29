import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import GolfTrace

final class SwingRecordStoreTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTraceStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }

  func testSaveAndLoadRoundTripsPlainSummaryTraceAndFlexibleMetadata() throws {
    let store = makeStore()
    let record = makeRecord(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      metadata: [
        "model": .string("gx10-v1"),
        "score": .number(87.5),
        "approved": .boolean(true),
        "tags": .array([.string("driver"), .string("down-the-line")]),
        "analysis": .object(["tempo": .number(3.1), "note": .null]),
      ]
    )

    try store.save(record)

    XCTAssertEqual(try store.load(id: record.id), record)
    XCTAssertEqual(try store.loadAll(), [record])
  }

  func testSaveOverwritesSameRecordAtomically() throws {
    let store = makeStore()
    var record = makeRecord(date: Date(timeIntervalSince1970: 100))
    try store.save(record)

    record.metadata["note"] = .string("เวอร์ชันใหม่")
    try store.save(record)

    XCTAssertEqual(try store.loadAll(), [record])
    let recordDirectory = store.directoryURL.appendingPathComponent(
      record.id.uuidString.lowercased(),
      isDirectory: true
    )
    let visibleFiles = try FileManager.default.contentsOfDirectory(
      at: recordDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    XCTAssertEqual(visibleFiles.map(\.lastPathComponent), ["record.json"])
  }

  func testLoadAllQuarantinesCorruptRecordAndKeepsValidHistoryWritable() throws {
    let store = makeStore()
    let validRecord = makeRecord(date: Date(timeIntervalSince1970: 100))
    try store.save(validRecord)

    let corruptID = UUID()
    let corruptDirectory = store.directoryURL.appendingPathComponent(
      corruptID.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: corruptDirectory,
      withIntermediateDirectories: true
    )
    try Data("not valid record json".utf8).write(
      to: corruptDirectory.appendingPathComponent("record.json"),
      options: .atomic
    )

    XCTAssertThrowsError(try store.loadAll())
    XCTAssertTrue(FileManager.default.fileExists(atPath: corruptDirectory.path))

    let recovered = try store.loadAllRecoveringInvalidRecords()

    XCTAssertEqual(recovered.records, [validRecord])
    XCTAssertEqual(recovered.invalidRecordCount, 1)
    XCTAssertEqual(recovered.quarantinedRecordCount, 1)
    XCTAssertGreaterThan(recovered.quarantinedBytes, 0)
    XCTAssertEqual(recovered.recoveryDirectoryURL, store.recoveryDirectoryURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: corruptDirectory.path))
    let quarantined = try FileManager.default.contentsOfDirectory(
      at: store.recoveryDirectoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    XCTAssertEqual(
      quarantined.filter { $0.lastPathComponent.hasPrefix("invalid-record-") }.count,
      1
    )

    let laterRecord = makeRecord(date: Date(timeIntervalSince1970: 200))
    try store.save(laterRecord)
    XCTAssertEqual(try store.loadAll().map(\.id), [laterRecord.id, validRecord.id])
  }

  func testRetentionKeepsNewestRecordsUpToConfiguredCount() throws {
    let store = makeStore(maximumRecordCount: 2)
    let oldest = makeRecord(date: Date(timeIntervalSince1970: 100))
    let middle = makeRecord(date: Date(timeIntervalSince1970: 200))
    let newest = makeRecord(date: Date(timeIntervalSince1970: 300))

    try store.save(oldest)
    try store.save(middle)
    try store.save(newest)

    XCTAssertEqual(try store.loadAll().map(\.id), [newest.id, middle.id])
    XCTAssertNil(try store.load(id: oldest.id))
  }

  func testStorageLimitRemovesOlderLargeReplay() throws {
    let store = makeStore(maximumStorageBytes: 12_000)
    let oldRecord = makeRecord(date: Date(timeIntervalSince1970: 100))
    try store.save(oldRecord)

    let largeReplay = try makeReplayFile(name: "old.mov", byteCount: 32_000)
    _ = try store.attachReplay(from: largeReplay, to: oldRecord)

    let newRecord = makeRecord(date: Date(timeIntervalSince1970: 200))
    try store.save(newRecord)

    XCTAssertEqual(try store.loadAll().map(\.id), [newRecord.id])
    XCTAssertNil(try store.load(id: oldRecord.id))
  }

  func testAttachReplayCopiesThroughStoreAndLeavesSourceByDefault() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let source = try makeReplayFile(name: "source.mov", byteCount: 4_096)

    let updated = try store.attachReplay(from: source, to: record)
    let replayURL = try XCTUnwrap(store.replayURL(for: updated))

    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: replayURL), try Data(contentsOf: source))
    XCTAssertEqual(try store.load(id: record.id), updated)
    XCTAssertTrue(replayURL.deletingLastPathComponent().path.hasPrefix(store.directoryURL.path))
  }

  func testAttachStageReplayPersistsPaneLayoutForTruthfulPIP() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let source = try makeReplayFile(name: "stage.mov", byteCount: 4_096)
    let layout = GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0.02, y: 0.08, width: 0.61, height: 0.86),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0.08, width: 0.34, height: 0.86)
    )

    let updated = try store.attachReplay(
      from: source,
      to: record,
      stagePaneLayout: layout
    )

    XCTAssertEqual(updated.stageReplayPaneLayout, layout)
    XCTAssertEqual(try store.load(id: record.id)?.stageReplayPaneLayout, layout)
  }

  func testRawReplayReplacementClearsPreviousStagePaneLayout() throws {
    let store = makeStore()
    let record = makeRecord()
    let stageSource = try makeReplayFile(name: "stage.mov", byteCount: 4_096)
    let rawSource = try makeReplayFile(name: "raw.mov", byteCount: 4_096)
    let layout = GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0.02, y: 0.08, width: 0.61, height: 0.86),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0.08, width: 0.34, height: 0.86)
    )
    let stageRecord = try store.attachReplay(
      from: stageSource,
      to: record,
      stagePaneLayout: layout
    )

    let rawRecord = try store.attachReplay(from: rawSource, to: stageRecord)

    XCTAssertNil(rawRecord.stageReplayPaneLayout)
    XCTAssertNil(try store.load(id: record.id)?.stageReplayPaneLayout)
  }

  func testAttachReplayMoveRemovesSourceOnlyAfterRecordIsSaved() throws {
    let store = makeStore()
    let record = makeRecord()
    let source = try makeReplayFile(name: "temporary.mp4", byteCount: 2_048)

    let updated = try store.attachReplay(
      from: source,
      to: record,
      transferMode: .move
    )

    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertNotNil(try store.load(id: updated.id))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try XCTUnwrap(store.replayURL(for: updated)).path
      )
    )
  }

  func testFailedReplacementKeepsPreviousReplayAndRecordUsable() throws {
    let store = makeStore()
    let record = makeRecord()
    let firstSource = try makeReplayFile(name: "first.mov", byteCount: 2_048)
    let recordWithReplay = try store.attachReplay(from: firstSource, to: record)
    let firstReplayURL = try XCTUnwrap(store.replayURL(for: recordWithReplay))
    let missingSource = temporaryDirectory.appendingPathComponent("missing.mov")

    XCTAssertThrowsError(
      try store.attachReplay(from: missingSource, to: recordWithReplay)
    )

    XCTAssertEqual(try store.load(id: record.id), recordWithReplay)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstReplayURL.path))
  }

  func testSuccessfulReplacementRemovesPreviousManagedReplay() throws {
    let store = makeStore()
    let record = makeRecord()
    let firstSource = try makeReplayFile(name: "replace-first.mov", byteCount: 1_024)
    let firstVersion = try store.attachReplay(from: firstSource, to: record)
    let firstReplayURL = try XCTUnwrap(store.replayURL(for: firstVersion))
    let secondSource = try makeReplayFile(name: "replace-second.mov", byteCount: 2_048)

    let secondVersion = try store.attachReplay(from: secondSource, to: firstVersion)
    let secondReplayURL = try XCTUnwrap(store.replayURL(for: secondVersion))

    XCTAssertFalse(FileManager.default.fileExists(atPath: firstReplayURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondReplayURL.path))
    XCTAssertEqual(try store.load(id: record.id), secondVersion)
  }

  func testDeleteRemovesRecordAndAttachedReplayAsOnePackage() throws {
    let store = makeStore()
    let record = makeRecord()
    let source = try makeReplayFile(name: "delete.mov", byteCount: 2_048)
    let updated = try store.attachReplay(from: source, to: record)
    let replayURL = try XCTUnwrap(store.replayURL(for: updated))

    try store.delete(updated)

    XCTAssertNil(try store.load(id: record.id))
    XCTAssertFalse(FileManager.default.fileExists(atPath: replayURL.path))
  }

  func testUnsafeReplayFilenameIsRejectedWithThaiError() throws {
    let store = makeStore()
    var record = makeRecord()
    record.replayFilename = "../outside.mov"

    XCTAssertThrowsError(try store.save(record)) { error in
      XCTAssertTrue(error.localizedDescription.contains("ชื่อไฟล์วิดีโอย้อนหลังไม่ปลอดภัย"))
    }
  }

  func testReservedRecordMetadataFilenameCannotBeUsedAsReplayOrDeletedOnAttach() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let recordDirectory = store.directoryURL.appendingPathComponent(
      record.id.uuidString.lowercased(),
      isDirectory: true
    )
    let recordURL = recordDirectory.appendingPathComponent("record.json")
    let originalRecordData = try Data(contentsOf: recordURL)
    let source = try makeReplayFile(name: "reserved-name.mov", byteCount: 1_024)
    var tamperedRecord = record
    tamperedRecord.replayFilename = "record.json"

    XCTAssertThrowsError(try store.attachReplay(from: source, to: tamperedRecord)) { error in
      guard let storeError = error as? SwingRecordStoreError,
        case .invalidReplayFilename = storeError
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    XCTAssertEqual(try Data(contentsOf: recordURL), originalRecordData)
    XCTAssertEqual(try store.load(id: record.id), record)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: recordDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ).map(\.lastPathComponent),
      ["record.json"]
    )
  }

  func testReplayURLRejectsSymlinkEscapeAndReplacementDoesNotTouchTarget() throws {
    let store = makeStore()
    var record = makeRecord()
    let replayFilename = "replay-\(UUID().uuidString.lowercased()).mov"
    record.replayFilename = replayFilename
    try store.save(record)
    let outside = try makeReplayFile(name: "outside-replay.mov", byteCount: 1_111)
    let outsideData = try Data(contentsOf: outside)
    let managedLink = store.directoryURL
      .appendingPathComponent(record.id.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(replayFilename)
    try FileManager.default.createSymbolicLink(
      at: managedLink,
      withDestinationURL: outside
    )

    XCTAssertNil(try store.replayURL(for: record))

    let replacement = try makeReplayFile(name: "replacement.mov", byteCount: 2_222)
    let updated = try store.attachReplay(from: replacement, to: record)
    XCTAssertEqual(try Data(contentsOf: outside), outsideData)
    XCTAssertNotNil(try store.replayURL(for: updated))
  }

  func testReplayURLDoesNotAdvertiseDirectoryAsReadyReplay() throws {
    let store = makeStore()
    var record = makeRecord()
    let replayFilename = "replay-\(UUID().uuidString.lowercased()).mov"
    record.replayFilename = replayFilename
    try store.save(record)
    let replayDirectory = store.directoryURL
      .appendingPathComponent(record.id.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(replayFilename, isDirectory: true)
    try FileManager.default.createDirectory(
      at: replayDirectory,
      withIntermediateDirectories: false
    )

    XCTAssertNil(try store.replayURL(for: record))
  }

  func testReplayFilenameCannotCollideWithStoryboardFilename() throws {
    let store = makeStore()
    let collidingFilename =
      "storyboard-address-\(UUID().uuidString.lowercased()).jpg"
    var artifacts = makeArtifacts()
    artifacts.keyframes[0].state = .available
    artifacts.keyframes[0].filename = collidingFilename
    var record = makeRecord(artifacts: artifacts)
    record.replayFilename = collidingFilename

    XCTAssertThrowsError(try store.save(record)) { error in
      guard let storeError = error as? SwingRecordStoreError,
        case .invalidReplayFilename = storeError
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testLegacyManagedReplayFilenameRemainsReadable() throws {
    let store = makeStore()
    var record = makeRecord()
    record.replayFilename = "replay.mov"
    try store.save(record)
    let replayURL = store.directoryURL
      .appendingPathComponent(record.id.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("replay.mov")
    try Data(repeating: 0x42, count: 512).write(to: replayURL, options: .atomic)

    XCTAssertEqual(try store.load(id: record.id), record)
    XCTAssertEqual(try store.replayURL(for: record), replayURL.standardizedFileURL)
  }

  func testDefaultStorageBudgetIsFourGiBForMultiTakeSessions() {
    XCTAssertEqual(SwingRecordStore.defaultMaximumRecordCount, 20)
    XCTAssertEqual(SwingRecordStore.defaultMaximumStorageBytes, 4_294_967_296)
  }

  func testAttachCameraOnlyBundlePreservesLegacyReplayAndCommitsVerifiedMetadata() throws {
    let store = makeStore()
    let record = makeRecord()
    let legacySource = try makeReplayFile(name: "legacy-stage.mov", byteCount: 1_024)
    let recordWithLegacy = try store.attachReplay(from: legacySource, to: record)
    let legacyURL = try XCTUnwrap(store.replayURL(for: recordWithLegacy))
    let cameraSource = try makeReplayFile(name: "camera-master.mov", byteCount: 4_096)

    let updated = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: cameraSource,
        bundle: makeReplayBundle(),
        to: record.id
      )
    )
    let resolved = try XCTUnwrap(store.replayBundleURLs(for: updated))

    XCTAssertEqual(updated.schemaVersion, SwingRecord.currentSchemaVersion)
    XCTAssertEqual(updated.replayFilename, recordWithLegacy.replayFilename)
    XCTAssertEqual(try store.replayURL(for: updated), legacyURL)
    XCTAssertEqual(resolved.status, .cameraSaved)
    XCTAssertNil(resolved.rapsodoURL)
    XCTAssertNil(resolved.synchronization)
    XCTAssertEqual(try Data(contentsOf: resolved.cameraURL), try Data(contentsOf: cameraSource))
    XCTAssertEqual(updated.replayBundle?.camera.filename, "camera.mov")
    XCTAssertEqual(updated.replayBundle?.camera.byteCount, 4_096)
    XCTAssertEqual(updated.replayBundle?.camera.contentSHA256?.count, 64)
    XCTAssertEqual(try store.load(id: record.id), updated)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: resolved.cameraURL.deletingLastPathComponent()
          .appendingPathComponent("bundle.json").path
      )
    )
  }

  func testAttachSynchronizedPairResolvesDistinctRoleBasedAssets() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let cameraSource = try makeReplayFile(name: "pair-camera.mov", byteCount: 2_048)
    let rapsodoSource = try makeReplayFile(name: "pair-rapsodo.mp4", byteCount: 3_072)

    let updated = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: cameraSource,
        rapsodoSourceURL: rapsodoSource,
        bundle: makeReplayBundle(includeRapsodo: true, synchronized: true),
        to: record.id
      )
    )
    let resolved = try XCTUnwrap(store.replayBundleURLs(for: updated))
    let rapsodoURL = try XCTUnwrap(resolved.rapsodoURL)

    XCTAssertEqual(resolved.status, .synchronizedPair)
    XCTAssertNotNil(resolved.synchronization)
    XCTAssertTrue(resolved.bundle.isSynchronizedPair)
    XCTAssertNotEqual(resolved.cameraURL, rapsodoURL)
    XCTAssertEqual(try Data(contentsOf: resolved.cameraURL), try Data(contentsOf: cameraSource))
    XCTAssertEqual(try Data(contentsOf: rapsodoURL), try Data(contentsOf: rapsodoSource))
    XCTAssertEqual(updated.replayBundle?.camera.role, .swingCamera)
    XCTAssertEqual(updated.replayBundle?.rapsodo?.role, .rapsodoScreen)
  }

  func testMissingRapsodoSourceStillCommitsCameraMaster() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let cameraSource = try makeReplayFile(name: "camera-survives.mov", byteCount: 2_048)
    let missingRapsodo = temporaryDirectory.appendingPathComponent("missing-rapsodo.mp4")

    let updated = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: cameraSource,
        rapsodoSourceURL: missingRapsodo,
        bundle: makeReplayBundle(includeRapsodo: true, synchronized: true),
        to: record.id
      )
    )
    let resolved = try XCTUnwrap(store.replayBundleURLs(for: updated))

    XCTAssertEqual(resolved.status, .cameraSaved)
    XCTAssertNil(updated.replayBundle?.rapsodo)
    XCTAssertNil(updated.replayBundle?.synchronization)
    XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.cameraURL.path))
    XCTAssertEqual(try Data(contentsOf: resolved.cameraURL), try Data(contentsOf: cameraSource))
  }

  func testDamagedRapsodoCompanionDegradesAvailabilityWithoutHidingCamera() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let cameraSource = try makeReplayFile(name: "damage-camera.mov", byteCount: 2_048)
    let rapsodoSource = try makeReplayFile(name: "damage-rapsodo.mov", byteCount: 2_048)
    let updated = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: cameraSource,
        rapsodoSourceURL: rapsodoSource,
        bundle: makeReplayBundle(includeRapsodo: true, synchronized: true),
        to: record.id
      )
    )
    let complete = try XCTUnwrap(store.replayBundleURLs(for: updated))
    try FileManager.default.removeItem(at: XCTUnwrap(complete.rapsodoURL))

    let degraded = try XCTUnwrap(store.replayBundleURLs(for: updated))

    XCTAssertEqual(degraded.status, .cameraSaved)
    XCTAssertNil(degraded.rapsodoURL)
    XCTAssertNil(degraded.synchronization)
    XCTAssertTrue(FileManager.default.fileExists(atPath: degraded.cameraURL.path))
  }

  func testBundleReplacementRemovesPreviousGenerationAsOneDirectory() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let firstCamera = try makeReplayFile(name: "first-camera.mov", byteCount: 1_024)
    let firstRapsodo = try makeReplayFile(name: "first-rapsodo.mov", byteCount: 1_024)
    let firstRecord = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: firstCamera,
        rapsodoSourceURL: firstRapsodo,
        bundle: makeReplayBundle(includeRapsodo: true, synchronized: true),
        to: record.id
      )
    )
    let firstURLs = try XCTUnwrap(store.replayBundleURLs(for: firstRecord))
    let firstGenerationDirectory = firstURLs.cameraURL.deletingLastPathComponent()
    let secondCamera = try makeReplayFile(name: "second-camera.mov", byteCount: 2_048)

    let secondRecord = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: secondCamera,
        bundle: makeReplayBundle(),
        to: record.id
      )
    )
    let secondURLs = try XCTUnwrap(store.replayBundleURLs(for: secondRecord))

    XCTAssertFalse(FileManager.default.fileExists(atPath: firstGenerationDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondURLs.cameraURL.path))
    XCTAssertEqual(try store.load(id: record.id), secondRecord)
  }

  func testMissingCameraKeepsPreviousBundleAndRecordUntouched() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let firstCamera = try makeReplayFile(name: "stable-camera.mov", byteCount: 2_048)
    let firstRecord = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: firstCamera,
        bundle: makeReplayBundle(),
        to: record.id
      )
    )
    let firstURLs = try XCTUnwrap(store.replayBundleURLs(for: firstRecord))
    let missingCamera = temporaryDirectory.appendingPathComponent("missing-camera.mov")

    XCTAssertThrowsError(
      try store.attachReplayBundle(
        cameraSourceURL: missingCamera,
        bundle: makeReplayBundle(),
        to: record.id
      )
    )

    XCTAssertEqual(try store.load(id: record.id), firstRecord)
    XCTAssertTrue(FileManager.default.fileExists(atPath: firstURLs.cameraURL.path))
  }

  func testNewStoreRemovesInterruptedAndUnreferencedBundleDirectoriesOnly() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let camera = try makeReplayFile(name: "reconciled-camera.mov", byteCount: 1_024)
    let committed = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: camera,
        bundle: makeReplayBundle(),
        to: record.id
      )
    )
    let committedURLs = try XCTUnwrap(store.replayBundleURLs(for: committed))
    let recordDirectory = committedURLs.cameraURL.deletingLastPathComponent()
      .deletingLastPathComponent()
    let interrupted = recordDirectory.appendingPathComponent(
      ".attaching-replay-bundle-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    let orphan = recordDirectory.appendingPathComponent(
      "replay-bundle-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)

    let reopenedStore = SwingRecordStore(directoryURL: store.directoryURL)
    _ = try reopenedStore.loadAll()

    XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    XCTAssertNotNil(try reopenedStore.replayBundleURLs(for: committed))
  }

  func testCorruptRecordPreservesBundleUntilWholePackageIsQuarantined() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let camera = try makeReplayFile(name: "recovery-camera.mov", byteCount: 2_048)
    let committed = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: camera,
        bundle: makeReplayBundle(),
        to: record.id
      )
    )
    let committedURLs = try XCTUnwrap(store.replayBundleURLs(for: committed))
    let generationDirectory = committedURLs.cameraURL.deletingLastPathComponent()
    let recordDirectory = generationDirectory.deletingLastPathComponent()
    try Data("corrupt record metadata".utf8).write(
      to: recordDirectory.appendingPathComponent("record.json"),
      options: .atomic
    )

    let reopenedStore = SwingRecordStore(directoryURL: store.directoryURL)
    XCTAssertThrowsError(try reopenedStore.loadAll())
    XCTAssertTrue(FileManager.default.fileExists(atPath: generationDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: committedURLs.cameraURL.path))

    let recovered = try reopenedStore.loadAllRecoveringInvalidRecords()
    XCTAssertEqual(recovered.invalidRecordCount, 1)
    XCTAssertEqual(recovered.quarantinedRecordCount, 1)
    XCTAssertGreaterThan(recovered.quarantinedBytes, 2_048)
    XCTAssertFalse(FileManager.default.fileExists(atPath: recordDirectory.path))
    let recoveryEnumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: recovered.recoveryDirectoryURL,
        includingPropertiesForKeys: nil
      )
    )
    let recoveredFilenames = recoveryEnumerator.compactMap { ($0 as? URL)?.lastPathComponent }
    XCTAssertTrue(recoveredFilenames.contains("camera.mov"))
    XCTAssertTrue(recoveredFilenames.contains("bundle.json"))
  }

  func testRetentionKeepsNewestBundleWholeAndDeletesOlderPackageWhole() throws {
    let store = makeStore(maximumStorageBytes: 1)
    let oldRecord = makeRecord(date: Date(timeIntervalSince1970: 100))
    try store.save(oldRecord)
    let camera = try makeReplayFile(name: "retention-camera.mov", byteCount: 8_192)
    let rapsodo = try makeReplayFile(name: "retention-rapsodo.mov", byteCount: 8_192)
    let oldWithBundle = try XCTUnwrap(
      store.attachReplayBundle(
        cameraSourceURL: camera,
        rapsodoSourceURL: rapsodo,
        bundle: makeReplayBundle(includeRapsodo: true, synchronized: true),
        to: oldRecord.id
      )
    )
    let oldURLs = try XCTUnwrap(store.replayBundleURLs(for: oldWithBundle))
    let oldPackage = oldURLs.cameraURL.deletingLastPathComponent().deletingLastPathComponent()

    XCTAssertTrue(FileManager.default.fileExists(atPath: oldURLs.cameraURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(oldURLs.rapsodoURL).path))

    let newRecord = makeRecord(date: Date(timeIntervalSince1970: 200))
    try store.save(newRecord)

    XCTAssertEqual(try store.loadAll().map(\.id), [newRecord.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldPackage.path))
  }

  func testReplayURLDoesNotWaitForLargeReplayCopyMutationLock() throws {
    let storageURL = temporaryDirectory.appendingPathComponent("Swings", isDirectory: true)
    let setupStore = SwingRecordStore(directoryURL: storageURL)
    var record = makeRecord()
    record.replayFilename = "replay.mov"
    try setupStore.save(record)

    let existingReplayURL =
      storageURL
      .appendingPathComponent(record.id.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent("replay.mov")
    try Data(repeating: 0x31, count: 512).write(
      to: existingReplayURL,
      options: .atomic
    )

    let blockingFileManager = BlockingReplayCopyFileManager()
    let store = SwingRecordStore(
      directoryURL: storageURL,
      fileManager: blockingFileManager
    )
    let replacement = try makeReplayFile(name: "large-copy.mov", byteCount: 4_096)
    let recordForAttach = record
    let attachFinished = expectation(description: "attach replay finishes")
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        _ = try store.attachReplay(from: replacement, to: recordForAttach)
      } catch {
        XCTFail("attachReplay failed: \(error)")
      }
      attachFinished.fulfill()
    }

    XCTAssertEqual(
      blockingFileManager.copyStarted.wait(timeout: .now() + 2),
      .success
    )
    // If replayURL still takes the mutation lock it cannot return until this
    // delayed release, making the elapsed-time assertion fail deterministically.
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
      blockingFileManager.allowCopy.signal()
    }

    let lookupStarted = CFAbsoluteTimeGetCurrent()
    XCTAssertEqual(try store.replayURL(for: record), existingReplayURL.standardizedFileURL)
    let lookupDuration = CFAbsoluteTimeGetCurrent() - lookupStarted
    XCTAssertLessThan(lookupDuration, 0.2)

    wait(for: [attachFinished], timeout: 2)
    XCTAssertNotEqual(try store.load(id: record.id)?.replayFilename, "replay.mov")
  }

  func testAttachLaunchMonitorMatchPreservesReplayAndExistingMetadata() throws {
    let store = makeStore()
    let record = makeRecord(metadata: ["note": .string("เก็บค่านี้ไว้")])
    try store.save(record)
    let replaySource = try makeReplayFile(name: "launch-monitor.mov", byteCount: 2_048)
    let recordWithReplay = try store.attachReplay(from: replaySource, to: record)
    let replayURL = try XCTUnwrap(store.replayURL(for: recordWithReplay))
    let match = makeLaunchMonitorMatch(deviceShotID: 501)

    let updated = try XCTUnwrap(
      store.attachLaunchMonitorMatch(match, to: record.id)
    )

    XCTAssertEqual(updated.schemaVersion, SwingRecord.currentSchemaVersion)
    XCTAssertEqual(updated.launchMonitorMatch, match)
    XCTAssertEqual(updated.replayFilename, recordWithReplay.replayFilename)
    XCTAssertEqual(updated.metadata["note"], .string("เก็บค่านี้ไว้"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: replayURL.path))
    XCTAssertEqual(try store.load(id: record.id), updated)
  }

  func testSecondLaunchMonitorMatchDoesNotOverwriteFirstShot() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let first = makeLaunchMonitorMatch(deviceShotID: 601)
    let second = makeLaunchMonitorMatch(deviceShotID: 602)

    _ = try store.attachLaunchMonitorMatch(first, to: record.id)
    let unchanged = try XCTUnwrap(
      store.attachLaunchMonitorMatch(second, to: record.id)
    )

    XCTAssertEqual(unchanged.launchMonitorMatch, first)
    XCTAssertEqual(try store.load(id: record.id)?.launchMonitorMatch, first)
  }

  func testPendingLaunchMonitorShotPersistsAndDeduplicatesAcrossStoreInstances() throws {
    let store = makeStore()
    let shot = makeLaunchMonitorShot(deviceShotID: 701)

    XCTAssertTrue(try store.savePendingLaunchMonitorShot(shot))
    XCTAssertFalse(try store.savePendingLaunchMonitorShot(shot))

    let reloadedStore = makeStore()
    XCTAssertEqual(try reloadedStore.loadPendingLaunchMonitorShots(), [shot])
  }

  func testPendingShotsKeepNewUUIDWhenSessionCounterRestartsAtSameDeviceShotID() throws {
    let store = makeStore()
    let previousSession = makeLaunchMonitorShot(deviceShotID: 704)
    let nextSession = makeLaunchMonitorShot(
      deviceShotID: 704,
      receivedAt: previousSession.receivedAt.addingTimeInterval(10)
    )

    XCTAssertTrue(try store.savePendingLaunchMonitorShot(previousSession))
    XCTAssertTrue(try store.savePendingLaunchMonitorShot(nextSession))
    XCTAssertEqual(
      try store.loadPendingLaunchMonitorShots().map(\.id),
      [previousSession.id, nextSession.id]
    )
  }

  func testReconcileAttachesPendingShotAndRemovesItOnlyAfterRecordIsSaved() throws {
    let store = makeStore()
    let record = makeRecord(date: Date(timeIntervalSince1970: 1_700_000_000))
    let shot = makeLaunchMonitorShot(
      deviceShotID: 702,
      receivedAt: record.createdAt.addingTimeInterval(2)
    )
    try store.save(record)
    try store.savePendingLaunchMonitorShot(shot)

    XCTAssertEqual(
      try store.reconcilePendingLaunchMonitorShots(
        matchedAt: record.createdAt.addingTimeInterval(3)
      ),
      1
    )

    XCTAssertEqual(
      try store.load(id: record.id)?.launchMonitorMatch?.shot.deviceShotID,
      shot.deviceShotID
    )
    XCTAssertEqual(try store.loadPendingLaunchMonitorShots(), [])
  }

  func testReconcileUsesNearestPendingShotWhenAnEarlierSwingWasMissed() throws {
    let store = makeStore()
    let record = makeRecord(date: Date(timeIntervalSince1970: 105))
    let older = makeLaunchMonitorShot(
      deviceShotID: 705,
      receivedAt: Date(timeIntervalSince1970: 100)
    )
    let nearest = makeLaunchMonitorShot(
      deviceShotID: 706,
      receivedAt: Date(timeIntervalSince1970: 105)
    )
    try store.save(record)
    try store.savePendingLaunchMonitorShot(older)
    try store.savePendingLaunchMonitorShot(nearest)

    XCTAssertEqual(try store.reconcilePendingLaunchMonitorShots(), 1)
    XCTAssertEqual(try store.load(id: record.id)?.launchMonitorMatch?.shot.id, nearest.id)
    XCTAssertEqual(try store.loadPendingLaunchMonitorShots(), [older])
  }

  func testCorruptPendingInboxIsQuarantinedWithoutDisablingValidRecords() throws {
    let store = makeStore()
    let record = makeRecord()
    try store.save(record)
    let corruptData = Data("not-json".utf8)
    try corruptData.write(
      to: store.directoryURL.appendingPathComponent(".pending-launch-monitor-shots.json"),
      options: .atomic
    )

    let result = try store.loadPendingLaunchMonitorShotsRecoveringCorruptFile()

    XCTAssertTrue(result.didQuarantineCorruptFile)
    XCTAssertEqual(result.shots, [])
    XCTAssertEqual(try store.load(id: record.id), record)
    let quarantinedFiles = try FileManager.default.contentsOfDirectory(
      at: store.directoryURL,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(".invalid-pending-launch-monitor-shots-") }
    XCTAssertEqual(quarantinedFiles.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantinedFiles.first)), corruptData)

    let nextRecord = makeRecord(date: record.createdAt.addingTimeInterval(10))
    try store.save(nextRecord)
    XCTAssertEqual(try store.load(id: nextRecord.id), nextRecord)
  }

  func testShotAlreadyAttachedToRecordCannotBeQueuedAgain() throws {
    let store = makeStore()
    let record = makeRecord()
    let match = makeLaunchMonitorMatch(deviceShotID: 703)
    try store.save(record)
    _ = try store.attachLaunchMonitorMatch(match, to: record.id)

    XCTAssertFalse(try store.savePendingLaunchMonitorShot(match.shot))
    XCTAssertEqual(try store.loadPendingLaunchMonitorShots(), [])
  }

  func testSchemaOneRecordWithoutLaunchMonitorFieldStillDecodes() throws {
    let store = makeStore()
    var legacyRecord = makeRecord(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    legacyRecord.schemaVersion = 1

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let encoded = try encoder.encode(legacyRecord)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "launchMonitorMatch")

    let recordDirectory = store.directoryURL.appendingPathComponent(
      legacyRecord.id.uuidString.lowercased(),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: recordDirectory,
      withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: object).write(
      to: recordDirectory.appendingPathComponent("record.json"),
      options: .atomic
    )

    let decoded = try XCTUnwrap(store.load(id: legacyRecord.id))
    XCTAssertEqual(decoded.schemaVersion, 1)
    XCTAssertNil(decoded.launchMonitorMatch)
    XCTAssertEqual(decoded.metadata, legacyRecord.metadata)
  }

  func testCapturedSessionAdapterConvertsCMTimeAndCGPointToPlainValues() throws {
    let captured = SwingSessionSummary(
      duration: 1.5,
      peakNormalizedHandSpeed: 2.4,
      pathLength: 0.9,
      sampleCount: 2,
      pointHistory: [
        SwingMotionPoint(
          normalizedLocation: CGPoint(x: 0.2, y: 0.3),
          timestamp: CMTime(seconds: 10, preferredTimescale: 1_000)
        ),
        SwingMotionPoint(
          normalizedLocation: CGPoint(x: 0.7, y: 0.8),
          timestamp: CMTime(seconds: 11.5, preferredTimescale: 1_000)
        ),
      ],
      completionReason: .returnedToStillness,
      startTimestamp: CMTime(seconds: 10, preferredTimescale: 1_000),
      endTimestamp: CMTime(seconds: 11.5, preferredTimescale: 1_000)
    )

    let record = SwingRecord(
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      capturedSession: captured
    )

    XCTAssertEqual(record.sessionSummary.completionReason, "returnedToStillness")
    XCTAssertEqual(record.sessionSummary.sourceStartTimestampSeconds, 10)
    XCTAssertEqual(record.sessionSummary.sourceEndTimestampSeconds, 11.5)
    XCTAssertEqual(record.tracePoints.map(\.timeOffsetSeconds), [0, 1.5])
    XCTAssertEqual(record.tracePoints[0].normalizedX, 0.2, accuracy: 0.000_001)
    XCTAssertEqual(record.tracePoints[1].normalizedY, 0.8, accuracy: 0.000_001)
  }

  func testAttachStoryboardCopiesAllAvailablePhasesAndPersistsVerifiedMetadata() throws {
    let store = makeStore()
    let record = makeRecord(artifacts: makeArtifacts())
    try store.save(record)
    let addressJPEG = try makeJPEG(name: "address-source.jpg", width: 7, height: 5)
    let topJPEG = try makeJPEG(name: "top-source.jpg", width: 9, height: 6)
    let exported = [
      exportedKeyframe(.address, timestampMs: 0, jpegURL: addressJPEG),
      exportedKeyframe(.top, timestampMs: 420, jpegURL: topJPEG),
      unavailableKeyframe(.impact, timestampMs: 610),
      unavailableKeyframe(.finish, timestampMs: 1_000, state: .failed),
    ]

    let updated = try XCTUnwrap(
      store.attachStoryboardKeyframes(
        exported,
        captureSourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
        captureOrientation: .degrees90,
        to: record.id
      )
    )
    let keyframes = try XCTUnwrap(updated.artifacts?.keyframes)

    XCTAssertEqual(keyframes.map(\.slot), [.address, .top, .impact, .finish])
    XCTAssertEqual(keyframes.map(\.state), [.available, .available, .unavailable, .failed])
    let address = try XCTUnwrap(keyframes.first { $0.slot == .address })
    XCTAssertEqual(address.pixelWidth, 7)
    XCTAssertEqual(address.pixelHeight, 5)
    XCTAssertGreaterThan(address.byteCount ?? 0, 0)
    XCTAssertEqual(address.contentSHA256?.count, 64)
    XCTAssertNotEqual(address.contentSHA256, "untrusted-exporter-hash")
    XCTAssertEqual(address.extractedSourceTimestampMs, 0)

    let managedURL = try XCTUnwrap(
      store.storyboardKeyframeURL(for: updated, slot: .address)
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    XCTAssertEqual(try Data(contentsOf: managedURL), try Data(contentsOf: addressJPEG))
    XCTAssertTrue(FileManager.default.fileExists(atPath: addressJPEG.path))
    XCTAssertEqual(try store.load(id: record.id), updated)
  }

  func testStoryboardAttachmentFailureKeepsRecordAndRemovesStagingFiles() throws {
    let store = makeStore()
    let record = makeRecord(artifacts: makeArtifacts())
    try store.save(record)
    let addressJPEG = try makeJPEG(name: "atomic-address.jpg", width: 4, height: 3)
    let missingJPEG = temporaryDirectory.appendingPathComponent("missing-top.jpg")

    XCTAssertThrowsError(
      try store.attachStoryboardKeyframes(
        [
          exportedKeyframe(.address, timestampMs: 0, jpegURL: addressJPEG),
          exportedKeyframe(.top, timestampMs: 420, jpegURL: missingJPEG),
        ],
        captureSourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
        captureOrientation: .degrees90,
        to: record.id
      )
    )

    XCTAssertEqual(try store.load(id: record.id), record)
    let recordDirectory = store.directoryURL.appendingPathComponent(
      record.id.uuidString.lowercased(),
      isDirectory: true
    )
    let visibleFiles = try FileManager.default.contentsOfDirectory(
      at: recordDirectory,
      includingPropertiesForKeys: nil,
      options: []
    )
    XCTAssertEqual(visibleFiles.map(\.lastPathComponent), ["record.json"])
  }

  func testStoryboardAttachmentDoesNotResurrectDeletedRecord() throws {
    let store = makeStore()
    let record = makeRecord(artifacts: makeArtifacts())
    try store.save(record)
    try store.delete(id: record.id)
    let jpeg = try makeJPEG(name: "deleted-record.jpg", width: 3, height: 2)

    XCTAssertNil(
      try store.attachStoryboardKeyframes(
        [exportedKeyframe(.address, timestampMs: 0, jpegURL: jpeg)],
        captureSourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
        captureOrientation: .degrees90,
        to: record.id
      )
    )
    XCTAssertNil(try store.load(id: record.id))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.directoryURL.appendingPathComponent(record.id.uuidString.lowercased()).path
      )
    )
  }

  func testStoryboardRejectsFramesFromDifferentPersistedOrientation() throws {
    let store = makeStore()
    let record = makeRecord(artifacts: makeArtifacts())
    try store.save(record)
    let jpeg = try makeJPEG(name: "wrong-orientation.jpg", width: 3, height: 2)

    XCTAssertThrowsError(
      try store.attachStoryboardKeyframes(
        [exportedKeyframe(.address, timestampMs: 0, jpegURL: jpeg)],
        captureSourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
        captureOrientation: .degrees270,
        to: record.id
      )
    ) { error in
      guard let storeError = error as? SwingRecordStoreError,
        case .storyboardCaptureMismatch = storeError
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertEqual(try store.load(id: record.id), record)
  }

  func testReplayClockMappingUpdatesOnlyObservedPhasesAndPreservesOtherArtifacts() throws {
    let store = makeStore()
    let record = makeRecord(artifacts: makeArtifacts())
    try store.save(record)
    let replaySource = try makeReplayFile(name: "clock-map.mov", byteCount: 2_048)
    let withReplay = try store.attachReplay(from: replaySource, to: record)
    let launchMatch = makeLaunchMonitorMatch(deviceShotID: 990)
    _ = try store.attachLaunchMonitorMatch(launchMatch, to: record.id)
    let mapping = SwingReplayClockMapping(
      scale: 1,
      offsetSeconds: -8,
      uncertaintyMilliseconds: 12,
      cameraSampleCount: 30,
      replaySampleCount: 30,
      cameraMediaRangeSeconds: 10.3...10.7,
      replayMediaRangeSeconds: 2.3...2.7
    )

    let updated = try XCTUnwrap(
      store.attachReplayClockMapping(
        mapping,
        cameraSwingStartSeconds: 10,
        to: record.id
      )
    )

    XCTAssertEqual(updated.replayFilename, withReplay.replayFilename)
    XCTAssertEqual(updated.launchMonitorMatch, launchMatch)
    XCTAssertEqual(updated.artifacts?.replayClockMapping, mapping)
    XCTAssertEqual(
      updated.artifacts?.phaseMarkers.map(\.replayTimestampMs),
      [nil, 2_420, 2_610, nil]
    )
    XCTAssertEqual(updated.artifacts?.keyframes, record.artifacts?.keyframes)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try XCTUnwrap(store.replayURL(for: updated)).path
      )
    )
  }

  func testReplayClockMappingDoesNotResurrectDeletedRecord() throws {
    let store = makeStore()
    let record = makeRecord(artifacts: makeArtifacts())
    try store.save(record)
    try store.delete(id: record.id)
    let mapping = SwingReplayClockMapping(
      scale: 1,
      offsetSeconds: 0,
      uncertaintyMilliseconds: 10,
      cameraSampleCount: 4,
      replaySampleCount: 4,
      cameraMediaRangeSeconds: 10...11,
      replayMediaRangeSeconds: 10...11
    )

    XCTAssertNil(
      try store.attachReplayClockMapping(
        mapping,
        cameraSwingStartSeconds: 10,
        to: record.id
      )
    )
    XCTAssertNil(try store.load(id: record.id))
  }

  private func makeStore(
    maximumRecordCount: Int = 20,
    maximumStorageBytes: Int64 = SwingRecordStore.defaultMaximumStorageBytes
  ) -> SwingRecordStore {
    SwingRecordStore(
      directoryURL: temporaryDirectory.appendingPathComponent("Swings", isDirectory: true),
      maximumRecordCount: maximumRecordCount,
      maximumStorageBytes: maximumStorageBytes
    )
  }

  private func makeRecord(
    id: UUID = UUID(),
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    metadata: [String: SwingRecordMetadataValue] = [:],
    artifacts: SwingRecordArtifacts? = nil
  ) -> SwingRecord {
    SwingRecord(
      id: id,
      createdAt: date,
      sessionSummary: SwingRecord.SessionSummary(
        durationSeconds: 1.25,
        peakNormalizedHandSpeed: 2.5,
        normalizedPathLength: 0.8,
        sampleCount: 2,
        completionReason: "returnedToStillness",
        sourceStartTimestampSeconds: 10,
        sourceEndTimestampSeconds: 11.25
      ),
      tracePoints: [
        SwingRecord.TracePoint(normalizedX: 0.2, normalizedY: 0.4, timeOffsetSeconds: 0),
        SwingRecord.TracePoint(normalizedX: 0.7, normalizedY: 0.8, timeOffsetSeconds: 1.25),
      ],
      artifacts: artifacts,
      metadata: metadata
    )
  }

  private func makeArtifacts() -> SwingRecordArtifacts {
    let packet = SwingEvidencePacket(
      schema: SwingEvidencePacket.schemaVersion,
      coordinateSpace: "vision_normalized_xy_origin_lower_left",
      contextStartMs: -100,
      durationMs: 1_000,
      cameraView: "downTheLine",
      captureFPS: 120,
      poseAnalysisFPS: 30,
      analyzedPoseFrameCount: 30,
      sentTimelineFrameCount: 0,
      timeline: [],
      metrics: [],
      phases: [
        evidencePhase("address", timestampMs: 0),
        evidencePhase("top", timestampMs: 420),
        evidencePhase("impact", timestampMs: 610),
        evidencePhase("finish", timestampMs: 1_000),
      ],
      auditFrameRequests: [],
      capabilities: [],
      limitations: []
    )
    return SwingRecordArtifacts(
      evidencePacket: packet,
      capture: SwingStoryboardCaptureSnapshot(
        sourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
        cameraView: "downTheLine",
        orientation: .degrees90,
        encodedPixelWidth: 1_920,
        encodedPixelHeight: 1_080,
        captureFPS: 120
      )
    )!
  }

  private func makeReplayBundle(
    id: UUID = UUID(),
    includeRapsodo: Bool = false,
    synchronized: Bool = false
  ) -> SwingReplayBundle {
    SwingReplayBundle(
      id: id,
      camera: SwingReplayAsset(
        role: .swingCamera,
        sourceKind: "iphone-high-speed-camera",
        sourceGenerationID: UUID(),
        durationMilliseconds: 1_000,
        encodedPixelWidth: 1_920,
        encodedPixelHeight: 1_080,
        nominalFPS: 120,
        orientation: .degrees90,
        mediaRangeSeconds: 0...1
      ),
      rapsodo: includeRapsodo
        ? SwingReplayAsset(
          role: .rapsodoScreen,
          sourceKind: "rapsodo-screen-capture",
          sourceGenerationID: UUID(),
          durationMilliseconds: 1_000,
          encodedPixelWidth: 1_280,
          encodedPixelHeight: 720,
          nominalFPS: 60,
          orientation: .degrees0,
          mediaRangeSeconds: 0...1
        ) : nil,
      synchronization: includeRapsodo && synchronized ? makeReplaySynchronization() : nil
    )
  }

  private func makeReplaySynchronization() -> SwingReplaySynchronization {
    SwingReplaySynchronization(
      cameraClock: SwingReplayAssetClockCalibration(
        scaleToMonotonicClock: 1,
        monotonicClockOffsetSeconds: 100,
        uncertaintyMilliseconds: 4,
        sampleCount: 8,
        mediaRangeSeconds: 0...1
      ),
      rapsodoClock: SwingReplayAssetClockCalibration(
        scaleToMonotonicClock: 1,
        monotonicClockOffsetSeconds: 100.05,
        uncertaintyMilliseconds: 5,
        sampleCount: 8,
        mediaRangeSeconds: 0...1
      ),
      timelineMonotonicRangeSeconds: 100.05...101,
      uncertaintyMilliseconds: 7
    )
  }

  private func evidencePhase(
    _ id: String,
    timestampMs: Int
  ) -> SwingEvidencePhaseMarker {
    SwingEvidencePhaseMarker(
      id: id,
      tMs: timestampMs,
      sourceType: .macVision2D,
      confidence: 0.9,
      limitation: nil
    )
  }

  private func exportedKeyframe(
    _ slot: SwingStoryboardPhaseSlot,
    timestampMs: Int,
    jpegURL: URL
  ) -> CameraStoryboardKeyframeArtifact {
    CameraStoryboardKeyframeArtifact(
      slot: slot,
      requestedSourceTimestampMs: timestampMs,
      extractedSourceTimestampMs: timestampMs,
      state: .available,
      temporaryJPEGURL: jpegURL,
      contentSHA256: "untrusted-exporter-hash",
      pixelWidth: 1,
      pixelHeight: 1,
      byteCount: 1,
      limitation: nil
    )
  }

  private func unavailableKeyframe(
    _ slot: SwingStoryboardPhaseSlot,
    timestampMs: Int,
    state: SwingStoryboardKeyframeExtractionState = .unavailable
  ) -> CameraStoryboardKeyframeArtifact {
    CameraStoryboardKeyframeArtifact(
      slot: slot,
      requestedSourceTimestampMs: timestampMs,
      extractedSourceTimestampMs: nil,
      state: state,
      temporaryJPEGURL: nil,
      contentSHA256: nil,
      pixelWidth: nil,
      pixelHeight: nil,
      byteCount: nil,
      limitation: "fixture has no frame"
    )
  }

  private func makeJPEG(name: String, width: Int, height: Int) throws -> URL {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let url = temporaryDirectory.appendingPathComponent(name)
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  private func makeReplayFile(name: String, byteCount: Int) throws -> URL {
    let url = temporaryDirectory.appendingPathComponent(name)
    try Data(repeating: 0x5A, count: byteCount).write(to: url, options: .atomic)
    return url
  }

  private func makeLaunchMonitorMatch(deviceShotID: UInt64) -> LaunchMonitorMatch {
    let swingDate = Date(timeIntervalSince1970: 1_700_000_000)
    return LaunchMonitorMatch(
      shot: makeLaunchMonitorShot(
        deviceShotID: deviceShotID,
        receivedAt: swingDate.addingTimeInterval(2)
      ),
      swingOccurredAt: swingDate,
      matchedAt: swingDate.addingTimeInterval(3),
      matchingWindowSeconds: 8
    )
  }

  private func makeLaunchMonitorShot(
    deviceShotID: UInt64,
    receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_002)
  ) -> LaunchMonitorShot {
    LaunchMonitorShot(
      receivedAt: receivedAt,
      deviceShotID: deviceShotID,
      clubHeadSpeedMetersPerSecond: 43.2,
      ballSpeedMetersPerSecond: 63.1,
      horizontalLaunchAngleDegrees: -0.8,
      verticalLaunchAngleDegrees: 13.5,
      spinAxisDegrees: -4.2,
      totalSpinRPM: 2_380,
      rawMeasurement: Data([0xAA, 0xBB])
    )
  }
}

private final class BlockingReplayCopyFileManager: FileManager, @unchecked Sendable {
  let copyStarted = DispatchSemaphore(value: 0)
  let allowCopy = DispatchSemaphore(value: 0)

  override func copyItem(at srcURL: URL, to dstURL: URL) throws {
    copyStarted.signal()
    guard allowCopy.wait(timeout: .now() + 5) == .success else {
      throw CocoaError(.fileWriteUnknown)
    }
    try super.copyItem(at: srcURL, to: dstURL)
  }
}
