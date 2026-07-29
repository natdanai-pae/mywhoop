import Foundation

enum GolfCoachEvidenceKind: String, Codable, Sendable {
  case rapsodoMeasured
  case cameraMeasured2D
  case personalBaseline
  case selectedGuideline
  case licensedKnowledge
  case externalReference
  case userStatement

  var displayName: String {
    switch self {
    case .rapsodoMeasured: return "Rapsodo วัดได้"
    case .cameraMeasured2D: return "กล้องวัดได้จากภาพ 2 มิติ"
    case .personalBaseline: return "เทียบวงดีของผู้เล่น"
    case .selectedGuideline: return "แนวทางที่ผู้เล่นเลือก"
    case .licensedKnowledge: return "แหล่งความรู้ที่มีสิทธิ์"
    case .externalReference: return "แหล่งอ้างอิงภายนอก"
    case .userStatement: return "ข้อมูลที่ผู้เล่นบอก"
    }
  }
}

struct GolfCoachEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let kind: GolfCoachEvidenceKind
  let label: String
  let value: String
  let confidence: Double
  let limitation: String?
}

struct GolfCoachCitation: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let title: String
  let url: String?
  let timecodeSeconds: Double?
  let rightsBasis: String
}

struct GolfCoachReferenceFrameEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let timestampSeconds: Double
  let imageHash: String
  let metrics2D: ReferencePoseMetrics
  var recognizedText: [String]? = nil
  let qualityFlags: [String]
  let poseModelVersion: String
}

struct GolfCoachKnowledgeEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let sourceTitle: String
  let sourceURL: String
  let timestampSeconds: Double?
  let claim: String
  let limitations: [String]
  let referenceFrames: [GolfCoachReferenceFrameEvidence]
  /// ผลตีความภาพของ VLM เป็นหลักฐานประเภท ai_inferred ไม่ใช่ค่าที่กล้องวัดโดยตรง
  var visualGroundings: [VisualClaimGrounding] = []
}

struct GolfCoachSwingSnapshot: Codable, Equatable, Sendable {
  let durationSeconds: Double
  let sampleCount: Int
  let handPathBodyLengths: Double?
  let peakHandSpeedBodyLengthsPerSecond: Double?
  let addressTorsoTiltDegrees: Double?
  let torsoTiltChangeDegrees: Double?
  let shoulderProjectionReductionPercent: Double?
  let hipProjectionReductionPercent: Double?
  let backswingSeconds: Double?
  let downswingSeconds: Double?
  let handTempoRatio: Double?
  let quality: String
  let trackedFraction: Double
  let limitation: String
}

struct GolfCoachLaunchSnapshot: Codable, Equatable, Sendable {
  let clubHeadSpeedMPH: Double
  let ballSpeedMPH: Double
  let horizontalLaunchAngleDegrees: Double
  let verticalLaunchAngleDegrees: Double
  let spinAxisDegrees: Double
  let totalSpinRPM: Int
  let smashFactor: Double?
  let source: String
  let sourceType: SwingEvidenceSourceType
}

/// รูปแบบข้อมูล Rapsodo ที่ส่งขึ้น AI: ชื่อคอลัมน์และหน่วยส่งครั้งเดียว
/// จากนั้นค่าทั้งหมดอยู่ในแถวตัวเลข ไม่มี raw BLE packet หรือชื่ออุปกรณ์
struct GolfCoachLaunchNumericPacket: Codable, Equatable, Sendable {
  static let schema = "golftrace.launch.numeric.v1"
  static let valueOrder = [
    "club_speed_mps", "ball_speed_mps", "horizontal_launch_deg",
    "vertical_launch_deg", "spin_axis_deg", "total_spin_rpm", "smash_factor",
  ]
  /// 1=m/s, 2=degree, 3=rpm, 4=ratio
  static let unitCodes = [1, 1, 2, 2, 2, 3, 4]

  let schema: String
  let receivedAtUnixMs: Int64
  /// 3 = Rapsodo measured
  let sourceCode: Int
  /// 2 = available
  let availabilityCode: Int
  let confidence: Double
  let valueOrder: [String]
  let unitCodes: [Int]
  let valueRow: [Double?]

  init(shot: LaunchMonitorShot) {
    schema = Self.schema
    receivedAtUnixMs = Int64((shot.receivedAt.timeIntervalSince1970 * 1_000).rounded())
    sourceCode = 3
    availabilityCode = 2
    confidence = 1
    valueOrder = Self.valueOrder
    unitCodes = Self.unitCodes
    valueRow = [
      shot.clubHeadSpeedMetersPerSecond,
      shot.ballSpeedMetersPerSecond,
      shot.horizontalLaunchAngleDegrees,
      shot.verticalLaunchAngleDegrees,
      shot.spinAxisDegrees,
      Double(shot.totalSpinRPM),
      shot.smashFactor,
    ]
  }
}

struct GolfCoachRequestContext: Codable, Equatable, Sendable {
  let language: String
  let playerQuestion: String
  let club: String
  let clubFamily: String
  let cameraView: String
  let guideline: String
  let coachProfile: String
  let coachTeachingStyle: String
  /// ใช้ใน UI/fallback ภายในเครื่อง; AI รับข้อมูลเดียวกันในรูป numeric packet เพื่อลด token
  var swing: GolfCoachSwingSnapshot? = nil
  /// ข้อมูลรายเวลาที่ Mac สกัดแล้ว เป็นหลักฐานหลักสำหรับ text model
  /// เก็บรูปแบบเต็มไว้ตรวจ contract ภายในเครื่อง แต่ไม่ encode ส่งขึ้นเครือข่าย
  var swingEvidencePacket: SwingEvidencePacket? = nil
  /// รูปแบบแถวตัวเลขที่ encode ส่งให้ AI จริง
  var swingEvidenceNumeric: SwingEvidenceNumericPacket? = nil
  /// ใช้แสดงผลและ fallback ในเครื่อง ไม่ encode ขึ้นเครือข่าย
  var launch: GolfCoachLaunchSnapshot? = nil
  /// รูปแบบแถวตัวเลขที่ encode ส่งให้ AI จริง
  var launchNumeric: GolfCoachLaunchNumericPacket? = nil
  /// ใช้แสดงหลักฐานในเครื่อง ข้อมูลตัวเลขซ้ำถูกตัดออกจาก network payload
  var evidence: [GolfCoachEvidence] = []
  let citations: [GolfCoachCitation]
  var knowledge: [GolfCoachKnowledgeEvidence] = []

  enum CodingKeys: String, CodingKey {
    case language, playerQuestion, club, clubFamily, cameraView, guideline
    case coachProfile, coachTeachingStyle, swingEvidenceNumeric, launchNumeric
    case citations, knowledge
  }

  static func make(
    question: String,
    settings: GolfPracticeSettings,
    summary: SwingSessionSummary?,
    analysis: SwingAnalysisSummary?,
    evidencePacket: SwingEvidencePacket? = nil,
    launch: LaunchMonitorShot?,
    citations: [GolfCoachCitation] = [],
    knowledgeExcerpts: [GolfKnowledgeExcerpt] = []
  ) -> GolfCoachRequestContext {
    let swingSnapshot: GolfCoachSwingSnapshot?
    if let summary, let analysis {
      swingSnapshot = GolfCoachSwingSnapshot(
        durationSeconds: summary.duration,
        sampleCount: summary.sampleCount,
        handPathBodyLengths: analysis.handPathBodyLengths.value,
        peakHandSpeedBodyLengthsPerSecond:
          analysis.peakHandSpeedBodyLengthsPerSecond.value,
        addressTorsoTiltDegrees: analysis.addressTorsoTiltDegrees.value,
        torsoTiltChangeDegrees: analysis.torsoTiltChangeDegrees.value,
        shoulderProjectionReductionPercent: analysis.shoulderSpanReductionPercent.value,
        hipProjectionReductionPercent: analysis.hipSpanReductionPercent.value,
        backswingSeconds: analysis.backswingSeconds.value,
        downswingSeconds: analysis.downswingSeconds.value,
        handTempoRatio: analysis.handTempoRatio.value,
        quality: analysis.quality.displayName,
        trackedFraction: analysis.trackedFraction,
        limitation:
          "ค่าจากกล้องเป็นภาพฉาย 2 มิติและเส้นทางกึ่งกลางข้อมือ "
          + "ไม่ใช่หัวไม้ มุมหมุน 3 มิติ หรือจังหวะปะทะลูก"
      )
    } else {
      swingSnapshot = nil
    }

    let launchSnapshot = launch.map {
      GolfCoachLaunchSnapshot(
        clubHeadSpeedMPH: $0.clubHeadSpeedMPH,
        ballSpeedMPH: $0.ballSpeedMPH,
        horizontalLaunchAngleDegrees: $0.horizontalLaunchAngleDegrees,
        verticalLaunchAngleDegrees: $0.verticalLaunchAngleDegrees,
        spinAxisDegrees: $0.spinAxisDegrees,
        totalSpinRPM: Int($0.totalSpinRPM),
        smashFactor: $0.smashFactor,
        source: $0.source,
        sourceType: .rapsodoMeasured
      )
    }

    var evidence: [GolfCoachEvidence] = []
    if let analysis {
      evidence.append(
        GolfCoachEvidence(
          id: "camera-quality",
          kind: .cameraMeasured2D,
          label: "ความต่อเนื่องของข้อต่อ",
          value: String(format: "%.0f%%", analysis.trackedFraction * 100),
          confidence: analysis.trackedFraction,
          limitation: analysis.reason
        )
      )
      if let tempo = analysis.handTempoRatio.value {
        evidence.append(
          GolfCoachEvidence(
            id: "hand-tempo",
            kind: .cameraMeasured2D,
            label: "จังหวะมือขึ้นต่อกลับลง",
            value: String(format: "%.2f : 1", tempo),
            confidence: analysis.handTempoRatio.trackedFraction,
            limitation: analysis.handTempoRatio.reason
          )
        )
      }
    }
    if let launch {
      evidence.append(
        GolfCoachEvidence(
          id: "rapsodo-ball",
          kind: .rapsodoMeasured,
          label: "ความเร็วลูกและสปิน",
          value: String(format: "%.1f mph · %d rpm", launch.ballSpeedMPH, launch.totalSpinRPM),
          confidence: 1,
          limitation: nil
        )
      )
    }
    evidence.append(
      GolfCoachEvidence(
        id: "selected-guideline",
        kind: .selectedGuideline,
        label: "แนวทางรอบนี้",
        value: settings.guideline.displayName,
        confidence: 1,
        limitation: "เป็นแนวทางที่ผู้เล่นเลือก ไม่ใช่กฎตายตัวของวงสวิง"
      )
    )

    let knowledge = knowledgeExcerpts.prefix(8).map { excerpt in
      let frames = (excerpt.visualEvidence ?? []).prefix(2).map { frame in
        GolfCoachReferenceFrameEvidence(
          id: frame.id,
          timestampSeconds: frame.timestampSeconds,
          imageHash: frame.sha256,
          metrics2D: frame.metrics,
          recognizedText: frame.recognizedText,
          qualityFlags: frame.qualityFlags,
          poseModelVersion: frame.poseModelVersion
        )
      }
      let groundings = (excerpt.visualGroundings ?? []).filter { grounding in
        grounding.supportedClaimIDs.contains(excerpt.id)
          || grounding.contradictedClaimIDs.contains(excerpt.id)
      }
      return GolfCoachKnowledgeEvidence(
        id: excerpt.id,
        sourceTitle: excerpt.sourceTitle,
        sourceURL: excerpt.sourceURL,
        timestampSeconds: excerpt.startSeconds,
        claim: excerpt.text,
        limitations: excerpt.limitations,
        referenceFrames: frames,
        visualGroundings: Array(groundings.prefix(6))
      )
    }

    for item in knowledge {
      evidence.append(
        GolfCoachEvidence(
          id: "knowledge-\(item.id)",
          kind: .externalReference,
          label: item.sourceTitle,
          value: item.claim,
          confidence: item.referenceFrames.isEmpty ? 0.6 : 0.8,
          limitation:
            item.limitations.first
            ?? "ภาพเป็นเฟรมอ้างอิง 2 มิติ ไม่ใช่การวัดวงสวิง 3 มิติ"
        )
      )
    }

    var allCitations = citations
    allCitations.append(
      contentsOf: knowledge.map {
        GolfCoachCitation(
          id: $0.id,
          title: $0.sourceTitle,
          url: $0.sourceURL,
          timecodeSeconds: $0.timestampSeconds,
          rightsBasis:
            "ผู้ใช้เพิ่ม URL เป็นแหล่งอ้างอิงภายนอก ต้องตรวจสิทธิ์แยกก่อนเผยแพร่หรือใช้ฝึกโมเดล"
        )
      })
    let uniqueCitations = Dictionary(grouping: allCitations, by: \.id).compactMap { _, values in
      values.first
    }.sorted { $0.id < $1.id }

    return GolfCoachRequestContext(
      language: "th-TH",
      playerQuestion: question,
      club: settings.club.displayName,
      clubFamily: settings.club.familyName,
      cameraView: settings.cameraView.displayName,
      guideline: settings.guideline.displayName,
      coachProfile: settings.coach.displayName,
      coachTeachingStyle: settings.coach.teachingStyle,
      swing: swingSnapshot,
      swingEvidencePacket: evidencePacket,
      swingEvidenceNumeric: evidencePacket.map(SwingEvidenceNumericPacket.init(packet:)),
      launch: launchSnapshot,
      launchNumeric: launch.map(GolfCoachLaunchNumericPacket.init(shot:)),
      evidence: evidence,
      citations: uniqueCitations,
      knowledge: knowledge
    )
  }
}

struct GolfCoachAdvice: Codable, Equatable, Sendable {
  let speech: String
  let focusTitle: String
  let evidenceSummary: String
  let drill: String
  let confidence: Double
  let limitations: [String]
  let citationIDs: [String]

  static func localFallback(for context: GolfCoachRequestContext) -> GolfCoachAdvice {
    if context.swing == nil {
      return GolfCoachAdvice(
        speech: "ยังเห็นวงสวิงไม่ครบ ลองจัดกล้องให้เห็นตั้งแต่ศีรษะถึงปลายไม้ก่อนนะครับ",
        focusTitle: "จัดกล้องให้ข้อมูลชัดก่อน",
        evidenceSummary: "ยังไม่มีผลวิเคราะห์วงล่าสุดที่เชื่อถือได้",
        drill: "ยืนท่าเตรียมค้างหนึ่งวินาที แล้วลองสวิงอีกครั้ง",
        confidence: 1,
        limitations: ["ยังไม่เรียก AI ภายนอก เพราะข้อมูลภาพไม่พอ"],
        citationIDs: []
      )
    }

    return GolfCoachAdvice(
      speech: "วงนี้บันทึกได้แล้วครับ รอบถัดไปให้คงจังหวะเดิมและเปลี่ยนเพียงหนึ่งอย่างตาม guideline ที่เลือก",
      focusTitle: "เปลี่ยนทีละหนึ่งอย่าง",
      evidenceSummary: context.evidence.first?.value ?? "มีข้อมูลวงสวิงจากกล้อง",
      drill: "ตีอีกสามลูกด้วยจังหวะเดิม แล้วค่อยเทียบแนวโน้ม",
      confidence: min(1, context.swing?.trackedFraction ?? 0.5),
      limitations: ["คำแนะนำสำรองนี้ไม่ใช่คำตอบจาก OpenRouter"],
      citationIDs: []
    )
  }
}
