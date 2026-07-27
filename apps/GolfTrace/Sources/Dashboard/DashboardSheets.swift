import AVFoundation
import Foundation
import ImageIO
import SwiftUI

enum SwingHistoryReviewLayout {
  static let phaseSpacing: CGFloat = 7
  static let storyboardHeight: CGFloat = 216

  static func canvasHeight(availableHeight: CGFloat) -> CGFloat {
    min(720, max(440, availableHeight - 32))
  }

  static func pipWidth(availableWidth: CGFloat) -> CGFloat {
    min(330, max(210, availableWidth * 0.29))
  }

  static func phaseWidth(availableWidth: CGFloat) -> CGFloat {
    let horizontalPadding: CGFloat = 26
    let gaps = phaseSpacing * CGFloat(SwingStoryboardPhaseSlot.allCases.count - 1)
    let usable = max(0, availableWidth - horizontalPadding - gaps)
    return min(138, max(56, usable / CGFloat(SwingStoryboardPhaseSlot.allCases.count)))
  }

  static func cameraFPSBadgeText(_ nominalFPS: Double?) -> String {
    guard let nominalFPS, nominalFPS.isFinite, nominalFPS > 0 else {
      return "Camera"
    }
    let roundedFPS = nominalFPS.rounded()
    let value =
      abs(nominalFPS - roundedFPS) < 0.25
      ? String(Int(roundedFPS))
      : String(format: "%.1f", nominalFPS)
    return "Camera \(value) fps"
  }

  static func mediaSelection(
    legacyReplayURL: URL?,
    stagePaneLayout: GolfTraceStagePaneLayout?,
    replayBundle: SwingReplayBundleURLs?,
    isRapsodoPrimary: Bool
  ) -> SwingHistoryReviewMediaSelection? {
    if let replayBundle {
      let camera = SwingHistoryReviewMedia(
        url: replayBundle.cameraURL,
        normalizedCrop: nil,
        role: .swingCamera
      )
      guard replayBundle.status == .synchronizedPair,
        let rapsodoURL = replayBundle.rapsodoURL,
        let synchronization = replayBundle.synchronization,
        let previewTimes = synchronizedPreviewTimes(synchronization)
      else {
        return SwingHistoryReviewMediaSelection(
          main: camera,
          pip: nil,
          bundleStatus: .cameraSaved,
          cameraNominalFPS: replayBundle.bundle.camera.nominalFPS
        )
      }

      let rapsodo = SwingHistoryReviewMedia(
        url: rapsodoURL,
        normalizedCrop: nil,
        role: .rapsodoScreen,
        requestedTimeSeconds: previewTimes.rapsodo
      )
      let synchronizedCamera = SwingHistoryReviewMedia(
        url: replayBundle.cameraURL,
        normalizedCrop: nil,
        role: .swingCamera,
        requestedTimeSeconds: previewTimes.camera
      )
      return SwingHistoryReviewMediaSelection(
        main: isRapsodoPrimary ? rapsodo : synchronizedCamera,
        pip: isRapsodoPrimary ? synchronizedCamera : rapsodo,
        bundleStatus: .synchronizedPair,
        cameraNominalFPS: replayBundle.bundle.camera.nominalFPS
      )
    }

    guard let legacyReplayURL else { return nil }
    guard let stagePaneLayout else {
      return SwingHistoryReviewMediaSelection(
        main: SwingHistoryReviewMedia(
          url: legacyReplayURL,
          normalizedCrop: nil,
          role: .legacyStage
        ),
        pip: nil,
        bundleStatus: nil,
        cameraNominalFPS: nil
      )
    }

    let camera = SwingHistoryReviewMedia(
      url: legacyReplayURL,
      normalizedCrop: stagePaneLayout.swingCamera,
      role: .swingCamera
    )
    let rapsodo = SwingHistoryReviewMedia(
      url: legacyReplayURL,
      normalizedCrop: stagePaneLayout.rapsodo,
      role: .rapsodoScreen
    )
    return SwingHistoryReviewMediaSelection(
      main: isRapsodoPrimary ? rapsodo : camera,
      pip: isRapsodoPrimary ? camera : rapsodo,
      bundleStatus: nil,
      cameraNominalFPS: nil
    )
  }

  private static func synchronizedPreviewTimes(
    _ synchronization: SwingReplaySynchronization
  ) -> (camera: TimeInterval, rapsodo: TimeInterval)? {
    guard synchronization.validationIssues.isEmpty else { return nil }
    let range = synchronization.timelineMonotonicRangeSeconds
    let commonMonotonicTime = range.lowerBound + (range.upperBound - range.lowerBound) / 2
    guard commonMonotonicTime.isFinite,
      let cameraTime = mediaTimeSeconds(
        forMonotonicTime: commonMonotonicTime,
        calibration: synchronization.cameraClock
      ),
      let rapsodoTime = mediaTimeSeconds(
        forMonotonicTime: commonMonotonicTime,
        calibration: synchronization.rapsodoClock
      )
    else { return nil }
    return (camera: cameraTime, rapsodo: rapsodoTime)
  }

  private static func mediaTimeSeconds(
    forMonotonicTime monotonicTime: TimeInterval,
    calibration: SwingReplayAssetClockCalibration
  ) -> TimeInterval? {
    guard calibration.validationIssues.isEmpty,
      monotonicTime.isFinite,
      calibration.scaleToMonotonicClock > 0
    else { return nil }
    let mediaTime =
      (monotonicTime - calibration.monotonicClockOffsetSeconds)
      / calibration.scaleToMonotonicClock
    guard mediaTime.isFinite,
      calibration.mediaRangeSeconds.contains(mediaTime)
    else { return nil }
    return mediaTime
  }
}

enum SwingHistoryReviewMediaRole: Equatable {
  case swingCamera
  case rapsodoScreen
  case legacyStage
}

struct SwingHistoryReviewMedia: Equatable {
  let url: URL
  let normalizedCrop: GolfTraceNormalizedRect?
  let role: SwingHistoryReviewMediaRole
  var requestedTimeSeconds: TimeInterval? = nil
}

struct SwingHistoryReviewMediaSelection: Equatable {
  let main: SwingHistoryReviewMedia
  let pip: SwingHistoryReviewMedia?
  let bundleStatus: SwingReplayBundleStatus?
  let cameraNominalFPS: Double?
}

/// History เป็น workspace ภายในหน้าต่างหลัก ไม่ใช่ Settings-style sheet
/// ผู้เรียกยังเป็นเจ้าของการสลับ workspace และ shared replay/timeline เหมือนเดิม
struct SwingHistoryWorkspace: View {
  @ObservedObject var history: SwingHistoryController
  @ObservedObject var replay: SwingReplayController
  let onClose: () -> Void
  let onOpenReplay: () -> Void

  @State private var searchText = ""
  @State private var selectedRecordID: UUID?
  @State private var rapsodoPrimaryRecordIDs: Set<UUID> = []

  init(
    history: SwingHistoryController,
    replay: SwingReplayController,
    onClose: @escaping () -> Void,
    onOpenReplay: @escaping () -> Void
  ) {
    _history = ObservedObject(wrappedValue: history)
    _replay = ObservedObject(wrappedValue: replay)
    self.onClose = onClose
    self.onOpenReplay = onOpenReplay
    _selectedRecordID = State(initialValue: history.records.first?.id)
  }

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 10) {
        historyBrowser
          .frame(width: browserWidth(for: proxy.size.width))

        selectedSwingDetail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding(14)
    }
    .background(
      LinearGradient(
        colors: [GolfTraceTheme.canvas, Color(red: 0.020, green: 0.034, blue: 0.052)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .preferredColorScheme(.dark)
    .onAppear(perform: repairSelection)
    .onChange(of: history.records.map(\.id)) { _, _ in
      repairSelection()
    }
    .onChange(of: filteredRecords.map(\.id)) { _, _ in
      repairSelection()
    }
    .onDisappear {
      // อย่าให้ thumbnail ของคลิปเก่าทำงานต่อผ่าน countdown/การบันทึกวงใหม่
      // งานที่กำลัง decode อยู่สูงสุดสองงานจะจบเอง ส่วนงานที่รอคิวถูกยกเลิกทันที
      Task {
        await SwingHistoryImageRepository.shared.cancelAll()
      }
    }
  }

  private var historyBrowser: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text("ประวัติวงสวิง")
          .font(.system(size: 24, weight: .bold, design: .rounded))
        HStack(spacing: 8) {
          Text("\(history.records.prefix(20).count) วง")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(GolfTraceTheme.mutedText)
          if history.isWorking {
            ProgressView()
              .controlSize(.small)
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 17)
      .padding(.bottom, 14)

      HStack(spacing: 8) {
        HStack(spacing: 9) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(GolfTraceTheme.mutedText)
          TextField("ค้นหาวงสวิง", text: $searchText)
            .textFieldStyle(.plain)
            .font(.subheadline)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(GolfTraceTheme.mutedText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("ล้างคำค้นหา")
          }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(GolfTraceTheme.border, lineWidth: 1)
        )
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)

      Rectangle()
        .fill(GolfTraceTheme.subtleBorder)
        .frame(height: 1)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
          ForEach(groupedRecords, id: \.day) { group in
            Section {
              ForEach(group.records) { record in
                recordCard(record)
              }
            } header: {
              Text(groupTitle(group.day, count: group.records.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.76))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .background(GolfTraceTheme.panel.opacity(0.98))
            }
          }

          if filteredRecords.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: searchText.isEmpty ? "figure.golf" : "magnifyingglass")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(GolfTraceTheme.mutedText)
              Text(searchText.isEmpty ? "ยังไม่มีวงที่บันทึกไว้" : "ไม่พบวงสวิงที่ค้นหา")
                .font(.subheadline.weight(.semibold))
              Text(history.statusText)
                .font(.caption)
                .foregroundStyle(GolfTraceTheme.mutedText)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
      }
    }
    .background(GolfTraceTheme.panel.opacity(0.82))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(GolfTraceTheme.border, lineWidth: 1)
    )
  }

  private func recordCard(_ record: SwingRecord) -> some View {
    let isSelected = record.id == selectedRecord?.id
    let replayURL = history.replayURL(for: record)
    let previewSource = previewSource(for: record, replayURL: replayURL)

    return Button {
      selectedRecordID = record.id
    } label: {
      HStack(spacing: 11) {
        SwingHistoryAsyncImage(source: previewSource) {
          ZStack {
            Color.white.opacity(0.035)
            Image(systemName: replayURL == nil ? "figure.golf" : "film")
              .font(.system(size: 19, weight: .medium))
              .foregroundStyle(Color.white.opacity(0.32))
          }
        }
        .frame(width: 104, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )

        VStack(alignment: .leading, spacing: 5) {
          Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)

          Text(recordSummary(record))
            .font(.caption.monospacedDigit())
            .foregroundStyle(GolfTraceTheme.mutedText)

          HStack(spacing: 6) {
            Label(cameraSourceLabel(record), systemImage: "iphone.gen3")
              .lineLimit(1)
            Spacer(minLength: 4)
            replayBadge(available: replayURL != nil)
          }
          .font(.caption2.weight(.medium))
        }

        Image(systemName: "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(Color.white.opacity(0.58))
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        isSelected ? GolfTraceTheme.blue.opacity(0.12) : Color.white.opacity(0.025),
        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .stroke(
            isSelected ? GolfTraceTheme.blue.opacity(0.90) : GolfTraceTheme.subtleBorder,
            lineWidth: isSelected ? 1.5 : 1
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "วงสวิง \(record.createdAt.formatted(date: .abbreviated, time: .shortened)), "
        + "\(recordSummary(record)), \(cameraSourceLabel(record)), "
        + (replayURL == nil ? "ไม่มี Replay" : "มี Replay")
    )
    .accessibilityValue(isSelected ? "เลือกอยู่" : "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var selectedSwingDetail: some View {
    if let record = selectedRecord {
      GeometryReader { geometry in
        reviewCanvas(record)
          .frame(
            height: SwingHistoryReviewLayout.canvasHeight(
              availableHeight: geometry.size.height
            )
          )
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .background(Color.black.opacity(0.16))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(GolfTraceTheme.border, lineWidth: 1)
      )
    } else {
      VStack(spacing: 14) {
        Image(systemName: "figure.golf")
          .font(.system(size: 36, weight: .medium))
          .foregroundStyle(GolfTraceTheme.mutedText)
        Text("เลือกวงสวิงจากรายการเพื่อดูหลักฐาน")
          .font(.headline)
          .foregroundStyle(Color.white.opacity(0.78))
        Button("กลับหน้าซ้อม", action: onClose)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .golfTracePanel(cornerRadius: 16)
    }
  }

  private func compactHeaderOverlay(_ record: SwingRecord) -> some View {
    let replayBundle = history.replayBundleURLs(for: record)

    return VStack(alignment: .leading, spacing: 5) {
      Text(compactDateText(record.createdAt))
        .font(.system(size: 17, weight: .bold, design: .rounded))
        .lineLimit(1)

      HStack(spacing: 7) {
        Text(cameraSourceLabel(record))
        Text("•")
        Text(String(format: "%.2f วินาที", record.sessionSummary.durationSeconds))
        Text("•")
        Text("\(record.sessionSummary.sampleCount) ตัวอย่าง")
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(Color.white.opacity(0.72))

      Label(cameraAngleLabel(record), systemImage: "camera.fill")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.white.opacity(0.76))

      if let replayBundle {
        HStack(spacing: 6) {
          replaySourceBadge(
            SwingHistoryReviewLayout.cameraFPSBadgeText(
              replayBundle.bundle.camera.nominalFPS
            ),
            systemImage: "camera.fill",
            tint: GolfTraceTheme.blue
          )
          if replayBundle.status == .synchronizedPair {
            replaySourceBadge(
              "Rapsodo Screen",
              systemImage: "rectangle.on.rectangle",
              tint: .orange
            )
          }
        }

        if replayBundle.status == .cameraSaved {
          Label("Rapsodo ไม่ครบ · เก็บกล้องแล้ว", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orange.opacity(0.96))
        }
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
  }

  private func detailActions(_ record: SwingRecord) -> some View {
    HStack(spacing: 9) {
      Button(action: onClose) {
        Label("กลับหน้าซ้อม", systemImage: "arrow.left")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 12)
          .frame(height: 36)
      }
      .buttonStyle(.plain)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
      .background(Color.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.white.opacity(0.14), lineWidth: 1)
      )
      .keyboardShortcut(.cancelAction)

      let replayAvailable = history.replayURL(for: record) != nil
      Button {
        if history.openReplay(for: record, using: replay) {
          onOpenReplay()
        }
      } label: {
        Label("เปิด Replay", systemImage: "play.fill")
          .font(.subheadline.weight(.bold))
          .padding(.horizontal, 16)
          .frame(height: 38)
      }
      .buttonStyle(.plain)
      .foregroundStyle(replayAvailable ? Color.white : GolfTraceTheme.mutedText)
      .background(
        replayAvailable ? GolfTraceTheme.blue : Color.white.opacity(0.055),
        in: RoundedRectangle(cornerRadius: 10)
      )
      .disabled(!replayAvailable)
    }
  }

  private func compactDateText(_ date: Date) -> String {
    let day = date.formatted(.dateTime.day().month(.abbreviated).year())
    let time = date.formatted(.dateTime.hour().minute())
    return "\(day) · \(time)"
  }

  private func reviewCanvas(_ record: SwingRecord) -> some View {
    let replayURL = history.replayURL(for: record)
    let isRapsodoPrimary = rapsodoPrimaryRecordIDs.contains(record.id)
    let mediaSelection = SwingHistoryReviewLayout.mediaSelection(
      legacyReplayURL: replayURL,
      stagePaneLayout: history.stagePaneLayout(for: record),
      replayBundle: history.replayBundleURLs(for: record),
      isRapsodoPrimary: isRapsodoPrimary
    )
    let mainSource = mediaSelection.map {
      SwingHistoryImageSource(
        url: $0.main.url,
        kind: .movie,
        normalizedCrop: $0.main.normalizedCrop,
        requestedTimeSeconds: $0.main.requestedTimeSeconds
      )
    }
    let pipSource = mediaSelection?.pip.map {
      SwingHistoryImageSource(
        url: $0.url,
        kind: .movie,
        normalizedCrop: $0.normalizedCrop,
        requestedTimeSeconds: $0.requestedTimeSeconds
      )
    }

    return GeometryReader { geometry in
      let pipWidth = SwingHistoryReviewLayout.pipWidth(availableWidth: geometry.size.width)

      ZStack {
        SwingHistoryAsyncImage(source: mainSource, contentMode: .fit) {
          ZStack {
            LinearGradient(
              colors: [Color.white.opacity(0.045), Color.black.opacity(0.20)],
              startPoint: .top,
              endPoint: .bottom
            )
            VStack(spacing: 10) {
              Image(systemName: replayURL == nil ? "video.slash" : "film")
                .font(.system(size: 32, weight: .medium))
              Text(
                replayURL == nil
                  ? "วงนี้ไม่มีไฟล์ Replay" : "กำลังเตรียมภาพตัวอย่างจาก Replay"
              )
              .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(GolfTraceTheme.mutedText)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        LinearGradient(
          colors: [Color.black.opacity(0.34), .clear, Color.black.opacity(0.18)],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)

        if let pipSource {
          replayPIP(
            source: pipSource,
            label: mediaSelection?.pip.map(mediaLabel) ?? "Replay",
            width: pipWidth,
            recordID: record.id
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
          .padding(.trailing, 18)
          .padding(.top, 92)
          .padding(.bottom, SwingHistoryReviewLayout.storyboardHeight + 18)
        }
      }
      .overlay(alignment: .topLeading) {
        compactHeaderOverlay(record)
          .padding(14)
      }
      .overlay(alignment: .topTrailing) {
        detailActions(record)
          .padding(14)
      }
      .overlay(alignment: .bottom) {
        storyboardOverlay(record)
      }
    }
    .background(Color.black.opacity(0.45))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(GolfTraceTheme.border, lineWidth: 1)
    )
  }

  private func replayPIP(
    source: SwingHistoryImageSource,
    label: String,
    width: CGFloat,
    recordID: UUID
  ) -> some View {
    ZStack(alignment: .topLeading) {
      SwingHistoryAsyncImage(source: source, contentMode: .fit) {
        ZStack {
          Color.black.opacity(0.72)
          ProgressView()
            .controlSize(.small)
        }
      }

      Text(label)
        .font(.caption.weight(.bold))
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.black.opacity(0.74), in: Capsule())
        .padding(8)
    }
    .frame(width: width, height: width * 9 / 16)
    .background(Color.black)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(GolfTraceTheme.blue.opacity(0.88), lineWidth: 1.5)
    )
    .overlay(alignment: .leading) {
      Button {
        togglePrimaryPane(for: recordID)
      } label: {
        Image(systemName: "arrow.left.arrow.right")
          .font(.system(size: 14, weight: .bold))
          .frame(width: 42, height: 42)
          .background(.ultraThinMaterial, in: Circle())
          .background(Color.black.opacity(0.56), in: Circle())
          .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
      }
      .buttonStyle(.plain)
      .offset(x: -22)
      .help("สลับภาพหลัก")
      .accessibilityLabel("สลับภาพหลักระหว่าง Rapsodo กับกล้องวงสวิง")
    }
  }

  private func togglePrimaryPane(for recordID: UUID) {
    if rapsodoPrimaryRecordIDs.contains(recordID) {
      rapsodoPrimaryRecordIDs.remove(recordID)
    } else {
      rapsodoPrimaryRecordIDs.insert(recordID)
    }
  }

  private func mediaLabel(_ media: SwingHistoryReviewMedia) -> String {
    switch media.role {
    case .swingCamera: return "iPhone กล้อง"
    case .rapsodoScreen: return "Rapsodo Screen"
    case .legacyStage: return "Replay"
    }
  }

  private func replaySourceBadge(
    _ text: String,
    systemImage: String,
    tint: Color
  ) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint.opacity(0.96))
      .padding(.horizontal, 7)
      .frame(height: 22)
      .background(tint.opacity(0.13), in: Capsule())
      .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 1))
  }

  private func storyboardOverlay(_ record: SwingRecord) -> some View {
    GeometryReader { geometry in
      let phaseWidth = SwingHistoryReviewLayout.phaseWidth(
        availableWidth: geometry.size.width
      )

      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 8) {
          Text("Swing Storyboard")
            .font(.headline)
          if record.artifacts == nil {
            Text(
              isLegacyRecord(record)
                ? "วงเก่า · ไม่มี Storyboard" : "ไม่มีหลักฐาน Storyboard"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.orange.opacity(0.94))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.orange.opacity(0.12), in: Capsule())
          } else {
            Label("มุมเดียว", systemImage: "camera.metering.center.weighted")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Color.white.opacity(0.78))
              .padding(.horizontal, 8)
              .frame(height: 24)
              .background(Color.white.opacity(0.07), in: Capsule())
          }
          Spacer()
          if let capture = record.artifacts?.capture {
            Text(cameraAngleLabel(capture.cameraView))
              .font(.caption)
              .foregroundStyle(GolfTraceTheme.mutedText)
          }
        }

        HStack(spacing: SwingHistoryReviewLayout.phaseSpacing) {
          ForEach(Array(SwingStoryboardPhaseSlot.allCases.enumerated()), id: \.element) {
            index, slot in
            storyboardPhase(
              record,
              slot: slot,
              ordinal: index + 1,
              width: phaseWidth
            )
          }
        }
      }
      .padding(13)
    }
    .frame(height: SwingHistoryReviewLayout.storyboardHeight)
    .background(Color(red: 0.020, green: 0.036, blue: 0.055).opacity(0.68))
    .overlay(alignment: .top) {
      Rectangle()
        .fill(Color.white.opacity(0.13))
        .frame(height: 1)
    }
  }

  private func storyboardPhase(
    _ record: SwingRecord,
    slot: SwingStoryboardPhaseSlot,
    ordinal: Int,
    width: CGFloat
  ) -> some View {
    let marker = record.artifacts?.phaseMarkers.first { $0.slot == slot }
    let descriptor = record.artifacts?.keyframes.first { $0.slot == slot }
    let url =
      descriptor?.filename == nil
      ? nil : history.storyboardKeyframeURL(for: record, slot: slot)
    let source = url.map { SwingHistoryImageSource(url: $0, kind: .image) }

    return VStack(alignment: .leading, spacing: 6) {
      SwingHistoryAsyncImage(source: source, contentMode: .fit) {
        ZStack {
          Color.white.opacity(0.035)
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
              style: StrokeStyle(lineWidth: 1, dash: source == nil ? [5, 4] : [])
            )
            .foregroundStyle(Color.white.opacity(0.16))
          Image(
            systemName: phasePlaceholderIcon(
              descriptor,
              hasVerifiedImage: source != nil
            )
          )
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.28))
        }
      }
      .frame(width: width, height: 82)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      Text("\(ordinal). \(slot.titleEN)")
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.68)

      if let marker {
        Text("หลักฐาน \(Int((marker.confidence * 100).rounded()))%")
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(confidenceColor(marker.confidence))
      } else {
        Text(
          record.artifacts == nil && isLegacyRecord(record)
            ? "วงเก่า" : "ไม่มีหลักฐาน"
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(GolfTraceTheme.mutedText)
      }
    }
    .frame(width: width, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      phaseAccessibilityLabel(
        slot,
        marker: marker,
        descriptor: descriptor,
        hasVerifiedImage: source != nil
      )
    )
  }

  private var selectedRecord: SwingRecord? {
    if let selectedRecordID,
      let record = filteredRecords.first(where: { $0.id == selectedRecordID })
    {
      return record
    }
    return filteredRecords.first
  }

  private var filteredRecords: [SwingRecord] {
    let recent = Array(history.records.prefix(20))
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return recent }
    return recent.filter { record in
      let searchable = [
        record.createdAt.formatted(date: .complete, time: .shortened),
        record.createdAt.formatted(date: .abbreviated, time: .shortened),
        cameraSourceLabel(record),
        cameraAngleLabel(record),
        history.replayURL(for: record) == nil ? "ไม่มี replay" : "มี replay",
      ].joined(separator: " ").lowercased()
      return searchable.localizedStandardContains(query)
    }
  }

  private var groupedRecords: [(day: Date, records: [SwingRecord])] {
    let calendar = Calendar.autoupdatingCurrent
    let groups = Dictionary(grouping: filteredRecords) {
      calendar.startOfDay(for: $0.createdAt)
    }
    return groups.keys.sorted(by: >).map { day in
      (day: day, records: groups[day, default: []])
    }
  }

  private func repairSelection() {
    let availableIDs = Set(filteredRecords.map(\.id))
    if let selectedRecordID, availableIDs.contains(selectedRecordID) {
      return
    }
    selectedRecordID = filteredRecords.first?.id
  }

  private func browserWidth(for totalWidth: CGFloat) -> CGFloat {
    min(470, max(340, totalWidth * 0.31))
  }

  private func groupTitle(_ day: Date, count: Int) -> String {
    "\(day.formatted(.dateTime.day().month(.abbreviated).year())) (\(count))"
  }

  private func recordSummary(_ record: SwingRecord) -> String {
    String(
      format: "%.2f วินาที · %d ตัวอย่าง",
      record.sessionSummary.durationSeconds,
      record.sessionSummary.sampleCount
    )
  }

  private func cameraSourceLabel(_ record: SwingRecord) -> String {
    guard let capture = record.artifacts?.capture else {
      return isLegacyRecord(record) ? "วงเก่า" : "ไม่มีข้อมูลแหล่งภาพ"
    }
    if capture.sourceID == SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID {
      return "iPhone กล้อง"
    }
    return capture.sourceID
  }

  private func cameraAngleLabel(_ record: SwingRecord) -> String {
    guard let cameraView = record.artifacts?.capture.cameraView else {
      return "ไม่มีข้อมูลมุมกล้อง"
    }
    return cameraAngleLabel(cameraView)
  }

  private func isLegacyRecord(_ record: SwingRecord) -> Bool {
    record.schemaVersion < SwingRecord.currentSchemaVersion
  }

  private func cameraAngleLabel(_ cameraView: String) -> String {
    switch cameraView.lowercased() {
    case "downtheline", "down_the_line", "down-the-line": return "มุม Down the line"
    case "faceon", "face_on", "face-on": return "มุม Face on"
    default: return "มุม \(cameraView)"
    }
  }

  private func previewSource(for record: SwingRecord, replayURL: URL?)
    -> SwingHistoryImageSource?
  {
    if let artifacts = record.artifacts {
      let descriptorSlots = Set(
        artifacts.keyframes.compactMap { descriptor in
          descriptor.filename == nil ? nil : descriptor.slot
        }
      )
      for slot in SwingStoryboardPhaseSlot.allCases where descriptorSlots.contains(slot) {
        if let keyframe = history.storyboardKeyframeURL(for: record, slot: slot) {
          return SwingHistoryImageSource(url: keyframe, kind: .image)
        }
      }
    }
    return replayURL.map { SwingHistoryImageSource(url: $0, kind: .movie) }
  }

  private func replayBadge(available: Bool) -> some View {
    Label(
      available ? "มี Replay" : "ไม่มี Replay",
      systemImage: available ? "play.fill" : "minus.circle"
    )
    .foregroundStyle(available ? Color.green.opacity(0.95) : GolfTraceTheme.mutedText)
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(
      (available ? Color.green : Color.white).opacity(0.08),
      in: RoundedRectangle(cornerRadius: 6)
    )
  }

  private func confidenceColor(_ confidence: Double) -> Color {
    if confidence >= 0.8 { return .green }
    if confidence >= 0.6 { return .orange }
    return .red.opacity(0.92)
  }

  private func phasePlaceholderIcon(
    _ descriptor: SwingStoryboardKeyframeDescriptor?,
    hasVerifiedImage: Bool
  ) -> String {
    switch descriptor?.state {
    case .pending: return "clock"
    case .failed: return "exclamationmark.triangle"
    case .unavailable: return "camera.slash"
    case .available: return hasVerifiedImage ? "photo" : "camera.slash"
    case nil: return "camera"
    }
  }

  private func phaseAccessibilityLabel(
    _ slot: SwingStoryboardPhaseSlot,
    marker: SwingStoryboardPhaseMarker?,
    descriptor: SwingStoryboardKeyframeDescriptor?,
    hasVerifiedImage: Bool
  ) -> String {
    guard let marker else { return "\(slot.titleTH) ไม่มีหลักฐาน" }
    let imageStatus: String
    if descriptor?.state == .available, !hasVerifiedImage {
      imageStatus = "ไม่พบไฟล์ภาพ"
    } else {
      imageStatus = descriptor?.state.rawValue ?? "ไม่มีภาพ"
    }
    return
      "\(slot.titleTH) หลักฐาน \(Int((marker.confidence * 100).rounded())) เปอร์เซ็นต์ ภาพ \(imageStatus)"
  }
}

private struct SwingHistoryImageSource: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case image
    case movie
  }

  let url: URL
  let kind: Kind
  let normalizedCrop: GolfTraceNormalizedRect?
  let requestedTimeSeconds: TimeInterval?

  init(
    url: URL,
    kind: Kind,
    normalizedCrop: GolfTraceNormalizedRect? = nil,
    requestedTimeSeconds: TimeInterval? = nil
  ) {
    self.url = url
    self.kind = kind
    self.normalizedCrop = normalizedCrop
    self.requestedTimeSeconds = requestedTimeSeconds
  }
}

private actor SwingHistoryDecodeLimiter {
  private var permits: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    permits = max(1, limit)
  }

  func acquire() async {
    if permits > 0 {
      permits -= 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      permits += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}

private actor SwingHistoryImageRepository {
  static let shared = SwingHistoryImageRepository()

  private let decodeLimiter = SwingHistoryDecodeLimiter(limit: 2)
  private var cache: [SwingHistoryImageSource: CGImage] = [:]
  private var cacheOrder: [SwingHistoryImageSource] = []
  private var cacheByteCount = 0
  private var unavailable: Set<SwingHistoryImageSource> = []
  private var inFlight: [SwingHistoryImageSource: Task<CGImage?, Never>] = [:]
  private var generation: UInt = 0

  private let maximumCacheBytes = 24 * 1_024 * 1_024
  private let maximumCacheEntries = 48

  func image(for source: SwingHistoryImageSource) async -> CGImage? {
    if let cached = cache[source] { return cached }
    if unavailable.contains(source) { return nil }
    if let task = inFlight[source] { return await task.value }

    let limiter = decodeLimiter
    let requestGeneration = generation
    let task: Task<CGImage?, Never> = Task.detached(priority: .utility) {
      await limiter.acquire()
      guard !Task.isCancelled else {
        await limiter.release()
        return nil
      }
      let result = Self.loadImage(for: source)
      await limiter.release()
      return result
    }
    inFlight[source] = task
    let result = await task.value
    guard requestGeneration == generation, !task.isCancelled else { return nil }
    inFlight[source] = nil
    if let result {
      if let previous = cache.updateValue(result, forKey: source) {
        cacheByteCount -= Self.decodedCost(of: previous)
        cacheOrder.removeAll { $0 == source }
      }
      cacheByteCount += Self.decodedCost(of: result)
      cacheOrder.append(source)
      while cacheByteCount > maximumCacheBytes || cache.count > maximumCacheEntries {
        guard !cacheOrder.isEmpty else { break }
        let oldest = cacheOrder.removeFirst()
        if let removed = cache.removeValue(forKey: oldest) {
          cacheByteCount -= Self.decodedCost(of: removed)
        }
      }
    } else {
      unavailable.insert(source)
    }
    return result
  }

  func cancelAll() {
    generation &+= 1
    for task in inFlight.values {
      task.cancel()
    }
    inFlight.removeAll()
  }

  nonisolated private static func decodedCost(of image: CGImage) -> Int {
    image.bytesPerRow * image.height
  }

  nonisolated private static func loadImage(for source: SwingHistoryImageSource) -> CGImage? {
    guard FileManager.default.fileExists(atPath: source.url.path) else { return nil }
    switch source.kind {
    case .image:
      guard
        let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          imageSource,
          0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 960,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary
        )
      else { return nil }
      return cropped(image, to: source.normalizedCrop)
    case .movie:
      let asset = AVURLAsset(url: source.url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize =
        source.normalizedCrop == nil
        ? CGSize(width: 960, height: 540)
        : CGSize(width: 1_600, height: 1_000)
      generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
      generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
      let requestedTime =
        source.requestedTimeSeconds.map { max(0, $0) }
        ?? 0.1
      var actualTime = CMTime.invalid
      guard
        let image = try? generator.copyCGImage(
          at: CMTime(seconds: requestedTime, preferredTimescale: 600),
          actualTime: &actualTime
        )
      else { return nil }
      return cropped(image, to: source.normalizedCrop)
    }
  }

  nonisolated private static func cropped(
    _ image: CGImage,
    to normalizedCrop: GolfTraceNormalizedRect?
  ) -> CGImage? {
    guard let normalizedCrop else { return image }
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let requested = normalizedCrop.pixelRect(in: imageBounds.size)
    let bounded = requested.intersection(imageBounds).integral
    guard bounded.width >= 2, bounded.height >= 2 else { return nil }
    return image.cropping(to: bounded)
  }
}

private struct SwingHistoryAsyncImage<Placeholder: View>: View {
  let source: SwingHistoryImageSource?
  var contentMode: ContentMode = .fill
  @ViewBuilder let placeholder: () -> Placeholder

  @State private var loadedSource: SwingHistoryImageSource?
  @State private var image: CGImage?

  var body: some View {
    Group {
      if loadedSource == source, let image {
        if contentMode == .fit {
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
        } else {
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFill()
        }
      } else {
        placeholder()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .task(id: source) {
      loadedSource = nil
      image = nil
      guard let source else { return }
      let loaded = await SwingHistoryImageRepository.shared.image(for: source)
      guard !Task.isCancelled else { return }
      guard let loaded else { return }
      image = loaded
      loadedSource = source
    }
  }
}

private enum AdvancedSettingsTab: String, CaseIterable, Identifiable {
  case ai
  case sources
  case rapsodo
  case knowledge
  case diagnostics

  var id: Self { self }

  var title: String {
    switch self {
    case .ai: return "AI Golf Pro"
    case .sources: return "แหล่งภาพ"
    case .rapsodo: return "Rapsodo"
    case .knowledge: return "คลังความรู้"
    case .diagnostics: return "การวินิจฉัย"
    }
  }

  var systemImage: String {
    switch self {
    case .ai: return "waveform"
    case .sources: return "camera"
    case .rapsodo: return "iphone"
    case .knowledge: return "book.closed"
    case .diagnostics: return "stethoscope"
    }
  }

  var subtitle: String {
    switch self {
    case .ai: return "โมเดล บัญชี งบประมาณ และเสียงผู้ฝึกสอน"
    case .sources: return "ภาพ 120 FPS และทางสำรองผ่านกล้องของ Apple"
    case .rapsodo: return "สถานะอุปกรณ์ สิทธิ์ใช้งาน และการเชื่อมต่อ"
    case .knowledge: return "โปรไฟล์ผู้ฝึกสอนและแหล่งอ้างอิง YouTube"
    case .diagnostics: return "ตรวจสอบภาพสด การวิเคราะห์ และสถานะของระบบ"
    }
  }
}

private struct AIGolfProSettingsDraft {
  var apiKeyInput = ""
  var isCheckingOpenRouter = false
  var keySaveStatus: String?
  var keySaveSucceeded = false
}

private struct GolfKnowledgeSettingsDraft {
  var urlInput = ""
  var newProfileName = ""
  var newProfileStyle = ""
  var profilePendingDeletion: AIGolfProKnowledgeProfile?
}

struct GolfTraceSettingsSheet: View {
  @ObservedObject var camera: CameraCaptureModel
  @ObservedObject var launchMonitor: LaunchMonitorController
  @ObservedObject var rapsodoCredentials: RapsodoCredentialSettings
  @ObservedObject var aiGolfPro: AIGolfProController
  @ObservedObject var knowledge: GolfKnowledgeController
  let activeSourceName: String
  let activeSourceFPSText: String
  let activeFrameCount: Int
  let activeDropCount: Int
  let onClose: () -> Void

  @State private var selectedTab: AdvancedSettingsTab = .ai
  @State private var aiDraft = AIGolfProSettingsDraft()
  @State private var rapsodoSecretInput = ""
  @State private var knowledgeDraft = GolfKnowledgeSettingsDraft()

  var body: some View {
    HStack(spacing: 0) {
      navigationRail

      VStack(spacing: 0) {
        settingsHeader
        settingsWorkspace
      }
    }
    .frame(minWidth: 1_040, idealWidth: 1_100, minHeight: 700, idealHeight: 760)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.035, green: 0.050, blue: 0.068),
          Color(red: 0.020, green: 0.032, blue: 0.048),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
    .preferredColorScheme(.dark)
  }

  private var settingsHeader: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("การตั้งค่าขั้นสูง")
          .font(.system(size: 20, weight: .bold, design: .rounded))
        Text("จัดการ AI อุปกรณ์ และข้อมูล โดยไม่รบกวนหน้าซ้อม")
          .font(.caption)
          .foregroundStyle(GolfTraceTheme.mutedText)
      }

      Spacer()

      Button(action: onClose) {
        Text("เสร็จสิ้น")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 16)
          .frame(height: 36)
      }
      .buttonStyle(.plain)
      .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
      .overlay(
        RoundedRectangle(cornerRadius: 11)
          .stroke(Color.white.opacity(0.13), lineWidth: 1)
      )
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 15)
    .background(Color.black.opacity(0.18))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(GolfTraceTheme.subtleBorder)
        .frame(height: 1)
    }
  }

  private var navigationRail: some View {
    VStack(alignment: .leading, spacing: 7) {
      Color.clear
        .frame(height: 31)

      ForEach(AdvancedSettingsTab.allCases) { tab in
        Button {
          withAnimation(.easeOut(duration: 0.16)) {
            selectedTab = tab
          }
        } label: {
          HStack(spacing: 12) {
            Image(systemName: tab.systemImage)
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(selectedTab == tab ? GolfTraceTheme.blue : Color.white.opacity(0.65))
              .frame(width: 24)

            Text(tab.title)
              .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
              .foregroundStyle(selectedTab == tab ? Color.white : Color.white.opacity(0.72))

            Spacer(minLength: 0)
          }
          .padding(.horizontal, 13)
          .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
          .background(
            selectedTab == tab ? GolfTraceTheme.blue.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 11)
              .stroke(
                selectedTab == tab ? GolfTraceTheme.blue.opacity(0.80) : Color.clear,
                lineWidth: 1
              )
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      Spacer(minLength: 24)
    }
    .padding(16)
    .frame(width: 204)
    .background(Color.black.opacity(0.20))
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color.white.opacity(0.10))
        .frame(width: 1)
    }
  }

  private var settingsWorkspace: some View {
    tabPage(selectedTab)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.06))
  }

  @ViewBuilder
  private func tabPage(_ tab: AdvancedSettingsTab) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if tab != .ai {
          pageHeading(tab)
        }

        switch tab {
        case .ai:
          aiPage
        case .sources:
          sourcesPage
        case .rapsodo:
          rapsodoPage
        case .knowledge:
          knowledgePage
        case .diagnostics:
          diagnosticsPage
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.visible)
  }

  private func pageHeading(_ tab: AdvancedSettingsTab) -> some View {
    HStack(spacing: 12) {
      Image(systemName: tab.systemImage)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(GolfTraceTheme.blue)
        .frame(width: 38, height: 38)
        .background(GolfTraceTheme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 2) {
        Text(tab.title)
          .font(.title3.weight(.semibold))
        Text(tab.subtitle)
          .font(.caption)
          .foregroundStyle(GolfTraceTheme.mutedText)
      }
    }
    .padding(.bottom, 2)
  }

  private var aiPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      aiReadinessBanner

      AIGolfProSettingsPanel(
        settings: aiGolfPro.settings,
        state: aiGolfPro.state,
        apiKeyInput: $aiDraft.apiKeyInput,
        isCheckingOpenRouter: $aiDraft.isCheckingOpenRouter,
        keySaveStatus: $aiDraft.keySaveStatus,
        keySaveSucceeded: $aiDraft.keySaveSucceeded
      )
    }
  }

  private var aiReadinessBanner: some View {
    let isReady = aiGolfPro.settings.hasStoredAPIKey
    let accent = isReady ? Color.green : Color.orange

    return HStack(spacing: 13) {
      Image(
        systemName: isReady ? "checkmark.shield.fill" : "shield.lefthalf.filled.badge.checkmark"
      )
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(accent)
      .frame(width: 42, height: 42)
      .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

      VStack(alignment: .leading, spacing: 3) {
        Text(isReady ? "OpenRouter พร้อมใช้ใน Mac เครื่องนี้" : "ตั้งค่า AI ก่อนเริ่มใช้ AI Golf Pro")
          .font(.headline)
        Text("API key ที่ตั้งค่าในหน้านี้จะถูกเก็บอย่างปลอดภัยใน Keychain เท่านั้น")
          .font(.caption)
          .foregroundStyle(GolfTraceTheme.mutedText)
      }

      Spacer(minLength: 12)

      Text(isReady ? "พร้อมใช้งาน" : "ยังไม่ได้ตั้งค่า")
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.28), lineWidth: 1))
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(accent.opacity(0.28), lineWidth: 1)
    )
  }

  private var sourcesPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        practiceSettingsSummary
          .frame(maxWidth: .infinity, alignment: .top)

        HighSpeedInputPanel(
          receiver: camera.highSpeedReceiver,
          start: camera.startHighSpeedInput
        )
        .frame(maxWidth: .infinity, alignment: .top)
      }

      fallbackCameraCard
      cameraSetupCard

      HStack(spacing: 8) {
        Circle()
          .fill(camera.isRunning ? Color.green : Color.orange)
          .frame(width: 7, height: 7)
        Text(camera.status)
          .font(.caption)
          .foregroundStyle(GolfTraceTheme.mutedText)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 4)
    }
  }

  private var rapsodoPage: some View {
    LaunchMonitorPanel(
      controller: launchMonitor,
      credentials: rapsodoCredentials,
      secretInput: $rapsodoSecretInput
    )
  }

  private var knowledgePage: some View {
    GolfKnowledgePanel(
      controller: knowledge,
      aiSettings: aiGolfPro.settings,
      urlInput: $knowledgeDraft.urlInput,
      newProfileName: $knowledgeDraft.newProfileName,
      newProfileStyle: $knowledgeDraft.newProfileStyle,
      profilePendingDeletion: $knowledgeDraft.profilePendingDeletion
    )
  }

  private var diagnosticsPage: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        AdvancedSettingsCard(
          title: "ข้อมูลภาพสด",
          systemImage: "video.fill",
          accent: GolfTraceTheme.blue
        ) {
          LiveCaptureDiagnosticRows(camera: camera)
        }
        .frame(maxWidth: .infinity, alignment: .top)

        AdvancedSettingsCard(
          title: "การวิเคราะห์ท่าทาง",
          systemImage: "figure.golf",
          accent: .orange
        ) {
          LivePoseDiagnosticRows(camera: camera)
        }
        .frame(maxWidth: .infinity, alignment: .top)
      }

      AdvancedSettingsCard(
        title: "การวิเคราะห์บน Mac",
        systemImage: "laptopcomputer",
        accent: GolfTraceTheme.blue
      ) {
        VStack(alignment: .leading, spacing: 11) {
          diagnosticExplanation(
            "ตรวจท่าร่างกายและเส้นทางกึ่งกลางมือบน Mac เครื่องนี้",
            systemImage: "laptopcomputer"
          )
          diagnosticExplanation(
            "ระบบเลือกวิเคราะห์ภาพล่าสุดเสมอ จึงไม่สะสมภาพวงสวิงเก่า",
            systemImage: "forward.end"
          )
          diagnosticExplanation(
            "เส้นสีฟ้าและส้มคือตำแหน่งกึ่งกลางข้อมือ ยังไม่ใช่เส้นทางหัวไม้",
            systemImage: "hand.raised"
          )
          diagnosticExplanation(
            "FPS คือจำนวนภาพที่รับหรือวิเคราะห์ได้ใน 1 วินาที",
            systemImage: "speedometer"
          )
        }
      }
    }
  }

  private var practiceSettingsSummary: some View {
    let settings = camera.highSpeedReceiver.practiceSettings

    return AdvancedSettingsCard(
      title: "ค่ารอบซ้อมจาก iPhone",
      systemImage: "iphone.gen3",
      accent: GolfTraceTheme.blue
    ) {
      VStack(alignment: .leading, spacing: 10) {
        diagnosticRow("ไม้", settings.club.displayName)
        diagnosticRow("มุมกล้อง", settings.cameraView.displayName)
        diagnosticRow("เส้นช่วยดู", settings.guideline.displayName)
        diagnosticRow("โปร", settings.coach.displayName)
        diagnosticRow("เสียงคำแนะนำ", settings.audioDevice.displayName)

        Text("เปลี่ยนค่าจากแอปกล้องบน iPhone แล้ว Mac จะอัปเดตให้อัตโนมัติ")
          .font(.caption2)
          .foregroundStyle(GolfTraceTheme.mutedText)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 3)
      }
    }
  }

  private var fallbackCameraCard: some View {
    AdvancedSettingsCard(
      title: "ทางสำรอง 60 FPS",
      systemImage: "arrow.triangle.2.circlepath.camera",
      accent: .orange
    ) {
      DisclosureGroup("เปิดการตั้งค่าทางสำรอง") {
        VStack(alignment: .leading, spacing: 12) {
          Text("ระบบกล้องของ Apple ส่งได้สูงสุด 60 FPS ใช้เฉพาะเมื่อโหมดส่งตรงเชื่อมไม่ได้")
            .font(.caption)
            .foregroundStyle(Color.orange.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)

          Picker("แหล่งภาพ", selection: $camera.selectedDeviceID) {
            Text("เลือกกล้อง").tag(String?.none)
            ForEach(camera.devices) { device in
              Text(device.isContinuityCamera ? "iPhone · \(device.name)" : device.name)
                .tag(Optional(device.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
          .disabled(camera.isRunning)

          HStack {
            Button("ค้นหาใหม่", systemImage: "arrow.clockwise") {
              camera.refreshDevices()
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(
              camera.isRunning ? "กลับไปโหมด 120 FPS" : "ใช้ทางสำรอง 60 FPS",
              systemImage: camera.isRunning ? "arrow.uturn.backward" : "play.fill"
            ) {
              if camera.isRunning {
                camera.stop()
                camera.startHighSpeedInput()
              } else {
                camera.start()
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(camera.isRunning ? .red : GolfTraceTheme.blue)
            .disabled(camera.selectedDeviceID == nil)
          }
        }
        .padding(.top, 10)
      }
      .font(.subheadline.weight(.semibold))
    }
  }

  private var cameraSetupCard: some View {
    AdvancedSettingsCard(
      title: "วิธีตั้งกล้อง",
      systemImage: "viewfinder",
      accent: GolfTraceTheme.blue
    ) {
      VStack(alignment: .leading, spacing: 11) {
        cameraSetupRow(
          "ส่งภาพผ่านเครือข่ายได้โดยไม่ต้องต่อสาย; USB-C ใช้ชาร์จไฟและติดตั้งรุ่นทดสอบ",
          systemImage: "wifi"
        )
        cameraSetupRow("จัดให้เห็นทั้งตัวและไม้กอล์ฟครบในภาพ", systemImage: "figure.golf")
        cameraSetupRow(
          "ถ้าพื้นอยู่ด้านบนของภาพ ให้หมุน iPhone 180° ก่อนเริ่มตี",
          systemImage: "rotate.right"
        )
        cameraSetupRow("ล็อกโฟกัสและแสง พร้อมใช้ไฟที่ไม่กะพริบ", systemImage: "lightbulb")
        cameraSetupRow(
          "แอป iPhone ตั้งเป้าส่งตรง 1080p 120 FPS; ใช้ 240 FPS สำหรับดูย้อนหลังไปก่อน",
          systemImage: "gauge.with.dots.needle.50percent"
        )
      }
    }
  }

  private func cameraSetupRow(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(GolfTraceTheme.mutedText)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func diagnosticExplanation(_ text: String, systemImage: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(GolfTraceTheme.blue.opacity(0.88))
        .frame(width: 18)
      Text(text)
        .font(.caption)
        .foregroundStyle(GolfTraceTheme.mutedText)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private func diagnosticRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(GolfTraceTheme.mutedText)
      Spacer(minLength: 12)
      Text(value)
        .font(.caption.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .foregroundStyle(Color.white.opacity(0.90))
    }
    .font(.caption)
  }
}

private struct LiveCaptureDiagnosticRows: View {
  @ObservedObject private var camera: CameraCaptureModel
  @ObservedObject private var liveState: CameraLiveState
  @ObservedObject private var receiver: HighSpeedVideoReceiver

  init(camera: CameraCaptureModel) {
    self.camera = camera
    _liveState = ObservedObject(wrappedValue: camera.liveState)
    _receiver = ObservedObject(wrappedValue: camera.highSpeedReceiver)
  }

  private var usesDirectIPhoneInput: Bool {
    switch receiver.state {
    case .advertising, .connected, .stalled:
      return true
    case .stopped, .failed:
      return false
    }
  }

  private var rawDisplayedOrientation: GolfTraceVideoOrientation {
    usesDirectIPhoneInput ? receiver.presentedVideoOrientation : .degrees0
  }

  private var effectiveDisplayedOrientation: GolfTraceVideoOrientation {
    rawDisplayedOrientation.addingHalfTurn(camera.videoHalfTurn.isEnabled)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      row(
        "แหล่งภาพ",
        usesDirectIPhoneInput
          ? "ส่งตรงจาก iPhone · เป้าหมาย 120 FPS" : "ทางสำรองของ Apple · สูงสุด 60 FPS"
      )
      row(
        "FPS ของภาพที่รับ",
        usesDirectIPhoneInput ? receiver.metrics.fpsText : liveState.frameMetrics.fpsText
      )
      row(
        "เฟรมที่รับ/ถอดแล้ว",
        "\(usesDirectIPhoneInput ? receiver.metrics.decodedFrames : liveState.frameMetrics.receivedFrames)"
      )
      row(
        "รับหรือถอดไม่สำเร็จ",
        "\(usesDirectIPhoneInput ? receiver.metrics.decoderDrops : liveState.frameMetrics.droppedFrames)"
      )
      row("มุมจาก iPhone", "\(Int(rawDisplayedOrientation.clockwiseDegrees))°")
      row("แก้กลับภาพ", camera.videoHalfTurn.isEnabled ? "180° · เปิด" : "ปิด")
      row("มุมที่แสดงจริง", "\(Int(effectiveDisplayedOrientation.clockwiseDegrees))°")
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    LiveDiagnosticRow(label: label, value: value)
  }
}

private struct LivePoseDiagnosticRows: View {
  @ObservedObject private var camera: CameraCaptureModel
  @ObservedObject private var liveState: CameraLiveState

  init(camera: CameraCaptureModel) {
    self.camera = camera
    _liveState = ObservedObject(wrappedValue: camera.liveState)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      LiveDiagnosticRow(label: "FPS ที่วิเคราะห์", value: liveState.poseMetrics.fpsText)
      LiveDiagnosticRow(label: "เวลาวิเคราะห์ล่าสุด", value: liveState.poseMetrics.timingText)
      LiveDiagnosticRow(
        label: "เฟรมที่ข้าม",
        value: "\(liveState.poseMetrics.inputFramesSkipped)"
      )
      LiveDiagnosticRow(
        label: "การเคลื่อนมือ",
        value: liveState.swingMotion?.state.displayName ?? "รอภาพ"
      )
      LiveDiagnosticRow(label: "สถานะจับวง", value: camera.swingSessionState.displayName)
    }
  }
}

private struct LiveDiagnosticRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(GolfTraceTheme.mutedText)
      Spacer(minLength: 12)
      Text(value)
        .font(.caption.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .foregroundStyle(Color.white.opacity(0.90))
    }
    .font(.caption)
  }
}

private struct AdvancedSettingsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let accent: Color
  let content: Content

  init(
    title: String,
    systemImage: String,
    accent: Color,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.accent = accent
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .foregroundStyle(accent)
          .frame(width: 18)
        Text(title)
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
      }

      content
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(red: 0.035, green: 0.048, blue: 0.063),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(0.13), lineWidth: 1)
    )
  }
}
