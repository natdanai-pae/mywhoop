@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import XCTest

@testable import GolfTrace

final class SwingReplayControllerTests: XCTestCase {
  func testReplayViewportAspectFitsWithoutStretching() {
    let viewport = GolfTraceReplayViewport.aspectFit(
      aspectRatio: 16.0 / 9.0,
      in: CGSize(width: 1_600, height: 1_000)
    )

    XCTAssertEqual(viewport.width, 1_600, accuracy: 0.001)
    XCTAssertEqual(viewport.height, 900, accuracy: 0.001)
  }

  func testReplayViewportKeepsRecordedPointCanvasAndScalesDownUniformly() {
    let sameSize = GolfTraceReplayViewport.layout(
      recordedCanvasSize: CGSize(width: 1_600, height: 1_000),
      videoAspectRatio: 1.6,
      in: CGSize(width: 2_000, height: 1_400)
    )
    XCTAssertEqual(sameSize.sourceCanvasSize, CGSize(width: 1_600, height: 1_000))
    XCTAssertEqual(sameSize.renderedSize, CGSize(width: 1_600, height: 1_000))
    XCTAssertEqual(sameSize.scale, 1, accuracy: 0.001)

    let scaledDown = GolfTraceReplayViewport.layout(
      recordedCanvasSize: CGSize(width: 1_600, height: 1_000),
      videoAspectRatio: 1.6,
      in: CGSize(width: 800, height: 700)
    )
    XCTAssertEqual(scaledDown.renderedSize, CGSize(width: 800, height: 500))
    XCTAssertEqual(scaledDown.scale, 0.5, accuracy: 0.001)
  }

  func testStageMovieMetadataRoundTripsRecordedCanvasSize() throws {
    let expected = CGSize(width: 1_982.5, height: 1_214.25)
    let description = GolfTraceStageMovieMetadata.description(for: expected)

    XCTAssertEqual(
      try XCTUnwrap(GolfTraceStageMovieMetadata.canvasSize(from: description)),
      expected
    )
    XCTAssertNil(GolfTraceStageMovieMetadata.canvasSize(from: "unrelated metadata"))
  }

  func testStageMovieMetadataRoundTripsPaneLayoutForSynchronizedPIP() throws {
    let layout = GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0.02, y: 0.08, width: 0.61, height: 0.86),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0.08, width: 0.34, height: 0.86)
    )
    let description = GolfTraceStageMovieMetadata.description(
      for: CGSize(width: 1_824, height: 1_365),
      paneLayout: layout
    )

    XCTAssertEqual(GolfTraceStageMovieMetadata.paneLayout(from: description), layout)
    XCTAssertEqual(
      GolfTraceStageMovieMetadata.canvasSize(from: description),
      CGSize(width: 1_824, height: 1_365)
    )
  }

  func testStageMovieMetadataRejectsDuplicatePaneFieldsWithoutCrashing() {
    let malformed =
      "golftrace.canvas-size=1824,1365;rapsodo=0.02,0.08,0.61,0.86;"
      + "rapsodo=0.10,0.10,0.50,0.80;camera=0.64,0.08,0.34,0.86"

    XCTAssertNil(GolfTraceStageMovieMetadata.descriptor(from: malformed))
  }

  func testReplayPIPConvertsTopLeftMetadataIntoCoreImageCoordinates() {
    let normalized = GolfTraceNormalizedRect(x: 0.10, y: 0.20, width: 0.30, height: 0.40)
    let sourceRect = GolfTraceReplayPIPComposition.sourceRect(
      for: normalized,
      in: CGRect(x: 0, y: 0, width: 1_000, height: 500)
    )

    XCTAssertEqual(sourceRect.minX, 100, accuracy: 0.001)
    XCTAssertEqual(sourceRect.minY, 200, accuracy: 0.001)
    XCTAssertEqual(sourceRect.width, 300, accuracy: 0.001)
    XCTAssertEqual(sourceRect.height, 200, accuracy: 0.001)
  }

  func testReplayPIPCompositionKeepsOneFiniteOutputFrame() {
    let sourceImage = CIImage(color: .white).cropped(
      to: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
    )
    let layout = GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0.02, y: 0.08, width: 0.61, height: 0.86),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0.08, width: 0.34, height: 0.86)
    )

    let output = GolfTraceReplayPIPComposition.compose(
      sourceImage: sourceImage,
      paneLayout: layout,
      isRapsodoPrimary: false
    )

    XCTAssertEqual(output.extent, sourceImage.extent)
    let pipRect = GolfTraceReplayPIPComposition.pipFrame(
      for: GolfTraceReplayPIPComposition.sourceRect(
        for: layout.rapsodo,
        in: sourceImage.extent
      ),
      in: sourceImage.extent
    )
    XCTAssertTrue(sourceImage.extent.contains(pipRect))
  }

  func testCaptureDimensionsPreserveVeryWideWindowAspect() throws {
    let dimensions = try XCTUnwrap(
      GolfTraceCaptureDimensions.aspectPreserving(
        sourceSize: CGSize(width: 4_000, height: 500),
        pointPixelScale: 2
      )
    )

    XCTAssertLessThanOrEqual(max(dimensions.width, dimensions.height), 2_560)
    XCTAssertEqual(dimensions.width % 2, 0)
    XCTAssertEqual(dimensions.height % 2, 0)
    XCTAssertEqual(
      Double(dimensions.width) / Double(dimensions.height),
      8,
      accuracy: 0.02
    )
  }

  @MainActor
  func testReplayPlayerSurfaceUsesAVPlayerLayerWithoutAVKitVideoPlayer() {
    let player = AVPlayer()
    let surface = SwingReplayPlayerSurface(player: player)

    XCTAssertTrue(surface.player === player)
    XCTAssertTrue(surface.layer is AVPlayerLayer)

    surface.player = nil
    XCTAssertNil(surface.player)
  }

  @MainActor
  func testTerminationStopsAcceptingNewReplayExports() throws {
    let (controller, recoveryDirectory) = try makeController()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let exporter = FakeReplayExporter()

    controller.prepareForTermination()
    controller.exportIfNeeded(
      for: makeSummary(start: 1, end: 2),
      recordID: UUID(),
      rotationDegrees: 0,
      using: exporter
    ) { _ in
      XCTFail("ไม่ควรสร้างคลิปใหม่หลังเริ่มปิดแอป")
    }

    XCTAssertTrue(exporter.requests.isEmpty)
    XCTAssertFalse(controller.hasPendingExportWork)
  }

  @MainActor
  func testStageRecordingUsesReplayPersistenceLifecycle() throws {
    let (controller, recoveryDirectory) = try makeController()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let stageURL = try makeManagedReplayFile(named: "stage")

    let recordID = UUID()
    let paneLayout = GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0.02, y: 0.08, width: 0.61, height: 0.86),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0.08, width: 0.34, height: 0.86)
    )
    controller.registerReplayRequest(recordID: recordID)
    let managedURL = controller.acceptStageRecording(
      stageURL,
      recordID: recordID,
      stagePaneLayout: paneLayout
    )

    XCTAssertEqual(controller.replayURL, managedURL)
    XCTAssertEqual(controller.replayRecordID, recordID)
    XCTAssertEqual(controller.replayPaneLayout, paneLayout)
    XCTAssertEqual(controller.currentReplayURL(for: recordID), managedURL)
    XCTAssertEqual(managedURL.deletingLastPathComponent(), recoveryDirectory)
    XCTAssertTrue(controller.canSaveReplay)
    XCTAssertFalse(controller.isPreparingReplay)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))

    controller.discardReplay()
    XCTAssertNil(controller.replayPaneLayout)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: managedURL.path),
      "คลิปชั่วคราวต้องอยู่จนกว่าคลังประวัติคัดลอกสำเร็จ"
    )

    controller.acknowledgePersistence(of: managedURL, succeeded: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path))
  }

  @MainActor
  func testStoredReplayKeepsOwningRecordForStoryboardLookup() throws {
    let (controller, recoveryDirectory) = try makeController()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let recordID = UUID()
    let storedURL = recoveryDirectory.appendingPathComponent("stored.mov")

    controller.showStoredReplay(storedURL, recordID: recordID, stagePaneLayout: nil)

    XCTAssertEqual(controller.replayURL, storedURL)
    XCTAssertEqual(controller.replayRecordID, recordID)
  }

  @MainActor
  func testRawExportFailureIsReportedToTheOwningTake() async throws {
    let (controller, recoveryDirectory) = try makeController()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let exporter = FakeReplayExporter()
    var reportedError: Error?

    controller.exportIfNeeded(
      for: makeSummary(start: 1, end: 2),
      recordID: UUID(),
      rotationDegrees: 0,
      using: exporter,
      onFailure: { reportedError = $0 },
      onReady: { _ in
        XCTFail("รีเพลย์ที่ export ล้มเหลวต้องไม่ส่ง success")
      }
    )

    exporter.completeRequest(at: 0, with: .failure(CocoaError(.fileWriteUnknown)))
    await waitUntil { reportedError != nil }

    XCTAssertNotNil(reportedError)
    XCTAssertFalse(controller.hasPendingExportWork)
    XCTAssertFalse(controller.isPreparingReplay)
  }

  @MainActor
  func testOlderRawExportCannotReplaceNewerStageReplay() async throws {
    let (controller, recoveryDirectory) = try makeController()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let exporter = FakeReplayExporter()
    let oldRecordID = UUID()
    let newRecordID = UUID()
    var completedOldReplay: CompletedSwingReplay?

    controller.exportIfNeeded(
      for: makeSummary(start: 1, end: 2),
      recordID: oldRecordID,
      rotationDegrees: 0,
      using: exporter
    ) { completedOldReplay = $0 }

    controller.registerReplayRequest(recordID: newRecordID)
    let newStageURL = try makeManagedReplayFile(named: "new-stage")
    let managedStageURL = controller.acceptStageRecording(
      newStageURL,
      recordID: newRecordID,
      stagePaneLayout: nil
    )
    XCTAssertEqual(controller.replayURL, managedStageURL)

    let oldRawURL = try makeManagedReplayFile(named: "old-raw")
    exporter.completeRequest(at: 0, with: .success(oldRawURL))
    await waitUntil { completedOldReplay != nil }

    XCTAssertEqual(controller.replayURL, managedStageURL)
    XCTAssertEqual(completedOldReplay?.recordID, oldRecordID)

    controller.acknowledgePersistence(of: try XCTUnwrap(completedOldReplay?.url), succeeded: true)
    controller.discardReplay()
    controller.acknowledgePersistence(of: managedStageURL, succeeded: true)
  }

  @MainActor
  func testConsecutiveSwingsExportInOrderAndKeepFilesUntilPersisted() async throws {
    let (controller, recoveryDirectory) = try makeController()
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }
    let exporter = FakeReplayExporter()
    let firstRecordID = UUID()
    let secondRecordID = UUID()
    var completed: [CompletedSwingReplay] = []

    controller.exportIfNeeded(
      for: makeSummary(start: 1, end: 2),
      recordID: firstRecordID,
      rotationDegrees: 0,
      using: exporter
    ) { completed.append($0) }
    controller.exportIfNeeded(
      for: makeSummary(start: 3, end: 4),
      recordID: secondRecordID,
      rotationDegrees: 180,
      using: exporter
    ) { completed.append($0) }

    XCTAssertEqual(exporter.requests.count, 1, "วงที่สองต้องรอวงแรกเขียนไฟล์เสร็จ")

    let firstURL = try makeManagedReplayFile(named: "first")
    exporter.completeRequest(at: 0, with: .success(firstURL))
    await waitUntil { completed.count == 1 && exporter.requests.count == 2 }

    XCTAssertEqual(completed.first?.recordID, firstRecordID)
    let managedFirstURL = try XCTUnwrap(completed.first?.url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedFirstURL.path))

    let secondURL = try makeManagedReplayFile(named: "second")
    exporter.completeRequest(at: 1, with: .success(secondURL))
    await waitUntil { completed.count == 2 && !controller.isPreparingReplay }

    XCTAssertEqual(completed.last?.recordID, secondRecordID)
    let managedSecondURL = try XCTUnwrap(completed.last?.url)
    XCTAssertEqual(controller.replayURL, managedSecondURL)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: managedFirstURL.path),
      "ห้ามลบคลิปวงแรกก่อนคลังถาวรคัดลอกเสร็จ"
    )

    controller.acknowledgePersistence(of: managedFirstURL, succeeded: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedFirstURL.path))

    controller.discardReplay()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: managedSecondURL.path),
      "แม้ปิดหน้าดูย้อนหลัง ก็ต้องรอให้การบันทึกคลิปเสร็จก่อน"
    )
    controller.acknowledgePersistence(of: managedSecondURL, succeeded: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedSecondURL.path))
  }

  @MainActor
  func testFailedPersistenceSurvivesRelaunchAndRetriesExactRecord() throws {
    let recoveryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "GolfTrace-ReplayRecoveryTests-\(UUID().uuidString)", isDirectory: true
      )
      .standardizedFileURL
    defer { try? FileManager.default.removeItem(at: recoveryDirectory) }

    let recordID = UUID()
    let paneLayout = GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0.02, y: 0.08, width: 0.61, height: 0.86),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0.08, width: 0.34, height: 0.86)
    )
    let firstController = SwingReplayController(recoveryDirectory: recoveryDirectory)
    let sourceURL = try makeManagedReplayFile(named: "recovery")
    let managedURL = firstController.acceptStageRecording(
      sourceURL,
      recordID: recordID,
      stagePaneLayout: paneLayout
    )
    firstController.acknowledgePersistence(of: managedURL, succeeded: false)

    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))

    let relaunchedController = SwingReplayController(recoveryDirectory: recoveryDirectory)
    relaunchedController.cleanStaleTemporaryReplaysAfterExclusiveLaunch()
    var recovered: CompletedSwingReplay?
    relaunchedController.recoverPendingPersistence { recovered = $0 }

    XCTAssertEqual(recovered?.recordID, recordID)
    XCTAssertEqual(recovered?.url, managedURL)
    XCTAssertEqual(recovered?.stagePaneLayout, paneLayout)

    relaunchedController.acknowledgePersistence(of: managedURL, succeeded: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path))
  }

  @MainActor
  private func waitUntil(
    _ condition: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<100 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("รอผล asynchronous เกินเวลาที่กำหนด", file: file, line: line)
  }

  private func makeSummary(start: Double, end: Double) -> SwingSessionSummary {
    SwingSessionSummary(
      duration: end - start,
      peakNormalizedHandSpeed: 1.5,
      pathLength: 0.8,
      sampleCount: 2,
      pointHistory: [],
      completionReason: .returnedToStillness,
      startTimestamp: CMTime(seconds: start, preferredTimescale: 1_000),
      endTimestamp: CMTime(seconds: end, preferredTimescale: 1_000)
    )
  }

  @MainActor
  private func makeController() throws -> (SwingReplayController, URL) {
    let recoveryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "GolfTrace-ReplayRecoveryTests-\(UUID().uuidString)", isDirectory: true
      )
      .standardizedFileURL
    try FileManager.default.createDirectory(
      at: recoveryDirectory,
      withIntermediateDirectories: true
    )
    return (
      SwingReplayController(recoveryDirectory: recoveryDirectory),
      recoveryDirectory
    )
  }

  private func makeManagedReplayFile(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("GolfTrace-วงล่าสุด-\(name)-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    try Data([0, 1, 2, 3]).write(to: url)
    return url.standardizedFileURL
  }
}

private final class FakeReplayExporter: SwingReplayExporting, @unchecked Sendable {
  struct Request {
    let swingStart: CMTime
    let swingEnd: CMTime
    let preRoll: TimeInterval
    let rotationDegrees: Double
    let completion: @Sendable (Result<URL, Error>) -> Void
  }

  private(set) var requests: [Request] = []

  func exportReplay(
    swingStart: CMTime,
    swingEnd: CMTime,
    preRoll: TimeInterval,
    rotationDegrees: Double,
    completion: @escaping @Sendable (Result<URL, Error>) -> Void
  ) {
    requests.append(
      Request(
        swingStart: swingStart,
        swingEnd: swingEnd,
        preRoll: preRoll,
        rotationDegrees: rotationDegrees,
        completion: completion
      )
    )
  }

  func completeRequest(at index: Int, with result: Result<URL, Error>) {
    requests[index].completion(result)
  }
}
