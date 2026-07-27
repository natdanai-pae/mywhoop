import Foundation
import SwiftUI

private enum DarkSettingsPalette {
  static let card = Color(red: 0.035, green: 0.043, blue: 0.054)
  static let inset = Color.white.opacity(0.035)
  static let border = Color.white.opacity(0.12)
  static let subtleBorder = Color.white.opacity(0.075)
}

private struct DarkSettingsCardModifier: ViewModifier {
  let background: Color
  let border: Color
  let cornerRadius: CGFloat
  let padding: CGFloat

  func body(content: Content) -> some View {
    content
      .environment(\.colorScheme, .dark)
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(background)
      )
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(border, lineWidth: 1)
      )
  }
}

extension View {
  fileprivate func darkSettingsCard(
    background: Color = DarkSettingsPalette.card,
    border: Color = DarkSettingsPalette.border,
    cornerRadius: CGFloat = 14,
    padding: CGFloat = 14
  ) -> some View {
    modifier(
      DarkSettingsCardModifier(
        background: background,
        border: border,
        cornerRadius: cornerRadius,
        padding: padding
      )
    )
  }

  fileprivate func darkSettingsInset(padding: CGFloat = 9) -> some View {
    darkSettingsCard(
      background: DarkSettingsPalette.inset,
      border: DarkSettingsPalette.subtleBorder,
      cornerRadius: 9,
      padding: padding
    )
  }
}

struct LaunchMonitorPanel: View {
  @ObservedObject var controller: LaunchMonitorController
  @ObservedObject var credentials: RapsodoCredentialSettings
  @Binding var secretInput: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Rapsodo MLM2PRO", systemImage: "scope")
        .font(.headline)
        .foregroundStyle(.primary)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: stateIcon)
            .foregroundStyle(stateColor)
          Text(controller.statusText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stateColor)
            .fixedSize(horizontal: false, vertical: true)

          Spacer(minLength: 8)

          if let batteryLevel = controller.batteryLevel {
            Label("\(batteryLevel)%", systemImage: "battery.75percent")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }

        if case .awaitingDeviceTrust(let id, let deviceName) = controller.state {
          VStack(alignment: .leading, spacing: 8) {
            Text("ยืนยันครั้งแรกก่อนเชื่อมต่อ")
              .font(.caption.weight(.bold))

            Text(
              "ตรวจว่า \(deviceName) ของคุณเปิดอยู่และอุปกรณ์เครื่องอื่นปิดอยู่ก่อนกดปุ่ม แอปจะจำรหัสนี้และเชื่อมต่ออัตโนมัติครั้งต่อไป"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)

            Text("รหัสที่ Mac ใช้จำเครื่อง: \(id.uuidString)")
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)

            HStack {
              Button("นี่คือ MLM2PRO ของฉัน") {
                controller.confirmTrustAndConnect(to: id)
              }
              .buttonStyle(.borderedProminent)

              Button("ไม่ใช่เครื่องนี้") {
                controller.rejectDeviceTrust(for: id)
              }
              .buttonStyle(.bordered)
            }
          }
        }

        if case .awaitingAuthorization = controller.state {
          Text(
            "บน iPhone: เปิด Rapsodo › Play › Simulation › 3rd Party Apps › Awesome Golf › Authenticate Now จนขึ้นสำเร็จ จากนั้นปิด Rapsodo เพื่อปล่อย Bluetooth แล้วค่อยลองเชื่อมใหม่"
          )
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)

          DisclosureGroup("ตั้งค่าสิทธิ์สำหรับนักพัฒนา") {
            VStack(alignment: .leading, spacing: 8) {
              Text(credentials.statusText)
                .font(.caption2)
                .foregroundStyle(credentials.hasStoredSecret ? Color.green : Color.secondary)

              if credentials.hasStoredSecret {
                HStack {
                  Button("ยืนยันอีกครั้ง") {
                    controller.setTokenProvider(credentials.tokenProvider)
                  }
                  .buttonStyle(.borderedProminent)

                  Button("เปลี่ยนรหัส") {
                    credentials.deleteSecret()
                  }
                  .buttonStyle(.bordered)
                }
              } else {
                SecureField("รหัสเชื่อมต่อจาก Rapsodo", text: $secretInput)

                Button("บันทึกและยืนยัน") {
                  guard credentials.saveSecret(secretInput) else { return }
                  secretInput = ""
                  controller.setTokenProvider(credentials.tokenProvider)
                }
                .buttonStyle(.borderedProminent)
                .disabled(secretInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }

              Text("ไม่ใช่รหัสผ่านบัญชี รหัสนี้เก็บใน Keychain ของ Mac และไม่ถูกเขียนลง log")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

              Text(
                "ต้องเป็น Secret สำหรับตัวเชื่อม Simulator ที่ Rapsodo อนุญาตโดยเฉพาะ การกด Third-party ในแอป Rapsodo เพียงอย่างเดียวจะไม่สร้างรหัสนี้"
              )
              .font(.caption2)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
          }
          .font(.caption.weight(.semibold))
        }

        if let trustedPeripheralID = controller.trustedPeripheralID {
          DisclosureGroup("เครื่อง MLM2PRO ที่แอปจำไว้") {
            VStack(alignment: .leading, spacing: 8) {
              Text(trustedPeripheralID.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

              Button("เปลี่ยนไปใช้ MLM2PRO เครื่องอื่น") {
                controller.forgetTrustedDevice()
                controller.start()
              }
              .buttonStyle(.bordered)
            }
            .padding(.top, 4)
          }
          .font(.caption.weight(.semibold))
        }

        if let lastError = controller.lastError {
          Text(lastError)
            .font(.caption2)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let shot = controller.latestShot {
          Divider()

          HStack {
            Text("ผลลูกล่าสุด")
              .font(.caption.weight(.bold))
            Spacer()
            Text(shot.receivedAt.formatted(date: .omitted, time: .standard))
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }

          launchRow("ความเร็วลูก", String(format: "%.1f mph", shot.ballSpeedMPH))
          launchRow("ความเร็วหัวไม้", String(format: "%.1f mph", shot.clubHeadSpeedMPH))
          launchRow(
            "มุมเหิน / ทิศทาง",
            String(
              format: "%.1f° / %+.1f°",
              shot.verticalLaunchAngleDegrees,
              shot.horizontalLaunchAngleDegrees
            )
          )
          launchRow(
            "สปิน / แกนสปิน",
            String(format: "%d rpm / %+.1f°", shot.totalSpinRPM, shot.spinAxisDegrees)
          )
          if let smashFactor = shot.smashFactor {
            launchRow("Smash Factor", String(format: "%.2f", smashFactor))
          }
        }

        if canRetry {
          Button("ลองเชื่อมต่อใหม่", systemImage: "arrow.clockwise") {
            controller.stop()
            controller.start()
          }
          .buttonStyle(.bordered)
        } else if controller.latestShot == nil {
          Text("Mac จะค้นหาและเชื่อมต่อให้อัตโนมัติ ไม่ต้องเปิด Rapsodo ค้างระหว่างตี")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .darkSettingsCard()
  }

  private var canRetry: Bool {
    switch controller.state {
    case .idle, .failed:
      return true
    case .bluetoothUnavailable, .scanning, .connecting, .discoveringServices,
      .awaitingDeviceTrust, .awaitingAuthorization, .arming, .ready, .stopping:
      return false
    }
  }

  private var stateIcon: String {
    switch controller.state {
    case .ready:
      return "checkmark.circle.fill"
    case .scanning, .awaitingDeviceTrust, .connecting, .discoveringServices,
      .awaitingAuthorization, .arming:
      return "dot.radiowaves.left.and.right"
    case .failed, .bluetoothUnavailable:
      return "exclamationmark.triangle.fill"
    case .idle, .stopping:
      return "pause.circle"
    }
  }

  private var stateColor: Color {
    switch controller.state {
    case .ready:
      return .green
    case .scanning, .awaitingDeviceTrust, .connecting, .discoveringServices,
      .awaitingAuthorization, .arming:
      return .orange
    case .failed, .bluetoothUnavailable:
      return .red
    case .idle, .stopping:
      return .secondary
    }
  }

  private func launchRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(.caption.monospacedDigit())
    }
    .font(.caption)
  }
}

struct HighSpeedInputPanel: View {
  @ObservedObject var receiver: HighSpeedVideoReceiver
  let start: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("การเชื่อมต่อ iPhone 120 FPS", systemImage: "iphone.radiowaves.left.and.right")
        .font(.headline)
        .foregroundStyle(.primary)

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Label("Mac เปิดรอให้อัตโนมัติ ไม่ต้องกดปุ่ม", systemImage: "checkmark.seal.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)

        Text(receiver.state.title)
          .font(.caption)
          .foregroundStyle(stateColor)

        HStack {
          if canStart {
            Button("เปิดรับภาพ 120 FPS อีกครั้ง") {
              start()
            }
            .buttonStyle(.borderedProminent)
          }

          Spacer()

          Text(receiver.metrics.fpsText)
            .font(.caption.monospacedDigit())
        }

        Text(
          "ผลรับภาพ: \(receiver.metrics.resolutionText) · ถอดแล้ว \(receiver.metrics.decodedFrames) เฟรม · ถอดไม่สำเร็จ \(receiver.metrics.decoderDrops) · ข้ามบนจอ \(receiver.metrics.renderDrops)"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(
          "รับ H.264 ผ่านเครือข่าย ซึ่งเป็นวิดีโอที่บีบอัดเพื่อลดข้อมูล แล้วถอดภาพและวิเคราะห์บน Mac เครื่องนี้ สาย USB-C ไม่ใช่เงื่อนไขของภาพสด"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .darkSettingsCard()
  }

  private var stateColor: Color {
    switch receiver.state {
    case .connected:
      return .green
    case .stalled:
      return .orange
    case .advertising:
      return .orange
    case .failed:
      return .red
    case .stopped:
      return .secondary
    }
  }

  private var canStart: Bool {
    switch receiver.state {
    case .stopped, .failed:
      return true
    case .advertising, .connected, .stalled:
      return false
    }
  }
}

struct AIGolfProSettingsPanel: View {
  @ObservedObject var settings: GolfAISettings
  let state: AIGolfProState
  @Binding var apiKeyInput: String
  @Binding var isCheckingOpenRouter: Bool
  @Binding var keySaveStatus: String?
  @Binding var keySaveSucceeded: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          aiConfigurationCard
            .frame(minWidth: 278, maxWidth: .infinity, alignment: .topLeading)
          openRouterCard
            .frame(minWidth: 278, maxWidth: .infinity, alignment: .topLeading)
        }

        VStack(alignment: .leading, spacing: 12) {
          aiConfigurationCard
          openRouterCard
        }
      }

      voiceAndTrainingCard
      advancedSettingsCard
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.colorScheme, .dark)
  }

  private var aiConfigurationCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("AI Golf Pro", systemImage: "waveform.path.ecg")
        .font(.headline)
        .foregroundStyle(.primary)

      Divider()

      Toggle("เปิดใช้ AI Golf Pro", isOn: $settings.aiEnabled)
        .toggleStyle(.switch)
        .darkSettingsInset(padding: 8)

      Toggle("วิเคราะห์อัตโนมัติหลังจบทุกวง", isOn: $settings.automaticCoachEnabled)
        .toggleStyle(.switch)
        .disabled(!settings.aiEnabled)
        .darkSettingsInset(padding: 8)

      VStack(alignment: .leading, spacing: 5) {
        Text("โมเดลโค้ชหลัก")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Picker("โมเดลโค้ชหลัก", selection: $settings.dsv4Model) {
          Text("DeepSeek V4 Flash · ประหยัดและตอบภาษาไทย")
            .tag(OpenRouterGolfModelCatalog.primaryCoach.id)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .darkSettingsInset(padding: 8)

      HStack {
        Text("ปลายทาง")
          .foregroundStyle(.secondary)
        Spacer()
        Text("openrouter.ai")
          .font(.caption.monospaced())
      }
      .font(.caption)

      Divider()

      Stepper(
        "งบในแอป $\(settings.weeklyBudgetUSD.formatted(.number.precision(.fractionLength(0)))) ต่อสัปดาห์",
        value: $settings.weeklyBudgetUSD,
        in: 1...50,
        step: 1
      )

      VStack(alignment: .leading, spacing: 6) {
        ProgressView(value: budgetProgress)
        HStack {
          Text("แอปนี้ใช้ $\(money(settings.localWeeklyCostUSD))")
          Spacer()
          Text("เหลือ $\(money(settings.localWeeklyBudgetRemainingUSD))")
        }
        .font(.caption.monospacedDigit())

        if let account = settings.openRouterAccount {
          Text("OpenRouter รายงานว่า key นี้ใช้สัปดาห์นี้ $\(money(account.weeklyUsageUSD))")
            .font(.caption)
            .foregroundStyle(.secondary)
          Label(
            settings.serverKeyHasWeeklyLimitWithinAppBudget
              ? "key มีเพดานฝั่ง OpenRouter ไม่เกินงบของแอป"
              : "แนะนำให้สร้าง key แยก โดยตั้ง Limit $10 และ Reset รายสัปดาห์",
            systemImage: settings.serverKeyHasWeeklyLimitWithinAppBudget
              ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
          )
          .font(.caption2)
          .foregroundStyle(
            settings.serverKeyHasWeeklyLimitWithinAppBudget ? Color.green : Color.orange
          )
        }
      }
      .darkSettingsInset()
    }
    .controlSize(.small)
    .darkSettingsCard()
  }

  private var openRouterCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("OpenRouter", systemImage: "network.badge.shield.half.filled")
        .font(.headline)
        .foregroundStyle(.primary)

      Divider()

      Text("API key ของ OpenRouter")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      SecureField("API key ของ OpenRouter", text: $apiKeyInput)
        .textFieldStyle(.roundedBorder)

      HStack(spacing: 8) {
        Button("บันทึกใน Keychain") {
          let succeeded = settings.saveAPIKey(apiKeyInput)
          keySaveSucceeded = succeeded
          keySaveStatus = settings.statusText
          if succeeded {
            apiKeyInput = ""
          }
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if settings.hasStoredAPIKey {
          Button("ลบ", role: .destructive) {
            settings.deleteAPIKey()
            keySaveSucceeded = false
            keySaveStatus = settings.statusText
          }
          .buttonStyle(.bordered)
        }
      }

      if let keySaveStatus {
        Label(
          keySaveStatus,
          systemImage: keySaveSucceeded
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(keySaveSucceeded ? Color.green : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("กดบันทึกแล้วผลการเก็บ key จะแสดงตรงนี้ทันที")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      if let suffix = settings.storedAPIKeySuffix {
        Label("คีย์ที่ใช้อยู่ ลงท้าย ••••\(suffix)", systemImage: "key.fill")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("คีย์ OpenRouter ที่ใช้อยู่ ลงท้าย \(suffix)")
      }

      Divider()

      Button {
        isCheckingOpenRouter = true
        Task { @MainActor in
          _ = await settings.checkOpenRouterConnection()
          isCheckingOpenRouter = false
        }
      } label: {
        HStack(spacing: 7) {
          if isCheckingOpenRouter {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "network.badge.shield.half.filled")
          }
          Text("ตรวจ key เครดิต และงบกับ OpenRouter")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!settings.hasStoredAPIKey || isCheckingOpenRouter)

      if hasOpenRouterCheckResult || isCheckingOpenRouter {
        Label(
          "ผลตรวจบัญชี OpenRouter: \(settings.statusText)",
          systemImage: healthIcon
        )
        .font(.caption)
        .foregroundStyle(healthColor)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("ผลตรวจเครดิตและงบจะแสดงแยกตรงนี้หลังจากกดตรวจ")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .controlSize(.small)
    .darkSettingsCard()
  }

  private var voiceAndTrainingCard: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("เสียงระหว่างซ้อม", systemImage: "speaker.wave.2.fill")
        .font(.headline)
        .foregroundStyle(.primary)

      Divider()

      Toggle("สั่งด้วยเสียงแล้วบันทึกครั้งละหนึ่งวง", isOn: $settings.handsFreeCaptureEnabled)
        .toggleStyle(.switch)
        .darkSettingsInset(padding: 8)

      Text("พูด “กอล์ฟเทรซ เริ่มวง” เพื่อให้นับ 3–2–1 แล้วบันทึกเพียงวงถัดไป")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("เมื่อปิด ระบบยังวิเคราะห์ภาพสด แต่จะไม่สร้างคลิปหรือประวัติอัตโนมัติ")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Toggle("ให้ AI Coach พูดคำแนะนำ", isOn: $settings.aiVoiceEnabled)
        .toggleStyle(.switch)
        .darkSettingsInset(padding: 8)

      LabeledContent("ความดังเสียงพูด") {
        Slider(value: $settings.aiVoiceVolume, in: 0...1)
          .frame(minWidth: 160, idealWidth: 260, maxWidth: 360)
      }
      .darkSettingsInset(padding: 8)

      LabeledContent("ความเร็วเสียงพูด") {
        Slider(value: $settings.aiVoiceRate, in: 0.35...0.60)
          .frame(minWidth: 160, idealWidth: 260, maxWidth: 360)
      }
      .darkSettingsInset(padding: 8)

      Toggle("เสียงชุดจังหวะ Tempo", isOn: $settings.tempoCueEnabled)
        .toggleStyle(.switch)
        .darkSettingsInset(padding: 8)

      Toggle("เสียงแจ้งผลตามเส้นช่วยดู", isOn: $settings.guidelineCueEnabled)
        .toggleStyle(.switch)
        .darkSettingsInset(padding: 8)

      LabeledContent("ความดังเสียงสั้น") {
        Slider(value: $settings.soundEffectsVolume, in: 0...1)
          .frame(minWidth: 160, idealWidth: 260, maxWidth: 360)
      }
      .darkSettingsInset(padding: 8)
    }
    .font(.caption)
    .controlSize(.small)
    .darkSettingsCard()
  }

  private var advancedSettingsCard: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 10) {
        settingField("ปลายทางถอดเสียง", text: $settings.whisperEndpoint)
        settingField("โมเดลถอดเสียง", text: $settings.whisperModel)

        Toggle("วิเคราะห์ภาพอ้างอิงด้วย VLM (ทดลอง)", isOn: $settings.vlmEnabled)
          .toggleStyle(.switch)

        if settings.vlmEnabled {
          settingField("ที่อยู่ VLM", text: $settings.vlmEndpoint)
          settingField("โมเดล VLM", text: $settings.vlmModel)
          Label(
            settings.vlmURL == nil
              ? "ยังไม่พร้อม: ใส่ HTTPS หรือที่อยู่ private/local ให้ถูกต้อง"
              : "ใช้กับภาพอ้างอิง YouTube เท่านั้น ยังไม่ส่งภาพผู้เล่นจริง",
            systemImage: settings.vlmURL == nil
              ? "exclamationmark.triangle.fill" : "checkmark.circle"
          )
          .font(.caption2)
          .foregroundStyle(settings.vlmURL == nil ? Color.orange : Color.secondary)
        }

        Divider()

        Text(
          "Mac สกัดจุดร่างกาย เส้นทางมือ ค่าตัวเลข และเวลาเป็น Swing Evidence Packet ก่อนส่ง "
            + "DeepSeek V4 Flash จึงอ่านข้อมูลที่วัดแล้วแทนการสกัดจากภาพใหม่ ส่วนภาพตรวจทาน "
            + "จะมีเพียง 1–2 keyframe เมื่อจำเป็น"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "API key เก็บใน Keychain ของ Mac และผูกกับที่อยู่ HTTPS ที่บันทึกไว้ ไม่เขียนลงไฟล์โปรเจกต์ "
            + "โมเดลฟรีใช้ได้เฉพาะการทดสอบที่ผ่านเกณฑ์ และจะไม่รับภาพผู้เล่นจริงโดยอัตโนมัติ"
        )
        .font(.caption2)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 8)
    } label: {
      Label("การตั้งค่าขั้นสูง · Whisper และภาพอ้างอิง", systemImage: "slider.horizontal.3")
        .font(.subheadline.weight(.semibold))
    }
    .controlSize(.small)
    .darkSettingsCard(cornerRadius: 12, padding: 12)
  }

  private var budgetProgress: Double {
    guard settings.weeklyBudgetUSD > 0 else { return 1 }
    return min(1, settings.localWeeklyCostUSD / settings.weeklyBudgetUSD)
  }

  private var hasOpenRouterCheckResult: Bool {
    switch settings.openRouterHealth {
    case .ready, .warning(_), .failed(_): return true
    case .checking, .notConfigured, .notChecked: return false
    }
  }

  private func money(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2)))
  }

  private var healthIcon: String {
    switch settings.openRouterHealth {
    case .ready: return "checkmark.shield.fill"
    case .checking: return "arrow.triangle.2.circlepath"
    case .warning(_): return "exclamationmark.shield.fill"
    case .failed(_): return "xmark.shield.fill"
    case .notConfigured, .notChecked: return "key.horizontal.fill"
    }
  }

  private var healthColor: Color {
    switch settings.openRouterHealth {
    case .ready: return .green
    case .checking: return .blue
    case .warning(_), .notChecked: return .orange
    case .failed(_): return .red
    case .notConfigured: return .secondary
    }
  }

  private func settingField(_ label: String, text: Binding<String>) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 120, alignment: .leading)
      TextField(label, text: text)
        .textFieldStyle(.roundedBorder)
    }
  }

}
