import CryptoKit
import Foundation
import ImageIO

enum SwingRecordStoreError: LocalizedError {
  case cannotFindApplicationSupport(String)
  case cannotCreateStorage(String)
  case cannotEncodeRecord(String)
  case cannotReadRecord(String)
  case cannotSaveRecord(String)
  case cannotDeleteRecord(String)
  case invalidRecordIdentifier
  case invalidReplayFilename
  case replaySourceNotFound
  case cannotAttachReplay(String)
  case replayAttachedButSourceNotRemoved(String)
  case invalidReplayBundle(String)
  case cannotAttachReplayBundle(String)
  case invalidStoryboardFilename
  case storyboardSourceNotFound
  case cannotAttachStoryboard(String)
  case invalidReplayClockMapping
  case storyboardCaptureMismatch

  var errorDescription: String? {
    switch self {
    case .cannotFindApplicationSupport(let detail):
      return "หาตำแหน่งเก็บข้อมูลของแอปไม่สำเร็จ: \(detail)"
    case .cannotCreateStorage(let detail):
      return "เตรียมพื้นที่เก็บวงสวิงไม่สำเร็จ: \(detail)"
    case .cannotEncodeRecord(let detail):
      return "เตรียมข้อมูลวงสวิงสำหรับบันทึกไม่สำเร็จ: \(detail)"
    case .cannotReadRecord(let detail):
      return "อ่านข้อมูลวงสวิงที่บันทึกไว้ไม่สำเร็จ: \(detail)"
    case .cannotSaveRecord(let detail):
      return "บันทึกข้อมูลวงสวิงไม่สำเร็จ: \(detail)"
    case .cannotDeleteRecord(let detail):
      return "ลบข้อมูลวงสวิงไม่สำเร็จ: \(detail)"
    case .invalidRecordIdentifier:
      return "รหัสวงสวิงในไฟล์ไม่ตรงกับตำแหน่งที่จัดเก็บ"
    case .invalidReplayFilename:
      return "ชื่อไฟล์วิดีโอย้อนหลังไม่ปลอดภัย"
    case .replaySourceNotFound:
      return "ไม่พบไฟล์วิดีโอย้อนหลังที่จะนำมาบันทึก"
    case .cannotAttachReplay(let detail):
      return "แนบวิดีโอย้อนหลังเข้ากับวงสวิงไม่สำเร็จ: \(detail)"
    case .replayAttachedButSourceNotRemoved(let detail):
      return "บันทึกวิดีโอย้อนหลังแล้ว แต่ลบไฟล์ชั่วคราวไม่สำเร็จ: \(detail)"
    case .invalidReplayBundle(let detail):
      return "ข้อมูลชุดวิดีโอย้อนหลังไม่สมบูรณ์: \(detail)"
    case .cannotAttachReplayBundle(let detail):
      return "แนบชุดวิดีโอย้อนหลังเข้ากับวงสวิงไม่สำเร็จ: \(detail)"
    case .invalidStoryboardFilename:
      return "ชื่อไฟล์ภาพ Storyboard ไม่ปลอดภัย"
    case .storyboardSourceNotFound:
      return "ไม่พบไฟล์ภาพ Storyboard ชั่วคราวที่จะนำมาบันทึก"
    case .cannotAttachStoryboard(let detail):
      return "แนบภาพ Storyboard เข้ากับวงสวิงไม่สำเร็จ: \(detail)"
    case .invalidReplayClockMapping:
      return "ข้อมูลเทียบเวลาระหว่างกล้องกับ replay ไม่สมบูรณ์"
    case .storyboardCaptureMismatch:
      return "ภาพ Storyboard มาจากแหล่งหรือแนวกล้องคนละชุดกับวงสวิง"
    }
  }
}

private struct PendingLaunchMonitorShotEnvelope: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  var shots: [LaunchMonitorShot]

  init(shots: [LaunchMonitorShot]) {
    schemaVersion = Self.currentSchemaVersion
    self.shots = shots
  }
}

struct PendingLaunchMonitorShotLoadResult: Equatable, Sendable {
  let shots: [LaunchMonitorShot]
  let didQuarantineCorruptFile: Bool
}

struct SwingRecordLoadResult: Equatable, Sendable {
  let records: [SwingRecord]
  let invalidRecordCount: Int
  let quarantinedRecordCount: Int
  let quarantinedBytes: Int64
  let recoveryDirectoryURL: URL
}

/// คลังข้อมูลวงสวิงในเครื่อง โดยหนึ่งวงอยู่ในโฟลเดอร์ของตัวเอง
///
/// โครงสร้างบนดิสก์คือ `Swings/<record-id>/record.json` และไฟล์ replay (ถ้ามี)
/// ทำให้การลบทั้งวงสวิงเปลี่ยนชื่อโฟลเดอร์ได้ทันที ก่อนค่อยคืนพื้นที่ภายหลัง
final class SwingRecordStore: @unchecked Sendable {
  enum ReplayTransferMode: Equatable, Sendable {
    /// เก็บไฟล์ต้นฉบับไว้ เหมาะกับไฟล์ที่อาจถูกใช้งานจากส่วนอื่นต่อ
    case copy

    /// ลบไฟล์ต้นฉบับหลังแนบและบันทึก record สำเร็จแล้ว
    case move
  }

  static let defaultMaximumRecordCount = 20
  static let defaultMaximumStorageBytes: Int64 = 4_294_967_296

  let directoryURL: URL
  let maximumRecordCount: Int
  let maximumStorageBytes: Int64

  private let fileManager: FileManager
  private let lock = NSLock()
  private var didReconcileReplayBundleDirectories = false
  private let recordFilename = "record.json"
  private let replayBundleManifestFilename = "bundle.json"
  private let pendingLaunchMonitorShotsFilename = ".pending-launch-monitor-shots.json"
  private static let supportedReplayExtensions: Set<String> = ["m4v", "mov", "mp4"]

  var recoveryDirectoryURL: URL {
    directoryURL.appendingPathComponent("Recovery", isDirectory: true)
  }

  convenience init(
    maximumRecordCount: Int = SwingRecordStore.defaultMaximumRecordCount,
    maximumStorageBytes: Int64 = SwingRecordStore.defaultMaximumStorageBytes,
    fileManager: FileManager = .default
  ) throws {
    let applicationSupport: URL
    do {
      applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
    } catch {
      throw SwingRecordStoreError.cannotFindApplicationSupport(error.localizedDescription)
    }

    self.init(
      directoryURL:
        applicationSupport
        .appendingPathComponent("GolfTrace", isDirectory: true)
        .appendingPathComponent("Swings", isDirectory: true),
      maximumRecordCount: maximumRecordCount,
      maximumStorageBytes: maximumStorageBytes,
      fileManager: fileManager
    )
  }

  /// ใช้ initializer นี้ใน tests เพื่อแยกข้อมูลออกจาก Application Support จริง
  init(
    directoryURL: URL,
    maximumRecordCount: Int = SwingRecordStore.defaultMaximumRecordCount,
    maximumStorageBytes: Int64 = SwingRecordStore.defaultMaximumStorageBytes,
    fileManager: FileManager = .default
  ) {
    self.directoryURL = directoryURL.standardizedFileURL
    self.maximumRecordCount = max(1, maximumRecordCount)
    self.maximumStorageBytes = max(1, maximumStorageBytes)
    self.fileManager = fileManager
  }

  /// บันทึก JSON แบบ atomic แล้วตัดวงสวิงเก่าที่เกินจำนวนหรือพื้นที่กำหนด
  func save(_ record: SwingRecord) throws {
    try synchronized {
      try prepareStorageUnlocked()
      try validateManagedArtifactFilenames(in: record)
      try saveRecordUnlocked(record)
      try enforceRetentionLimitsUnlocked()
    }
  }

  /// โหลดวงสวิงทั้งหมด เรียงใหม่สุดก่อนเสมอ
  func loadAll() throws -> [SwingRecord] {
    try synchronized {
      try prepareStorageUnlocked()
      return try loadAllUnlocked()
    }
  }

  /// โหลดวงที่ยังเชื่อถือได้ และแยก package ที่อ่านไม่ได้ออกจากคลังแบบ best effort
  /// เพื่อให้ record เสียเพียงวงเดียวไม่ทำให้ History และการบันทึกวงใหม่หยุดทั้งแอป
  func loadAllRecoveringInvalidRecords() throws -> SwingRecordLoadResult {
    try synchronized {
      try prepareStorageUnlocked()
      return try loadAllRecoveringInvalidRecordsUnlocked()
    }
  }

  func load(id: UUID) throws -> SwingRecord? {
    try synchronized {
      try prepareStorageUnlocked()
      return try loadUnlocked(id: id)
    }
  }

  /// แนบผลจาก launch monitor โดยโหลด record รุ่นล่าสุดภายใน lock ก่อนแก้ไข
  ///
  /// วิธีนี้รักษาทั้ง replay และ metadata ที่งานอื่นอาจเพิ่งบันทึกไว้ และไม่เขียนทับ
  /// ผลลูกเดิมหาก packet ซ้ำหรือมีผลลูกอื่นมาถึงภายหลัง
  @discardableResult
  func attachLaunchMonitorMatch(
    _ match: LaunchMonitorMatch,
    to recordID: UUID
  ) throws -> SwingRecord? {
    try synchronized {
      try prepareStorageUnlocked()
      guard var record = try loadUnlocked(id: recordID) else { return nil }
      guard record.launchMonitorMatch == nil else { return record }

      record.schemaVersion = SwingRecord.currentSchemaVersion
      record.launchMonitorMatch = match
      try saveRecordUnlocked(record)
      try enforceRetentionLimitsUnlocked()
      return record
    }
  }

  /// แนบ clock calibration กับ record รุ่นล่าสุดและคำนวณ seek time ของ phase
  /// จากเวลา camera แบบ absolute เท่านั้น Marker นอกช่วง anchor จะคง nil
  /// แทนการ extrapolate หรือเดาเวลาใน replay
  @discardableResult
  func attachReplayClockMapping(
    _ mapping: SwingReplayClockMapping,
    cameraSwingStartSeconds: TimeInterval,
    to recordID: UUID
  ) throws -> SwingRecord? {
    try synchronized {
      try prepareStorageUnlocked()
      guard Self.isValidReplayClockMapping(mapping),
        cameraSwingStartSeconds.isFinite
      else {
        throw SwingRecordStoreError.invalidReplayClockMapping
      }
      guard var record = try loadUnlocked(id: recordID),
        var artifacts = record.artifacts
      else { return nil }

      artifacts.replayClockMapping = mapping
      artifacts.phaseMarkers = artifacts.phaseMarkers.map { marker in
        var updated = marker
        let absoluteCameraTime =
          cameraSwingStartSeconds + (Double(marker.sourceTimestampMs) / 1_000)
        if let replayTime = mapping.replayTimeSeconds(
          forCameraTimeSeconds: absoluteCameraTime
        ), replayTime >= 0 {
          updated.replayTimestampMs = Int((replayTime * 1_000).rounded())
        } else {
          updated.replayTimestampMs = nil
        }
        return updated
      }
      record.schemaVersion = SwingRecord.currentSchemaVersion
      record.artifacts = artifacts
      try saveRecordUnlocked(record)
      try enforceRetentionLimitsUnlocked()
      return record
    }
  }

  /// เก็บค่าจาก launch monitor ทันที แม้ยังไม่มีวงสวิงที่จับคู่ได้
  ///
  /// ไฟล์นี้เป็นกล่องพักถาวรแยกจาก record เพื่อให้ค่าการตีไม่หายเมื่อแอปปิด
  /// หรือเมื่อตัวตรวจจับท่าทางพลาดวงนั้น การเขียนซ้ำด้วย UUID ของช็อตเดิมจะไม่เพิ่มข้อมูล
  @discardableResult
  func savePendingLaunchMonitorShot(_ shot: LaunchMonitorShot) throws -> Bool {
    try synchronized {
      try prepareStorageUnlocked()

      let isAlreadyAttached = try loadAllUnlocked().contains {
        $0.launchMonitorMatch?.shot.id == shot.id
      }
      guard !isAlreadyAttached else { return false }

      var pendingShots = try loadPendingLaunchMonitorShotsUnlocked()
      guard !pendingShots.contains(where: { $0.id == shot.id }) else {
        return false
      }
      pendingShots.append(shot)
      pendingShots.sort(by: Self.launchMonitorShotSortOrder)
      try savePendingLaunchMonitorShotsUnlocked(pendingShots)
      return true
    }
  }

  func loadPendingLaunchMonitorShots() throws -> [LaunchMonitorShot] {
    try synchronized {
      try prepareStorageUnlocked()
      return try loadPendingLaunchMonitorShotsUnlocked()
    }
  }

  /// อ่านกล่องพักโดยแยกความเสียหายของไฟล์นี้ออกจากคลังวงสวิงหลัก
  ///
  /// ไฟล์ที่อ่านไม่ได้จะถูกเปลี่ยนชื่อเก็บไว้สำหรับตรวจสอบ ไม่ลบทิ้ง จากนั้นแอปยัง
  /// โหลดและบันทึก record ปกติต่อได้
  func loadPendingLaunchMonitorShotsRecoveringCorruptFile() throws
    -> PendingLaunchMonitorShotLoadResult
  {
    try synchronized {
      try prepareStorageUnlocked()
      do {
        return PendingLaunchMonitorShotLoadResult(
          shots: try loadPendingLaunchMonitorShotsUnlocked(),
          didQuarantineCorruptFile: false
        )
      } catch {
        try quarantinePendingLaunchMonitorShotsUnlocked()
        return PendingLaunchMonitorShotLoadResult(
          shots: [],
          didQuarantineCorruptFile: true
        )
      }
    }
  }

  func removePendingLaunchMonitorShot(shotID: UUID) throws {
    try synchronized {
      try prepareStorageUnlocked()
      let existing = try loadPendingLaunchMonitorShotsUnlocked()
      let retained = existing.filter { $0.id != shotID }
      guard retained.count != existing.count else { return }
      try savePendingLaunchMonitorShotsUnlocked(retained)
    }
  }

  /// ซ่อมงานที่ค้างจากการปิดหรือ crash ระหว่างบันทึก record กับการแนบค่าลูก
  ///
  /// การจับคู่ใช้กติกา FIFO และช่วงเวลาเดียวกับหน้าจอหลัก จากนั้นลบเฉพาะค่าที่แนบ
  /// สำเร็จแล้วออกจากกล่องพัก การทำงานทั้งหมดอยู่ภายใน lock เดียวกัน
  @discardableResult
  func reconcilePendingLaunchMonitorShots(
    matchingWindowSeconds: TimeInterval = ShotSwingMatchController.defaultMatchingWindowSeconds,
    matchedAt: Date = Date()
  ) throws -> Int {
    try synchronized {
      try prepareStorageUnlocked()
      let records = try loadAllUnlocked()
      let attachedShotIDs = Set(
        records.compactMap { $0.launchMonitorMatch?.shot.id }
      )
      let loadedPendingShots = try loadPendingLaunchMonitorShotsUnlocked()
      var pendingShots = loadedPendingShots.filter {
        !attachedShotIDs.contains($0.id)
      }
      pendingShots.sort(by: Self.launchMonitorShotSortOrder)

      var matchedCount = 0
      for record in records.reversed() where record.launchMonitorMatch == nil {
        guard
          let shotIndex = Self.closestLaunchMonitorShotIndex(
            in: pendingShots,
            to: record.createdAt,
            matchingWindowSeconds: matchingWindowSeconds
          )
        else {
          continue
        }

        let shot = pendingShots.remove(at: shotIndex)
        var updatedRecord = record
        updatedRecord.schemaVersion = SwingRecord.currentSchemaVersion
        updatedRecord.launchMonitorMatch = LaunchMonitorMatch(
          shot: shot,
          swingOccurredAt: record.createdAt,
          matchedAt: matchedAt,
          matchingWindowSeconds: matchingWindowSeconds
        )
        try saveRecordUnlocked(updatedRecord)
        matchedCount += 1
      }

      if pendingShots != loadedPendingShots {
        try savePendingLaunchMonitorShotsUnlocked(pendingShots)
      }
      return matchedCount
    }
  }

  /// ลบ record และ replay ในการเปลี่ยนชื่อโฟลเดอร์ครั้งเดียว
  func delete(_ record: SwingRecord) throws {
    try delete(id: record.id)
  }

  func delete(id: UUID) throws {
    try synchronized {
      try prepareStorageUnlocked()
      try deleteRecordDirectoryUnlocked(id: id)
    }
  }

  /// แนบ replay ผ่านไฟล์ staging ในโฟลเดอร์ปลายทางก่อน จึงไม่ทิ้งไฟล์ครึ่งหนึ่ง
  /// หากเกิดข้อผิดพลาด record เดิมและ replay เดิมจะยังใช้งานได้
  @discardableResult
  func attachReplay(
    from sourceURL: URL,
    to record: SwingRecord,
    transferMode: ReplayTransferMode = .copy,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil
  ) throws -> SwingRecord {
    try synchronized {
      try prepareStorageUnlocked()
      // Validate the caller-supplied record before creating any destination file. In
      // particular, a forged replayFilename of record.json must never reach the
      // replacement cleanup below.
      try validateManagedArtifactFilenames(in: record)

      let source = sourceURL.standardizedFileURL
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw SwingRecordStoreError.replaySourceNotFound
      }

      let recordDirectory = try prepareRecordDirectoryForWriteUnlocked(id: record.id)

      let fileExtension = safeReplayExtension(from: source)
      let replayFilename = "replay-\(UUID().uuidString.lowercased()).\(fileExtension)"
      try validateReplayFilename(replayFilename)
      let destination = recordDirectory.appendingPathComponent(replayFilename)
      let staging = recordDirectory.appendingPathComponent(
        ".attaching-\(UUID().uuidString.lowercased()).tmp"
      )
      defer { try? fileManager.removeItem(at: staging) }

      do {
        try fileManager.copyItem(at: source, to: staging)
        // การย้ายภายในโฟลเดอร์เดียวกันเป็นการสลับชื่อไฟล์ใน filesystem
        // จึงไม่มีช่วงที่ destination มีข้อมูลเพียงบางส่วน
        try fileManager.moveItem(at: staging, to: destination)
      } catch {
        throw SwingRecordStoreError.cannotAttachReplay(error.localizedDescription)
      }

      var updatedRecord = record
      let previousReplayFilename = updatedRecord.replayFilename
      updatedRecord.replayFilename = replayFilename
      if let stagePaneLayout {
        updatedRecord.setStageReplayPaneLayout(stagePaneLayout)
      } else {
        // A raw-camera fallback must never inherit window-composite pane
        // coordinates from an older replay attached to the same record.
        updatedRecord.clearStageReplayPaneLayout()
      }

      do {
        try saveRecordUnlocked(updatedRecord)
      } catch {
        removeRegularManagedFileIfPresent(
          named: replayFilename,
          recordID: record.id
        )
        throw error
      }

      if let previousReplayFilename,
        previousReplayFilename != replayFilename
      {
        removeRegularManagedFileIfPresent(
          named: previousReplayFilename,
          recordID: record.id
        )
      }

      if transferMode == .move, source != destination {
        do {
          try fileManager.removeItem(at: source)
        } catch {
          throw SwingRecordStoreError.replayAttachedButSourceNotRemoved(
            error.localizedDescription
          )
        }
      }

      try enforceRetentionLimitsUnlocked()
      return updatedRecord
    }
  }

  /// คืนตำแหน่ง replay ที่อยู่ภายในคลัง โดยไม่อนุญาต path ที่ออกนอกโฟลเดอร์ record
  func replayURL(for record: SwingRecord) throws -> URL? {
    // Intentionally lock-free: attachReplay can hold the mutation lock while it
    // copies a large movie. History renders this lookup on MainActor and must not
    // wait for that copy. All inputs below are immutable and FileManager stat/path
    // operations are safe to perform concurrently with the serialized mutations.
    guard let replayFilename = record.replayFilename else { return nil }
    try validateManagedArtifactFilenames(in: record)
    return regularManagedFileURLIfSafe(
      named: replayFilename,
      recordID: record.id
    )
  }

  /// Commits a camera master and an optional Rapsodo companion as one replay
  /// generation. Both files and their manifest are completed in a hidden
  /// directory first; one same-directory rename publishes the generation and
  /// the atomic `record.json` replacement is the authoritative commit point.
  ///
  /// The legacy `replayFilename` is intentionally preserved. It may contain a
  /// whole-stage movie for older playback surfaces while newer clients prefer
  /// the independent bundle.
  @discardableResult
  func attachReplayBundle(
    cameraSourceURL: URL,
    rapsodoSourceURL: URL? = nil,
    bundle requestedBundle: SwingReplayBundle,
    to recordID: UUID,
    transferMode: ReplayTransferMode = .copy
  ) throws -> SwingRecord? {
    try synchronized { () -> SwingRecord? in
      try prepareStorageUnlocked()
      guard var record = try loadUnlocked(id: recordID) else { return nil }

      if record.replayBundle?.id == requestedBundle.id {
        guard try replayBundleURLs(for: record) != nil else {
          throw SwingRecordStoreError.invalidReplayBundle(
            "รหัสชุดวิดีโอซ้ำกับชุดที่บันทึกไว้แต่ไฟล์เดิมไม่สมบูรณ์"
          )
        }
        return record
      }

      guard requestedBundle.schema == SwingReplayBundle.schemaVersion,
        requestedBundle.camera.role == .swingCamera,
        !requestedBundle.camera.sourceKind.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty
      else {
        throw SwingRecordStoreError.invalidReplayBundle("ข้อมูลกล้องหลักไม่ถูกต้อง")
      }
      let cameraSource = try validatedReplaySourceURL(cameraSourceURL)
      // Rapsodo is a best-effort companion. A missing, stale, symlinked, or
      // mismatched source must not prevent the irreplaceable camera master from
      // reaching History.
      let requestedRapsodo: (descriptor: SwingReplayAsset, source: URL)?
      if let descriptor = requestedBundle.rapsodo,
        descriptor.role == .rapsodoScreen,
        !descriptor.sourceKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let sourceURL = rapsodoSourceURL,
        let source = try? validatedReplaySourceURL(sourceURL),
        source.resolvingSymlinksInPath().standardizedFileURL
          != cameraSource.resolvingSymlinksInPath().standardizedFileURL
      {
        requestedRapsodo = (descriptor: descriptor, source: source)
      } else {
        requestedRapsodo = nil
      }

      let recordDirectory = try prepareRecordDirectoryForWriteUnlocked(id: recordID)
      let bundleDirectoryName = replayBundleDirectoryName(for: requestedBundle.id)
      let destinationDirectory = recordDirectory.appendingPathComponent(
        bundleDirectoryName,
        isDirectory: true
      )
      if itemType(at: destinationDirectory) != nil {
        // A visible but unreferenced generation can remain after a crash between
        // directory publication and the record commit. It is safe to replace as
        // the current record does not name this bundle ID.
        guard
          canonicalReplayBundleDirectoryURLIfSafe(
            bundleID: requestedBundle.id,
            recordID: recordID
          ) != nil
        else {
          throw SwingRecordStoreError.cannotAttachReplayBundle(
            "โฟลเดอร์ชุดวิดีโอเดิมไม่ปลอดภัย"
          )
        }
        do {
          try fileManager.removeItem(at: destinationDirectory)
        } catch {
          throw SwingRecordStoreError.cannotAttachReplayBundle(error.localizedDescription)
        }
      }

      let stagingDirectory = recordDirectory.appendingPathComponent(
        ".attaching-replay-bundle-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      defer { try? fileManager.removeItem(at: stagingDirectory) }

      var managedBundle = requestedBundle
      managedBundle.schema = SwingReplayBundle.schemaVersion
      do {
        try fileManager.createDirectory(
          at: stagingDirectory,
          withIntermediateDirectories: false
        )

        managedBundle.camera = try copyReplayAsset(
          requestedBundle.camera,
          role: .swingCamera,
          from: cameraSource,
          to: stagingDirectory
        )

        if let requestedRapsodo {
          // Companion copy/inspection is deliberately recoverable. The camera
          // generation still commits and advertises `cameraSaved` if Rapsodo is
          // unavailable or incomplete at this point.
          managedBundle.rapsodo = try? copyReplayAsset(
            requestedRapsodo.descriptor,
            role: .rapsodoScreen,
            from: requestedRapsodo.source,
            to: stagingDirectory
          )
          if let copiedRapsodo = managedBundle.rapsodo {
            do {
              try validateReplayAsset(copiedRapsodo)
            } catch {
              try? fileManager.removeItem(
                at: stagingDirectory.appendingPathComponent(copiedRapsodo.filename)
              )
              managedBundle.rapsodo = nil
            }
          }
        } else {
          managedBundle.rapsodo = nil
        }

        if managedBundle.rapsodo == nil
          || managedBundle.synchronization?.validationIssues.isEmpty != true
        {
          managedBundle.synchronization = nil
          managedBundle.status = .cameraSaved
        } else {
          managedBundle.status = .synchronizedPair
        }
        try validateReplayBundle(managedBundle)

        let manifestData = try makeEncoder().encode(managedBundle)
        try manifestData.write(
          to: stagingDirectory.appendingPathComponent(replayBundleManifestFilename),
          options: .atomic
        )
        try fileManager.moveItem(at: stagingDirectory, to: destinationDirectory)
      } catch let error as SwingRecordStoreError {
        throw error
      } catch {
        throw SwingRecordStoreError.cannotAttachReplayBundle(error.localizedDescription)
      }

      let previousBundleID = record.replayBundle?.id
      record.schemaVersion = SwingRecord.currentSchemaVersion
      record.replayBundle = managedBundle
      do {
        try saveRecordUnlocked(record)
      } catch {
        removeManagedReplayBundleDirectoryIfPresent(
          bundleID: managedBundle.id,
          recordID: recordID
        )
        throw error
      }

      if let previousBundleID, previousBundleID != managedBundle.id {
        removeManagedReplayBundleDirectoryIfPresent(
          bundleID: previousBundleID,
          recordID: recordID
        )
      }

      if transferMode == .move {
        var removalErrors: [String] = []
        let committedSources = [
          cameraSource,
          managedBundle.rapsodo == nil ? nil : requestedRapsodo?.source,
        ].compactMap { $0 }
        for source in committedSources {
          do {
            try fileManager.removeItem(at: source)
          } catch {
            removalErrors.append(error.localizedDescription)
          }
        }
        if !removalErrors.isEmpty {
          throw SwingRecordStoreError.replayAttachedButSourceNotRemoved(
            removalErrors.joined(separator: " • ")
          )
        }
      }

      try enforceRetentionLimitsUnlocked()
      return record
    }
  }

  /// Resolves the required camera master and, independently, the optional
  /// Rapsodo companion. Damage to the companion degrades availability to
  /// `cameraSaved`; it never hides a valid camera master.
  func replayBundleURLs(for record: SwingRecord) throws -> SwingReplayBundleURLs? {
    guard let bundle = record.replayBundle else { return nil }
    try validateManagedArtifactFilenames(in: record)
    guard
      let bundleDirectory = canonicalReplayBundleDirectoryURLIfSafe(
        bundleID: bundle.id,
        recordID: record.id
      ),
      let manifestURL = regularManagedReplayBundleFileURLIfSafe(
        named: replayBundleManifestFilename,
        bundleDirectory: bundleDirectory
      ),
      let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? makeDecoder().decode(SwingReplayBundle.self, from: manifestData),
      manifest == bundle,
      let cameraURL = regularManagedReplayBundleFileURLIfSafe(
        named: bundle.camera.filename,
        bundleDirectory: bundleDirectory
      ),
      replayAssetFileMatchesDescriptor(cameraURL, descriptor: bundle.camera)
    else {
      return nil
    }

    let rapsodoURL: URL?
    if let descriptor = bundle.rapsodo,
      let resolved = regularManagedReplayBundleFileURLIfSafe(
        named: descriptor.filename,
        bundleDirectory: bundleDirectory
      ),
      replayAssetFileMatchesDescriptor(resolved, descriptor: descriptor)
    {
      rapsodoURL = resolved
    } else {
      rapsodoURL = nil
    }
    return SwingReplayBundleURLs(
      bundle: bundle,
      cameraURL: cameraURL,
      rapsodoURL: rapsodoURL
    )
  }

  /// แนบ JPEG ทุก phase ผ่าน staging แล้วแก้ record รุ่นล่าสุดภายใน lock เดียวกัน
  /// เท่านั้น หาก record ถูกลบไประหว่าง export จะคืน nil และไม่สร้างโฟลเดอร์นั้นกลับมา
  @discardableResult
  func attachStoryboardKeyframes(
    _ exportedKeyframes: [CameraStoryboardKeyframeArtifact],
    captureSourceID: String,
    captureOrientation: SwingStoryboardCaptureOrientation,
    to recordID: UUID
  ) throws -> SwingRecord? {
    try synchronized {
      try prepareStorageUnlocked()
      guard var record = try loadUnlocked(id: recordID),
        var artifacts = record.artifacts
      else { return nil }
      guard artifacts.capture.sourceID == captureSourceID,
        artifacts.capture.orientation == captureOrientation
      else {
        throw SwingRecordStoreError.storyboardCaptureMismatch
      }

      let exportedBySlot = Dictionary(
        exportedKeyframes.map { ($0.slot, $0) },
        uniquingKeysWith: { current, _ in current }
      )
      let existingBySlot = Dictionary(
        artifacts.keyframes.map { ($0.slot, $0) },
        uniquingKeysWith: { current, candidate in
          current.state == .available ? current : candidate
        }
      )
      let recordDirectory = recordDirectoryURL(for: recordID)
      var stagedURLs: [URL] = []
      var committedURLs: [URL] = []
      var descriptors: [SwingStoryboardKeyframeDescriptor] = []
      defer {
        for url in stagedURLs { try? fileManager.removeItem(at: url) }
      }

      do {
        for marker in artifacts.phaseMarkers {
          guard let exported = exportedBySlot[marker.slot],
            exported.requestedSourceTimestampMs == marker.sourceTimestampMs
          else {
            descriptors.append(
              failedStoryboardDescriptor(
                marker: marker,
                existing: existingBySlot[marker.slot],
                limitation: "ผล keyframe ไม่ตรงกับ phase ที่บันทึกไว้"
              )
            )
            continue
          }

          guard exported.state == .available else {
            descriptors.append(
              failedStoryboardDescriptor(
                marker: marker,
                existing: existingBySlot[marker.slot],
                state: exported.state,
                limitation: exported.limitation ?? "ไม่มีภาพสำหรับ phase นี้"
              )
            )
            continue
          }

          guard let sourceURL = exported.temporaryJPEGURL?.standardizedFileURL,
            fileManager.fileExists(atPath: sourceURL.path)
          else {
            throw SwingRecordStoreError.storyboardSourceNotFound
          }
          let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
          guard !data.isEmpty,
            let dimensions = Self.jpegDimensions(data)
          else {
            throw SwingRecordStoreError.cannotAttachStoryboard(
              "ไฟล์ JPEG ของ \(marker.slot.titleEN) อ่านไม่ได้"
            )
          }

          let filename =
            "storyboard-\(marker.slot.rawValue)-\(UUID().uuidString.lowercased()).jpg"
          try validateStoryboardFilenames([filename])
          let destination = recordDirectory.appendingPathComponent(filename)
          let staging = recordDirectory.appendingPathComponent(
            ".attaching-storyboard-\(UUID().uuidString.lowercased()).tmp"
          )
          try fileManager.copyItem(at: sourceURL, to: staging)
          stagedURLs.append(staging)

          let existing = existingBySlot[marker.slot]
          descriptors.append(
            SwingStoryboardKeyframeDescriptor(
              slot: marker.slot,
              sourceTimestampMs: marker.sourceTimestampMs,
              nearestPoseTimestampMs: existing?.nearestPoseTimestampMs,
              alignmentDeltaMs: existing?.alignmentDeltaMs,
              state: .available,
              imageContentID: existing?.imageContentID,
              filename: filename,
              contentSHA256: Self.sha256Hex(data),
              pixelWidth: dimensions.width,
              pixelHeight: dimensions.height,
              extractedSourceTimestampMs: exported.extractedSourceTimestampMs,
              byteCount: data.count,
              limitation: exported.limitation
            )
          )
          // Keep destination paired with this staging in the same order.
          committedURLs.append(destination)
        }

        for (staging, destination) in zip(stagedURLs, committedURLs) {
          try fileManager.moveItem(at: staging, to: destination)
        }
      } catch let error as SwingRecordStoreError {
        for url in committedURLs { try? fileManager.removeItem(at: url) }
        throw error
      } catch {
        for url in committedURLs { try? fileManager.removeItem(at: url) }
        throw SwingRecordStoreError.cannotAttachStoryboard(error.localizedDescription)
      }

      let previousFilenames = Set(artifacts.keyframes.compactMap(\.filename))
      artifacts.keyframes = descriptors
      record.schemaVersion = SwingRecord.currentSchemaVersion
      record.artifacts = artifacts
      do {
        try saveRecordUnlocked(record)
      } catch {
        for url in committedURLs { try? fileManager.removeItem(at: url) }
        throw error
      }

      let retainedFilenames = Set(descriptors.compactMap(\.filename))
      for filename in previousFilenames.subtracting(retainedFilenames) {
        if (try? validateStoryboardFilenames([filename])) != nil {
          removeRegularManagedFileIfPresent(
            named: filename,
            recordID: recordID
          )
        }
      }
      try enforceRetentionLimitsUnlocked()
      return record
    }
  }

  /// บันทึก failure ต่อ phase โดยไม่ทำลาย JPEG ที่เคยสำเร็จจากการลองก่อนหน้า
  @discardableResult
  func markStoryboardKeyframesFailed(
    for recordID: UUID,
    limitation: String
  ) throws -> SwingRecord? {
    try synchronized {
      try prepareStorageUnlocked()
      guard var record = try loadUnlocked(id: recordID),
        var artifacts = record.artifacts
      else { return nil }
      let existingBySlot = Dictionary(
        artifacts.keyframes.map { ($0.slot, $0) },
        uniquingKeysWith: { current, candidate in
          current.state == .available ? current : candidate
        }
      )
      artifacts.keyframes = artifacts.phaseMarkers.map {
        failedStoryboardDescriptor(
          marker: $0,
          existing: existingBySlot[$0.slot],
          limitation: limitation
        )
      }
      record.schemaVersion = SwingRecord.currentSchemaVersion
      record.artifacts = artifacts
      try saveRecordUnlocked(record)
      return record
    }
  }

  func storyboardKeyframeURL(
    for record: SwingRecord,
    slot: SwingStoryboardPhaseSlot
  ) throws -> URL? {
    // This is also called repeatedly while History lays out storyboard cards.
    // Keep it independent from the coarse mutation lock for the same reason as
    // replayURL(for:).
    guard
      let filename = record.artifacts?.keyframes.first(where: { $0.slot == slot })?
        .filename
    else { return nil }
    try validateManagedArtifactFilenames(in: record)
    return regularManagedFileURLIfSafe(
      named: filename,
      recordID: record.id
    )
  }

  private func saveRecordUnlocked(_ record: SwingRecord) throws {
    try validateManagedArtifactFilenames(in: record)

    let data: Data
    do {
      data = try makeEncoder().encode(record)
    } catch {
      throw SwingRecordStoreError.cannotEncodeRecord(error.localizedDescription)
    }

    let recordDirectory = try prepareRecordDirectoryForWriteUnlocked(id: record.id)
    let recordURL = recordDirectory.appendingPathComponent(recordFilename)
    if let existingType = itemType(at: recordURL), existingType != .typeRegular {
      throw SwingRecordStoreError.cannotSaveRecord(
        "\(recordFilename) ไม่ใช่ไฟล์ปกติภายในโฟลเดอร์วงสวิง"
      )
    }
    do {
      try data.write(
        to: recordURL,
        options: .atomic
      )
    } catch {
      throw SwingRecordStoreError.cannotSaveRecord(error.localizedDescription)
    }
  }

  private func loadAllUnlocked() throws -> [SwingRecord] {
    let directoryContents: [URL]
    do {
      directoryContents = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw SwingRecordStoreError.cannotReadRecord(error.localizedDescription)
    }

    let records = try directoryContents.compactMap { url -> SwingRecord? in
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true,
        let directoryID = UUID(uuidString: url.lastPathComponent)
      else {
        return nil
      }
      guard let record = try loadUnlocked(id: directoryID) else { return nil }
      guard record.id == directoryID else {
        throw SwingRecordStoreError.invalidRecordIdentifier
      }
      return record
    }

    return records.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  private func loadAllRecoveringInvalidRecordsUnlocked() throws -> SwingRecordLoadResult {
    let directoryContents: [URL]
    do {
      directoryContents = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw SwingRecordStoreError.cannotReadRecord(error.localizedDescription)
    }

    var records: [SwingRecord] = []
    var invalidRecordCount = 0
    var quarantinedRecordCount = 0

    for url in directoryContents {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true,
        let directoryID = UUID(uuidString: url.lastPathComponent)
      else {
        continue
      }

      do {
        guard let record = try loadUnlocked(id: directoryID) else { continue }
        guard record.id == directoryID else {
          throw SwingRecordStoreError.invalidRecordIdentifier
        }
        records.append(record)
      } catch {
        invalidRecordCount += 1
        if quarantineInvalidRecordDirectoryUnlocked(id: directoryID) {
          quarantinedRecordCount += 1
        }
      }
    }

    records.sort {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id.uuidString < $1.id.uuidString
    }
    return SwingRecordLoadResult(
      records: records,
      invalidRecordCount: invalidRecordCount,
      quarantinedRecordCount: quarantinedRecordCount,
      quarantinedBytes: allocatedSize(of: recoveryDirectoryURL),
      recoveryDirectoryURL: recoveryDirectoryURL
    )
  }

  private func loadUnlocked(id: UUID) throws -> SwingRecord? {
    let declaredRecordURL = recordDirectoryURL(for: id).appendingPathComponent(recordFilename)
    guard itemType(at: declaredRecordURL) != nil else { return nil }
    guard
      let recordURL = regularManagedFileURLIfSafe(
        named: recordFilename,
        recordID: id
      )
    else {
      throw SwingRecordStoreError.cannotReadRecord(
        "\(recordFilename) ไม่ใช่ไฟล์ปกติภายในโฟลเดอร์วงสวิง"
      )
    }

    do {
      let data = try Data(contentsOf: recordURL)
      let record = try makeDecoder().decode(SwingRecord.self, from: data)
      guard record.id == id else {
        throw SwingRecordStoreError.invalidRecordIdentifier
      }
      try validateManagedArtifactFilenames(in: record)
      return record
    } catch let error as SwingRecordStoreError {
      throw error
    } catch {
      throw SwingRecordStoreError.cannotReadRecord(
        "\(recordURL.lastPathComponent): \(error.localizedDescription)"
      )
    }
  }

  private func loadPendingLaunchMonitorShotsUnlocked() throws -> [LaunchMonitorShot] {
    let url = directoryURL.appendingPathComponent(pendingLaunchMonitorShotsFilename)
    guard fileManager.fileExists(atPath: url.path) else { return [] }

    do {
      let envelope = try makeDecoder().decode(
        PendingLaunchMonitorShotEnvelope.self,
        from: Data(contentsOf: url)
      )
      guard envelope.schemaVersion == PendingLaunchMonitorShotEnvelope.currentSchemaVersion else {
        throw SwingRecordStoreError.cannotReadRecord(
          "รุ่นไฟล์ค่าจาก launch monitor ไม่รองรับ"
        )
      }

      var seenIDs: Set<UUID> = []
      return envelope.shots
        .sorted(by: Self.launchMonitorShotSortOrder)
        .filter { seenIDs.insert($0.id).inserted }
    } catch let error as SwingRecordStoreError {
      throw error
    } catch {
      throw SwingRecordStoreError.cannotReadRecord(
        "ค่าจาก launch monitor: \(error.localizedDescription)"
      )
    }
  }

  private func savePendingLaunchMonitorShotsUnlocked(_ shots: [LaunchMonitorShot]) throws {
    let url = directoryURL.appendingPathComponent(pendingLaunchMonitorShotsFilename)
    if shots.isEmpty {
      guard fileManager.fileExists(atPath: url.path) else { return }
      do {
        try fileManager.removeItem(at: url)
      } catch {
        throw SwingRecordStoreError.cannotSaveRecord(
          "ล้างค่าจาก launch monitor ที่จับคู่แล้วไม่สำเร็จ: \(error.localizedDescription)"
        )
      }
      return
    }

    do {
      let data = try makeEncoder().encode(PendingLaunchMonitorShotEnvelope(shots: shots))
      try data.write(to: url, options: .atomic)
    } catch {
      throw SwingRecordStoreError.cannotSaveRecord(
        "เก็บค่าจาก launch monitor ไม่สำเร็จ: \(error.localizedDescription)"
      )
    }
  }

  private func quarantinePendingLaunchMonitorShotsUnlocked() throws {
    let source = directoryURL.appendingPathComponent(pendingLaunchMonitorShotsFilename)
    guard fileManager.fileExists(atPath: source.path) else { return }
    let destination = directoryURL.appendingPathComponent(
      ".invalid-pending-launch-monitor-shots-\(UUID().uuidString.lowercased()).json"
    )
    do {
      try fileManager.moveItem(at: source, to: destination)
    } catch {
      throw SwingRecordStoreError.cannotSaveRecord(
        "แยกไฟล์ค่าจาก launch monitor ที่อ่านไม่ได้ไม่สำเร็จ: \(error.localizedDescription)"
      )
    }
  }

  /// ย้ายเฉพาะ UUID directory จริงที่ยังอยู่ใต้ Swings; symlink หรือ path ที่ไม่ปลอดภัย
  /// จะถูกข้ามโดยไม่ตามปลายทาง และยังไม่นำมาปนกับผล History ที่เชื่อถือได้
  @discardableResult
  private func quarantineInvalidRecordDirectoryUnlocked(id: UUID) -> Bool {
    let declared = recordDirectoryURL(for: id)
    let source: URL
    switch itemType(at: declared) {
    case .typeDirectory:
      guard let canonical = canonicalRecordDirectoryURLIfSafe(for: id) else { return false }
      source = canonical
    case .typeSymbolicLink:
      // ย้ายตัว symlink เองโดยไม่ resolve หรือตามไปแตะปลายทาง
      source = declared
    default:
      return false
    }

    let recoveryDirectory = recoveryDirectoryURL
    let destination = recoveryDirectory.appendingPathComponent(
      "invalid-record-\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(
        at: recoveryDirectory,
        withIntermediateDirectories: true
      )
      try fileManager.moveItem(at: source, to: destination)
      return true
    } catch {
      return false
    }
  }

  private func enforceRetentionLimitsUnlocked() throws {
    let records = try loadAllUnlocked()
    var retainedCount = 0
    // ไฟล์กู้คืนไม่ถูกลบทิ้งเงียบ ๆ แต่ยังนับรวมใน quota เพื่อไม่ให้หน้า History
    // อ้างว่าคลังอยู่ใต้ขีดจำกัดทั้งที่ package ที่แยกไว้กินพื้นที่อยู่จริง
    var retainedBytes = allocatedSize(of: recoveryDirectoryURL)

    for record in records {
      let packageBytes = allocatedSize(of: recordDirectoryURL(for: record.id))
      let fitsCount = retainedCount < maximumRecordCount
      let fitsStorage = retainedBytes + packageBytes <= maximumStorageBytes
      // เก็บวงใหม่สุดอย่างน้อยหนึ่งวง แม้ replay วงเดียวจะใหญ่กว่าค่าที่ตั้งไว้
      if retainedCount == 0 || (fitsCount && fitsStorage) {
        retainedCount += 1
        retainedBytes += packageBytes
      } else {
        try deleteRecordDirectoryUnlocked(id: record.id)
      }
    }
  }

  private func allocatedSize(of directory: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .fileAllocatedSizeKey,
      .totalFileAllocatedSizeKey,
      .fileSizeKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else {
        continue
      }
      let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
      total += Int64(bytes)
    }
    return total
  }

  private func deleteRecordDirectoryUnlocked(id: UUID) throws {
    let declaredRecordDirectory = recordDirectoryURL(for: id)
    guard itemType(at: declaredRecordDirectory) != nil else { return }
    guard let recordDirectory = canonicalRecordDirectoryURLIfSafe(for: id) else {
      throw SwingRecordStoreError.cannotDeleteRecord(
        "โฟลเดอร์วงสวิงไม่ใช่โฟลเดอร์ปกติภายในคลัง"
      )
    }

    let tombstone = directoryURL.appendingPathComponent(
      ".deleting-\(id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    do {
      // เปลี่ยนชื่อก่อน เพื่อให้ load ครั้งถัดไปมองว่า record ถูกลบทันที
      try fileManager.moveItem(at: recordDirectory, to: tombstone)
      try fileManager.removeItem(at: tombstone)
    } catch {
      throw SwingRecordStoreError.cannotDeleteRecord(error.localizedDescription)
    }
  }

  private func prepareStorageUnlocked() throws {
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      let staleTombstones = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: []
      ).filter { $0.lastPathComponent.hasPrefix(".deleting-") }
      for tombstone in staleTombstones {
        try? fileManager.removeItem(at: tombstone)
      }
      if !didReconcileReplayBundleDirectories {
        try reconcileReplayBundleDirectoriesUnlocked()
        didReconcileReplayBundleDirectories = true
      }
    } catch {
      throw SwingRecordStoreError.cannotCreateStorage(error.localizedDescription)
    }
  }

  /// Removes only incomplete hidden bundle transactions and complete bundle
  /// generations not referenced by a decodable `record.json`. Partner files are
  /// never removed individually.
  private func reconcileReplayBundleDirectoriesUnlocked() throws {
    let recordDirectories = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for declaredRecordDirectory in recordDirectories {
      guard let recordID = UUID(uuidString: declaredRecordDirectory.lastPathComponent),
        let recordDirectory = canonicalRecordDirectoryURLIfSafe(for: recordID)
      else { continue }

      let children = try fileManager.contentsOfDirectory(
        at: recordDirectory,
        includingPropertiesForKeys: nil,
        options: []
      )
      for child in children
      where child.lastPathComponent.hasPrefix(".attaching-replay-bundle-") {
        guard itemType(at: child) == .typeDirectory else { continue }
        try? fileManager.removeItem(at: child)
      }

      let recordURL = recordDirectory.appendingPathComponent(recordFilename)
      guard itemType(at: recordURL) == .typeRegular,
        let data = try? Data(contentsOf: recordURL),
        let record = try? makeDecoder().decode(SwingRecord.self, from: data),
        record.id == recordID
      else {
        // A corrupt record is quarantined by the established recovery path. Do
        // not discard any of its visible evidence while diagnosis is possible.
        continue
      }

      for child in children {
        guard let bundleID = replayBundleID(fromDirectoryName: child.lastPathComponent),
          bundleID != record.replayBundle?.id,
          canonicalReplayBundleDirectoryURLIfSafe(
            bundleID: bundleID,
            recordID: recordID
          ) != nil
        else { continue }
        try? fileManager.removeItem(at: child)
      }
    }
  }

  private func validatedReplaySourceURL(_ sourceURL: URL) throws -> URL {
    let source = sourceURL.standardizedFileURL
    guard itemType(at: source) == .typeRegular else {
      throw SwingRecordStoreError.replaySourceNotFound
    }
    return source
  }

  private func copyReplayAsset(
    _ descriptor: SwingReplayAsset,
    role: SwingReplayAssetRole,
    from sourceURL: URL,
    to stagingDirectory: URL
  ) throws -> SwingReplayAsset {
    let fileExtension = safeReplayExtension(from: sourceURL)
    let filename = "\(role == .swingCamera ? "camera" : "rapsodo").\(fileExtension)"
    let destination = stagingDirectory.appendingPathComponent(filename)
    do {
      try fileManager.copyItem(at: sourceURL, to: destination)
      let metadata = try replayFileMetadata(at: destination)
      guard metadata.byteCount > 0 else {
        throw SwingRecordStoreError.cannotAttachReplayBundle("ไฟล์ \(role.rawValue) ว่างเปล่า")
      }
      var managed = descriptor
      managed.role = role
      managed.filename = filename
      managed.contentSHA256 = metadata.sha256
      managed.byteCount = metadata.byteCount
      return managed
    } catch let error as SwingRecordStoreError {
      try? fileManager.removeItem(at: destination)
      throw error
    } catch {
      try? fileManager.removeItem(at: destination)
      throw SwingRecordStoreError.cannotAttachReplayBundle(error.localizedDescription)
    }
  }

  private func replayFileMetadata(at url: URL) throws -> (sha256: String, byteCount: Int64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while true {
      let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
      guard !chunk.isEmpty else { break }
      byteCount += Int64(chunk.count)
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize()
    return (
      digest.map { String(format: "%02x", $0) }.joined(),
      byteCount
    )
  }

  private func validateReplayBundle(_ bundle: SwingReplayBundle) throws {
    guard bundle.schema == SwingReplayBundle.schemaVersion else {
      throw SwingRecordStoreError.invalidReplayBundle("ไม่รองรับ schema ของชุดวิดีโอ")
    }
    guard bundle.camera.role == .swingCamera else {
      throw SwingRecordStoreError.invalidReplayBundle("asset กล้องหลักใช้ role ไม่ถูกต้อง")
    }
    try validateReplayAsset(bundle.camera)

    if let rapsodo = bundle.rapsodo {
      guard rapsodo.role == .rapsodoScreen,
        rapsodo.filename.lowercased() != bundle.camera.filename.lowercased()
      else {
        throw SwingRecordStoreError.invalidReplayBundle("asset Rapsodo ใช้ role หรือชื่อไฟล์ไม่ถูกต้อง")
      }
      try validateReplayAsset(rapsodo)
    }

    if let synchronization = bundle.synchronization {
      guard bundle.rapsodo != nil, synchronization.validationIssues.isEmpty else {
        throw SwingRecordStoreError.invalidReplayBundle("ข้อมูล synchronization ไม่สมบูรณ์")
      }
      try validateReplaySynchronizationMediaRanges(
        synchronization,
        camera: bundle.camera,
        rapsodo: bundle.rapsodo!
      )
    }
    let expectedStatus: SwingReplayBundleStatus =
      bundle.rapsodo != nil && bundle.synchronization != nil
      ? .synchronizedPair : .cameraSaved
    guard bundle.status == expectedStatus else {
      throw SwingRecordStoreError.invalidReplayBundle("สถานะชุดวิดีโอไม่ตรงกับ asset ที่มีจริง")
    }
  }

  private func validateReplayAsset(_ asset: SwingReplayAsset) throws {
    try validateReplayBundleAssetFilename(asset.filename, role: asset.role)
    guard !asset.sourceKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let hash = asset.contentSHA256,
      hash.count == 64,
      hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      let byteCount = asset.byteCount,
      byteCount > 0
    else {
      throw SwingRecordStoreError.invalidReplayBundle("descriptor ของ \(asset.role.rawValue) ไม่ครบ")
    }
    if let durationMilliseconds = asset.durationMilliseconds, durationMilliseconds <= 0 {
      throw SwingRecordStoreError.invalidReplayBundle("ระยะเวลาวิดีโอไม่ถูกต้อง")
    }
    if (asset.encodedPixelWidth == nil) != (asset.encodedPixelHeight == nil)
      || (asset.encodedPixelWidth.map { $0 <= 0 } ?? false)
      || (asset.encodedPixelHeight.map { $0 <= 0 } ?? false)
    {
      throw SwingRecordStoreError.invalidReplayBundle("ขนาดภาพวิดีโอไม่ถูกต้อง")
    }
    if let nominalFPS = asset.nominalFPS, !nominalFPS.isFinite || nominalFPS <= 0 {
      throw SwingRecordStoreError.invalidReplayBundle("อัตราเฟรมวิดีโอไม่ถูกต้อง")
    }
    if let range = asset.mediaRangeSeconds,
      !range.lowerBound.isFinite
        || !range.upperBound.isFinite
        || range.lowerBound >= range.upperBound
    {
      throw SwingRecordStoreError.invalidReplayBundle("ช่วงเวลา media ไม่ถูกต้อง")
    }
  }

  private func validateReplaySynchronizationMediaRanges(
    _ synchronization: SwingReplaySynchronization,
    camera: SwingReplayAsset,
    rapsodo: SwingReplayAsset
  ) throws {
    for (assetRange, calibratedRange) in [
      (camera.mediaRangeSeconds, synchronization.cameraClock.mediaRangeSeconds),
      (rapsodo.mediaRangeSeconds, synchronization.rapsodoClock.mediaRangeSeconds),
    ] {
      guard let assetRange else { continue }
      guard assetRange.lowerBound <= calibratedRange.lowerBound,
        assetRange.upperBound >= calibratedRange.upperBound
      else {
        throw SwingRecordStoreError.invalidReplayBundle(
          "ช่วง synchronization อยู่นอกช่วง media ของ asset"
        )
      }
    }
  }

  private func validateReplayBundleAssetFilename(
    _ filename: String,
    role: SwingReplayAssetRole
  ) throws {
    let fileURL = URL(fileURLWithPath: filename)
    let expectedStem = role == .swingCamera ? "camera" : "rapsodo"
    guard !filename.isEmpty,
      !filename.hasPrefix("."),
      filename == fileURL.lastPathComponent,
      fileURL.deletingPathExtension().lastPathComponent.lowercased() == expectedStem,
      Self.supportedReplayExtensions.contains(fileURL.pathExtension.lowercased())
    else {
      throw SwingRecordStoreError.invalidReplayBundle("ชื่อไฟล์ asset ไม่ปลอดภัย")
    }
  }

  private func replayAssetFileMatchesDescriptor(
    _ url: URL,
    descriptor: SwingReplayAsset
  ) -> Bool {
    guard let expectedByteCount = descriptor.byteCount,
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let actualByteCount = (attributes[.size] as? NSNumber)?.int64Value
    else { return false }
    return expectedByteCount == actualByteCount && actualByteCount > 0
  }

  private func validateReplayFilename(_ filename: String?) throws {
    guard let filename else { return }
    let lowercasedFilename = filename.lowercased()
    let reservedMetadataFilenames: Set<String> = [
      recordFilename.lowercased(),
      pendingLaunchMonitorShotsFilename.lowercased(),
      "manifest.json",
      "metadata.json",
    ]
    guard !filename.isEmpty,
      !filename.hasPrefix("."),
      filename == URL(fileURLWithPath: filename).lastPathComponent,
      !reservedMetadataFilenames.contains(lowercasedFilename),
      Self.supportedReplayExtensions.contains(
        URL(fileURLWithPath: lowercasedFilename).pathExtension
      )
    else {
      throw SwingRecordStoreError.invalidReplayFilename
    }

    let stem = URL(fileURLWithPath: lowercasedFilename)
      .deletingPathExtension()
      .lastPathComponent
    // replay.<video-extension> was produced by the first store schema. Keep it
    // readable, while all newly attached files use replay-<UUID>.<extension>.
    if stem == "replay" { return }
    guard stem.hasPrefix("replay-") else {
      throw SwingRecordStoreError.invalidReplayFilename
    }
    let identifier = String(stem.dropFirst("replay-".count))
    guard identifier.count == 36, UUID(uuidString: identifier) != nil else {
      throw SwingRecordStoreError.invalidReplayFilename
    }
  }

  private func validateStoryboardFilenames(_ filenames: [String]) throws {
    for filename in filenames {
      guard !filename.isEmpty,
        !filename.hasPrefix("."),
        filename == URL(fileURLWithPath: filename).lastPathComponent,
        filename.lowercased().hasSuffix(".jpg")
      else {
        throw SwingRecordStoreError.invalidStoryboardFilename
      }
    }
  }

  private func validateManagedArtifactFilenames(in record: SwingRecord) throws {
    let storyboardFilenames = record.artifacts?.keyframes.compactMap(\.filename) ?? []
    if let replayFilename = record.replayFilename,
      Set(storyboardFilenames.map { $0.lowercased() })
        .contains(replayFilename.lowercased())
    {
      throw SwingRecordStoreError.invalidReplayFilename
    }
    try validateReplayFilename(record.replayFilename)
    if let replayBundle = record.replayBundle {
      try validateReplayBundle(replayBundle)
      let bundleFilenames = [replayBundle.camera.filename, replayBundle.rapsodo?.filename]
        .compactMap { $0 }
      guard Set(bundleFilenames.map { $0.lowercased() }).count == bundleFilenames.count,
        Set(storyboardFilenames.map { $0.lowercased() })
          .isDisjoint(with: Set(bundleFilenames.map { $0.lowercased() }))
      else {
        throw SwingRecordStoreError.invalidReplayBundle("ชื่อไฟล์ asset ซ้ำกัน")
      }
    }
    try validateStoryboardFilenames(storyboardFilenames)
  }

  /// Creates (or validates) a real record directory. Symlinked UUID directories
  /// are rejected so a crafted store entry cannot redirect writes outside Swings.
  private func prepareRecordDirectoryForWriteUnlocked(id: UUID) throws -> URL {
    let declared = recordDirectoryURL(for: id)
    if itemType(at: declared) == nil {
      do {
        try fileManager.createDirectory(
          at: declared,
          withIntermediateDirectories: true
        )
      } catch {
        throw SwingRecordStoreError.cannotCreateStorage(error.localizedDescription)
      }
    }
    guard let canonical = canonicalRecordDirectoryURLIfSafe(for: id) else {
      throw SwingRecordStoreError.cannotCreateStorage(
        "โฟลเดอร์วงสวิงไม่ใช่โฟลเดอร์ปกติภายในคลัง"
      )
    }
    return canonical
  }

  /// Resolves the UUID directory and requires it to remain a direct child of the
  /// configured Swings root. attributesOfItem uses lstat semantics, so symlinks
  /// are rejected before resolving their destinations.
  private func canonicalRecordDirectoryURLIfSafe(for id: UUID) -> URL? {
    let declared = recordDirectoryURL(for: id)
    guard itemType(at: declared) == .typeDirectory else { return nil }
    let canonicalRoot = directoryURL.resolvingSymlinksInPath().standardizedFileURL
    let canonicalRecord = declared.resolvingSymlinksInPath().standardizedFileURL
    guard canonicalRecord.deletingLastPathComponent().path == canonicalRoot.path else {
      return nil
    }
    return canonicalRecord
  }

  /// Returns only an existing regular, non-symlink file whose canonical parent is
  /// the expected Swings/<UUID> directory. Missing, directory, broken, and escaped
  /// paths deliberately return nil so the UI cannot advertise them as ready.
  private func regularManagedFileURLIfSafe(
    named filename: String,
    recordID: UUID
  ) -> URL? {
    guard let recordDirectory = canonicalRecordDirectoryURLIfSafe(for: recordID) else {
      return nil
    }
    let declared = recordDirectory.appendingPathComponent(filename)
    guard itemType(at: declared) == .typeRegular else { return nil }
    let canonicalFile = declared.resolvingSymlinksInPath().standardizedFileURL
    guard canonicalFile.deletingLastPathComponent().path == recordDirectory.path else {
      return nil
    }
    return canonicalFile
  }

  private func replayBundleDirectoryName(for bundleID: UUID) -> String {
    "replay-bundle-\(bundleID.uuidString.lowercased())"
  }

  private func replayBundleID(fromDirectoryName name: String) -> UUID? {
    let prefix = "replay-bundle-"
    guard name.hasPrefix(prefix) else { return nil }
    let identifier = String(name.dropFirst(prefix.count))
    guard identifier.count == 36 else { return nil }
    return UUID(uuidString: identifier)
  }

  private func canonicalReplayBundleDirectoryURLIfSafe(
    bundleID: UUID,
    recordID: UUID
  ) -> URL? {
    guard let recordDirectory = canonicalRecordDirectoryURLIfSafe(for: recordID) else {
      return nil
    }
    let declared = recordDirectory.appendingPathComponent(
      replayBundleDirectoryName(for: bundleID),
      isDirectory: true
    )
    guard itemType(at: declared) == .typeDirectory else { return nil }
    let canonical = declared.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.deletingLastPathComponent().path == recordDirectory.path else {
      return nil
    }
    return canonical
  }

  private func regularManagedReplayBundleFileURLIfSafe(
    named filename: String,
    bundleDirectory: URL
  ) -> URL? {
    guard !filename.isEmpty,
      filename == URL(fileURLWithPath: filename).lastPathComponent
    else { return nil }
    let declared = bundleDirectory.appendingPathComponent(filename)
    guard itemType(at: declared) == .typeRegular else { return nil }
    let canonical = declared.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.deletingLastPathComponent().path == bundleDirectory.path else {
      return nil
    }
    return canonical
  }

  private func removeManagedReplayBundleDirectoryIfPresent(
    bundleID: UUID,
    recordID: UUID
  ) {
    guard
      let directory = canonicalReplayBundleDirectoryURLIfSafe(
        bundleID: bundleID,
        recordID: recordID
      )
    else { return }
    // Remove the generation as one unit; never leave or delete an individual
    // camera/Rapsodo partner independently.
    try? fileManager.removeItem(at: directory)
  }

  private func removeRegularManagedFileIfPresent(
    named filename: String,
    recordID: UUID
  ) {
    guard let url = regularManagedFileURLIfSafe(named: filename, recordID: recordID) else {
      return
    }
    try? fileManager.removeItem(at: url)
  }

  private func itemType(at url: URL) -> FileAttributeType? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      return nil
    }
    return attributes[.type] as? FileAttributeType
  }

  private func failedStoryboardDescriptor(
    marker: SwingStoryboardPhaseMarker,
    existing: SwingStoryboardKeyframeDescriptor?,
    state: SwingStoryboardKeyframeExtractionState = .failed,
    limitation: String
  ) -> SwingStoryboardKeyframeDescriptor {
    if let existing, existing.state == .available,
      existing.filename != nil || existing.imageContentID != nil
    {
      return existing
    }
    return SwingStoryboardKeyframeDescriptor(
      slot: marker.slot,
      sourceTimestampMs: marker.sourceTimestampMs,
      nearestPoseTimestampMs: existing?.nearestPoseTimestampMs,
      alignmentDeltaMs: existing?.alignmentDeltaMs,
      state: state,
      imageContentID: existing?.imageContentID,
      filename: nil,
      contentSHA256: nil,
      pixelWidth: nil,
      pixelHeight: nil,
      extractedSourceTimestampMs: nil,
      byteCount: nil,
      limitation: limitation
    )
  }

  private static func jpegDimensions(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return (image.width, image.height)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isValidReplayClockMapping(_ mapping: SwingReplayClockMapping) -> Bool {
    mapping.schema == SwingReplayClockMapping.schemaVersion
      && mapping.scale.isFinite
      && mapping.scale > 0
      && mapping.offsetSeconds.isFinite
      && mapping.uncertaintyMilliseconds.isFinite
      && mapping.uncertaintyMilliseconds >= 0
      && mapping.cameraSampleCount >= 4
      && mapping.replaySampleCount >= 4
      && mapping.cameraMediaRangeSeconds.lowerBound.isFinite
      && mapping.cameraMediaRangeSeconds.upperBound.isFinite
      && mapping.replayMediaRangeSeconds.lowerBound.isFinite
      && mapping.replayMediaRangeSeconds.upperBound.isFinite
  }

  private func safeReplayExtension(from url: URL) -> String {
    let candidate = url.pathExtension.lowercased()
    return Self.supportedReplayExtensions.contains(candidate) ? candidate : "mov"
  }

  private func recordDirectoryURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
  }

  private func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }

  private static func launchMonitorShotSortOrder(
    _ lhs: LaunchMonitorShot,
    _ rhs: LaunchMonitorShot
  ) -> Bool {
    if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt < rhs.receivedAt }
    if lhs.deviceShotID != rhs.deviceShotID { return lhs.deviceShotID < rhs.deviceShotID }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func closestLaunchMonitorShotIndex(
    in shots: [LaunchMonitorShot],
    to swingDate: Date,
    matchingWindowSeconds: TimeInterval
  ) -> Int? {
    shots.enumerated()
      .filter {
        abs($0.element.receivedAt.timeIntervalSince(swingDate)) <= matchingWindowSeconds
      }
      .min {
        let leftDistance = abs($0.element.receivedAt.timeIntervalSince(swingDate))
        let rightDistance = abs($1.element.receivedAt.timeIntervalSince(swingDate))
        if leftDistance != rightDistance { return leftDistance < rightDistance }
        return $0.offset < $1.offset
      }?
      .offset
  }

  private func synchronized<Result>(_ body: () throws -> Result) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }
}
