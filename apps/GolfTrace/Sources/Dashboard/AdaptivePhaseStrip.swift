import AppKit
import SwiftUI

/// A stable presentation model keeps the storyboard UI independent from the
/// persisted analyzer schema. Only evidence-backed markers enter this layer.
struct AdaptivePhaseStripEvidence: Equatable, Identifiable {
  let phaseID: String
  let sourceTimestampMs: Int
  let replayTimestampMs: Int?
  let confidence: Double
  let provenanceText: String
  let limitation: String?
  let thumbnailURL: URL?

  var id: String { phaseID }
}

struct AdaptivePhaseStripSource: Equatable {
  let angleLabel: String
  let detail: String
}

struct AdaptivePhaseStripSlot: Equatable, Identifiable {
  struct Descriptor: Equatable {
    let id: String
    let title: String
  }

  let descriptor: Descriptor
  let evidence: AdaptivePhaseStripEvidence?

  var id: String { descriptor.id }
  var isAvailable: Bool { evidence != nil }
  var canSelect: Bool { isAvailable }
  var canSeek: Bool { evidence?.replayTimestampMs != nil }
  var replayTimeSeconds: TimeInterval? {
    evidence?.replayTimestampMs.map { TimeInterval($0) / 1_000 }
  }
  var statusText: String { evidence?.provenanceText ?? "ยังไม่มั่นใจ" }
}

enum AdaptivePhaseStripResolver {
  static let descriptors = [
    AdaptivePhaseStripSlot.Descriptor(id: "address", title: "Address"),
    AdaptivePhaseStripSlot.Descriptor(id: "takeaway", title: "Takeaway"),
    AdaptivePhaseStripSlot.Descriptor(id: "backswing", title: "Half Backswing"),
    AdaptivePhaseStripSlot.Descriptor(id: "top", title: "Top"),
    AdaptivePhaseStripSlot.Descriptor(id: "downswing", title: "Delivery"),
    AdaptivePhaseStripSlot.Descriptor(id: "impact", title: "Impact Window"),
    AdaptivePhaseStripSlot.Descriptor(id: "followThrough", title: "Extension"),
    AdaptivePhaseStripSlot.Descriptor(id: "finish", title: "Finish"),
  ]

  static func slots(
    from evidence: [AdaptivePhaseStripEvidence]
  ) -> [AdaptivePhaseStripSlot] {
    let bestEvidence = evidence.reduce(into: [String: AdaptivePhaseStripEvidence]()) {
      result,
      candidate in
      guard let phaseID = canonicalPhaseID(candidate.phaseID) else { return }
      guard let current = result[phaseID] else {
        result[phaseID] = candidate
        return
      }

      // Prefer evidence that can drive the shared replay. Confidence breaks
      // ties without allowing duplicate analyzer markers to reorder the strip.
      let candidateRank = (candidate.replayTimestampMs == nil ? 0 : 1, candidate.confidence)
      let currentRank = (current.replayTimestampMs == nil ? 0 : 1, current.confidence)
      if candidateRank > currentRank {
        result[phaseID] = candidate
      }
    }

    return descriptors.map { descriptor in
      AdaptivePhaseStripSlot(
        descriptor: descriptor,
        evidence: bestEvidence[descriptor.id]
      )
    }
  }

  private static func canonicalPhaseID(_ rawValue: String) -> String? {
    let normalized =
      rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter(\.isLetter)

    switch normalized {
    case "address", "setup": return "address"
    case "takeaway": return "takeaway"
    case "backswing", "halfbackswing": return "backswing"
    case "top": return "top"
    case "downswing", "delivery": return "downswing"
    case "impact", "impactwindow": return "impact"
    case "followthrough", "extension": return "followThrough"
    case "finish": return "finish"
    default: return nil
    }
  }
}

struct AdaptivePhaseStrip: View {
  let source: AdaptivePhaseStripSource
  let evidence: [AdaptivePhaseStripEvidence]
  let onSeek: (TimeInterval) -> Void

  @State private var selectedPhaseID: String?

  private var slots: [AdaptivePhaseStripSlot] {
    AdaptivePhaseStripResolver.slots(from: evidence)
  }

  private var selectedSlot: AdaptivePhaseStripSlot? {
    guard let selectedPhaseID else { return nil }
    return slots.first(where: { $0.id == selectedPhaseID })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header

      HStack(spacing: 8) {
        ForEach(slots) { slot in
          phaseCard(slot)
        }
      }

      detailRow
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      LinearGradient(
        colors: [GolfTraceTheme.panel.opacity(0.98), Color.black.opacity(0.84)],
        startPoint: .top,
        endPoint: .bottom
      ),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(GolfTraceTheme.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.42), radius: 14, y: 4)
    .onAppear {
      selectInitialEvidenceIfNeeded()
    }
    .onChange(of: evidence) { _, _ in
      selectInitialEvidenceIfNeeded()
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Text("Swing Storyboard")
        .font(.subheadline.weight(.bold))

      Text("\(slots.filter(\.isAvailable).count) จาก 8 phase มีหลักฐาน")
        .font(.caption)
        .foregroundStyle(GolfTraceTheme.mutedText)

      Spacer()

      Label(source.angleLabel, systemImage: "camera.viewfinder")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.white.opacity(0.88))

      Text(source.detail)
        .font(.caption2)
        .foregroundStyle(GolfTraceTheme.mutedText)
        .lineLimit(1)
    }
  }

  private func phaseCard(_ slot: AdaptivePhaseStripSlot) -> some View {
    Button {
      guard slot.canSelect else { return }
      selectedPhaseID = slot.id
      if let replayTimeSeconds = slot.replayTimeSeconds {
        onSeek(replayTimeSeconds)
      }
    } label: {
      VStack(spacing: 6) {
        HStack(spacing: 4) {
          Text(slot.descriptor.title)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.72)

          Spacer(minLength: 0)

          if let timestampMs = slot.evidence?.replayTimestampMs {
            Text(formatTimestamp(timestampMs))
              .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
              .foregroundStyle(GolfTraceTheme.blue)
          } else if let sourceTimestampMs = slot.evidence?.sourceTimestampMs {
            Text("วง \(formatTimestamp(sourceTimestampMs))")
              .font(.system(size: 8, weight: .medium, design: .monospaced))
              .foregroundStyle(GolfTraceTheme.mutedText)
          }
        }

        phaseVisual(slot)
          .frame(maxWidth: .infinity)
          .frame(height: 92)

        Text(slot.statusText)
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(statusColor(for: slot))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
          .background(statusColor(for: slot).opacity(slot.isAvailable ? 0.14 : 0.07))
          .clipShape(RoundedRectangle(cornerRadius: 5))
      }
      .padding(7)
      .frame(maxWidth: .infinity)
      .background(
        Color.white.opacity(slot.isAvailable ? 0.055 : 0.025),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(cardBorderColor(for: slot), lineWidth: selectedPhaseID == slot.id ? 1.5 : 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!slot.canSelect)
    .opacity(slot.isAvailable ? 1 : 0.66)
    .accessibilityLabel(accessibilityLabel(for: slot))
    .accessibilityHint(accessibilityHint(for: slot))
  }

  @ViewBuilder
  private func phaseVisual(_ slot: AdaptivePhaseStripSlot) -> some View {
    if let thumbnailURL = slot.evidence?.thumbnailURL {
      AdaptivePhaseThumbnail(url: thumbnailURL)
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 7)
          .fill(Color.black.opacity(0.42))

        Image(systemName: slot.isAvailable ? "circle.dotted" : "questionmark")
          .font(.system(size: slot.isAvailable ? 27 : 23, weight: .light))
          .foregroundStyle(
            slot.isAvailable ? GolfTraceTheme.blue.opacity(0.88) : Color.white.opacity(0.22)
          )
      }
    }
  }

  @ViewBuilder
  private var detailRow: some View {
    if let selectedSlot, let marker = selectedSlot.evidence {
      HStack(spacing: 7) {
        Circle()
          .fill(statusColor(for: selectedSlot))
          .frame(width: 6, height: 6)
        Text(selectedSlot.descriptor.title)
          .font(.caption2.weight(.bold))
        Text("• \(marker.provenanceText)")
          .font(.caption2)
          .foregroundStyle(GolfTraceTheme.mutedText)
        Text("ความมั่นใจ \(Int((marker.confidence * 100).rounded()))%")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(GolfTraceTheme.mutedText)
        if let limitation = marker.limitation, !limitation.isEmpty {
          Text("• \(limitation)")
            .font(.caption2)
            .foregroundStyle(Color.orange.opacity(0.9))
            .lineLimit(1)
        }
        Spacer()
      }
    } else {
      Text("แสดงเฉพาะ phase จากมุมกล้องเดียวกันที่มีหลักฐาน — ไม่ผสมเฟรมจากแหล่งอื่น")
        .font(.caption2)
        .foregroundStyle(GolfTraceTheme.mutedText)
    }
  }

  private func selectInitialEvidenceIfNeeded() {
    if let selectedPhaseID,
      slots.contains(where: { $0.id == selectedPhaseID && $0.isAvailable })
    {
      return
    }
    selectedPhaseID = slots.first(where: { $0.canSelect })?.id
  }

  private func statusColor(for slot: AdaptivePhaseStripSlot) -> Color {
    guard let confidence = slot.evidence?.confidence else { return GolfTraceTheme.mutedText }
    if confidence >= 0.85 { return .green }
    if confidence >= 0.60 { return .orange }
    return GolfTraceTheme.blue
  }

  private func cardBorderColor(for slot: AdaptivePhaseStripSlot) -> Color {
    if selectedPhaseID == slot.id { return GolfTraceTheme.blue }
    if slot.isAvailable { return statusColor(for: slot).opacity(0.78) }
    return Color.white.opacity(0.12)
  }

  private func formatTimestamp(_ milliseconds: Int) -> String {
    let seconds = Double(max(0, milliseconds)) / 1_000
    return String(
      format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
  }

  private func accessibilityLabel(for slot: AdaptivePhaseStripSlot) -> String {
    guard let evidence = slot.evidence else {
      return "\(slot.descriptor.title), ยังไม่มั่นใจ"
    }
    return
      "\(slot.descriptor.title), \(evidence.provenanceText), ความมั่นใจ \(Int((evidence.confidence * 100).rounded())) เปอร์เซ็นต์"
  }

  private func accessibilityHint(for slot: AdaptivePhaseStripSlot) -> String {
    guard slot.canSelect else { return "เฟสนี้ยังไม่มีหลักฐาน" }
    return slot.canSeek
      ? "กดเพื่อดูรายละเอียดและเลื่อนไปยังเฟสนี้"
      : "กดเพื่อดูรายละเอียด เฟสนี้ยังไม่มีเวลาในรีเพลย์"
  }
}

private struct AdaptivePhaseThumbnail: View {
  let url: URL

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 7)
        .fill(Color.black.opacity(0.54))

      if let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .padding(2)
      } else {
        Image(systemName: "photo.badge.exclamationmark")
          .font(.system(size: 24, weight: .light))
          .foregroundStyle(Color.white.opacity(0.28))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 7))
  }
}
