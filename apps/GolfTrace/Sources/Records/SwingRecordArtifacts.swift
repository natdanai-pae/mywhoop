import Foundation

/// แปดช่วงมาตรฐานของ Storyboard
///
/// `allCases` เป็นแหล่งจริงเพียงแห่งเดียวสำหรับลำดับบน UI ส่วน record จะเก็บ marker
/// เฉพาะช่วงที่มีหลักฐานรองรับเท่านั้น จึงไม่สร้างภาพหรือเวลาเดาเพื่อเติมช่องว่าง
enum SwingStoryboardPhaseSlot: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case address
  case takeaway
  case backswing
  case top
  case downswing
  case impact
  case followThrough = "follow_through"
  case finish

  var titleTH: String {
    switch self {
    case .address: return "จรดลูก"
    case .takeaway: return "เริ่มแบ็กสวิง"
    case .backswing: return "แบ็กสวิง"
    case .top: return "บนสุด"
    case .downswing: return "ดาวน์สวิง"
    case .impact: return "ปะทะ"
    case .followThrough: return "ฟอลโลว์ทรู"
    case .finish: return "จบวง"
    }
  }

  var titleEN: String {
    switch self {
    case .address: return "Address"
    case .takeaway: return "Takeaway"
    case .backswing: return "Backswing"
    case .top: return "Top"
    case .downswing: return "Downswing"
    case .impact: return "Impact"
    case .followThrough: return "Follow-through"
    case .finish: return "Finish"
    }
  }

  /// แปลงชื่อ marker จาก analyzer หลายรุ่นเป็น slot เดียวกันโดยไม่ตีความ marker ที่ไม่รู้จัก
  init?(evidenceMarkerID: String) {
    let normalized =
      evidenceMarkerID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "-", with: "_")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: "_")

    switch normalized {
    case "address", "setup": self = .address
    case "takeaway", "take_away": self = .takeaway
    case "backswing", "back_swing", "half_backswing": self = .backswing
    case "top", "top_estimated_from_hand_reversal": self = .top
    case "downswing", "down_swing": self = .downswing
    case "impact", "impact_window", "impact_estimated_from_hand_return": self = .impact
    case "extension", "followthrough", "follow_through", "follow_thru": self = .followThrough
    case "finish", "finish_from_session_end", "finish_returned_to_stillness": self = .finish
    default: return nil
    }
  }
}

/// การหมุนที่ต้องใช้กับพิกเซลดิบของแหล่งภาพหนึ่งชุด
enum SwingStoryboardCaptureOrientation: String, Codable, Equatable, Sendable {
  case degrees0 = "degrees_0"
  case degrees90 = "degrees_90"
  case degrees180 = "degrees_180"
  case degrees270 = "degrees_270"
  case unknown

  init(_ orientation: GolfTraceVideoOrientation) {
    switch orientation {
    case .degrees0: self = .degrees0
    case .degrees90: self = .degrees90
    case .degrees180: self = .degrees180
    case .degrees270: self = .degrees270
    }
  }

  var clockwiseDegrees: Double? {
    switch self {
    case .degrees0: return 0
    case .degrees90: return 90
    case .degrees180: return 180
    case .degrees270: return 270
    case .unknown: return nil
    }
  }

  /// The only caller-applied transform allowed on top of the wire orientation
  /// is GolfTrace's explicit 180-degree correction for an upside-down mount.
  func isSameOrManualHalfTurn(from source: Self) -> Bool {
    guard let expected = clockwiseDegrees,
      let sourceDegrees = source.clockwiseDegrees
    else { return false }
    let delta = (expected - sourceDegrees + 360).truncatingRemainder(dividingBy: 360)
    return abs(delta) < 0.1 || abs(delta - 180) < 0.1
  }
}

/// ค่าคงที่ของแหล่งภาพกล้องสำหรับ record หนึ่งวง
///
/// Marker และ keyframe ทั้งหมดใน `SwingRecordArtifacts` อ้างอิง snapshot เดียวนี้โดยนัย
/// จึงไม่สามารถเอาเฟรมคนละมุมกล้องมาปะปนใน Storyboard เดียวกันได้
struct SwingStoryboardCaptureSnapshot: Codable, Equatable, Sendable {
  static let primaryIPhoneSourceID = "iphone.camera.primary"

  var sourceID: String
  var cameraView: String
  var orientation: SwingStoryboardCaptureOrientation
  var encodedPixelWidth: Int?
  var encodedPixelHeight: Int?
  var captureFPS: Double?

  init(
    sourceID: String,
    cameraView: String,
    orientation: SwingStoryboardCaptureOrientation,
    encodedPixelWidth: Int? = nil,
    encodedPixelHeight: Int? = nil,
    captureFPS: Double? = nil
  ) {
    self.sourceID = sourceID
    self.cameraView = cameraView
    self.orientation = orientation
    self.encodedPixelWidth = encodedPixelWidth
    self.encodedPixelHeight = encodedPixelHeight
    self.captureFPS = captureFPS
  }

  static func inferred(from packet: SwingEvidencePacket) -> Self {
    Self(
      sourceID: primaryIPhoneSourceID,
      cameraView: packet.cameraView,
      orientation: .unknown,
      captureFPS: packet.captureFPS
    )
  }

  var validationIssues: [String] {
    var issues: [String] = []
    if sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("capture_source_id_missing")
    }
    if cameraView.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("capture_camera_view_missing")
    }
    if (encodedPixelWidth == nil) != (encodedPixelHeight == nil) {
      issues.append("capture_dimensions_incomplete")
    }
    if let encodedPixelWidth, encodedPixelWidth <= 0 {
      issues.append("capture_width_invalid")
    }
    if let encodedPixelHeight, encodedPixelHeight <= 0 {
      issues.append("capture_height_invalid")
    }
    if let captureFPS, !captureFPS.isFinite || captureFPS <= 0 {
      issues.append("capture_fps_invalid")
    }
    return issues
  }
}

/// ที่มาของเวลา phase โดยไม่ลดทอนรายละเอียดของ marker เดิม
struct SwingStoryboardPhaseProvenance: Codable, Equatable, Sendable {
  var evidenceMarkerID: String
  var sourceType: SwingEvidenceSourceType
}

/// เวลา phase ที่พร้อมใช้กับ Storyboard
///
/// `sourceTimestampMs` อ้างอิง t=0 ของวงสวิงจาก iPhone ส่วน `replayTimestampMs`
/// อ้างอิงต้นไฟล์ replay ทั้งหน้าจอ จึงต้องเป็น nil จนกว่าจะมี clock mapping ที่ยืนยันได้
struct SwingStoryboardPhaseMarker: Codable, Equatable, Sendable {
  var slot: SwingStoryboardPhaseSlot
  var sourceTimestampMs: Int
  var replayTimestampMs: Int?
  var provenance: SwingStoryboardPhaseProvenance
  var confidence: Double
  var limitation: String?
}

enum SwingStoryboardKeyframeExtractionState: String, Codable, Equatable, Sendable {
  case pending
  case available
  case unavailable
  case failed
}

/// สัญญาสำหรับตัวแยก keyframe รุ่นถัดไป โดยยังไม่แอบอ้างว่ามีไฟล์ภาพแล้ว
struct SwingStoryboardKeyframeDescriptor: Codable, Equatable, Sendable {
  var slot: SwingStoryboardPhaseSlot
  var sourceTimestampMs: Int
  var nearestPoseTimestampMs: Int?
  var alignmentDeltaMs: Int?
  var state: SwingStoryboardKeyframeExtractionState
  var imageContentID: String?
  var filename: String?
  var contentSHA256: String?
  var pixelWidth: Int?
  var pixelHeight: Int?
  /// เวลาเฟรมที่ AVFoundation ดึงได้จริง เทียบกับ t=0 ของวงสวิงจาก iPhone
  /// ไม่จำเป็นต้องเท่ากับ `sourceTimestampMs` เพราะ codec เลือกเฟรมที่ใกล้ที่สุด
  var extractedSourceTimestampMs: Int? = nil
  var byteCount: Int? = nil
  var limitation: String?
}

/// หลักฐานและ artifact ทั้งหมดที่ทำให้ Swing Storyboard สร้างซ้ำได้ภายหลัง
struct SwingRecordArtifacts: Codable, Equatable, Sendable {
  static let schemaVersion = "golftrace.swing-record-artifacts.v1"

  var schema: String
  var capture: SwingStoryboardCaptureSnapshot
  var evidencePacket: SwingEvidencePacket
  var phaseMarkers: [SwingStoryboardPhaseMarker]
  var keyframes: [SwingStoryboardKeyframeDescriptor]
  /// Calibration ระหว่าง media clock ของ iPhone กับ replay ทั้งหน้าจอ
  /// เป็น nil จน stage recorder มี anchor เพียงพอและผ่าน uncertainty gate
  var replayClockMapping: SwingReplayClockMapping? = nil

  /// คืน nil เมื่อ packet และ capture มาจากคนละมุม เพื่อรักษา one-angle invariant
  init?(
    evidencePacket: SwingEvidencePacket,
    capture: SwingStoryboardCaptureSnapshot? = nil
  ) {
    let resolvedCapture = capture ?? .inferred(from: evidencePacket)
    guard resolvedCapture.cameraView == evidencePacket.cameraView,
      resolvedCapture.validationIssues.isEmpty
    else { return nil }

    var markerBySlot: [SwingStoryboardPhaseSlot: SwingStoryboardPhaseMarker] = [:]
    for marker in evidencePacket.phases {
      guard let slot = SwingStoryboardPhaseSlot(evidenceMarkerID: marker.id) else { continue }
      let candidate = SwingStoryboardPhaseMarker(
        slot: slot,
        sourceTimestampMs: marker.tMs,
        replayTimestampMs: nil,
        provenance: SwingStoryboardPhaseProvenance(
          evidenceMarkerID: marker.id,
          sourceType: marker.sourceType
        ),
        confidence: marker.confidence,
        limitation: marker.limitation
      )
      if let existing = markerBySlot[slot], existing.confidence >= candidate.confidence {
        continue
      }
      markerBySlot[slot] = candidate
    }

    let orderedMarkers = SwingStoryboardPhaseSlot.allCases.compactMap { markerBySlot[$0] }
    let auditRequestBySlot = Dictionary(
      evidencePacket.auditFrameRequests.compactMap { request in
        SwingStoryboardPhaseSlot(evidenceMarkerID: request.role).map { ($0, request) }
      },
      uniquingKeysWith: { current, _ in current }
    )
    let keyframes: [SwingStoryboardKeyframeDescriptor] =
      orderedMarkers.map { marker in
        let request = auditRequestBySlot[marker.slot]
        return SwingStoryboardKeyframeDescriptor(
          slot: marker.slot,
          sourceTimestampMs: marker.sourceTimestampMs,
          nearestPoseTimestampMs: request?.nearestPoseTMs,
          alignmentDeltaMs: request?.alignmentDeltaMs,
          state: request?.imageContentID == nil
            ? SwingStoryboardKeyframeExtractionState.pending
            : SwingStoryboardKeyframeExtractionState.available,
          imageContentID: request?.imageContentID,
          filename: nil,
          contentSHA256: nil,
          pixelWidth: nil,
          pixelHeight: nil,
          limitation: request?.imageContentID == nil
            ? "รอตัวแยก keyframe ผูกพิกเซลจากแหล่งภาพเดียวกับ record"
            : nil
        )
      }

    schema = Self.schemaVersion
    self.capture = resolvedCapture
    self.evidencePacket = evidencePacket
    phaseMarkers = orderedMarkers
    self.keyframes = keyframes
  }

  /// ตรวจไฟล์ที่อ่านกลับจากดิสก์โดยไม่เปลี่ยนหรือเติมข้อมูลใน record
  func validationIssues() -> [String] {
    var issues = capture.validationIssues
    if schema != Self.schemaVersion { issues.append("artifacts_schema_not_supported") }
    if let replayClockMapping,
      replayClockMapping.schema != SwingReplayClockMapping.schemaVersion
    {
      issues.append("replay_clock_mapping_schema_not_supported")
    }
    if capture.cameraView != evidencePacket.cameraView {
      issues.append("artifacts_mixed_camera_view")
    }
    issues.append(contentsOf: evidencePacket.validationIssues().map { "evidence_\($0)" })

    let slots = phaseMarkers.map(\.slot)
    if Set(slots).count != slots.count { issues.append("phase_slot_duplicated") }
    if phaseMarkers
      != SwingStoryboardPhaseSlot.allCases.compactMap({ slot in
        phaseMarkers.first { $0.slot == slot }
      })
    {
      issues.append("phase_order_invalid")
    }
    for marker in phaseMarkers {
      if marker.sourceTimestampMs < 0 || marker.sourceTimestampMs > evidencePacket.durationMs {
        issues.append("phase_source_timestamp_invalid")
      }
      if let replayTimestampMs = marker.replayTimestampMs, replayTimestampMs < 0 {
        issues.append("phase_replay_timestamp_invalid")
      }
      if !(0...1).contains(marker.confidence) { issues.append("phase_confidence_invalid") }
    }
    for keyframe in keyframes {
      if !slots.contains(keyframe.slot) { issues.append("keyframe_without_phase") }
      if keyframe.state == .available,
        keyframe.imageContentID == nil && keyframe.filename == nil
      {
        issues.append("keyframe_available_without_content")
      }
      if let extractedSourceTimestampMs = keyframe.extractedSourceTimestampMs,
        extractedSourceTimestampMs < 0
          || extractedSourceTimestampMs > evidencePacket.durationMs
      {
        issues.append("keyframe_extracted_timestamp_invalid")
      }
      if let byteCount = keyframe.byteCount, byteCount <= 0 {
        issues.append("keyframe_byte_count_invalid")
      }
    }
    return Array(Set(issues)).sorted()
  }
}
