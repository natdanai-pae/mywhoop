import SwiftUI

struct HandsFreeCaptureStatusPresentation {
  let title: String
  let detail: String
  let systemImage: String
  let tint: Color
  let isActive: Bool
  let isActionEnabled: Bool

  static func make(
    captureState: HandsFreeCaptureState,
    voiceStatus: HandsFreeVoiceCommandStatus,
    voiceError: String?,
    isEnabled: Bool,
    isAskingAI: Bool
  ) -> Self {
    guard isEnabled else {
      return Self(
        title: "คำสั่งเสียงปิดอยู่",
        detail: "เปิดได้จากเมนู AI",
        systemImage: "mic.slash",
        tint: .secondary,
        isActive: false,
        isActionEnabled: false
      )
    }

    if isAskingAI {
      return Self(
        title: "AI กำลังตอบหรือประมวลผล",
        detail: "คำสั่งเริ่มวงพักชั่วคราว · AI จะแจ้งเมื่อพร้อม",
        systemImage: "waveform",
        tint: GolfTraceTheme.blue,
        isActive: true,
        isActionEnabled: false
      )
    }

    switch captureState {
    case .acknowledged:
      return active(
        "รับคำสั่งแล้ว · เตรียมตี",
        "AI กำลังเริ่มนับถอยหลัง",
        icon: "speaker.wave.2.fill"
      )
    case .countdown(let value):
      return active(
        "นับถอยหลัง · \(value)",
        "รอให้ถึง 1 ก่อนเริ่มสวิง",
        icon: "timer"
      )
    case .armed:
      return Self(
        title: "พร้อมตี · รอวงเดียว",
        detail: "AI จะหยุดบันทึกเมื่อวงจบ",
        systemImage: "record.circle",
        tint: GolfTraceTheme.blue,
        isActive: true,
        isActionEnabled: true
      )
    case .capturing:
      return Self(
        title: "กำลังบันทึกวง",
        detail: "พูด “กอล์ฟเทรซ ยกเลิก”",
        systemImage: "record.circle.fill",
        tint: .red,
        isActive: true,
        isActionEnabled: true
      )
    case .finalizing:
      return Self(
        title: "บันทึกแล้ว · กำลังสร้างรีเพลย์",
        detail: "AI จะแจ้งเมื่อเปิดดูได้",
        systemImage: "ellipsis.circle",
        tint: .orange,
        isActive: true,
        isActionEnabled: false
      )
    case .replayReady:
      return Self(
        title: "บันทึกแล้ว · กำลังเปิดรีเพลย์",
        detail: "พร้อมตีวงถัดไป",
        systemImage: "checkmark.circle.fill",
        tint: .green,
        isActive: false,
        isActionEnabled: false
      )
    case .cancelled:
      return Self(
        title: "ยกเลิกการบันทึกแล้ว",
        detail: "กำลังกลับไปรอฟังคำสั่ง",
        systemImage: "xmark.circle",
        tint: .secondary,
        isActive: false,
        isActionEnabled: false
      )
    case .timedOut(let reason):
      if reason == .finalizing {
        return Self(
          title: "รีเพลย์ใช้เวลานานกว่าปกติ",
          detail: "ระบบยังเก็บไฟล์อยู่ · AI จะแจ้งเมื่อพร้อม",
          systemImage: "clock.arrow.circlepath",
          tint: .orange,
          isActive: true,
          isActionEnabled: false
        )
      }
      return Self(
        title: "ยังไม่พบวง · ยกเลิกแล้ว",
        detail: "พูดคำสั่งใหม่เมื่อพร้อม",
        systemImage: "clock.badge.exclamationmark",
        tint: .orange,
        isActive: false,
        isActionEnabled: false
      )
    case .error(let message):
      return Self(
        title: "บันทึกวงนี้ไม่ได้",
        detail: message,
        systemImage: "exclamationmark.triangle.fill",
        tint: .red,
        isActive: false,
        isActionEnabled: false
      )
    case .listening:
      break
    }

    switch voiceStatus {
    case .requestingAuthorization:
      return active("กำลังขอสิทธิ์เสียง", "อนุญาตไมค์และการรู้จำเสียง", icon: "lock.open")
    case .listening, .restarting:
      return active(
        "พร้อมฟังคำสั่ง",
        "พูด “กอล์ฟเทรซ เริ่มวง”",
        icon: "mic.fill"
      )
    case .speakingFeedback:
      return active("AI กำลังตอบ", "ฟังจบแล้วระบบจะรอคำสั่งต่อ", icon: "speaker.wave.2.fill")
    case .unavailable:
      return Self(
        title: "ไมค์คำสั่งไม่พร้อม",
        detail: voiceError ?? "กดแถบนี้หรือ Space เพื่อเริ่มแทน",
        systemImage: "mic.slash.fill",
        tint: .orange,
        isActive: false,
        isActionEnabled: true
      )
    case .idle, .suspended:
      return Self(
        title: "พร้อมเริ่มหนึ่งวง",
        detail: "กดแถบนี้หรือ Space เพื่อเริ่ม",
        systemImage: "record.circle",
        tint: GolfTraceTheme.blue,
        isActive: false,
        isActionEnabled: true
      )
    }
  }

  private static func active(_ title: String, _ detail: String, icon: String) -> Self {
    Self(
      title: title,
      detail: detail,
      systemImage: icon,
      tint: GolfTraceTheme.blue,
      isActive: true,
      isActionEnabled: true
    )
  }
}

struct HandsFreeCountdownOverlay: View {
  let value: Int
  let usesTempo: Bool

  var body: some View {
    VStack(spacing: 14) {
      Text("\(value)")
        .font(.system(size: 88, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .shadow(color: GolfTraceTheme.blue.opacity(0.72), radius: 22)

      HStack(spacing: 8) {
        ForEach([3, 2, 1], id: \.self) { step in
          Text("\(step)")
            .font(.caption.monospacedDigit().weight(.bold))
            .foregroundStyle(step == value ? .white : GolfTraceTheme.mutedText)
            .frame(width: 25, height: 25)
            .background(
              step == value ? GolfTraceTheme.blue.opacity(0.86) : Color.white.opacity(0.08),
              in: Circle()
            )
        }
      }

      Label(
        usesTempo ? "นับถอยหลัง + Tempo 3:1" : "นับถอยหลังแล้วบันทึกหนึ่งวง",
        systemImage: usesTempo ? "metronome" : "record.circle"
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white.opacity(0.92))
      .padding(.horizontal, 13)
      .padding(.vertical, 8)
      .background(.black.opacity(0.66), in: Capsule())
      .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 22)
    .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 24))
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("นับถอยหลัง \(value)")
  }
}
