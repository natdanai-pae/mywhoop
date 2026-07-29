import Combine
import CoreMedia
import Foundation

struct SwingRecordArtifactAvailability: Equatable, Sendable {
  let replayURL: URL?
  let replayBundle: SwingReplayBundleURLs?
  let stagePaneLayout: GolfTraceStagePaneLayout?
  let storyboardURLs: [SwingStoryboardPhaseSlot: URL]
}

/// เชื่อมผลวงสวิงบนหน้าจอเข้ากับคลังถาวรในเครื่อง
///
/// งานอ่าน/เขียนและคัดลอกวิดีโอทำบนคิวเบื้องหลัง เพื่อไม่ให้ภาพสดหรือปุ่มบนหน้าจอค้าง
/// งานแต่ละชิ้นต่อคิวกัน จึงไม่เกิดกรณีแนบคลิปก่อนบันทึกข้อมูลวงสวิงเสร็จ
@MainActor
final class SwingHistoryController: ObservableObject {
  @Published private(set) var records: [SwingRecord] = [] {
    didSet { scheduleArtifactAvailabilityRefresh(for: records) }
  }
  @Published private(set) var artifactAvailability: [UUID: SwingRecordArtifactAvailability] = [:]
  @Published private(set) var statusText = "กำลังเตรียมประวัติวงสวิง…"
  @Published private(set) var isWorking = false

  private let store: SwingRecordStore?
  private let shotMatcher: ShotSwingMatchController
  private var lastCapturedSummary: SwingSessionSummary?
  private var persistenceTask: Task<Void, Never>?
  private var pendingOperationCount = 0
  private var pendingStoryboardExportCount = 0
  private var pendingStoryboardMarkers: [UUID: [SwingStoryboardPhaseMarker]] = [:]
  private var acceptsNewCaptures = true
  private var startupNotice: String?
  private var artifactAvailabilityTask: Task<Void, Never>?
  private var artifactAvailabilityGeneration: UInt64 = 0

  /// ใช้ตอนปิดแอป เพื่อบอก AppKit ว่ายังต้องรอการเขียนไฟล์ให้ครบก่อน
  var hasPendingPersistenceWork: Bool {
    pendingOperationCount > 0 || pendingStoryboardExportCount > 0
  }

  /// เมื่อ macOS เริ่มปิดแอป จะไม่รับวงใหม่ แต่ยังยอมให้คลิปของวงที่อยู่ในคิวแนบให้เสร็จ
  func prepareForTermination() {
    acceptsNewCaptures = false
  }

  init() {
    do {
      let createdStore = try SwingRecordStore()
      let pendingLoad = try createdStore.loadPendingLaunchMonitorShotsRecoveringCorruptFile()
      let recordLoad = try createdStore.loadAllRecoveringInvalidRecords()
      _ = try createdStore.reconcilePendingLaunchMonitorShots()
      let storedRecords = try createdStore.loadAll()
      let pendingShots = try createdStore.loadPendingLaunchMonitorShots()
      let attachedShotIDs = Set(
        storedRecords.compactMap { $0.launchMonitorMatch?.shot.id }
      )
      let restoredMatcher = ShotSwingMatchController(
        maximumPendingCount: max(
          ShotSwingMatchController.defaultMaximumPendingCount,
          pendingShots.count
        ),
        restoredPendingShots: pendingShots,
        restoredSeenShotIDs: attachedShotIDs
      )
      for record in storedRecords.reversed() where record.launchMonitorMatch == nil {
        _ = restoredMatcher.registerSwing(record)
      }

      store = createdStore
      shotMatcher = restoredMatcher
      if pendingLoad.didQuarantineCorruptFile {
        startupNotice = "พบไฟล์ค่าจาก MLM2PRO ที่อ่านไม่ได้ จึงแยกเก็บไว้ตรวจสอบแล้ว"
      }
      if recordLoad.invalidRecordCount > 0 {
        let invalidNotice: String
        if recordLoad.quarantinedRecordCount == recordLoad.invalidRecordCount {
          invalidNotice =
            "พบประวัติ \(recordLoad.invalidRecordCount) วงที่อ่านไม่ได้ จึงแยกไว้ที่ \(recordLoad.recoveryDirectoryURL.path)"
        } else {
          invalidNotice =
            "ข้ามประวัติ \(recordLoad.invalidRecordCount) วงที่อ่านไม่ได้ โดยวงอื่นยังใช้งานได้"
        }
        startupNotice = [startupNotice, invalidNotice]
          .compactMap { $0 }
          .joined(separator: " • ")
      }
      // ใช้ snapshot หลัง reconcile เป็นแหล่งจริงของ UI แล้วค่อยตรวจ artifact
      // แยกบน background เพื่อไม่ให้ body ของ History แตะ filesystem
      records = storedRecords
      scheduleArtifactAvailabilityRefresh(for: storedRecords)
      let baseStatus =
        storedRecords.isEmpty
        ? "ยังไม่มีวงที่บันทึกไว้" : "เก็บประวัติไว้ \(storedRecords.count) วง"
      if let startupNotice {
        statusText = "\(baseStatus) • \(startupNotice)"
        self.startupNotice = nil
      } else {
        statusText = baseStatus
      }
    } catch {
      store = nil
      shotMatcher = ShotSwingMatchController()
      statusText = error.localizedDescription
    }
  }

  /// บันทึกผลหนึ่งครั้งเท่านั้น แม้ SwiftUI จะส่งค่าเดิมกลับมาอีกหลายรอบ
  /// คืนรหัสของวงที่เริ่มบันทึก เพื่อให้คลิปย้อนหลังจับคู่กับวงนี้ได้โดยตรง
  @discardableResult
  func captureIfNeeded(
    _ summary: SwingSessionSummary?,
    analysis: SwingAnalysisSummary?,
    evidencePacket: SwingEvidencePacket? = nil,
    captureSnapshot: SwingStoryboardCaptureSnapshot? = nil
  ) -> UUID? {
    guard acceptsNewCaptures, let store, let summary else { return nil }
    let endSeconds = CMTimeGetSeconds(summary.endTimestamp)
    guard endSeconds.isFinite, summary != lastCapturedSummary else { return nil }

    lastCapturedSummary = summary
    let artifacts = evidencePacket.flatMap {
      SwingRecordArtifacts(evidencePacket: $0, capture: captureSnapshot)
    }
    var record = SwingRecord(
      capturedSession: summary,
      artifacts: artifacts,
      metadata: Self.metadata(from: analysis)
    )
    let launchMonitorMatch = shotMatcher.registerSwing(record)
    record.launchMonitorMatch = launchMonitorMatch?.persistentMetadata
    let recordToSave = record
    if let artifacts {
      pendingStoryboardMarkers[record.id] = artifacts.phaseMarkers
      if pendingStoryboardMarkers.count > 32 {
        let retainedIDs = Set(records.prefix(20).map(\.id)).union([record.id])
        pendingStoryboardMarkers = pendingStoryboardMarkers.filter {
          retainedIDs.contains($0.key)
        }
      }
    }
    statusText = "กำลังบันทึกผลวงล่าสุด…"

    enqueue { [weak self] in
      do {
        let loadedRecords = try await Task.detached {
          try store.save(recordToSave)
          if let matchedShotID = launchMonitorMatch?.shot.id {
            try store.removePendingLaunchMonitorShot(shotID: matchedShotID)
          }
          return try store.loadAll()
        }.value
        guard let self else { return }
        self.records = loadedRecords
        self.statusText =
          launchMonitorMatch == nil
          ? "บันทึกผลวงล่าสุดแล้ว กำลังรอค่าจาก MLM2PRO"
          : "บันทึกผลวงล่าสุดพร้อมค่าจาก MLM2PRO แล้ว"
      } catch {
        self?.statusText = error.localizedDescription
      }
    }

    return recordToSave.id
  }

  /// Snapshot camera buffer ทันทีหลัง `captureIfNeeded` คืน record ID แล้วค่อย
  /// ต่อคิวแนบ JPEG หลัง record JSON งานแรกบันทึกเสร็จ การสร้าง MOV/JPEG ไม่เข้า
  /// MainActor และการลบ record ระหว่างทางจะไม่ถูกย้อนกลับมาสร้างใหม่
  func materializeStoryboardKeyframes(
    for recordID: UUID,
    summary: SwingSessionSummary,
    using source: any CameraStoryboardArtifactExporting,
    preRoll: TimeInterval = 0.75,
    captureOrientation: SwingStoryboardCaptureOrientation
  ) {
    guard acceptsNewCaptures, let store else { return }
    let markers =
      pendingStoryboardMarkers[recordID]
      ?? records.first(where: { $0.id == recordID })?.artifacts?.phaseMarkers
      ?? []
    guard !markers.isEmpty,
      summary.startTimestamp.isValid,
      summary.endTimestamp.isValid,
      CMTimeCompare(summary.endTimestamp, summary.startTimestamp) > 0
    else { return }

    pendingStoryboardExportCount += 1
    isWorking = true
    statusText = "กำลังเตรียมภาพ Storyboard จากกล้อง…"
    source.exportStoryboardArtifacts(
      swingStart: summary.startTimestamp,
      swingEnd: summary.endTimestamp,
      phaseMarkers: markers,
      preRoll: preRoll,
      captureOrientation: captureOrientation
    ) { [weak self] exportResult in
      Task { @MainActor [weak self] in
        guard let self else {
          if case .success(let result) = exportResult {
            result.removeTemporaryFiles()
          }
          return
        }
        self.pendingStoryboardExportCount = max(0, self.pendingStoryboardExportCount - 1)
        self.pendingStoryboardMarkers.removeValue(forKey: recordID)
        self.isWorking = self.hasPendingPersistenceWork

        switch exportResult {
        case .success(let result):
          self.enqueue { [weak self] in
            do {
              let update = try await Task.detached {
                defer { result.removeTemporaryFiles() }
                let record = try store.attachStoryboardKeyframes(
                  result.keyframes,
                  captureSourceID: result.sourceID,
                  captureOrientation: result.captureOrientation,
                  to: recordID
                )
                return (records: try store.loadAll(), didAttach: record != nil)
              }.value
              guard let self else { return }
              self.records = update.records
              if update.didAttach {
                self.statusText = "บันทึกภาพ Storyboard จากกล้องแล้ว"
              }
            } catch {
              result.removeTemporaryFiles()
              self?.statusText = error.localizedDescription
            }
          }
        case .failure(let error):
          let limitation = error.localizedDescription
          self.enqueue { [weak self] in
            do {
              let loadedRecords = try await Task.detached {
                _ = try store.markStoryboardKeyframesFailed(
                  for: recordID,
                  limitation: limitation
                )
                return try store.loadAll()
              }.value
              guard let self else { return }
              self.records = loadedRecords
              self.statusText = "ยังสร้างภาพ Storyboard ไม่สำเร็จ: \(limitation)"
            } catch {
              self?.statusText = error.localizedDescription
            }
          }
        }
      }
    }
  }

  /// แนบ calibration ของ replay แบบต่อคิวหลัง record save และ keyframe งานอื่น
  /// เพื่อให้ทุกส่วนโหลด record ล่าสุดภายใน store lock และไม่เขียนทับกัน
  func attachReplayClockMapping(
    _ mapping: SwingReplayClockMapping,
    to recordID: UUID,
    summary: SwingSessionSummary
  ) {
    guard let store else { return }
    let cameraSwingStartSeconds = CMTimeGetSeconds(summary.startTimestamp)
    guard cameraSwingStartSeconds.isFinite else { return }

    enqueue { [weak self] in
      do {
        let result = try await Task.detached {
          let updated = try store.attachReplayClockMapping(
            mapping,
            cameraSwingStartSeconds: cameraSwingStartSeconds,
            to: recordID
          )
          return (records: try store.loadAll(), didAttach: updated != nil)
        }.value
        guard let self else { return }
        self.records = result.records
        if result.didAttach {
          self.statusText = "ผูกเวลา Storyboard กับ replay แล้ว"
        }
      } catch {
        self?.statusText = error.localizedDescription
      }
    }
  }

  /// รับค่าลูกจาก event stream ของ MLM2PRO โดยไม่บังคับว่าค่าลูกหรือวงสวิงต้องมาก่อน
  ///
  /// หากวงสวิงถูกบันทึกไว้แล้ว งานแนบค่าลูกจะต่อท้ายคิว persistence เดิม จึงไม่เขียนทับ
  /// replay หรือผลวิเคราะห์ที่กำลังบันทึกอยู่
  func receiveLaunchMonitorShot(_ shot: LaunchMonitorShot) {
    guard let store else { return }
    guard let match = shotMatcher.registerShot(shot) else {
      statusText = "รับค่าจาก MLM2PRO แล้ว กำลังรอจับคู่กับวงสวิง…"
      enqueue { [weak self] in
        do {
          _ = try await Task.detached {
            try store.savePendingLaunchMonitorShot(shot)
          }.value
        } catch {
          self?.statusText = error.localizedDescription
        }
      }
      return
    }

    statusText = "กำลังจับคู่ค่าจาก MLM2PRO กับวงสวิง…"
    let persistentMatch = match.persistentMetadata
    enqueue { [weak self] in
      do {
        let result = try await Task.detached {
          _ = try store.savePendingLaunchMonitorShot(shot)
          let updated = try store.attachLaunchMonitorMatch(
            persistentMatch,
            to: match.recordID
          )
          let didAttach = updated?.launchMonitorMatch?.shot.id == match.shot.id
          if didAttach {
            try store.removePendingLaunchMonitorShot(shotID: match.shot.id)
          }
          return (
            records: try store.loadAll(),
            didAttach: didAttach
          )
        }.value
        guard let self else { return }
        self.records = result.records
        self.statusText =
          result.didAttach
          ? "จับคู่ค่าจาก MLM2PRO กับวงสวิงแล้ว"
          : "ไม่พบวงสวิงที่จะจับคู่กับค่าจาก MLM2PRO"
      } catch {
        self?.statusText = error.localizedDescription
      }
    }
  }

  /// แนบคลิปกับรหัสวงที่ระบุชัดเจน คลิปต้นทางยังคงอยู่ให้หน้าดูย้อนหลังใช้งานต่อ
  /// `completion` คืน `true` เมื่อแนบสำเร็จ และคืน `false` เมื่อไม่มีวงหรือเกิดข้อผิดพลาด
  func attachReplayIfNeeded(
    _ replayURL: URL?,
    to recordID: UUID,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    guard let store, let replayURL else {
      completion(false)
      return
    }

    enqueue { [weak self] in
      do {
        let result = try await Task.detached {
          guard let record = try store.load(id: recordID) else {
            return (records: try store.loadAll(), didAttach: false)
          }
          // Always copy through the store's atomic replacement path. This also
          // repairs a record whose previous replay is missing or corrupt, and
          // makes recovery safe after a crash between the copy and its ack.
          _ = try store.attachReplay(
            from: replayURL,
            to: record,
            transferMode: .copy,
            stagePaneLayout: stagePaneLayout
          )
          return (records: try store.loadAll(), didAttach: true)
        }.value
        guard let self else {
          completion(false)
          return
        }
        self.records = result.records
        if result.didAttach {
          self.statusText = "เก็บผลและคลิปวงล่าสุดไว้ในเครื่องแล้ว"
        }
        completion(result.didAttach)
      } catch {
        self?.statusText = error.localizedDescription
        completion(false)
      }
    }
  }

  /// Persists the independently encoded camera master and an optional Rapsodo
  /// companion. Camera-only success is a first-class result; callers must use
  /// the returned status rather than assuming that two supplied URLs became a
  /// synchronized PIP pair.
  func attachReplayBundleIfNeeded(
    cameraURL: URL?,
    rapsodoURL: URL?,
    bundle: SwingReplayBundle,
    to recordID: UUID,
    completion: @escaping @MainActor (SwingReplayBundleStatus?) -> Void
  ) {
    guard let store, let cameraURL else {
      completion(nil)
      return
    }

    enqueue { [weak self] in
      do {
        let result = try await Task.detached {
          let updated = try store.attachReplayBundle(
            cameraSourceURL: cameraURL,
            rapsodoSourceURL: rapsodoURL,
            bundle: bundle,
            to: recordID,
            transferMode: .copy
          )
          let status: SwingReplayBundleStatus?
          if let updated,
            let resolved = try store.replayBundleURLs(for: updated)
          {
            status = resolved.status
          } else {
            status = nil
          }
          return (records: try store.loadAll(), status: status)
        }.value
        guard let self else {
          completion(nil)
          return
        }
        self.records = result.records
        switch result.status {
        case .synchronizedPair:
          self.statusText = "บันทึกคลิปกล้องและ Rapsodo ที่ซิงก์กันแล้ว"
        case .cameraSaved:
          self.statusText = "บันทึกคลิปกล้องแล้ว แต่ยังไม่มีคู่ Rapsodo ที่ซิงก์ได้"
        case nil:
          break
        }
        completion(result.status)
      } catch {
        self?.statusText = error.localizedDescription
        completion(nil)
      }
    }
  }

  /// รอจนงานอ่าน/เขียนที่ต่อคิวไว้ทั้งหมดจบ ใช้ก่อนอนุญาตให้ macOS ปิดแอป
  func flushPendingOperations() async {
    while hasPendingPersistenceWork {
      let latestTask = persistenceTask
      await latestTask?.value
      await Task.yield()
    }
  }

  @discardableResult
  func openReplay(for record: SwingRecord, using replay: SwingReplayController) -> Bool {
    guard let store else { return false }
    do {
      let legacyURL = try store.replayURL(for: record)
      let bundle = try store.replayBundleURLs(for: record)
      guard let url = legacyURL ?? bundle?.cameraURL else {
        statusText = "วงนี้ยังไม่มีคลิปย้อนหลัง"
        return false
      }
      replay.showStoredReplay(
        url,
        recordID: record.id,
        stagePaneLayout: legacyURL == nil ? nil : record.stageReplayPaneLayout
      )
      statusText = "เปิดคลิปจากประวัติแล้ว"
      return true
    } catch {
      statusText = error.localizedDescription
      return false
    }
  }

  /// คืนไฟล์ replay ที่คลังตรวจสอบ path แล้วสำหรับงานแสดงผลแบบอ่านอย่างเดียว
  ///
  /// UI ไม่ได้รับ `SwingRecordStore` โดยตรง และ nil หมายถึงไม่มีไฟล์จริงให้เปิด แม้
  /// record รุ่นเก่าอาจยังมีชื่อไฟล์ค้างอยู่ใน metadata ก็ตาม
  func replayURL(for record: SwingRecord) -> URL? {
    artifactAvailability[record.id]?.replayURL
  }

  /// คืน URL แบบแยก role หลังตรวจ manifest, path และไฟล์จริงแล้ว PIP ใช้ได้
  /// เฉพาะเมื่อ `status == .synchronizedPair`; camera-only ยังคงเปิดย้อนหลังได้
  func replayBundleURLs(for record: SwingRecord) -> SwingReplayBundleURLs? {
    artifactAvailability[record.id]?.replayBundle
  }

  func replayBundleStatus(for record: SwingRecord) -> SwingReplayBundleStatus? {
    artifactAvailability[record.id]?.replayBundle?.status
  }

  /// พิกัดสอง pane มีเฉพาะ replay แบบทั้งหน้าต่างรุ่นใหม่ วงเก่าและ camera
  /// fallback คืน nil เพื่อไม่ให้ UI สร้าง Rapsodo PIP ที่ไม่มีหลักฐานจริง
  func stagePaneLayout(for record: SwingRecord) -> GolfTraceStagePaneLayout? {
    artifactAvailability[record.id]?.stagePaneLayout
  }

  /// คืน JPEG ของ phase ที่คลังตรวจสอบชื่อไฟล์และขอบเขต directory แล้ว
  /// โดยไม่ expose store หรือสร้าง artifact ทดแทนเมื่อข้อมูลจริงไม่มี
  func storyboardKeyframeURL(
    for record: SwingRecord,
    slot: SwingStoryboardPhaseSlot
  ) -> URL? {
    artifactAvailability[record.id]?.storyboardURLs[slot]
  }

  /// ทำ path/symlink validation บน background ครั้งเดียวต่อ snapshot ของ records
  /// เพื่อให้ SwiftUI card, search และ Storyboard อ่าน dictionary เท่านั้น
  private func scheduleArtifactAvailabilityRefresh(for records: [SwingRecord]) {
    artifactAvailabilityGeneration &+= 1
    let generation = artifactAvailabilityGeneration
    artifactAvailabilityTask?.cancel()

    guard let store else {
      artifactAvailability = [:]
      return
    }

    artifactAvailabilityTask = Task { [weak self] in
      let snapshot = await Task.detached(priority: .utility) {
        var availability: [UUID: SwingRecordArtifactAvailability] = [:]
        availability.reserveCapacity(records.count)

        for record in records {
          guard !Task.isCancelled else { return availability }
          let legacyReplayURL = (try? store.replayURL(for: record))?.standardizedFileURL
          let replayBundle = try? store.replayBundleURLs(for: record)
          let replayURL = legacyReplayURL ?? replayBundle?.cameraURL.standardizedFileURL
          var storyboardURLs: [SwingStoryboardPhaseSlot: URL] = [:]
          for slot in SwingStoryboardPhaseSlot.allCases {
            guard !Task.isCancelled else { return availability }
            if let url = try? store.storyboardKeyframeURL(for: record, slot: slot) {
              storyboardURLs[slot] = url.standardizedFileURL
            }
          }
          availability[record.id] = SwingRecordArtifactAvailability(
            replayURL: replayURL,
            replayBundle: replayBundle,
            stagePaneLayout: legacyReplayURL == nil ? nil : record.stageReplayPaneLayout,
            storyboardURLs: storyboardURLs
          )
        }
        return availability
      }.value

      guard !Task.isCancelled, let self,
        self.artifactAvailabilityGeneration == generation
      else { return }
      self.artifactAvailability = snapshot
    }
  }

  private func reload() {
    guard let store else { return }
    enqueue { [weak self] in
      do {
        let loadedRecords = try await Task.detached {
          try store.loadAll()
        }.value
        guard let self else { return }
        self.records = loadedRecords
        let baseStatus =
          loadedRecords.isEmpty
          ? "ยังไม่มีวงที่บันทึกไว้" : "เก็บประวัติไว้ \(loadedRecords.count) วง"
        if let startupNotice = self.startupNotice {
          self.statusText = "\(baseStatus) • \(startupNotice)"
          self.startupNotice = nil
        } else {
          self.statusText = baseStatus
        }
      } catch {
        self?.statusText = error.localizedDescription
      }
    }
  }

  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previousTask = persistenceTask
    pendingOperationCount += 1
    isWorking = true
    persistenceTask = Task { [weak self] in
      defer {
        if let self {
          self.pendingOperationCount = max(0, self.pendingOperationCount - 1)
          self.isWorking = self.hasPendingPersistenceWork
        }
      }
      _ = await previousTask?.value
      guard !Task.isCancelled else { return }
      await operation()
    }
  }

  private static func metadata(
    from analysis: SwingAnalysisSummary?
  ) -> [String: SwingRecordMetadataValue] {
    guard let analysis else { return [:] }
    var metadata: [String: SwingRecordMetadataValue] = [
      "analysisModel": .string("2d-body-projection-v1"),
      "analysisQuality": .string(analysis.quality.rawValue),
      "analysisReason": .string(analysis.reason),
      "trackedFraction": .number(analysis.trackedFraction),
    ]

    func include(_ key: String, _ reading: SwingMetricReading) {
      if let value = reading.value {
        metadata[key] = .number(value)
      }
      metadata["\(key)Quality"] = .string(reading.quality.rawValue)
      metadata["\(key)TrackedFraction"] = .number(reading.trackedFraction)
    }

    include("handPathBodyLengths", analysis.handPathBodyLengths)
    include("peakHandSpeedBodyLengthsPerSecond", analysis.peakHandSpeedBodyLengthsPerSecond)
    include("addressTorsoTiltDegrees", analysis.addressTorsoTiltDegrees)
    include("torsoTiltChangeDegrees", analysis.torsoTiltChangeDegrees)
    include("shoulderSpanReductionPercent", analysis.shoulderSpanReductionPercent)
    include("hipSpanReductionPercent", analysis.hipSpanReductionPercent)
    include("backswingSeconds", analysis.backswingSeconds)
    include("downswingSeconds", analysis.downswingSeconds)
    include("handTempoRatio", analysis.handTempoRatio)
    return metadata
  }
}
