import Foundation

/// แหล่งกำเนิดของข้อมูลทุกชิ้นที่ส่งให้ AI ต้องระบุชัดเจน
/// เพื่อไม่ให้ค่าที่ AI คาดเดาปะปนกับค่าที่กล้องหรือ launch monitor วัดจริง
enum SwingEvidenceSourceType: String, Codable, Equatable, Sendable {
  case macVision2D = "mac_vision_2d"
  case macDerived2D = "mac_derived_2d"
  case rapsodoMeasured = "rapsodo_measured"
  case aiInferred = "ai_inferred"
}

enum SwingEvidenceAvailability: String, Codable, Equatable, Sendable {
  case available
  case limited
  case unavailable
}

/// หนึ่งเฟรมของข้อมูลที่ Mac สกัดแล้ว ไม่ใช่ภาพดิบ
///
/// `joints` ใช้รหัสสั้นและเก็บค่า `[x, y, confidence]` ในพิกัด Vision 0...1
/// เพื่อประหยัด token แต่ยังคงเวลาและความมั่นใจของทุกจุดไว้
struct SwingEvidenceTimelineFrame: Codable, Equatable, Sendable {
  let tMs: Int
  let joints: [String: [Double]]
  /// `[x, y]` ของกึ่งกลางข้อมือ ไม่ใช่หัวไม้
  let handCenter: [Double]?
  /// ค่ารายเฟรม เช่น ความเร็วมือ มุมลำตัว และช่วงไหล่/สะโพกแบบภาพ 2 มิติ
  let values: [String: Double]
}

/// ค่าสรุปพร้อมช่วงเวลาที่ใช้คำนวณและที่มาของค่า
struct SwingEvidenceMetric: Codable, Equatable, Sendable {
  let id: String
  let value: Double?
  let unit: String
  let sourceType: SwingEvidenceSourceType
  let availability: SwingEvidenceAvailability
  let confidence: Double
  let windowStartMs: Int
  let windowEndMs: Int
  let limitation: String
}

struct SwingEvidencePhaseMarker: Codable, Equatable, Sendable {
  let id: String
  let tMs: Int
  let sourceType: SwingEvidenceSourceType
  let confidence: Double
  let limitation: String?
}

/// ตำแหน่งเวลาที่ตัวแยกภาพควรสร้าง keyframe ภายหลัง
/// ตัว packet ไม่แอบอ้างว่ามีภาพ หาก `imageContentID` ยังเป็น nil
struct SwingAuditFrameRequest: Codable, Equatable, Sendable {
  let role: String
  let requestedTMs: Int
  let nearestPoseTMs: Int?
  let alignmentDeltaMs: Int?
  let imageContentID: String?
}

struct SwingEvidenceCapability: Codable, Equatable, Sendable {
  let id: String
  let availability: SwingEvidenceAvailability
  let sourceType: SwingEvidenceSourceType?
  let limitation: String
}

/// ข้อมูลวงสวิงแบบ feature-first ที่ Mac เตรียมให้ AI
///
/// เส้นทางหลักส่ง packet นี้ให้ text model; ภาพ keyframe 1–2 ภาพเป็นเพียง
/// หลักฐานตรวจทานแบบเลือกใช้ ไม่ใช่หน้าที่ของโมเดลในการสกัดค่าทั้งหมดใหม่
struct SwingEvidencePacket: Codable, Equatable, Sendable {
  static let schemaVersion = "golftrace.swing-evidence.v1"
  static let maximumTimelineFrames = 30
  static let maximumAuditFrames = 2

  let schema: String
  let coordinateSpace: String
  /// เวลาเริ่มข้อมูลก่อนเริ่มสวิง เช่น -600 หมายถึงมีท่า address ก่อน t=0 อยู่ 600 ms
  let contextStartMs: Int
  let durationMs: Int
  let cameraView: String
  let captureFPS: Double?
  let poseAnalysisFPS: Double?
  let analyzedPoseFrameCount: Int
  let sentTimelineFrameCount: Int
  let timeline: [SwingEvidenceTimelineFrame]
  let metrics: [SwingEvidenceMetric]
  let phases: [SwingEvidencePhaseMarker]
  let auditFrameRequests: [SwingAuditFrameRequest]
  let capabilities: [SwingEvidenceCapability]
  let limitations: [String]

  /// ตรวจ contract ก่อนเรียกโมเดล หากมีปัญหาต้องหยุดหรือขอข้อมูลใหม่บน Mac
  func validationIssues() -> [String] {
    var issues: [String] = []
    if schema != Self.schemaVersion { issues.append("schema_not_supported") }
    if durationMs <= 0 { issues.append("duration_invalid") }
    if timeline.count > Self.maximumTimelineFrames { issues.append("timeline_too_large") }
    if auditFrameRequests.count > Self.maximumAuditFrames { issues.append("audit_frames_too_many") }

    var previousTMs: Int?
    for frame in timeline {
      if frame.tMs < contextStartMs || frame.tMs > durationMs {
        issues.append("timeline_out_of_window")
      }
      if let previousTMs, frame.tMs <= previousTMs { issues.append("timeline_not_monotonic") }
      previousTMs = frame.tMs

      for values in frame.joints.values {
        guard values.count == 3,
          values.allSatisfy(\.isFinite),
          (0...1).contains(values[0]),
          (0...1).contains(values[1]),
          (0...1).contains(values[2])
        else {
          issues.append("joint_invalid")
          continue
        }
      }
      if let handCenter = frame.handCenter,
        handCenter.count != 2
          || !handCenter.allSatisfy(\.isFinite)
          || !(0...1).contains(handCenter[0])
          || !(0...1).contains(handCenter[1])
      {
        issues.append("hand_center_invalid")
      }
      if !frame.values.values.allSatisfy(\.isFinite) { issues.append("frame_value_invalid") }
    }

    for metric in metrics {
      if let value = metric.value, !value.isFinite { issues.append("metric_invalid") }
      if !(0...1).contains(metric.confidence) { issues.append("metric_confidence_invalid") }
      if metric.windowStartMs < contextStartMs || metric.windowEndMs > durationMs
        || metric.windowStartMs > metric.windowEndMs
      {
        issues.append("metric_window_invalid")
      }
    }

    for marker in phases {
      if marker.tMs < 0 || marker.tMs > durationMs { issues.append("phase_out_of_window") }
      if !(0...1).contains(marker.confidence) { issues.append("phase_confidence_invalid") }
    }
    return Array(Set(issues)).sorted()
  }
}

struct SwingAnalysisResult: Equatable, Sendable {
  let summary: SwingAnalysisSummary
  let evidencePacket: SwingEvidencePacket
}

/// รูปแบบที่ส่งขึ้น AI จริง: ใช้แถวตัวเลขแทน object ยาว ๆ ซ้ำทุกเฟรม
/// ชื่อคอลัมน์ส่งเพียงครั้งเดียวเพื่อกันโมเดลสลับความหมายของตัวเลข
struct SwingEvidenceNumericPacket: Codable, Equatable, Sendable {
  static let schema = "golftrace.numeric.v1"
  static let frameValueOrder = [
    "hand_x", "hand_y", "hand_speed_image_per_s", "torso_tilt_2d_deg",
    "shoulder_span_2d", "hip_span_2d", "torso_length_2d",
  ]

  let schema: String
  /// 1 = down-the-line, 2 = face-on, 0 = unknown
  let cameraViewCode: Int
  /// `[contextStartMs, durationMs]`
  let timeWindow: [Int]
  /// `[captureFPS, poseAnalysisFPS]`
  let fps: [Double?]
  /// `[analyzedPoseFrameCount, sentTimelineFrameCount]`
  let counts: [Int]
  let jointOrder: [String]
  let frameValueOrder: [String]
  /// `[tMs, joint1.x, joint1.y, joint1.confidence, ..., frame values...]`
  let frameRows: [[Double?]]
  let metricOrder: [String]
  /// `[value, unitCode, sourceCode, availabilityCode, confidence, startMs, endMs]`
  let metricRows: [[Double?]]
  let phaseOrder: [String]
  /// `[tMs, sourceCode, confidence]`
  let phaseRows: [[Double]]
  let auditRoleOrder: [String]
  /// `[requestedTMs, nearestPoseTMs, deltaMs, hasImage]`
  let auditRows: [[Double?]]
  let capabilityOrder: [String]
  /// `[availabilityCode, sourceCode]`; source 0 = ไม่มีแหล่งวัด
  let capabilityRows: [[Double]]
  /// 1=2D only, 2=hand is not club, 3=no club detector,
  /// 4=impact unconfirmed, 5=audit pixels absent
  let qualityFlagCodes: [Int]

  init(packet: SwingEvidencePacket) {
    let joints = [
      "nose", "neck", "ls", "rs", "le", "re", "lw", "rw",
      "lh", "rh", "lk", "rk", "la", "ra",
    ]
    schema = Self.schema
    switch packet.cameraView {
    case "downTheLine": cameraViewCode = 1
    case "faceOn": cameraViewCode = 2
    default: cameraViewCode = 0
    }
    timeWindow = [packet.contextStartMs, packet.durationMs]
    fps = [packet.captureFPS, packet.poseAnalysisFPS]
    counts = [packet.analyzedPoseFrameCount, packet.sentTimelineFrameCount]
    jointOrder = joints
    frameValueOrder = Self.frameValueOrder
    frameRows = packet.timeline.map { frame in
      var row: [Double?] = [Double(frame.tMs)]
      for joint in joints {
        let point = frame.joints[joint]
        row.append(point?[safe: 0])
        row.append(point?[safe: 1])
        row.append(point?[safe: 2])
      }
      row.append(frame.handCenter?[safe: 0])
      row.append(frame.handCenter?[safe: 1])
      row.append(frame.values["hand_speed_image_per_s"])
      row.append(frame.values["torso_tilt_2d_deg"])
      row.append(frame.values["shoulder_span_2d"])
      row.append(frame.values["hip_span_2d"])
      row.append(frame.values["torso_length_2d"])
      return row
    }
    metricOrder = packet.metrics.map(\.id)
    metricRows = packet.metrics.map { metric in
      [
        metric.value,
        Double(Self.unitCode(metric.unit)),
        Double(Self.sourceCode(metric.sourceType)),
        Double(Self.availabilityCode(metric.availability)),
        metric.confidence,
        Double(metric.windowStartMs),
        Double(metric.windowEndMs),
      ]
    }
    phaseOrder = packet.phases.map(\.id)
    phaseRows = packet.phases.map {
      [Double($0.tMs), Double(Self.sourceCode($0.sourceType)), $0.confidence]
    }
    auditRoleOrder = packet.auditFrameRequests.map(\.role)
    auditRows = packet.auditFrameRequests.map {
      [
        Double($0.requestedTMs),
        $0.nearestPoseTMs.map(Double.init),
        $0.alignmentDeltaMs.map(Double.init),
        $0.imageContentID == nil ? 0 : 1,
      ]
    }
    capabilityOrder = packet.capabilities.map(\.id)
    capabilityRows = packet.capabilities.map {
      [
        Double(Self.availabilityCode($0.availability)),
        Double($0.sourceType.map(Self.sourceCode) ?? 0),
      ]
    }
    qualityFlagCodes =
      [1, 2, 3, 4] + (packet.auditFrameRequests.contains { $0.imageContentID == nil } ? [5] : [])
  }

  private static func sourceCode(_ source: SwingEvidenceSourceType) -> Int {
    switch source {
    case .macVision2D: return 1
    case .macDerived2D: return 2
    case .rapsodoMeasured: return 3
    case .aiInferred: return 4
    }
  }

  private static func availabilityCode(_ value: SwingEvidenceAvailability) -> Int {
    switch value {
    case .unavailable: return 0
    case .limited: return 1
    case .available: return 2
    }
  }

  private static func unitCode(_ unit: String) -> Int {
    switch unit {
    case "body_length": return 1
    case "body_length_per_second": return 2
    case "degree": return 3
    case "percent": return 4
    case "second": return 5
    case "ratio": return 6
    default: return 0
    }
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
