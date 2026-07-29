import SwiftUI

struct DashboardHeader: View {
  @Binding var isPracticeModeEnabled: Bool
  let isAIRecording: Bool
  let hasStoredAPIKey: Bool
  let isAIBusy: Bool
  let captureStatusTitle: String
  let captureStatusDetail: String
  let captureStatusSystemImage: String
  let captureStatusTint: Color
  let isCaptureStatusActive: Bool
  let isCaptureActionEnabled: Bool
  let onToggleAI: () -> Void
  let onToggleCapture: () -> Void
  let onCaptureScreen: () -> Void
  let onOpenControls: () -> Void

  var body: some View {
    ZStack {
      HStack(spacing: 10) {
        Image(systemName: "figure.golf")
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(GolfTraceTheme.blue)
          .frame(width: 38, height: 38)
          .background(GolfTraceTheme.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))

        Text("GolfTrace")
          .font(.system(size: 20, weight: .bold, design: .rounded))

        Spacer()

        Button {
          isPracticeModeEnabled.toggle()
        } label: {
          Label("โหมดฝึกซ้อม", systemImage: isPracticeModeEnabled ? "flag.fill" : "flag")
            .font(.subheadline.weight(.semibold))
            .frame(width: 125, height: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(isPracticeModeEnabled ? 0.14 : 0.08), lineWidth: 1)
        )

        Button(action: onCaptureScreen) {
          Label("เก็บภาพ", systemImage: "camera.viewfinder")
            .font(.subheadline.weight(.semibold))
            .frame(width: 92, height: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .help("เก็บภาพหน้าจอไว้ในเครื่อง")

        Button(action: onOpenControls) {
          Image(systemName: "gearshape.fill")
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 52, height: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .help("ควบคุมแหล่งภาพ กล้อง AI และประวัติ")
      }

      HStack(spacing: 10) {
        Button(action: onToggleAI) {
          HStack(spacing: 9) {
            Image(systemName: isAIRecording ? "stop.fill" : "waveform")
              .foregroundStyle(isAIRecording ? Color.red : GolfTraceTheme.blue)
            Text(isAIRecording ? "หยุดฟัง" : "AI Golf Pro")
              .foregroundStyle(.white)
          }
          .font(.subheadline.weight(.semibold))
          .frame(width: 132, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAIRecording ? Color.red : Color.white)
        .background(
          (isAIRecording ? Color.red : GolfTraceTheme.blue).opacity(0.12),
          in: Capsule()
        )
        .overlay(
          Capsule()
            .stroke(
              (isAIRecording ? Color.red : GolfTraceTheme.blue).opacity(0.78),
              lineWidth: 1
            )
        )
        .disabled(!hasStoredAPIKey || (!isAIRecording && isAIBusy))
        .help("กดเพื่อถามด้วยเสียง พร้อมเก็บ snapshot ในเครื่องและข้อมูลวงสวิงล่าสุด")

        captureStatusPill
      }
      .offset(x: 25)
    }
    .padding(.horizontal, 30)
    .padding(.vertical, 10)
    .background(GolfTraceTheme.canvas.opacity(0.98))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(GolfTraceTheme.subtleBorder)
        .frame(height: 1)
    }
  }

  private var captureStatusPill: some View {
    Button(action: onToggleCapture) {
      HStack(spacing: 9) {
        HeaderWaveform(isActive: isCaptureStatusActive, tint: captureStatusTint)
          .frame(width: 36, height: 19)

        Image(systemName: captureStatusSystemImage)
          .font(.caption.weight(.bold))
          .foregroundStyle(captureStatusTint)

        VStack(alignment: .leading, spacing: 1) {
          Text(captureStatusTitle)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
          Text(captureStatusDetail)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(GolfTraceTheme.mutedText)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 13)
      .frame(width: 278, height: 42)
      .background(captureStatusTint.opacity(0.09), in: Capsule())
      .overlay(Capsule().stroke(captureStatusTint.opacity(0.28), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(!isCaptureActionEnabled)
    .keyboardShortcut(.space, modifiers: [])
    .help("เริ่มหรือยกเลิกการบันทึกหนึ่งวง · ปุ่ม Space")
    .accessibilityLabel("\(captureStatusTitle), \(captureStatusDetail)")
  }
}
