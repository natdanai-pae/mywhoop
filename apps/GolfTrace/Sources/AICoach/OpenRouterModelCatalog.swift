import Foundation

enum GolfAIModelRole: String, Codable, Sendable {
  case coach
  case critic
  case visionAudit
  case shadowEvaluation
}

enum GolfAIInputClass: String, Codable, Sendable {
  case structuredSwingPacket
  case playerAuditFrame
  case syntheticEvaluationFrame
}

/// รายชื่อโมเดลที่ pin ไว้เพื่อให้ผลทดสอบทำซ้ำได้
/// Popularity บน leaderboard ไม่ใช่หลักฐานว่าโมเดลเข้าใจกอล์ฟ
struct OpenRouterGolfModelProfile: Equatable, Sendable {
  let id: String
  let role: GolfAIModelRole
  let acceptsImages: Bool
  let isFree: Bool
  let requiresEvaluationPass: Bool
  let allowsRealPlayerFrames: Bool
  let expiresAt: Date?
  let note: String

  func isEligible(
    for input: GolfAIInputClass,
    evaluationPassed: Bool,
    playerFrameConsent: Bool,
    now: Date = Date()
  ) -> Bool {
    if let expiresAt, now >= expiresAt { return false }
    if requiresEvaluationPass && !evaluationPassed { return false }
    switch input {
    case .structuredSwingPacket:
      return true
    case .playerAuditFrame:
      return acceptsImages && allowsRealPlayerFrames && playerFrameConsent
    case .syntheticEvaluationFrame:
      return acceptsImages
    }
  }
}

enum OpenRouterGolfModelCatalog {
  /// เส้นทางหลัก: ถูกและรับ structured output; รับเฉพาะ packet ที่ Mac สกัดแล้ว
  static let primaryCoach = OpenRouterGolfModelProfile(
    id: "deepseek/deepseek-v4-flash",
    role: .coach,
    acceptsImages: false,
    isFree: false,
    requiresEvaluationPass: true,
    allowsRealPlayerFrames: false,
    expiresAt: nil,
    note: "text model สำหรับตีความ SwingEvidencePacket ภาษาไทยหลังผ่านชุดทดสอบ GolfTrace"
  )

  /// โมเดลคนละตระกูล ใช้ตรวจคำตอบเฉพาะกรณีความมั่นใจต่ำหรือหลักฐานขัดกัน
  static let paidCritic = OpenRouterGolfModelProfile(
    id: "tencent/hy3",
    role: .critic,
    acceptsImages: false,
    isFree: false,
    requiresEvaluationPass: true,
    allowsRealPlayerFrames: false,
    expiresAt: nil,
    note: "text critic; ไม่ใช่ vision และไม่ใช่โมเดลเฉพาะกอล์ฟ"
  )

  /// ตัวตรวจภาพแบบจ่าย ใช้ 1–2 keyframe เมื่อ packet ไม่พอและผู้ใช้ยินยอมเท่านั้น
  static let paidVisionAudit = OpenRouterGolfModelProfile(
    id: "google/gemini-3.1-flash-lite",
    role: .visionAudit,
    acceptsImages: true,
    isFree: false,
    requiresEvaluationPass: true,
    allowsRealPlayerFrames: true,
    expiresAt: nil,
    note: "audit 1–2 keyframes; ห้ามใช้แทน local pose/club detector"
  )

  /// ใช้กับข้อมูลสังเคราะห์/packet ที่ไม่ระบุตัวบุคคลเพื่อ benchmark เท่านั้น
  static let freeVisionShadow = OpenRouterGolfModelProfile(
    id: "google/gemma-4-31b-it:free",
    role: .shadowEvaluation,
    acceptsImages: true,
    isFree: true,
    requiresEvaluationPass: false,
    allowsRealPlayerFrames: false,
    expiresAt: nil,
    note: "free shadow ไม่มี ZDR ที่ยืนยัน จึงห้ามรับภาพผู้เล่นจริง"
  )

  /// รุ่นฟรีนี้ใกล้หมดอายุ จึงเก็บไว้เพียงเพื่อทำ regression ชั่วคราว
  static let temporaryHy3Free = OpenRouterGolfModelProfile(
    id: "tencent/hy3:free",
    role: .shadowEvaluation,
    acceptsImages: false,
    isFree: true,
    requiresEvaluationPass: false,
    allowsRealPlayerFrames: false,
    expiresAt: ISO8601DateFormatter().date(from: "2026-07-21T00:00:00Z"),
    note: "text-only และ OpenRouter ประกาศยุติ 21 กรกฎาคม 2026"
  )
}
