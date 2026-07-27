import AppKit
import SwiftUI

struct GolfKnowledgePanel: View {
  @ObservedObject var controller: GolfKnowledgeController
  @ObservedObject var aiSettings: GolfAISettings
  @Binding var urlInput: String
  @Binding var newProfileName: String
  @Binding var newProfileStyle: String
  @Binding var profilePendingDeletion: AIGolfProKnowledgeProfile?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "books.vertical.fill")
          .foregroundStyle(GolfTraceTheme.blue)
          .frame(width: 20)
        Text("คลัง AI โปร · โปรไฟล์และแหล่งอ้างอิง")
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
      }

      Rectangle()
        .fill(Color.white.opacity(0.08))
        .frame(height: 1)

      VStack(alignment: .leading, spacing: 12) {
        Label(
          "สร้างและบันทึกโปรไฟล์ก่อน แล้วค่อยใส่ YouTube หลายลิงก์ในโปรไฟล์นั้น AI จะอ้างอิงเฉพาะชุดแหล่งของโปรไฟล์ที่เลือก",
          systemImage: "person.crop.circle.badge.plus"
        )
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)

        profileCreator

        if controller.profiles.isEmpty {
          Label(
            "ยังเพิ่ม YouTube ไม่ได้ — ตั้งชื่อ AI โปรแล้วกด “บันทึกโปรไฟล์” ก่อน",
            systemImage: "lock.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        } else {
          profileSelector

          if let profile = controller.selectedProfile {
            selectedProfileSummary(profile)
            sourceEditor(profile)

            Text(controller.statusText)
              .font(.caption2)
              .foregroundStyle(statusColor)
              .fixedSize(horizontal: false, vertical: true)

            if controller.selectedSources.isEmpty {
              Label(
                "โปรไฟล์นี้ยังไม่มีแหล่งอ้างอิง วางลิงก์ YouTube ด้านบนได้หลายบรรทัด",
                systemImage: "link.badge.plus"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 4)
            } else {
              Divider()
              VStack(spacing: 8) {
                ForEach(controller.selectedSources) { source in
                  knowledgeRow(source, profileID: profile.id)
                }
              }
            }
          }
        }

        DisclosureGroup("ตั้งค่า MCP ขั้นสูง") {
          VStack(alignment: .leading, spacing: 9) {
            TextField("MCP endpoint", text: $controller.mcpEndpoint)
              .textFieldStyle(.roundedBorder)
            HStack {
              TextField("ภาษา เช่น en, th", text: $controller.transcriptLanguage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
              Button("ทดสอบคำพูด + ภาพ") {
                controller.verifyMCP()
              }
              .buttonStyle(.bordered)
            }

            Text(
              "ค่าเริ่มต้นคือ youtube-context-mcp ที่รันเฉพาะใน Mac ผ่าน 127.0.0.1 แอปไม่ส่ง BDA API key ไปยัง MCP และไม่ควรเปิด MCP นี้เป็น 0.0.0.0"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, 5)
        }
        .font(.caption.weight(.semibold))

        Label(
          "แอปไม่ดาวน์โหลดวิดีโอทั้งไฟล์ ขอเฉพาะคำถอดเสียงและเฟรมอ้างอิงตามเวลาผ่าน MCP ที่ตั้งไว้ พร้อมเก็บ URL, เวลา และ hash เพื่อบอกที่มาของคำแนะนำ พิกเซลภาพไป VLM เฉพาะเมื่อผู้ใช้เปิดเท่านั้น",
          systemImage: "checkmark.shield"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(red: 0.035, green: 0.048, blue: 0.063),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(0.13), lineWidth: 1)
    )
    .confirmationDialog(
      "ลบโปรไฟล์ AI โปร?",
      isPresented: Binding(
        get: { profilePendingDeletion != nil },
        set: { if !$0 { profilePendingDeletion = nil } }
      ),
      presenting: profilePendingDeletion
    ) { profile in
      Button("ลบ \(profile.name)", role: .destructive) {
        controller.removeProfile(profile.id)
        profilePendingDeletion = nil
      }
      Button("ยกเลิก", role: .cancel) {
        profilePendingDeletion = nil
      }
    } message: { profile in
      Text("ลิงก์ที่ไม่ได้ใช้ในโปรไฟล์อื่นจะถูกนำออกจากคลังด้วย")
    }
  }

  private var profileCreator: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("1. สร้างโปรไฟล์ AI โปร", systemImage: "person.crop.circle.fill.badge.plus")
        .font(.caption.weight(.semibold))
      HStack(alignment: .top, spacing: 8) {
        VStack(spacing: 7) {
          TextField("ชื่อโปรไฟล์ เช่น โปรจังหวะนุ่ม", text: $newProfileName)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("ชื่อโปรไฟล์ AI โปร")
          TextField(
            "แนวทางที่ชอบ เช่น tempo นุ่ม เน้นเหล็ก และไม่บังคับวงเดียว",
            text: $newProfileStyle
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("แนวทางการสอนของโปรไฟล์")
        }
        Button("บันทึกโปรไฟล์", systemImage: "square.and.arrow.down.fill") {
          if controller.createProfile(name: newProfileName, teachingStyle: newProfileStyle) != nil {
            newProfileName = ""
            newProfileStyle = ""
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(10)
    .background(GolfTraceTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(GolfTraceTheme.blue.opacity(0.17), lineWidth: 1)
    )
  }

  private var profileSelector: some View {
    HStack(spacing: 8) {
      Label("โปรไฟล์ที่กำลังใช้", systemImage: "person.2.crop.square.stack.fill")
        .font(.caption.weight(.semibold))
      Menu {
        ForEach(controller.profiles) { profile in
          Button {
            controller.selectProfile(profile.id)
          } label: {
            Label(
              profile.name,
              systemImage: profile.id == controller.selectedProfileID
                ? "checkmark.circle.fill" : "circle"
            )
          }
        }
      } label: {
        Label(
          controller.selectedProfile?.name ?? "เลือกโปรไฟล์",
          systemImage: "chevron.up.chevron.down"
        )
      }
      .menuStyle(.borderlessButton)

      Spacer()

      if let selectedProfile = controller.selectedProfile {
        Button("ลบโปรไฟล์", systemImage: "trash", role: .destructive) {
          profilePendingDeletion = selectedProfile
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      }
    }
  }

  private func selectedProfileSummary(_ profile: AIGolfProKnowledgeProfile) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "figure.golf")
        .font(.title2)
        .foregroundStyle(Color.accentColor)
        .frame(width: 36, height: 36)
        .background(Color.accentColor.opacity(0.12), in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(profile.name)
          .font(.subheadline.weight(.semibold))
        Text(profile.teachingStyle.isEmpty ? "ยังไม่ได้ระบุแนวทางการสอน" : profile.teachingStyle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("อ้างอิง \(controller.selectedSources.count) แหล่ง · พร้อม \(controller.readyCount) แหล่ง")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(controller.readyCount > 0 ? Color.green : Color.secondary)
      }
      Spacer()
    }
    .padding(10)
    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    )
  }

  private func sourceEditor(_ profile: AIGolfProKnowledgeProfile) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("2. เพิ่ม YouTube ให้ \(profile.name)", systemImage: "link.badge.plus")
        .font(.caption.weight(.semibold))

      TextEditor(text: $urlInput)
        .font(.caption.monospaced())
        .frame(minHeight: 74, maxHeight: 110)
        .padding(5)
        .scrollContentBackground(.hidden)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .stroke(Color.white.opacity(0.14))
        )
        .accessibilityLabel("ลิงก์ YouTube หลายลิงก์ของ \(profile.name)")

      HStack {
        Button("เพิ่มลิงก์ทั้งหมด", systemImage: "plus.circle.fill") {
          controller.addURLs(from: urlInput, to: profile.id)
          urlInput = ""
        }
        .buttonStyle(.borderedProminent)
        .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button("ให้ DeepSeek อ่านใหม่", systemImage: "brain.head.profile") {
          controller.reindexReadyTranscripts()
        }
        .buttonStyle(.bordered)
        .disabled(controller.selectedSources.allSatisfy(\.chunks.isEmpty))

        Spacer()
        Text("พร้อม \(controller.readyCount)/\(controller.selectedSources.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(controller.readyCount > 0 ? Color.green : Color.secondary)
      }
    }
  }

  private func knowledgeRow(_ source: YouTubeKnowledgeSource, profileID: UUID) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: phaseIcon(for: source.status))
        .foregroundStyle(color(for: source.status))
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 3) {
        Button(source.title) {
          guard let url = URL(string: source.canonicalURL) else { return }
          NSWorkspace.shared.open(url)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)

        HStack(spacing: 5) {
          Text(phaseTitle(for: source.status))
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color(for: source.status).opacity(0.12), in: Capsule())
            .foregroundStyle(color(for: source.status))
          Text(source.status.title)
            .font(.caption2)
            .foregroundStyle(color(for: source.status))
            .fixedSize(horizontal: false, vertical: true)
        }

        Text("แหล่งอ้างอิง: \(source.canonicalURL)")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)

        if source.status == .ready || source.frames?.isEmpty == false {
          Text((source.visualStatus ?? .notRequested).title)
            .font(.caption2)
            .foregroundStyle(visualColor(source.visualStatus ?? .notRequested))
            .fixedSize(horizontal: false, vertical: true)

          Text(vlmStatusText(source))
            .font(.caption2)
            .foregroundStyle(vlmStatusColor(source))
            .fixedSize(horizontal: false, vertical: true)
        }

        if source.characterCount > 0 {
          Text(
            "\(source.characterCount.formatted()) ตัวอักษร · \(source.chunks.count) ช่วง · \(source.claims.count) แนวคิด · \(source.frames?.count ?? 0) ภาพ · Vision ใช้ได้ \(source.readyFrameCount) · OCR \(source.frames?.filter { !($0.recognizedText ?? []).isEmpty }.count ?? 0) ภาพ · VLM ผูกภาพได้ \(source.readyVisualGroundingCount) หัวข้อ"
          )
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
        }

        if let frames = source.frames, !frames.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 6) {
              ForEach(Array(frames.prefix(6))) { frame in
                frameThumbnail(frame)
              }
            }
          }
          .scrollIndicators(.hidden)
        }
      }

      Spacer(minLength: 8)

      if !source.status.isBusy {
        Button("ลองใหม่") {
          controller.retry(source.id)
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      } else {
        ProgressView()
          .controlSize(.small)
      }

      if !source.claims.isEmpty, !source.status.isBusy, source.visualStatus?.isBusy != true {
        Button("อ่านภาพใหม่") {
          controller.refreshVisualEvidence(source.id)
        }
        .buttonStyle(.borderless)
        .font(.caption2)
      }

      Button("ลบ", role: .destructive) {
        controller.remove(source.id, from: profileID)
      }
      .buttonStyle(.borderless)
      .font(.caption2)
    }
    .padding(9)
    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.white.opacity(0.07), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func frameThumbnail(_ frame: ReferenceFrameObservation) -> some View {
    if let url = controller.imageURL(for: frame), let image = NSImage(contentsOf: url) {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: 96, height: 54)
        .clipped()
        .overlay(alignment: .bottomLeading) {
          Text(timecode(frame.timestampSeconds))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
            .padding(3)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(frame.hasUsableBodyPose ? Color.green : Color.orange, lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(
          "ภาพอ้างอิงเวลา \(timecode(frame.timestampSeconds)) \(frame.hasUsableBodyPose ? "อ่านท่าทางได้" : "ข้อมูลท่าทางยังไม่พอ")"
        )
    }
  }

  private func timecode(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  private func visualColor(_ status: YouTubeVisualStatus) -> Color {
    switch status {
    case .ready: return .green
    case .fetching: return .blue
    case .notRequested: return .secondary
    case .unavailable, .failed: return .orange
    }
  }

  private func vlmStatusText(_ source: YouTubeKnowledgeSource) -> String {
    if !aiSettings.vlmEnabled {
      if source.readyVisualGroundingCount > 0 {
        return "Qwen3-VL ปิดอยู่ · เก็บผลเดิมไว้ \(source.readyVisualGroundingCount) หัวข้อ"
      }
      return "Qwen3-VL ปิดอยู่ · ใช้ Apple Vision/OCR เท่านั้น"
    }
    return "Qwen3-VL · \((source.visualGroundingStatus ?? .notRequested).title)"
  }

  private func vlmStatusColor(_ source: YouTubeKnowledgeSource) -> Color {
    guard aiSettings.vlmEnabled else { return .secondary }
    switch source.visualGroundingStatus ?? .notRequested {
    case .ready: return .green
    case .analyzing: return .blue
    case .notRequested: return .secondary
    case .failed: return .orange
    }
  }

  private var statusColor: Color {
    if controller.statusText.contains("พร้อม") { return .green }
    if controller.statusText.contains("ไม่") || controller.statusText.contains("ผิด") {
      return .orange
    }
    return .secondary
  }

  private func phaseTitle(for status: YouTubeKnowledgeStatus) -> String {
    switch status {
    case .queued: return "รอ"
    case .fetchingTranscript, .transcriptReady, .indexing: return "กำลังอ่าน"
    case .ready: return "พร้อม"
    case .noTranscript, .failed: return "ผิดพลาด"
    }
  }

  private func phaseIcon(for status: YouTubeKnowledgeStatus) -> String {
    switch status {
    case .ready: return "checkmark.circle.fill"
    case .queued: return "clock.fill"
    case .fetchingTranscript, .transcriptReady, .indexing: return "text.magnifyingglass"
    case .noTranscript: return "captions.bubble.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }

  private func color(for status: YouTubeKnowledgeStatus) -> Color {
    switch status {
    case .ready: return .green
    case .queued, .fetchingTranscript, .transcriptReady, .indexing: return .blue
    case .noTranscript, .failed: return .orange
    }
  }
}
