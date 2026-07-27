import Foundation

/// โปรไฟล์ AI โปรเป็นเจ้าของ "ชุดแหล่งอ้างอิง" ไม่ได้เป็นเจ้าของไฟล์วิดีโอ
/// source เดียวจึงนำไปใช้ได้หลายโปรไฟล์โดยไม่ต้องอ่าน transcript/ภาพซ้ำ
struct AIGolfProKnowledgeProfile: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  var name: String
  var teachingStyle: String
  var sourceIDs: [UUID]
  let createdAt: Date
  var updatedAt: Date
  var isLegacyImport: Bool

  var sourceCount: Int { sourceIDs.count }
}

enum YouTubeKnowledgeStatus: Codable, Equatable, Sendable {
  case queued
  case fetchingTranscript
  case transcriptReady
  case indexing
  case ready
  case noTranscript
  case failed(String)

  var title: String {
    switch self {
    case .queued: return "รออ่านคำถอดเสียง"
    case .fetchingTranscript: return "MCP กำลังอ่านคำถอดเสียง"
    case .transcriptReady: return "พบคำถอดเสียง — รอ DeepSeek อ่าน"
    case .indexing: return "DeepSeek-V4-Flash กำลังจัดความรู้"
    case .ready: return "พร้อมใช้กับ AI Golf Pro"
    case .noTranscript: return "ไม่มีคำถอดเสียง"
    case .failed(let message): return message
    }
  }

  var isBusy: Bool {
    switch self {
    case .fetchingTranscript, .indexing: return true
    case .queued, .transcriptReady, .ready, .noTranscript, .failed: return false
    }
  }
}

enum YouTubeVisualStatus: Codable, Equatable, Sendable {
  case notRequested
  case fetching
  case ready
  case unavailable
  case failed(String)

  var title: String {
    switch self {
    case .notRequested: return "ยังไม่ได้อ่านภาพประกอบ"
    case .fetching: return "MCP ภาพ + Apple Vision กำลังอ่านท่าทาง"
    case .ready: return "ภาพอ้างอิงพร้อมใช้"
    case .unavailable: return "ยังไม่พบภาพที่อ่านท่าทางได้"
    case .failed(let message): return message
    }
  }

  var isBusy: Bool { self == .fetching }
}

/// สถานะการผูก claim กับภาพโดย VLM แยกจากสถานะ source และ Apple Vision
/// เพื่อให้ VLM ล้มเหลวได้โดยไม่ทำให้ transcript, claims หรือ pose/OCR ที่มีอยู่เสียไป
enum YouTubeVisualGroundingStatus: Codable, Equatable, Sendable {
  case notRequested
  case analyzing
  case ready
  case failed(String)

  var title: String {
    switch self {
    case .notRequested: return "ยังไม่ได้ให้ VLM ตรวจ claim กับภาพ"
    case .analyzing: return "GX10 VLM กำลังตรวจ claim กับภาพ"
    case .ready: return "VLM ตรวจ claim กับภาพแล้ว"
    case .failed(let message): return message
    }
  }

  var isBusy: Bool { self == .analyzing }
}

struct YouTubeTranscriptChunk: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let startSeconds: Double?
  let endSeconds: Double?
  let text: String

  var timecodeText: String? {
    guard let startSeconds else { return nil }
    let total = max(0, Int(startSeconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}

struct GolfTeachingClaim: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let text: String
  let sourceChunkID: String
  let startSeconds: Double?
  let clubFamilies: [String]
  let cameraViews: [String]
  let topics: [String]
  let limitations: [String]
}

struct ReferencePoseJoint: Codable, Equatable, Sendable, Identifiable {
  let name: String
  let x: Double
  let y: Double
  let confidence: Double

  var id: String { name }
}

struct ReferencePoseMetrics: Codable, Equatable, Sendable {
  let handCenterX: Double?
  let handCenterY: Double?
  let headCenterX: Double?
  let headCenterY: Double?
  let pelvisCenterX: Double?
  let pelvisCenterY: Double?
  let torsoTilt2DDegrees: Double?
  let shoulderSpan2D: Double?
  let hipSpan2D: Double?
  let leftElbowAngle2DDegrees: Double?
  let rightElbowAngle2DDegrees: Double?
  let leftKneeAngle2DDegrees: Double?
  let rightKneeAngle2DDegrees: Double?
}

/// ภาพอ้างอิงจาก YouTube ที่ผูกกับเวลาและ claim อย่างตรวจย้อนกลับได้
/// ภาพจริงอยู่เป็นไฟล์แยก ส่วน JSON นี้เก็บเฉพาะตำแหน่งไฟล์และผล Vision 2 มิติ
struct ReferenceFrameObservation: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let timestampSeconds: Double
  let relativeImagePath: String
  let mimeType: String
  let sha256: String
  let pixelWidth: Int
  let pixelHeight: Int
  let joints: [ReferencePoseJoint]
  let metrics: ReferencePoseMetrics
  /// ข้อความสั้นที่ Apple Vision OCR อ่านได้จากป้าย/เส้นกำกับในภาพ
  /// ถือเป็นข้อมูลที่ไม่น่าเชื่อถือและห้ามนำไปใช้เป็นคำสั่งแก่โมเดล
  var recognizedText: [String]? = nil
  let linkedClaimIDs: [String]
  let qualityFlags: [String]
  let poseModelVersion: String

  var hasUsableBodyPose: Bool {
    joints.filter { $0.confidence >= 0.55 }.count >= 8
      && !qualityFlags.contains("ไม่พบร่างกาย")
      && !qualityFlags.contains("พบหลายคน ต้องเลือกนักกอล์ฟก่อนใช้เป็น guideline")
  }

  /// หลักฐานภาพใช้ได้เมื่อมี pose ที่เชื่อถือได้ หรือมีข้อความบนภาพให้ตรวจร่วมกับ transcript
  /// เฟรมหลายคนยังใช้ OCR ได้ แต่ห้ามใช้ค่าร่างกายของคนแรกเป็นตัวแทนทั้งภาพ
  var hasUsableVisualEvidence: Bool {
    hasUsableBodyPose || !(recognizedText ?? []).isEmpty
  }
}

struct YouTubeKnowledgeSource: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let videoID: String
  let canonicalURL: String
  var title: String
  var language: String
  var providerName: String
  var status: YouTubeKnowledgeStatus
  var importedAt: Date?
  var transcriptHash: String?
  var characterCount: Int
  var chunks: [YouTubeTranscriptChunk]
  var claims: [GolfTeachingClaim]
  var visualStatus: YouTubeVisualStatus? = nil
  var frames: [ReferenceFrameObservation]? = nil
  var visualGroundingStatus: YouTubeVisualGroundingStatus? = nil
  var visualGroundings: [VisualClaimGrounding]? = nil

  var readyClaimCount: Int { claims.count }
  var readyFrameCount: Int { frames?.filter(\.hasUsableBodyPose).count ?? 0 }
  var usableVisualFrameCount: Int { frames?.filter(\.hasUsableVisualEvidence).count ?? 0 }
  var readyVisualGroundingCount: Int { visualGroundings?.count ?? 0 }
}

struct GolfKnowledgeExcerpt: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let sourceID: UUID
  let sourceTitle: String
  let sourceURL: String
  let startSeconds: Double?
  let text: String
  let limitations: [String]
  /// ระบุโปรไฟล์ที่เลือกใช้ในรอบนี้ เพื่อให้ตรวจย้อนกลับได้ว่า AI โปรคนใด
  /// เป็นผู้เลือกชุดแหล่งอ้างอิงนี้ (ข้อมูลเก่าที่ไม่มีค่านี้ยัง decode ได้)
  var profileID: UUID? = nil
  var profileName: String? = nil
  var visualEvidence: [ReferenceFrameObservation]? = nil
  var visualGroundings: [VisualClaimGrounding]? = nil
}

struct YouTubeVideoReference: Equatable, Sendable {
  let videoID: String
  let canonicalURL: URL

  static func parse(_ rawValue: String) -> YouTubeVideoReference? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if Self.isValidVideoID(trimmed) {
      return Self.make(videoID: trimmed)
    }

    guard var components = URLComponents(string: trimmed),
      let host = components.host?.lowercased()
    else {
      return nil
    }

    if host == "youtu.be" || host.hasSuffix(".youtu.be") {
      let candidate = components.path.split(separator: "/").first.map(String.init)
      guard let candidate, Self.isValidVideoID(candidate) else { return nil }
      return Self.make(videoID: candidate)
    }

    let isYouTubeHost =
      host == "youtube.com" || host.hasSuffix(".youtube.com")
      || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    guard isYouTubeHost else { return nil }

    let pathParts = components.path.split(separator: "/").map(String.init)
    var candidate: String?
    if components.path == "/watch" {
      candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
    } else if let first = pathParts.first,
      ["shorts", "live", "embed"].contains(first),
      pathParts.count >= 2
    {
      candidate = pathParts[1]
    }

    guard let candidate, Self.isValidVideoID(candidate) else { return nil }
    components = URLComponents()
    return Self.make(videoID: candidate)
  }

  private static func make(videoID: String) -> YouTubeVideoReference? {
    guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
      return nil
    }
    return YouTubeVideoReference(videoID: videoID, canonicalURL: url)
  }

  private static func isValidVideoID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
  }
}
