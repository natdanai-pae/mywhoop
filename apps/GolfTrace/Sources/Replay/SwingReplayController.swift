import AppKit
import Combine
import CoreMedia
import Darwin
import Foundation
import UniformTypeIdentifiers

protocol SwingReplayExporting: AnyObject {
  func exportReplay(
    swingStart: CMTime,
    swingEnd: CMTime,
    preRoll: TimeInterval,
    rotationDegrees: Double,
    completion: @escaping @Sendable (Result<URL, Error>) -> Void
  )
}

extension HighSpeedVideoReceiver: SwingReplayExporting {}

struct CompletedSwingReplay: Equatable {
  let requestID: UUID
  let recordID: UUID
  let url: URL
  let stagePaneLayout: GolfTraceStagePaneLayout?
}

enum SwingReplayRequestError: LocalizedError, Equatable {
  case requestsClosed
  case missingSummary
  case duplicateSummary
  case invalidTiming

  var errorDescription: String? {
    switch self {
    case .requestsClosed:
      return "ระบบกำลังปิดและไม่รับงานสร้างรีเพลย์ใหม่"
    case .missingSummary:
      return "ยังไม่มีช่วงเวลาวงสวิงสำหรับสร้างรีเพลย์"
    case .duplicateSummary:
      return "วงสวิงนี้ถูกส่งไปสร้างรีเพลย์แล้ว"
    case .invalidTiming:
      return "เวลาของวงสวิงไม่สมบูรณ์"
    }
  }
}

protocol SwingReplayFileIOExecuting: Sendable {
  func exportReplay(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) async throws

  func recoverReplay(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) async throws

  func removeItems(at urls: [URL]) async
}

/// Serializes potentially large replay copies away from MainActor. Both copy
/// paths commit with a same-directory rename/replace, so cancellation or a
/// failed copy cannot expose a partial destination movie.
actor SwingReplayFileIOExecutor: SwingReplayFileIOExecuting {
  private let fileManager = FileManager()

  init() {}

  func exportReplay(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) throws {
    try copyAtomically(
      from: sourceURL,
      to: destinationURL,
      stagingAt: stagingURL
    )
  }

  func recoverReplay(
    from sourceURL: URL,
    to destinationURL: URL,
    stagingAt stagingURL: URL
  ) throws {
    try copyAtomically(
      from: sourceURL,
      to: destinationURL,
      stagingAt: stagingURL
    )
  }

  func removeItems(at urls: [URL]) {
    for url in urls {
      try? fileManager.removeItem(at: url)
    }
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

private enum SwingReplaySameVolumeMove {
  /// `FileManager.moveItem` may implement a cross-volume move as copy + delete.
  /// A POSIX rename is guaranteed to stay metadata-only and fail with `EXDEV`,
  /// allowing the controller to route that fallback to its background actor.
  static func perform(from sourceURL: URL, to destinationURL: URL) throws {
    var result: Int32 = -1
    var errorCode: Int32 = EINVAL
    sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
      destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else { return }
        result = Darwin.rename(sourcePath, destinationPath)
        if result != 0 {
          errorCode = errno
        }
      }
    }
    guard result == 0 else {
      throw NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(errorCode),
        userInfo: [NSFilePathErrorKey: sourceURL.path]
      )
    }
  }
}

/// ประสานการสร้างคลิปย้อนหลังหนึ่งครั้งเมื่อวงสวิงใหม่จบลง
///
/// ตัวควบคุมนี้เก็บเฉพาะไฟล์ชั่วคราวที่แอปสร้างเอง ไฟล์ที่ผู้ใช้บันทึกผ่าน
/// `NSSavePanel` เป็นสำเนาแยกและจะไม่ถูกลบเมื่อวงถัดไปมาถึง
@MainActor
final class SwingReplayController: ObservableObject {
  typealias RecoveryMover = @MainActor (URL, URL) throws -> Void

  @Published private(set) var replayURL: URL?
  @Published private(set) var replayRecordID: UUID?
  @Published private(set) var replayPaneLayout: GolfTraceStagePaneLayout?
  @Published private(set) var statusText = "รอวงสวิงจบเพื่อสร้างภาพย้อนหลัง"
  @Published private(set) var isPreparingReplay = false
  @Published private(set) var isSavingReplay = false

  private static let temporaryReplayPrefix = "GolfTrace-วงล่าสุด-"
  private static let pendingRecoveryPrefix = "GolfTrace-วงล่าสุด-pending-"
  private static let persistedMarkerExtension = "persisted"
  private static let recoveryMetadataExtension = "recovery.json"

  private struct RecoveryReplayMetadata: Codable {
    let stagePaneLayout: GolfTraceStagePaneLayout?
  }

  private struct ExportRequest {
    let id: UUID
    let recordID: UUID
    let order: UInt64
    let summary: SwingSessionSummary
    let rotationDegrees: Double
    let exporter: any SwingReplayExporting
    let onReady: @MainActor (CompletedSwingReplay) -> Void
    let onFailure: @MainActor (Error) -> Void
  }

  private struct RecoveryCopyOperation {
    let id: UUID
    let sourceURL: URL
    let destinationURL: URL
    let recordID: UUID
  }

  private let fileManager: FileManager
  private let recoveryDirectory: URL
  private let fileIOExecutor: any SwingReplayFileIOExecuting
  private let recoveryMover: RecoveryMover
  private var lastRequestedSummary: SwingSessionSummary?
  private var activeRequest: ExportRequest?
  private var queuedRequests: [ExportRequest] = []
  private var awaitingPersistence: Set<URL> = []
  private var pendingPersistenceRecordIDs: [URL: UUID] = [:]
  private var pendingPersistencePaneLayouts: [URL: GolfTraceStagePaneLayout] = [:]
  private var deliveredRecoveryURLs: Set<URL> = []
  private var persistedTemporaryReplays: Set<URL> = []
  private var exportDrainContinuations: [CheckedContinuation<Void, Never>] = []
  private var pendingFileIOIDs: Set<UUID> = []
  private var fileIOTasks: [UUID: Task<Void, Never>] = [:]
  private var activeSaveID: UUID?
  private var recoveryCopiesBySource: [URL: RecoveryCopyOperation] = [:]
  private var recoveryAliasesBySource: [URL: URL] = [:]
  private var failedPersistenceURLs: Set<URL> = []
  private var acceptsNewExportRequests = true
  private var nextReplayOrder: UInt64 = 0
  private var latestRequestedReplayOrder: UInt64 = 0
  private var replayOrderByRecordID: [UUID: UInt64] = [:]
  private var didCleanStaleTemporaryReplays = false

  init(
    fileManager: FileManager = .default,
    recoveryDirectory: URL? = nil,
    fileIOExecutor: (any SwingReplayFileIOExecuting)? = nil,
    recoveryMover: RecoveryMover? = nil
  ) {
    self.fileManager = fileManager
    if let recoveryDirectory {
      self.recoveryDirectory = recoveryDirectory.standardizedFileURL
    } else {
      let applicationSupport =
        (try? fileManager.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )) ?? fileManager.temporaryDirectory
      self.recoveryDirectory =
        applicationSupport
        .appendingPathComponent("GolfTrace", isDirectory: true)
        .appendingPathComponent("ReplayRecovery", isDirectory: true)
        .standardizedFileURL
    }
    self.fileIOExecutor = fileIOExecutor ?? SwingReplayFileIOExecutor()
    self.recoveryMover =
      recoveryMover ?? { sourceURL, destinationURL in
        try SwingReplaySameVolumeMove.perform(from: sourceURL, to: destinationURL)
      }
  }

  deinit {
    for task in fileIOTasks.values {
      task.cancel()
    }
  }

  /// Must run only after the app owns the single-instance lock. A duplicate
  /// process must never delete temporary movies still used by the live process.
  func cleanStaleTemporaryReplaysAfterExclusiveLaunch() {
    guard !didCleanStaleTemporaryReplays else { return }
    didCleanStaleTemporaryReplays = true
    removeStaleTemporaryReplays()
    loadRecoverableReplays()
  }

  /// Replays whose history copy failed survive in Application Support and are
  /// offered again after the next exclusive launch. Delivery is idempotent for
  /// the lifetime of this controller; a failed copy remains available next run.
  func recoverPendingPersistence(
    _ onReady: @escaping @MainActor (CompletedSwingReplay) -> Void
  ) {
    let recoverable =
      pendingPersistenceRecordIDs
      .filter { url, _ in
        !deliveredRecoveryURLs.contains(url) && fileManager.fileExists(atPath: url.path)
      }
      .sorted { first, second in
        first.key.lastPathComponent < second.key.lastPathComponent
      }

    for (url, recordID) in recoverable {
      deliveredRecoveryURLs.insert(url)
      onReady(
        CompletedSwingReplay(
          requestID: UUID(),
          recordID: recordID,
          url: url,
          stagePaneLayout: pendingPersistencePaneLayouts[url]
        )
      )
    }
  }

  var canSaveReplay: Bool {
    replayURL != nil && !isPreparingReplay && !isSavingReplay
  }

  var isShowingGeneratedReplay: Bool {
    replayURL.map(isManagedTemporaryReplay) ?? false
  }

  /// ใช้ตอนปิดแอป เพื่อรอให้ทุกวงที่รับไว้สร้างคลิปเสร็จตามลำดับ
  var hasPendingExportWork: Bool {
    activeRequest != nil || !queuedRequests.isEmpty || !pendingFileIOIDs.isEmpty
  }

  func flushPendingExports() async {
    guard hasPendingExportWork else { return }
    await withCheckedContinuation { continuation in
      exportDrainContinuations.append(continuation)
    }
  }

  func prepareForTermination() {
    acceptsNewExportRequests = false
  }

  /// Registers completion order before either the composite recorder or raw
  /// fallback finishes. Asynchronous work from an older swing may still be
  /// persisted, but it must never replace a newer replay on screen.
  @discardableResult
  func registerReplayRequest(recordID: UUID) -> UInt64 {
    if let existingOrder = replayOrderByRecordID[recordID] {
      return existingOrder
    }
    nextReplayOrder &+= 1
    let order = nextReplayOrder
    replayOrderByRecordID[recordID] = order
    latestRequestedReplayOrder = order
    return order
  }

  /// สร้างคลิปเมื่อได้รับผลสรุปวงใหม่เท่านั้น การส่งผลสรุปเดิมเข้ามาซ้ำจาก
  /// SwiftUI หรือ Combine จะไม่เริ่มงานเขียนไฟล์ซ้ำ
  func exportIfNeeded(
    for summary: SwingSessionSummary?,
    recordID: UUID,
    rotationDegrees: Double,
    using exporter: any SwingReplayExporting,
    onFailure: @escaping @MainActor (Error) -> Void = { _ in },
    onReady: @escaping @MainActor (CompletedSwingReplay) -> Void
  ) {
    guard acceptsNewExportRequests else {
      onFailure(SwingReplayRequestError.requestsClosed)
      return
    }
    guard let summary else {
      onFailure(SwingReplayRequestError.missingSummary)
      return
    }
    guard summary != lastRequestedSummary else {
      onFailure(SwingReplayRequestError.duplicateSummary)
      return
    }
    guard summary.startTimestamp.isValid, summary.endTimestamp.isValid,
      CMTimeCompare(summary.endTimestamp, summary.startTimestamp) > 0
    else {
      statusText = "สร้างภาพย้อนหลังไม่ได้ เพราะเวลาของวงสวิงไม่สมบูรณ์"
      onFailure(SwingReplayRequestError.invalidTiming)
      return
    }

    let order = registerReplayRequest(recordID: recordID)
    lastRequestedSummary = summary
    queuedRequests.append(
      ExportRequest(
        id: UUID(),
        recordID: recordID,
        order: order,
        summary: summary,
        rotationDegrees: rotationDegrees,
        exporter: exporter,
        onReady: onReady,
        onFailure: onFailure
      )
    )
    isPreparingReplay = true
    statusText =
      activeRequest == nil
      ? "กำลังสร้างคลิปย้อนหลังของวงล่าสุด…"
      : "รับวงใหม่แล้ว · รอสร้างคลิปย้อนหลังตามลำดับ…"
    startNextExportIfPossible()
  }

  /// เปิดหน้าต่างมาตรฐานของ macOS เพื่อให้ผู้ใช้เลือกชื่อและตำแหน่งเก็บไฟล์
  /// ไฟล์ปลายทางเป็นสำเนาถาวร จึงยังอยู่แม้แอปล้างคลิปชั่วคราววงเก่า
  func saveReplay() {
    guard let sourceURL = replayURL?.standardizedFileURL else {
      statusText = "ยังไม่มีคลิปย้อนหลังให้บันทึก"
      return
    }

    let panel = NSSavePanel()
    panel.title = "บันทึกคลิปวงสวิง"
    panel.message = "เลือกชื่อและตำแหน่งสำหรับเก็บคลิปวงสวิงล่าสุด"
    panel.prompt = "บันทึก"
    panel.allowedContentTypes = [.quickTimeMovie]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = suggestedFileName()

    guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
    startSave(from: sourceURL, to: destinationURL)
  }

  /// Testable half of `saveReplay()`. The save panel remains on MainActor while
  /// the potentially large copy and atomic destination commit run serially on
  /// the replay file-I/O actor.
  func saveReplay(to destinationURL: URL) {
    guard let sourceURL = replayURL?.standardizedFileURL else {
      statusText = "ยังไม่มีคลิปย้อนหลังให้บันทึก"
      return
    }
    startSave(from: sourceURL, to: destinationURL)
  }

  private func startSave(from sourceURL: URL, to destinationURL: URL) {
    guard activeSaveID == nil else { return }

    let destination = destinationURL.standardizedFileURL
    guard sourceURL != destination else {
      statusText = "บันทึกคลิปแล้ว: \(destinationURL.lastPathComponent)"
      return
    }

    let operationID = UUID()
    let stagingURL = destination.deletingLastPathComponent()
      .appendingPathComponent(".GolfTrace-save-\(operationID.uuidString.lowercased())")
      .appendingPathExtension(destination.pathExtension.isEmpty ? "mov" : destination.pathExtension)
    activeSaveID = operationID
    isSavingReplay = true
    statusText = "กำลังบันทึกคลิป…"
    beginFileIO(operationID)

    let executor = fileIOExecutor
    let task = Task { [weak self] in
      let result: Result<Void, Error>
      do {
        try await executor.exportReplay(
          from: sourceURL,
          to: destination,
          stagingAt: stagingURL
        )
        result = .success(())
      } catch {
        result = .failure(error)
      }
      self?.finishSave(
        result,
        operationID: operationID,
        sourceURL: sourceURL,
        destinationURL: destination
      )
    }
    fileIOTasks[operationID] = task
  }

  /// ล้างคลิปชั่วคราวที่แสดงอยู่ โดยไม่แตะไฟล์ที่ผู้ใช้เคยบันทึกเอง
  func discardReplay() {
    let discardedURL = replayURL
    replayRecordID = nil
    replayPaneLayout = nil
    replayURL = nil
    removeTemporaryReplayIfReleased(at: discardedURL)
    statusText =
      isPreparingReplay
      ? "กำลังสร้างคลิปย้อนหลังของวงล่าสุด…"
      : "รอวงสวิงจบเพื่อสร้างภาพย้อนหลัง"
  }

  /// เปิดคลิปถาวรจากประวัติ โดยไม่ถือว่าเป็นไฟล์ชั่วคราวที่ตัวควบคุมมีสิทธิ์ลบ
  func showStoredReplay(
    _ url: URL,
    recordID: UUID,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil
  ) {
    nextReplayOrder &+= 1
    latestRequestedReplayOrder = nextReplayOrder
    let previousURL = replayURL
    replayRecordID = recordID
    replayPaneLayout = stagePaneLayout
    replayURL = url
    statusText = "กำลังแสดงคลิปจากประวัติ"
    if previousURL != url {
      removeTemporaryReplayIfReleased(at: previousURL)
    }
  }

  /// Accepts a WindowServer-composited movie produced during the swing. It is
  /// managed with the same persistence handshake as the legacy raw-camera
  /// export, but already contains both devices and every visible overlay.
  @discardableResult
  func acceptStageRecording(
    _ url: URL,
    recordID: UUID,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil
  ) -> URL {
    let order = registerReplayRequest(recordID: recordID)
    let standardizedURL = prepareReplayForPersistence(url, recordID: recordID)
    trackPendingPersistence(
      standardizedURL,
      recordID: recordID,
      stagePaneLayout: stagePaneLayout
    )
    if order == latestRequestedReplayOrder {
      let previousURL = replayURL
      replayRecordID = recordID
      replayPaneLayout = stagePaneLayout
      replayURL = standardizedURL
      isPreparingReplay =
        activeRequest != nil || !queuedRequests.isEmpty || !recoveryCopiesBySource.isEmpty
      statusText = "คลิปทั้งหน้าจอพร้อมดูย้อนหลังแล้ว"
      if previousURL != standardizedURL {
        removeTemporaryReplayIfReleased(at: previousURL)
      }
    }
    return standardizedURL
  }

  /// แจ้งว่าคลังถาวรคัดลอกคลิปเสร็จแล้ว จึงลบไฟล์ชั่วคราววงเก่าได้อย่างปลอดภัย
  func acknowledgePersistence(of url: URL, succeeded: Bool) {
    let submittedURL = url.standardizedFileURL
    let standardizedURL = recoveryAliasesBySource[submittedURL] ?? submittedURL
    let completedAliasSources = recoveryAliasesBySource.compactMap { source, destination in
      destination == standardizedURL ? source : nil
    }

    if succeeded {
      awaitingPersistence.remove(standardizedURL)
      pendingPersistenceRecordIDs.removeValue(forKey: standardizedURL)
      pendingPersistencePaneLayouts.removeValue(forKey: standardizedURL)
      deliveredRecoveryURLs.remove(standardizedURL)
      failedPersistenceURLs.remove(standardizedURL)
      markPersistenceCompleted(at: standardizedURL)
      persistedTemporaryReplays.insert(standardizedURL)
      removeTemporaryReplayIfReleased(at: standardizedURL)
    } else {
      failedPersistenceURLs.insert(standardizedURL)
      statusText = "ยังเก็บคลิปลงประวัติไม่สำเร็จ · จะลองกู้และบันทึกใหม่ครั้งหน้า"
    }

    // The history callback is the ownership hand-off point: it guarantees that
    // history has finished reading the originally delivered source (including
    // any retries), so the cross-volume fallback may now release that source.
    for source in completedAliasSources {
      recoveryAliasesBySource.removeValue(forKey: source)
    }
    if !completedAliasSources.isEmpty {
      scheduleBackgroundRemoval(
        completedAliasSources.flatMap {
          [$0, persistedMarkerURL(for: $0), recoveryMetadataURL(for: $0)]
        }
      )
    }
  }

  private func startNextExportIfPossible() {
    guard activeRequest == nil, !queuedRequests.isEmpty else {
      isPreparingReplay =
        activeRequest != nil || !queuedRequests.isEmpty || !recoveryCopiesBySource.isEmpty
      return
    }

    let request = queuedRequests.removeFirst()
    activeRequest = request
    isPreparingReplay = true
    if request.order == latestRequestedReplayOrder {
      statusText = "กำลังสร้างคลิปย้อนหลังของวงล่าสุด…"
    }
    let requestID = request.id

    request.exporter.exportReplay(
      swingStart: request.summary.startTimestamp,
      swingEnd: request.summary.endTimestamp,
      preRoll: 0.75,
      rotationDegrees: request.rotationDegrees
    ) { [weak self] result in
      Task { @MainActor [weak self] in
        self?.finishExport(result, requestID: requestID)
      }
    }
  }

  private func finishExport(_ result: Result<URL, Error>, requestID: UUID) {
    guard let request = activeRequest, request.id == requestID else {
      if case .success(let unusedURL) = result {
        removeTemporaryReplay(at: unusedURL)
      }
      return
    }

    activeRequest = nil
    switch result {
    case .success(let newURL):
      let standardizedURL = prepareReplayForPersistence(
        newURL,
        recordID: request.recordID
      )
      trackPendingPersistence(standardizedURL, recordID: request.recordID)
      request.onReady(
        CompletedSwingReplay(
          requestID: request.id,
          recordID: request.recordID,
          url: standardizedURL,
          stagePaneLayout: nil
        )
      )
      if request.order == latestRequestedReplayOrder {
        let previousURL = replayURL
        replayRecordID = request.recordID
        replayPaneLayout = nil
        replayURL = standardizedURL
        statusText = "คลิปวงล่าสุดพร้อมดูย้อนหลังแล้ว"
        if previousURL != standardizedURL {
          removeTemporaryReplayIfReleased(at: previousURL)
        }
      }

    case .failure(let error):
      request.onFailure(error)
      if request.order == latestRequestedReplayOrder {
        if replayURL == nil {
          statusText = "สร้างคลิปย้อนหลังไม่สำเร็จ: \(error.localizedDescription)"
        } else {
          statusText =
            "สร้างคลิปวงล่าสุดไม่สำเร็จ กำลังแสดงวงก่อนหน้า: \(error.localizedDescription)"
        }
      }
    }

    if queuedRequests.isEmpty {
      isPreparingReplay = false
    } else if queuedRequests.contains(where: { $0.order == latestRequestedReplayOrder }) {
      statusText = "คลิปวงก่อนหน้าพร้อมแล้ว · กำลังสร้างคลิปวงถัดไป…"
    }
    startNextExportIfPossible()
    resumeExportDrainContinuationsIfNeeded()
  }

  /// Returns the URL currently representing this stable history record. The
  /// path may change when a background recovery copy replaces a temporary URL.
  func currentReplayURL(for recordID: UUID) -> URL? {
    guard replayRecordID == recordID else { return nil }
    return replayURL
  }

  private func removeStaleTemporaryReplays() {
    let temporaryDirectory = fileManager.temporaryDirectory
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: temporaryDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for file in files where file.lastPathComponent.hasPrefix(Self.temporaryReplayPrefix) {
      try? fileManager.removeItem(at: file)
    }
  }

  private func loadRecoverableReplays() {
    do {
      try fileManager.createDirectory(
        at: recoveryDirectory,
        withIntermediateDirectories: true
      )
      let files = try fileManager.contentsOfDirectory(
        at: recoveryDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )

      for file in files {
        let standardizedURL = file.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == "mov",
          let recordID = recoveryRecordID(from: standardizedURL)
        else {
          continue
        }

        let markerURL = persistedMarkerURL(for: standardizedURL)
        if fileManager.fileExists(atPath: markerURL.path) {
          try? fileManager.removeItem(at: standardizedURL)
          try? fileManager.removeItem(at: markerURL)
          try? fileManager.removeItem(at: recoveryMetadataURL(for: standardizedURL))
          continue
        }

        trackPendingPersistence(
          standardizedURL,
          recordID: recordID,
          stagePaneLayout: loadRecoveryMetadata(for: standardizedURL)?.stagePaneLayout
        )
      }
    } catch {
      statusText = "ตรวจคลิปที่รอกู้คืนไม่สำเร็จ: \(error.localizedDescription)"
    }
  }

  private func prepareReplayForPersistence(_ sourceURL: URL, recordID: UUID) -> URL {
    let source = sourceURL.standardizedFileURL
    if source.deletingLastPathComponent() == recoveryDirectory {
      return source
    }
    guard isGeneratedTemporaryReplay(source) else { return source }

    do {
      try fileManager.createDirectory(
        at: recoveryDirectory,
        withIntermediateDirectories: true
      )
      let fileExtension = source.pathExtension.isEmpty ? "mov" : source.pathExtension
      let destination =
        recoveryDirectory
        .appendingPathComponent(
          "\(Self.pendingRecoveryPrefix)\(recordID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        )
        .appendingPathExtension(fileExtension)
        .standardizedFileURL

      do {
        // The common same-volume path is a metadata-only rename and remains
        // synchronous so callers can immediately hand the durable URL to history.
        try recoveryMover(source, destination)
        return destination
      } catch {
        // A cross-volume move degrades to a serialized background copy. Return
        // the still-valid source immediately; its history callback gates deletion.
        scheduleRecoveryCopy(
          from: source,
          to: destination,
          recordID: recordID
        )
        return source
      }
    } catch {
      statusText = "เตรียมคลิปสำหรับกู้คืนไม่สำเร็จ: \(error.localizedDescription)"
      return source
    }
  }

  private func scheduleRecoveryCopy(
    from sourceURL: URL,
    to destinationURL: URL,
    recordID: UUID
  ) {
    let source = sourceURL.standardizedFileURL
    let destination = destinationURL.standardizedFileURL
    guard recoveryCopiesBySource[source] == nil else { return }

    let operationID = UUID()
    let operation = RecoveryCopyOperation(
      id: operationID,
      sourceURL: source,
      destinationURL: destination,
      recordID: recordID
    )
    let stagingURL = destination.deletingLastPathComponent()
      .appendingPathComponent(".GolfTrace-recovery-\(operationID.uuidString.lowercased())")
      .appendingPathExtension(destination.pathExtension.isEmpty ? "mov" : destination.pathExtension)
    recoveryCopiesBySource[source] = operation
    beginFileIO(operationID)

    let executor = fileIOExecutor
    let task = Task { [weak self] in
      let result: Result<Void, Error>
      do {
        try await executor.recoverReplay(
          from: source,
          to: destination,
          stagingAt: stagingURL
        )
        result = .success(())
      } catch {
        result = .failure(error)
      }
      self?.finishRecoveryCopy(result, operation: operation)
    }
    fileIOTasks[operationID] = task
  }

  private func finishRecoveryCopy(
    _ result: Result<Void, Error>,
    operation: RecoveryCopyOperation
  ) {
    let source = operation.sourceURL
    let destination = operation.destinationURL
    guard recoveryCopiesBySource[source]?.id == operation.id else {
      if case .success = result {
        scheduleBackgroundRemoval([
          destination,
          persistedMarkerURL(for: destination),
          recoveryMetadataURL(for: destination),
        ])
      }
      finishFileIO(operation.id)
      return
    }

    recoveryCopiesBySource.removeValue(forKey: source)
    switch result {
    case .success:
      if awaitingPersistence.remove(source) != nil {
        awaitingPersistence.insert(destination)
        pendingPersistenceRecordIDs.removeValue(forKey: source)
        pendingPersistenceRecordIDs[destination] = operation.recordID
        let paneLayout = pendingPersistencePaneLayouts.removeValue(forKey: source)
        if let paneLayout {
          pendingPersistencePaneLayouts[destination] = paneLayout
          saveRecoveryMetadata(
            RecoveryReplayMetadata(stagePaneLayout: paneLayout),
            for: destination
          )
        }

        if deliveredRecoveryURLs.remove(source) != nil {
          deliveredRecoveryURLs.insert(destination)
        }
        if failedPersistenceURLs.remove(source) != nil {
          failedPersistenceURLs.insert(destination)
          scheduleBackgroundRemoval([
            source,
            persistedMarkerURL(for: source),
            recoveryMetadataURL(for: source),
          ])
        } else {
          recoveryAliasesBySource[source] = destination
        }

        if replayURL?.standardizedFileURL == source {
          replayURL = destination
        }
      } else {
        // History already persisted the delivered source while recovery copied.
        // The extra recovery artifact is no longer needed.
        scheduleBackgroundRemoval([
          destination,
          persistedMarkerURL(for: destination),
          recoveryMetadataURL(for: destination),
        ])
      }

    case .failure(let error):
      if replayURL?.standardizedFileURL == source {
        statusText = "สำรองคลิปสำหรับกู้คืนไม่สำเร็จ: \(error.localizedDescription)"
      }
    }

    isPreparingReplay =
      activeRequest != nil || !queuedRequests.isEmpty || !recoveryCopiesBySource.isEmpty
    finishFileIO(operation.id)
  }

  private func trackPendingPersistence(
    _ url: URL,
    recordID: UUID,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil
  ) {
    let standardizedURL = url.standardizedFileURL
    awaitingPersistence.insert(standardizedURL)
    pendingPersistenceRecordIDs[standardizedURL] = recordID
    if let stagePaneLayout {
      pendingPersistencePaneLayouts[standardizedURL] = stagePaneLayout
      if standardizedURL.deletingLastPathComponent() == recoveryDirectory {
        saveRecoveryMetadata(
          RecoveryReplayMetadata(stagePaneLayout: stagePaneLayout),
          for: standardizedURL
        )
      }
    }
  }

  private func recoveryRecordID(from url: URL) -> UUID? {
    let name = url.deletingPathExtension().lastPathComponent
    guard name.hasPrefix(Self.pendingRecoveryPrefix) else { return nil }
    let suffix = name.dropFirst(Self.pendingRecoveryPrefix.count)
    guard suffix.count >= 36 else { return nil }
    return UUID(uuidString: String(suffix.prefix(36)))
  }

  private func markPersistenceCompleted(at url: URL) {
    guard url.deletingLastPathComponent() == recoveryDirectory else { return }
    let markerURL = persistedMarkerURL(for: url)
    try? Data().write(to: markerURL, options: .atomic)
  }

  private func persistedMarkerURL(for url: URL) -> URL {
    url.appendingPathExtension(Self.persistedMarkerExtension)
  }

  private func recoveryMetadataURL(for url: URL) -> URL {
    url.appendingPathExtension(Self.recoveryMetadataExtension)
  }

  private func saveRecoveryMetadata(
    _ metadata: RecoveryReplayMetadata,
    for url: URL
  ) {
    guard let data = try? JSONEncoder().encode(metadata) else { return }
    try? data.write(to: recoveryMetadataURL(for: url), options: .atomic)
  }

  private func loadRecoveryMetadata(for url: URL) -> RecoveryReplayMetadata? {
    guard let data = try? Data(contentsOf: recoveryMetadataURL(for: url)) else {
      return nil
    }
    return try? JSONDecoder().decode(RecoveryReplayMetadata.self, from: data)
  }

  private func removeTemporaryReplay(at url: URL?) {
    guard let url, isManagedTemporaryReplay(url) else { return }
    try? fileManager.removeItem(at: url)
    try? fileManager.removeItem(at: persistedMarkerURL(for: url))
    try? fileManager.removeItem(at: recoveryMetadataURL(for: url))
  }

  private func removeTemporaryReplayIfReleased(at url: URL?) {
    guard let url else { return }
    let standardizedURL = url.standardizedFileURL
    guard standardizedURL != replayURL?.standardizedFileURL,
      !awaitingPersistence.contains(standardizedURL)
    else {
      return
    }

    // ไฟล์ที่สร้างสำเร็จต้องมีสำเนาในคลังแล้ว ส่วนไฟล์เก่าจากเวอร์ชันก่อน
    // ไม่มีสถานะรอคัดลอกและล้างได้ตามกติกาเดิม
    guard
      persistedTemporaryReplays.contains(standardizedURL)
        || !isManagedTemporaryReplay(standardizedURL)
    else {
      return
    }
    persistedTemporaryReplays.remove(standardizedURL)
    removeTemporaryReplay(at: standardizedURL)
  }

  private func finishSave(
    _ result: Result<Void, Error>,
    operationID: UUID,
    sourceURL: URL,
    destinationURL: URL
  ) {
    defer { finishFileIO(operationID) }
    guard activeSaveID == operationID else { return }

    activeSaveID = nil
    isSavingReplay = false
    // A late completion from an older replay must not replace the status of a
    // newer replay selected while the background copy was in flight.
    guard replayURL?.standardizedFileURL == sourceURL else { return }

    switch result {
    case .success:
      statusText = "บันทึกคลิปแล้ว: \(destinationURL.lastPathComponent)"
    case .failure(let error):
      statusText = "บันทึกคลิปไม่สำเร็จ: \(error.localizedDescription)"
    }
  }

  private func scheduleBackgroundRemoval(_ urls: [URL]) {
    let standardizedURLs = Array(Set(urls.map(\.standardizedFileURL)))
    guard !standardizedURLs.isEmpty else { return }

    let operationID = UUID()
    beginFileIO(operationID)
    let executor = fileIOExecutor
    let task = Task { [weak self] in
      await executor.removeItems(at: standardizedURLs)
      self?.finishFileIO(operationID)
    }
    fileIOTasks[operationID] = task
  }

  private func beginFileIO(_ operationID: UUID) {
    pendingFileIOIDs.insert(operationID)
  }

  private func finishFileIO(_ operationID: UUID) {
    guard pendingFileIOIDs.remove(operationID) != nil else { return }
    fileIOTasks.removeValue(forKey: operationID)
    resumeExportDrainContinuationsIfNeeded()
  }

  private func resumeExportDrainContinuationsIfNeeded() {
    guard !hasPendingExportWork, !exportDrainContinuations.isEmpty else { return }
    let continuations = exportDrainContinuations
    exportDrainContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func isManagedTemporaryReplay(_ url: URL) -> Bool {
    let standardizedURL = url.standardizedFileURL
    return isGeneratedTemporaryReplay(standardizedURL)
      || (standardizedURL.deletingLastPathComponent() == recoveryDirectory
        && standardizedURL.lastPathComponent.hasPrefix(Self.pendingRecoveryPrefix))
  }

  private func isGeneratedTemporaryReplay(_ url: URL) -> Bool {
    let standardizedURL = url.standardizedFileURL
    let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
    return standardizedURL.deletingLastPathComponent() == temporaryDirectory
      && standardizedURL.lastPathComponent.hasPrefix(Self.temporaryReplayPrefix)
  }

  private func suggestedFileName() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "th_TH")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return "วงสวิง-\(formatter.string(from: Date())).mov"
  }
}
