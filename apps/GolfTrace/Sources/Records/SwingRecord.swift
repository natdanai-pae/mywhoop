import CoreMedia
import Foundation

/// ค่าข้อมูลแบบ JSON สำหรับเก็บผลวิเคราะห์ที่อาจเพิ่มขึ้นในเวอร์ชันถัดไป
///
/// ใช้ชนิดนี้แทน `[String: Any]` เพื่อให้ข้อมูลยังคงเป็น `Codable`, ทดสอบได้
/// และอ่านไฟล์เก่าได้โดยไม่ต้องผูกกับโครงสร้างผลวิเคราะห์เพียงรูปแบบเดียว
enum SwingRecordMetadataValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case boolean(Bool)
  case array([SwingRecordMetadataValue])
  case object([String: SwingRecordMetadataValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([SwingRecordMetadataValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: SwingRecordMetadataValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "รูปแบบ metadata ของวงสวิงไม่ถูกต้อง"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .boolean(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}

/// Stable roles for replay media. The role, rather than array position or a
/// filename convention, is the durable identity of each independently encoded
/// asset.
enum SwingReplayAssetRole: String, Codable, CaseIterable, Equatable, Sendable {
  case swingCamera = "swing_camera"
  case rapsodoScreen = "rapsodo_screen"
}

/// Truthful persistence state exposed to History. A valid camera master is the
/// minimum durable result; PIP is enabled only for a fully calibrated pair.
enum SwingReplayBundleStatus: String, Codable, Equatable, Sendable {
  case cameraSaved = "camera_saved"
  case synchronizedPair = "synchronized_pair"
}

/// Affine calibration from one asset's file PTS to the Mac monotonic clock.
/// Keeping a calibration per asset avoids tying synchronization to whichever
/// movie happens to be selected as the primary playback surface.
struct SwingReplayAssetClockCalibration: Codable, Equatable, Sendable {
  var scaleToMonotonicClock: Double
  var monotonicClockOffsetSeconds: Double
  var uncertaintyMilliseconds: Double
  var sampleCount: Int
  var mediaRangeSeconds: ClosedRange<Double>

  func monotonicTimeSeconds(forMediaTimeSeconds mediaTimeSeconds: Double) -> Double? {
    guard mediaTimeSeconds.isFinite,
      mediaRangeSeconds.contains(mediaTimeSeconds)
    else { return nil }
    let result = scaleToMonotonicClock * mediaTimeSeconds + monotonicClockOffsetSeconds
    return result.isFinite ? result : nil
  }

  var validationIssues: [String] {
    var issues: [String] = []
    if !scaleToMonotonicClock.isFinite || scaleToMonotonicClock <= 0 {
      issues.append("clock_scale_invalid")
    }
    if !monotonicClockOffsetSeconds.isFinite {
      issues.append("clock_offset_invalid")
    }
    if !uncertaintyMilliseconds.isFinite || uncertaintyMilliseconds < 0 {
      issues.append("clock_uncertainty_invalid")
    }
    if sampleCount < 4 { issues.append("clock_samples_insufficient") }
    if !mediaRangeSeconds.lowerBound.isFinite
      || !mediaRangeSeconds.upperBound.isFinite
      || mediaRangeSeconds.lowerBound >= mediaRangeSeconds.upperBound
    {
      issues.append("clock_media_range_invalid")
    }
    return issues
  }
}

/// Synchronization contract for the two independent movies. The method name is
/// versioned because the current Mac-receipt calibration does not claim to
/// remove unknown device transport latency.
struct SwingReplaySynchronization: Codable, Equatable, Sendable {
  static let schemaVersion = "golftrace.swing-replay-sync.v1"
  static let monotonicReceiptMethod = "mac-monotonic-receipt-v1"
  static let maximumPIPUncertaintyMilliseconds = 100.0

  var schema: String
  var method: String
  var cameraClock: SwingReplayAssetClockCalibration
  var rapsodoClock: SwingReplayAssetClockCalibration
  var timelineMonotonicRangeSeconds: ClosedRange<Double>
  var uncertaintyMilliseconds: Double

  init(
    schema: String = SwingReplaySynchronization.schemaVersion,
    method: String = SwingReplaySynchronization.monotonicReceiptMethod,
    cameraClock: SwingReplayAssetClockCalibration,
    rapsodoClock: SwingReplayAssetClockCalibration,
    timelineMonotonicRangeSeconds: ClosedRange<Double>,
    uncertaintyMilliseconds: Double
  ) {
    self.schema = schema
    self.method = method
    self.cameraClock = cameraClock
    self.rapsodoClock = rapsodoClock
    self.timelineMonotonicRangeSeconds = timelineMonotonicRangeSeconds
    self.uncertaintyMilliseconds = uncertaintyMilliseconds
  }

  var validationIssues: [String] {
    var issues: [String] = []
    if schema != Self.schemaVersion { issues.append("sync_schema_not_supported") }
    if method != Self.monotonicReceiptMethod { issues.append("sync_method_not_supported") }
    issues.append(contentsOf: cameraClock.validationIssues.map { "camera_\($0)" })
    issues.append(contentsOf: rapsodoClock.validationIssues.map { "rapsodo_\($0)" })
    if !timelineMonotonicRangeSeconds.lowerBound.isFinite
      || !timelineMonotonicRangeSeconds.upperBound.isFinite
      || timelineMonotonicRangeSeconds.lowerBound >= timelineMonotonicRangeSeconds.upperBound
    {
      issues.append("sync_timeline_range_invalid")
    }
    if !uncertaintyMilliseconds.isFinite || uncertaintyMilliseconds < 0 {
      issues.append("sync_uncertainty_invalid")
    } else {
      let calibratedMinimum = hypot(
        cameraClock.uncertaintyMilliseconds,
        rapsodoClock.uncertaintyMilliseconds
      )
      if uncertaintyMilliseconds + 0.001 < calibratedMinimum {
        issues.append("sync_uncertainty_underreported")
      }
      if uncertaintyMilliseconds > Self.maximumPIPUncertaintyMilliseconds {
        issues.append("sync_uncertainty_exceeds_pip_budget")
      }
    }

    if let cameraStart = cameraClock.monotonicTimeSeconds(
      forMediaTimeSeconds: cameraClock.mediaRangeSeconds.lowerBound
    ),
      let cameraEnd = cameraClock.monotonicTimeSeconds(
        forMediaTimeSeconds: cameraClock.mediaRangeSeconds.upperBound
      ),
      let rapsodoStart = rapsodoClock.monotonicTimeSeconds(
        forMediaTimeSeconds: rapsodoClock.mediaRangeSeconds.lowerBound
      ),
      let rapsodoEnd = rapsodoClock.monotonicTimeSeconds(
        forMediaTimeSeconds: rapsodoClock.mediaRangeSeconds.upperBound
      )
    {
      let calibratedOverlapStart = max(cameraStart, rapsodoStart)
      let calibratedOverlapEnd = min(cameraEnd, rapsodoEnd)
      if calibratedOverlapStart >= calibratedOverlapEnd {
        issues.append("sync_calibrated_overlap_missing")
      } else if timelineMonotonicRangeSeconds.lowerBound < calibratedOverlapStart - 0.001
        || timelineMonotonicRangeSeconds.upperBound > calibratedOverlapEnd + 0.001
      {
        issues.append("sync_timeline_outside_calibrated_overlap")
      }
    }
    return Array(Set(issues)).sorted()
  }
}

/// One independently encoded replay asset. Hash and byte count are assigned by
/// `SwingRecordStore` from the committed copy, never trusted from an exporter.
struct SwingReplayAsset: Codable, Equatable, Sendable {
  var role: SwingReplayAssetRole
  var filename: String
  var sourceKind: String
  var sourceGenerationID: UUID?
  var contentSHA256: String?
  var byteCount: Int64?
  var durationMilliseconds: Int?
  var encodedPixelWidth: Int?
  var encodedPixelHeight: Int?
  var nominalFPS: Double?
  var orientation: SwingStoryboardCaptureOrientation
  var mediaRangeSeconds: ClosedRange<Double>?

  init(
    role: SwingReplayAssetRole,
    filename: String = "",
    sourceKind: String,
    sourceGenerationID: UUID? = nil,
    contentSHA256: String? = nil,
    byteCount: Int64? = nil,
    durationMilliseconds: Int? = nil,
    encodedPixelWidth: Int? = nil,
    encodedPixelHeight: Int? = nil,
    nominalFPS: Double? = nil,
    orientation: SwingStoryboardCaptureOrientation = .unknown,
    mediaRangeSeconds: ClosedRange<Double>? = nil
  ) {
    self.role = role
    self.filename = filename
    self.sourceKind = sourceKind
    self.sourceGenerationID = sourceGenerationID
    self.contentSHA256 = contentSHA256
    self.byteCount = byteCount
    self.durationMilliseconds = durationMilliseconds
    self.encodedPixelWidth = encodedPixelWidth
    self.encodedPixelHeight = encodedPixelHeight
    self.nominalFPS = nominalFPS
    self.orientation = orientation
    self.mediaRangeSeconds = mediaRangeSeconds
  }
}

/// Replay generation owned by one swing record. The camera master is required;
/// Rapsodo and its calibration are deliberately optional so a failed companion
/// capture never causes the high-speed camera evidence to be lost.
struct SwingReplayBundle: Codable, Equatable, Sendable {
  static let schemaVersion = "golftrace.swing-replay-bundle.v1"

  var schema: String
  var id: UUID
  var status: SwingReplayBundleStatus
  var camera: SwingReplayAsset
  var rapsodo: SwingReplayAsset?
  var synchronization: SwingReplaySynchronization?

  init(
    schema: String = SwingReplayBundle.schemaVersion,
    id: UUID = UUID(),
    camera: SwingReplayAsset,
    rapsodo: SwingReplayAsset? = nil,
    synchronization: SwingReplaySynchronization? = nil
  ) {
    self.schema = schema
    self.id = id
    self.camera = camera
    self.rapsodo = rapsodo
    self.synchronization = synchronization
    status = rapsodo != nil && synchronization != nil ? .synchronizedPair : .cameraSaved
  }

  var isSynchronizedPair: Bool {
    status == .synchronizedPair
      && camera.role == .swingCamera
      && rapsodo?.role == .rapsodoScreen
      && synchronization?.validationIssues.isEmpty == true
  }
}

/// Store-resolved URLs. Missing or damaged Rapsodo media degrades to a camera
/// master rather than making the entire swing unavailable.
struct SwingReplayBundleURLs: Equatable, Sendable {
  let bundle: SwingReplayBundle
  let cameraURL: URL
  let rapsodoURL: URL?

  var status: SwingReplayBundleStatus {
    rapsodoURL != nil && bundle.isSynchronizedPair ? .synchronizedPair : .cameraSaved
  }

  var synchronization: SwingReplaySynchronization? {
    status == .synchronizedPair ? bundle.synchronization : nil
  }
}

/// หลักฐานการจับคู่ค่าจาก launch monitor กับวงสวิงที่บันทึกไว้
///
/// `timeOffsetSeconds` ใช้เครื่องหมายบวกเมื่อค่าจาก MLM2PRO มาถึงหลังวงสวิง
/// และใช้เครื่องหมายลบเมื่อค่ามาถึงก่อนวงสวิง การเก็บเวลาทั้งสองฝั่งเป็น `Date`
/// ทำให้ตรวจสอบการจับคู่ย้อนหลังได้โดยไม่ปะปนกับ `CMTime` ของเฟรมวิดีโอ
struct LaunchMonitorMatch: Codable, Equatable, Sendable {
  static let currentMethod = "wall-clock-nearest-v2"

  var shot: LaunchMonitorShot
  var matchedAt: Date
  var timeOffsetSeconds: TimeInterval
  var matchingWindowSeconds: TimeInterval
  var method: String

  init(
    shot: LaunchMonitorShot,
    swingOccurredAt: Date,
    matchedAt: Date,
    matchingWindowSeconds: TimeInterval,
    method: String = LaunchMonitorMatch.currentMethod
  ) {
    self.shot = shot
    self.matchedAt = matchedAt
    self.timeOffsetSeconds = shot.receivedAt.timeIntervalSince(swingOccurredAt)
    self.matchingWindowSeconds = matchingWindowSeconds
    self.method = method
  }
}

/// ข้อมูลวงสวิงหนึ่งครั้งที่พร้อมบันทึกลงดิสก์
///
/// ไม่มี `CGPoint` หรือ `CMTime` อยู่ในข้อมูลที่เข้ารหัส เพื่อให้รูปแบบไฟล์ไม่ขึ้นกับ
/// framework ของ Apple และสามารถย้ายไปใช้กับระบบวิเคราะห์รุ่นถัดไปได้ง่าย
struct SwingRecord: Codable, Equatable, Identifiable, Sendable {
  struct SessionSummary: Codable, Equatable, Sendable {
    var durationSeconds: TimeInterval
    var peakNormalizedHandSpeed: Double
    var normalizedPathLength: Double
    var sampleCount: Int
    var completionReason: String
    var sourceStartTimestampSeconds: TimeInterval?
    var sourceEndTimestampSeconds: TimeInterval?
  }

  struct TracePoint: Codable, Equatable, Sendable {
    var normalizedX: Double
    var normalizedY: Double
    var timeOffsetSeconds: TimeInterval
  }

  static let currentSchemaVersion = 4

  var schemaVersion: Int
  var id: UUID
  var createdAt: Date
  var sessionSummary: SessionSummary
  var tracePoints: [TracePoint]
  var replayFilename: String?
  var replayBundle: SwingReplayBundle?
  var launchMonitorMatch: LaunchMonitorMatch?
  var artifacts: SwingRecordArtifacts?
  var metadata: [String: SwingRecordMetadataValue]

  init(
    schemaVersion: Int = SwingRecord.currentSchemaVersion,
    id: UUID = UUID(),
    createdAt: Date = Date(),
    sessionSummary: SessionSummary,
    tracePoints: [TracePoint],
    replayFilename: String? = nil,
    replayBundle: SwingReplayBundle? = nil,
    launchMonitorMatch: LaunchMonitorMatch? = nil,
    artifacts: SwingRecordArtifacts? = nil,
    metadata: [String: SwingRecordMetadataValue] = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.createdAt = createdAt
    self.sessionSummary = sessionSummary
    self.tracePoints = tracePoints
    self.replayFilename = replayFilename
    self.replayBundle = replayBundle
    self.launchMonitorMatch = launchMonitorMatch
    self.artifacts = artifacts
    self.metadata = metadata
  }

  /// แปลงผลจากตัวตรวจจับวงสวิงปัจจุบันเป็นค่าธรรมดาที่พร้อมบันทึก
  init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    capturedSession: SwingSessionSummary,
    artifacts: SwingRecordArtifacts? = nil,
    metadata: [String: SwingRecordMetadataValue] = [:]
  ) {
    let startSeconds = Self.validSeconds(capturedSession.startTimestamp)
    let completionReason: String
    switch capturedSession.completionReason {
    case .returnedToStillness:
      completionReason = "returnedToStillness"
    case .timedOut:
      completionReason = "timedOut"
    }

    self.init(
      id: id,
      createdAt: createdAt,
      sessionSummary: SessionSummary(
        durationSeconds: capturedSession.duration,
        peakNormalizedHandSpeed: capturedSession.peakNormalizedHandSpeed,
        normalizedPathLength: capturedSession.pathLength,
        sampleCount: capturedSession.sampleCount,
        completionReason: completionReason,
        sourceStartTimestampSeconds: startSeconds,
        sourceEndTimestampSeconds: Self.validSeconds(capturedSession.endTimestamp)
      ),
      tracePoints: capturedSession.pointHistory.compactMap { point in
        guard let timestamp = Self.validSeconds(point.timestamp) else { return nil }
        return TracePoint(
          normalizedX: Double(point.normalizedLocation.x),
          normalizedY: Double(point.normalizedLocation.y),
          timeOffsetSeconds: max(0, timestamp - (startSeconds ?? timestamp))
        )
      },
      artifacts: artifacts,
      metadata: metadata
    )
  }

  private static func validSeconds(_ time: CMTime) -> TimeInterval? {
    let seconds = CMTimeGetSeconds(time)
    return seconds.isFinite ? seconds : nil
  }
}

extension SwingRecord {
  private static let stageReplayLayoutMetadataKey = "stageReplayLayout"

  var stageReplayPaneLayout: GolfTraceStagePaneLayout? {
    guard
      case .object(let payload)? = metadata[Self.stageReplayLayoutMetadataKey],
      case .string("windowComposite")? = payload["kind"],
      let rapsodo = Self.normalizedRect(from: payload["rapsodo"]),
      let swingCamera = Self.normalizedRect(from: payload["swingCamera"])
    else { return nil }

    let layout = GolfTraceStagePaneLayout(
      rapsodo: rapsodo,
      swingCamera: swingCamera
    )
    return layout.isValid ? layout : nil
  }

  mutating func setStageReplayPaneLayout(_ layout: GolfTraceStagePaneLayout) {
    guard layout.isValid else { return }
    metadata[Self.stageReplayLayoutMetadataKey] = .object([
      "kind": .string("windowComposite"),
      "rapsodo": Self.metadataValue(for: layout.rapsodo),
      "swingCamera": Self.metadataValue(for: layout.swingCamera),
    ])
  }

  mutating func clearStageReplayPaneLayout() {
    metadata.removeValue(forKey: Self.stageReplayLayoutMetadataKey)
  }

  private static func metadataValue(
    for rect: GolfTraceNormalizedRect
  ) -> SwingRecordMetadataValue {
    .object([
      "x": .number(rect.x),
      "y": .number(rect.y),
      "width": .number(rect.width),
      "height": .number(rect.height),
    ])
  }

  private static func normalizedRect(
    from value: SwingRecordMetadataValue?
  ) -> GolfTraceNormalizedRect? {
    guard case .object(let payload)? = value,
      case .number(let x)? = payload["x"],
      case .number(let y)? = payload["y"],
      case .number(let width)? = payload["width"],
      case .number(let height)? = payload["height"]
    else { return nil }
    let rect = GolfTraceNormalizedRect(x: x, y: y, width: width, height: height)
    return rect.isValid ? rect : nil
  }
}
