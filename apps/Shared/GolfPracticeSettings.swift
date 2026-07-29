import Foundation

/// ชนิดไม้ที่ผู้เล่นเลือกก่อนตี ใช้แยก baseline และ guideline ของแต่ละไม้
/// ไม่ใช่ค่าที่เดาจากภาพ จึงไม่ควรเปลี่ยนอัตโนมัติโดยไม่บอกผู้ใช้
enum GolfClub: String, Codable, CaseIterable, Identifiable, Sendable {
  case driver
  case fairway3
  case fairway5
  case fairway7
  case hybrid2
  case hybrid3
  case hybrid4
  case hybrid5
  case iron3
  case iron4
  case iron5
  case iron6
  case iron7
  case iron8
  case iron9
  case pitchingWedge
  case gapWedge
  case sandWedge
  case lobWedge
  case putter

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .driver: return "ไดรเวอร์"
    case .fairway3: return "แฟร์เวย์ 3"
    case .fairway5: return "แฟร์เวย์ 5"
    case .fairway7: return "แฟร์เวย์ 7"
    case .hybrid2: return "ไฮบริด 2"
    case .hybrid3: return "ไฮบริด 3"
    case .hybrid4: return "ไฮบริด 4"
    case .hybrid5: return "ไฮบริด 5"
    case .iron3: return "เหล็ก 3"
    case .iron4: return "เหล็ก 4"
    case .iron5: return "เหล็ก 5"
    case .iron6: return "เหล็ก 6"
    case .iron7: return "เหล็ก 7"
    case .iron8: return "เหล็ก 8"
    case .iron9: return "เหล็ก 9"
    case .pitchingWedge: return "พิชชิงเวดจ์"
    case .gapWedge: return "แก๊ปเวดจ์"
    case .sandWedge: return "แซนด์เวดจ์"
    case .lobWedge: return "ล็อบเวดจ์"
    case .putter: return "พัตเตอร์"
    }
  }

  var shortName: String {
    switch self {
    case .driver: return "DR"
    case .fairway3: return "3W"
    case .fairway5: return "5W"
    case .fairway7: return "7W"
    case .hybrid2: return "2H"
    case .hybrid3: return "3H"
    case .hybrid4: return "4H"
    case .hybrid5: return "5H"
    case .iron3: return "3I"
    case .iron4: return "4I"
    case .iron5: return "5I"
    case .iron6: return "6I"
    case .iron7: return "7I"
    case .iron8: return "8I"
    case .iron9: return "9I"
    case .pitchingWedge: return "PW"
    case .gapWedge: return "GW"
    case .sandWedge: return "SW"
    case .lobWedge: return "LW"
    case .putter: return "PT"
    }
  }

  var familyName: String {
    switch self {
    case .driver: return "หัวไม้ไดรเวอร์"
    case .fairway3, .fairway5, .fairway7: return "หัวไม้แฟร์เวย์"
    case .hybrid2, .hybrid3, .hybrid4, .hybrid5: return "ไฮบริด"
    case .iron3, .iron4, .iron5: return "เหล็กยาว"
    case .iron6, .iron7: return "เหล็กกลาง"
    case .iron8, .iron9: return "เหล็กสั้น"
    case .pitchingWedge, .gapWedge, .sandWedge, .lobWedge: return "เวดจ์"
    case .putter: return "พัตเตอร์"
    }
  }
}

enum GolfCameraView: String, Codable, CaseIterable, Identifiable, Sendable {
  /// กล้องอยู่ด้านหลังผู้เล่น มองไปตามแนวเป้าหมาย
  case downTheLine
  /// กล้องอยู่ด้านหน้าผู้เล่น ตั้งฉากกับแนวเป้าหมาย
  case faceOn

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .downTheLine: return "หลังแนวตี"
    case .faceOn: return "ด้านหน้า"
    }
  }

  var setupHint: String {
    switch self {
    case .downTheLine:
      return "ตั้งกล้องระดับมือ เล็งผ่านแนวมือไปยังเป้าหมาย"
    case .faceOn:
      return "ตั้งกล้องระดับมือ ให้กลางภาพอยู่กึ่งกลางลำตัว"
    }
  }
}

/// Guideline คือเส้นช่วยดู ไม่ใช่คำตัดสินว่าวงใดถูกหรือผิด
enum GolfGuideline: String, Codable, CaseIterable, Identifiable, Sendable {
  case personalBaseline
  case posture
  case swingPlane
  case rotation
  case tempo
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .personalBaseline: return "วงดีของฉัน"
    case .posture: return "ท่าเตรียม"
    case .swingPlane: return "แนวสวิง"
    case .rotation: return "การหมุน"
    case .tempo: return "จังหวะ"
    case .none: return "ไม่แสดงเส้น"
    }
  }
}

/// โปรรุ่นเริ่มต้นเป็นบุคลิกสมมติ ไม่ใช้ชื่อ ใบหน้า หรือเสียงของบุคคลจริง
enum GolfCoachProfileID: String, Codable, CaseIterable, Identifiable, Sendable {
  case personalBlend
  case dataCoach
  case rhythmCoach
  case bodyCoach

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .personalBlend: return "โปรของฉัน"
    case .dataCoach: return "โปรวิเคราะห์"
    case .rhythmCoach: return "โปรจังหวะ"
    case .bodyCoach: return "โปรการเคลื่อนไหว"
    }
  }

  var teachingStyle: String {
    switch self {
    case .personalBlend: return "ผสมแนวทางที่คุณเลือก และเทียบกับวงที่ดีที่สุดของคุณ"
    case .dataCoach: return "พูดสั้น ใช้ค่าที่วัดได้ และแก้ทีละหนึ่งเรื่อง"
    case .rhythmCoach: return "เน้นความต่อเนื่อง จังหวะขึ้นลง และแบบฝึกที่ทำตามง่าย"
    case .bodyCoach: return "เน้นท่าเตรียม การหมุนลำตัว สะโพก และการรักษาสมดุล"
    }
  }
}

enum GolfCoachAudioDevice: String, Codable, CaseIterable, Identifiable, Sendable {
  case mac
  case iphone
  case muted

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .mac: return "พูดที่ Mac"
    case .iphone: return "พูดที่ iPhone"
    case .muted: return "ปิดเสียง"
    }
  }
}

/// ค่าควบคุมรอบซ้อมที่ iPhone ส่งไป Mac พร้อมสตรีมวิดีโอ
struct GolfPracticeSettings: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  static let `default` = GolfPracticeSettings(
    club: .iron7,
    cameraView: .downTheLine,
    guideline: .personalBaseline,
    coach: .personalBlend,
    audioDevice: .mac
  )

  var schemaVersion: Int
  var club: GolfClub
  var cameraView: GolfCameraView
  var guideline: GolfGuideline
  var coach: GolfCoachProfileID
  var audioDevice: GolfCoachAudioDevice

  init(
    schemaVersion: Int = currentSchemaVersion,
    club: GolfClub,
    cameraView: GolfCameraView,
    guideline: GolfGuideline,
    coach: GolfCoachProfileID,
    audioDevice: GolfCoachAudioDevice
  ) {
    self.schemaVersion = schemaVersion
    self.club = club
    self.cameraView = cameraView
    self.guideline = guideline
    self.coach = coach
    self.audioDevice = audioDevice
  }

  func encoded() -> Data? {
    try? JSONEncoder().encode(self)
  }

  static func decode(_ data: Data) -> GolfPracticeSettings? {
    guard let value = try? JSONDecoder().decode(Self.self, from: data),
      value.schemaVersion <= currentSchemaVersion
    else {
      return nil
    }
    return value
  }
}
