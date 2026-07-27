import Foundation
import SwiftUI
import UIKit

private enum CameraTheme {
  static let blue = Color(red: 70 / 255, green: 136 / 255, blue: 242 / 255)
  static let green = Color(red: 102 / 255, green: 220 / 255, blue: 128 / 255)
}

private enum CameraReferenceArtwork: String {
  case brand = "CameraReferenceBrand"
  case club = "CameraReferenceClub"
  case cameraAngle = "CameraReferenceAngle"
  case guideline = "CameraReferenceGuideline"
  case coach = "CameraReferenceCoach"
  case frameAction = "CameraReferenceFrameAction"
  case practiceAction = "CameraReferencePracticeAction"
  case settingsAction = "CameraReferenceSettingsAction"
}

private struct CameraReferenceArtworkView: View {
  let artwork: CameraReferenceArtwork
  let size: CGFloat

  var body: some View {
    Group {
      if let image = GolfTraceBundledPNG.image(named: artwork.rawValue) {
        image
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "circle.dotted")
          .resizable()
          .scaledToFit()
          .foregroundStyle(CameraTheme.blue)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct ContentView: View {
  @ObservedObject var camera: CameraService
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var orientationController = PhysicalOrientationController()
  @State private var isShowingDiagnostics = false
  @State private var isShowingFormatCatalog = false
  @State private var areControlsVisible = true
  @State private var controlsAutoHideTask: Task<Void, Never>?

  var body: some View {
    GeometryReader { geometry in
      let isLandscape = geometry.size.width > geometry.size.height

      ZStack {
        Color.black.ignoresSafeArea()

        CameraPreview(session: camera.session)
          .ignoresSafeArea()
          .accessibilityLabel("ภาพสดจากกล้องหลัง")
          .accessibilityHint("ใช้จัดให้เห็นร่างกายและพื้นที่วงสวิงอยู่ภายในกรอบ")

        cameraShade
          .opacity(showsFullControls ? 1 : 0.18)

        Color.clear
          .contentShape(Rectangle())
          .onTapGesture {
            toggleControls()
          }
          .accessibilityHidden(true)

        SwingFramingGuide(cameraView: camera.practiceSettings.cameraView)
          .padding(.horizontal, isLandscape ? 12 : 14)
          .padding(.top, isLandscape ? 4 : 8)
          .padding(.bottom, isLandscape ? 6 : 12)
          .allowsHitTesting(false)

        if showsFullControls {
          if isLandscape {
            landscapeLayout
          } else {
            portraitLayout(hidesTitle: geometry.size.width < 420)
          }
        } else {
          essentialStatusHUD(compact: isLandscape)
        }

        WindowSceneAttachmentView { scene in
          orientationController.attach(scene: scene)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .sheet(isPresented: $isShowingDiagnostics) {
      diagnosticsSheet
    }
    .statusBarHidden(!showsFullControls)
    .animation(controlAnimation, value: showsFullControls)
    .task {
      // กล้องและการส่งภาพต้องอยู่ด้านหน้าเสมอ ป้องกัน iPhone ล็อกหน้าจอ
      // กลางวงสวิงแล้วตัดการเชื่อมต่อกับ Mac โดยที่ผู้ใช้ไม่รู้สาเหตุ
      UIApplication.shared.isIdleTimerDisabled = true
      orientationController.activate()
      camera.startPreview()
      revealControls(scheduleAutoHide: false)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        UIApplication.shared.isIdleTimerDisabled = true
        orientationController.activate()
        camera.startPreview()
        revealControls(scheduleAutoHide: true)
      } else {
        controlsAutoHideTask?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        orientationController.deactivate()
        camera.stopPreview()
      }
    }
    .onChange(of: isReady) { _, ready in
      if ready {
        scheduleControlsAutoHideIfNeeded()
      } else {
        controlsAutoHideTask?.cancel()
      }
    }
    .onChange(of: requiresVisibleControls) { _, requiresControls in
      if requiresControls {
        revealControls(scheduleAutoHide: false)
      }
    }
    .onChange(of: isShowingDiagnostics) { _, isPresented in
      if isPresented {
        controlsAutoHideTask?.cancel()
      } else {
        scheduleControlsAutoHideIfNeeded()
      }
    }
    .onDisappear {
      controlsAutoHideTask?.cancel()
      UIApplication.shared.isIdleTimerDisabled = false
      orientationController.deactivate()
    }
  }

  private var cameraShade: some View {
    LinearGradient(
      stops: [
        .init(color: .black.opacity(0.60), location: 0),
        .init(color: .black.opacity(0.10), location: 0.27),
        .init(color: .clear, location: 0.55),
        .init(color: .black.opacity(0.20), location: 0.72),
        .init(color: .black.opacity(0.80), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var showsFullControls: Bool {
    areControlsVisible || isVoiceOverEnabled
  }

  private var controlAnimation: Animation? {
    reduceMotion ? nil : .easeInOut(duration: 0.22)
  }

  private var requiresVisibleControls: Bool {
    switch camera.state {
    case .denied, .restricted, .unavailable, .failed:
      return true
    case .idle, .requestingPermission, .preparing, .running, .stopped:
      break
    }

    if case .failed = camera.macStreamState {
      return true
    }
    return false
  }

  private func toggleControls() {
    if areControlsVisible {
      hideControls()
    } else {
      revealControls(scheduleAutoHide: false)
    }
  }

  private func revealControls(scheduleAutoHide: Bool) {
    controlsAutoHideTask?.cancel()
    withAnimation(controlAnimation) {
      areControlsVisible = true
    }
    if scheduleAutoHide {
      scheduleControlsAutoHideIfNeeded()
    }
  }

  private func hideControls() {
    controlsAutoHideTask?.cancel()
    guard !isVoiceOverEnabled else { return }
    withAnimation(controlAnimation) {
      areControlsVisible = false
    }
  }

  private func scheduleControlsAutoHideIfNeeded() {
    controlsAutoHideTask?.cancel()
    guard areControlsVisible,
      isReady,
      !requiresVisibleControls,
      !isShowingDiagnostics,
      !isVoiceOverEnabled
    else {
      return
    }

    controlsAutoHideTask = Task { @MainActor in
      try? await Task<Never, Never>.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(controlAnimation) {
        areControlsVisible = false
      }
      controlsAutoHideTask = nil
    }
  }

  private func portraitLayout(hidesTitle: Bool) -> some View {
    VStack(spacing: 12) {
      topStatusBar(compact: false, hidesTitle: hidesTitle)
        .simultaneousGesture(TapGesture().onEnded { controlsAutoHideTask?.cancel() })
      Spacer(minLength: 0)
      bottomControlDeck(compact: false)
        .simultaneousGesture(TapGesture().onEnded { controlsAutoHideTask?.cancel() })
    }
    .padding(.horizontal, 14)
    .padding(.top, -5.5)
    .padding(.bottom, 19)
  }

  private var landscapeLayout: some View {
    VStack(spacing: 8) {
      topStatusBar(compact: true, hidesTitle: false)
        .simultaneousGesture(TapGesture().onEnded { controlsAutoHideTask?.cancel() })
      Spacer(minLength: 0)
      bottomControlDeck(compact: true)
        .simultaneousGesture(TapGesture().onEnded { controlsAutoHideTask?.cancel() })
    }
    .padding(.horizontal, 12)
    .padding(.top, 4)
    .padding(.bottom, 6)
  }

  private func essentialStatusHUD(compact: Bool) -> some View {
    VStack {
      HStack {
        Spacer(minLength: 0)

        Button {
          revealControls(scheduleAutoHide: false)
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
          HStack(spacing: compact ? 7 : 9) {
            Circle()
              .fill(mainStatus.color)
              .frame(width: 8, height: 8)
              .shadow(color: mainStatus.color.opacity(0.65), radius: 5)

            HStack(spacing: 4) {
              Image(systemName: "speedometer")
              Text(compactDeliveredFrameRateText)
                .monospacedDigit()
            }
            .foregroundStyle(frameRateStatusColor)

            Rectangle()
              .fill(.white.opacity(0.16))
              .frame(width: 1, height: 18)

            Image(systemName: "display")
              .foregroundStyle(macStatusColor)

            Image(systemName: "chevron.down")
              .foregroundStyle(.white.opacity(0.80))
          }
          .font(.system(size: compact ? 12 : 13, weight: .bold))
          .padding(.horizontal, compact ? 11 : 13)
          .frame(height: 42)
          .cameraGlassPanel(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "\(mainStatus.title), \(shortFrameRateText(camera.deliveredFrameRate)), \(macConnectionText)"
        )
        .accessibilityHint("แตะเพื่อแสดงเครื่องมือและการตั้งค่า")
        .accessibilityAddTraits(.isButton)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, compact ? 12 : 14)
    .padding(.top, compact ? 4 : 7)
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  private func topStatusBar(compact: Bool, hidesTitle: Bool) -> some View {
    HStack(spacing: compact ? 10 : 12) {
      HStack(spacing: compact ? 8 : 10) {
        CameraReferenceArtworkView(artwork: .brand, size: 34)

        if !hidesTitle {
          Text("กล้องวงสวิง")
            .font(compact ? .subheadline.weight(.bold) : .headline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.74)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("GolfTrace กล้องวงสวิง")

      Spacer(minLength: 0)

      topMetricPill(
        title: headerFrameRateText,
        symbol: nil,
        color: frameRateStatusColor,
        compact: compact
      )

      topMetricPill(
        title: macConnectionText,
        symbol: "display",
        color: macStatusColor,
        compact: compact
      )

      Button {
        isShowingDiagnostics = true
      } label: {
        Image(systemName: "gearshape.fill")
          .font(.system(size: compact ? 20 : 24, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("เปิดการตั้งค่าทั้งหมด")
      .accessibilityHint("ตั้งค่าการซ้อม กล้อง เสียง และดูข้อมูลการส่งภาพไปยัง Mac")
    }
    .padding(.horizontal, compact ? 12 : 14)
    .frame(height: compact ? 52 : 59)
    .cameraGlassPanel(cornerRadius: compact ? 18 : 16)
    .accessibilityElement(children: .contain)
  }

  private func topMetricPill(
    title: String,
    symbol: String?,
    color: Color,
    compact: Bool
  ) -> some View {
    HStack(spacing: compact ? 5 : 7) {
      if let symbol {
        Image(systemName: symbol)
          .font(.system(size: compact ? 11 : 13, weight: .semibold))
      }

      Text(title)
        .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .foregroundStyle(color)
    .padding(.horizontal, compact ? 9 : 5.5)
    .frame(height: compact ? 31 : 30)
    .background(color.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(color.opacity(0.86), lineWidth: 1.2))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private func bottomControlDeck(compact: Bool) -> some View {
    if compact {
      VStack(spacing: 7) {
        readinessStrip(compact: true)

        if let recovery = recoveryAction {
          recoveryButton(recovery, compact: true)
        }

        Divider()
          .overlay(.white.opacity(0.16))

        HStack(spacing: 9) {
          practiceContextRow(compact: true)
          Rectangle()
            .fill(.white.opacity(0.16))
            .frame(width: 1, height: 42)
          actionRow(compact: true)
            .frame(maxWidth: 260)
        }
      }
      .padding(9)
      .cameraGlassPanel(cornerRadius: 18)
    } else {
      VStack(spacing: 15) {
        portraitStatusPanel
        actionRow(compact: false)
      }
    }
  }

  private var portraitStatusPanel: some View {
    VStack(spacing: 10) {
      readinessStrip(compact: false)

      if let recovery = recoveryAction {
        recoveryButton(recovery, compact: true)
      }

      Divider()
        .overlay(.white.opacity(0.16))

      practiceContextRow(compact: false)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, recoveryAction == nil ? 17.5 : 12)
    .cameraGlassPanel(cornerRadius: 18)
  }

  private func readinessStrip(compact: Bool) -> some View {
    let ready = isReady
    let degraded = isFrameRateDegraded
    let color = ready ? CameraTheme.green : (degraded ? Color.orange : mainStatus.color)

    return Button {
      if degraded {
        isShowingDiagnostics = true
      } else if !camera.state.isRunning {
        camera.startPreview()
      } else if !camera.macStreamState.isStreaming {
        camera.startMacStream()
      }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    } label: {
      HStack(spacing: compact ? 9 : 13) {
        ZStack {
          Circle()
            .fill(color.opacity(0.12))
          Circle()
            .stroke(color, lineWidth: compact ? 3 : 4)
          Image(
            systemName: ready
              ? "checkmark"
              : (degraded ? "exclamationmark" : "arrow.clockwise")
          )
            .font(.system(size: compact ? 14 : 20, weight: .bold))
            .foregroundStyle(color)
        }
        .frame(width: compact ? 44 : 48, height: compact ? 44 : 48)
        .shadow(color: color.opacity(0.18), radius: 8)

        VStack(alignment: .leading, spacing: compact ? 0 : 2) {
          Text(readinessTitle)
            .font(compact ? .caption.weight(.bold) : .headline.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.72)

          Text(readinessSubtitle)
            .font(compact ? .caption2 : .subheadline)
            .foregroundStyle(.white.opacity(0.70))
            .lineLimit(compact ? 1 : 2)
            .minimumScaleFactor(0.72)
        }

        Spacer(minLength: 0)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(ready ? "พร้อมส่งภาพ เริ่มวงสวิงได้เลย" : readinessTitle)
    .accessibilityHint(
      ready
        ? "Mac จะตรวจจับ บันทึก และวิเคราะห์วงสวิงให้อัตโนมัติ"
        : readinessSubtitle
    )
  }

  private func practiceContextRow(compact: Bool) -> some View {
    HStack(spacing: 0) {
      clubMenu(compact: compact)
      contextDivider(compact: compact)
      cameraViewMenu(compact: compact)
      contextDivider(compact: compact)
      guidelineMenu(compact: compact)
      contextDivider(compact: compact)
      coachMenu(compact: compact)
    }
    .accessibilityElement(children: .contain)
  }

  private func contextDivider(compact: Bool) -> some View {
    Rectangle()
      .fill(.white.opacity(0.16))
      .frame(width: 1, height: compact ? 44 : 56)
  }

  private func clubMenu(compact: Bool) -> some View {
    Menu {
      Picker("เลือกไม้กอล์ฟ", selection: clubBinding) {
        ForEach(GolfClub.allCases) { club in
          Text(club.displayName).tag(club)
        }
      }
    } label: {
      PracticeContextItem(
        value: camera.practiceSettings.club.displayName,
        artwork: .club,
        compact: compact
      )
    }
    .accessibilityLabel("ไม้ที่ใช้ \(camera.practiceSettings.club.displayName)")
    .accessibilityHint("แตะเพื่อเลือกไม้กอล์ฟ")
  }

  private func cameraViewMenu(compact: Bool) -> some View {
    Menu {
      Picker("เลือกมุมกล้อง", selection: cameraViewBinding) {
        ForEach(GolfCameraView.allCases) { cameraView in
          Text(cameraView.displayName).tag(cameraView)
        }
      }
    } label: {
      PracticeContextItem(
        value: camera.practiceSettings.cameraView.displayName,
        artwork: .cameraAngle,
        compact: compact
      )
    }
    .accessibilityLabel("มุมกล้อง \(camera.practiceSettings.cameraView.displayName)")
    .accessibilityHint("แตะเพื่อเลือกมุมด้านหน้าหรือหลังแนวตี")
  }

  private func guidelineMenu(compact: Bool) -> some View {
    Menu {
      Picker("เลือกเส้นช่วยดู", selection: guidelineBinding) {
        ForEach(GolfGuideline.allCases) { guideline in
          Text(guideline.displayName).tag(guideline)
        }
      }
    } label: {
      PracticeContextItem(
        value: camera.practiceSettings.guideline.displayName,
        artwork: .guideline,
        compact: compact
      )
    }
    .accessibilityLabel("เส้นช่วยดู \(camera.practiceSettings.guideline.displayName)")
    .accessibilityHint("แตะเพื่อเลือกสิ่งที่ต้องการดูหลังตี")
  }

  private func coachMenu(compact: Bool) -> some View {
    Menu {
      Picker("เลือกโปรผู้ช่วย", selection: coachBinding) {
        ForEach(GolfCoachProfileID.allCases) { coach in
          Text(coach.displayName).tag(coach)
        }
      }
    } label: {
      PracticeContextItem(
        value: camera.practiceSettings.coach.displayName,
        artwork: .coach,
        compact: compact
      )
    }
    .accessibilityLabel("โปรผู้ช่วย \(camera.practiceSettings.coach.displayName)")
    .accessibilityHint("แตะเพื่อเลือกรูปแบบคำแนะนำ")
  }

  private func actionRow(compact: Bool) -> some View {
    HStack(spacing: compact ? 7 : 6) {
      Menu {
        Picker("เลือกมุมกล้อง", selection: cameraViewBinding) {
          ForEach(GolfCameraView.allCases) { cameraView in
            Text(cameraView.displayName).tag(cameraView)
          }
        }
      } label: {
        CameraActionTile(
          title: "จัดเฟรม",
          artwork: .frameAction,
          accent: CameraTheme.blue,
          compact: compact,
          emphasized: true
        )
      }
      .accessibilityLabel("จัดเฟรม มุม\(camera.practiceSettings.cameraView.displayName)")
      .accessibilityHint("แตะเพื่อเลือกมุมกล้องและปรับกรอบ")

      practiceActionMenu(compact: compact)

      Button {
        isShowingDiagnostics = true
      } label: {
        CameraActionTile(
          title: "ตั้งค่า",
          artwork: .settingsAction,
          accent: .white,
          compact: compact,
          emphasized: false
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("เปิดการตั้งค่าทั้งหมด")
      .accessibilityHint("ตั้งค่าการซ้อม กล้อง เสียง และดูข้อมูลการส่งภาพไปยัง Mac")
    }
  }

  private func practiceActionMenu(compact: Bool) -> some View {
    Menu {
      Menu("ไม้ที่ใช้: \(camera.practiceSettings.club.displayName)") {
        Picker("เลือกไม้กอล์ฟ", selection: clubBinding) {
          ForEach(GolfClub.allCases) { club in
            Text(club.displayName).tag(club)
          }
        }
      }

      Menu("มุมกล้อง: \(camera.practiceSettings.cameraView.displayName)") {
        Picker("เลือกมุมกล้อง", selection: cameraViewBinding) {
          ForEach(GolfCameraView.allCases) { cameraView in
            Text(cameraView.displayName).tag(cameraView)
          }
        }
      }

      Menu("เส้นช่วยดู: \(camera.practiceSettings.guideline.displayName)") {
        Picker("เลือกเส้นช่วยดู", selection: guidelineBinding) {
          ForEach(GolfGuideline.allCases) { guideline in
            Text(guideline.displayName).tag(guideline)
          }
        }
      }

      Menu("AI โปร: \(camera.practiceSettings.coach.displayName)") {
        Picker("เลือกโปรผู้ช่วย", selection: coachBinding) {
          ForEach(GolfCoachProfileID.allCases) { coach in
            Text(coach.displayName).tag(coach)
          }
        }
      }
    } label: {
      CameraActionTile(
        title: "การซ้อม",
        artwork: .practiceAction,
        accent: .white,
        compact: compact,
        emphasized: false
      )
    }
    .accessibilityLabel("ตั้งค่าการซ้อม")
    .accessibilityHint("เลือกไม้ มุมกล้อง เส้นช่วยดู และ AI โปร")
  }

  private var macStatusColor: Color {
    if camera.macStreamState.isStreaming {
      return CameraTheme.green
    }
    if case .failed = camera.macStreamState {
      return .red
    }
    return .orange
  }

  private var diagnosticsSheet: some View {
    NavigationStack {
      List {
        Section("การซ้อมครั้งนี้") {
          Picker("ไม้ที่ใช้", selection: clubBinding) {
            ForEach(GolfClub.allCases) { club in
              Text(club.displayName).tag(club)
            }
          }

          Picker("มุมกล้อง", selection: cameraViewBinding) {
            ForEach(GolfCameraView.allCases) { cameraView in
              Text(cameraView.displayName).tag(cameraView)
            }
          }

          Picker("เส้นช่วยดู", selection: guidelineBinding) {
            ForEach(GolfGuideline.allCases) { guideline in
              Text(guideline.displayName).tag(guideline)
            }
          }

          Picker("AI โปร", selection: coachBinding) {
            ForEach(GolfCoachProfileID.allCases) { coach in
              Text(coach.displayName).tag(coach)
            }
          }
        }

        Section("โหมดภาพความเร็วสูง") {
          if camera.availableProfiles.isEmpty {
            Text("ยังไม่พบโหมดภาพความเร็วสูงจากกล้องหลัง")
              .foregroundStyle(.secondary)
          } else {
            ForEach(camera.availableProfiles) { profile in
              Button {
                camera.selectProfile(profile)
              } label: {
                HStack(spacing: 12) {
                  Image(
                    systemName: isRequested(profile)
                      ? "checkmark.circle.fill"
                      : "circle"
                  )
                  .foregroundStyle(isRequested(profile) ? Color.green : Color.secondary)

                  VStack(alignment: .leading, spacing: 2) {
                    Text(profile.title)
                      .foregroundStyle(.primary)
                    Text(profile.displayText)
                      .font(.caption.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }

                  Spacer()
                }
              }
              .disabled(camera.state == .preparing || !camera.state.canStart)
              .accessibilityLabel(
                "\(profile.title) \(isRequested(profile) ? "เลือกอยู่" : "")"
              )
              .accessibilityHint("เลือกความละเอียดและจำนวนภาพต่อวินาทีของกล้องหลัง")
            }
          }

          Text("FPS หมายถึงจำนวนภาพต่อวินาที แนะนำ 1080p ที่ 120 ภาพต่อวินาที")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("ค่าที่ใช้งานจริง") {
          configurationRow(
            label: "ค่าที่เลือก",
            value: camera.requestedProfile?.displayText ?? "ให้ระบบเลือกอัตโนมัติ"
          )
          configurationRow(
            label: "กล้องใช้งาน",
            value: camera.activeConfiguration?.displayText ?? "กำลังรอตั้งค่ากล้อง"
          )
          configurationRow(
            label: "กล้องส่งจริง",
            value: frameRateText(camera.deliveredFrameRate)
          )
          configurationRow(
            label: "ส่งไป Mac",
            value: camera.macStreamState.isStreaming
              ? frameRateText(camera.macStreamMetrics.sentFramesPerSecond)
              : camera.macStreamState.title
          )
          configurationRow(
            label: "เฟรมตก",
            value:
              "กล้อง \(camera.droppedFrameCount) · "
              + "ส่งไม่ทัน \(camera.macStreamMetrics.transportDrops)"
          )

          if let requested = camera.requestedProfile,
            let active = camera.activeConfiguration
          {
            Label(
              active.matches(requested)
                ? "ความละเอียดและความเร็วตรงกับค่าที่เลือก"
                : "ค่าที่กล้องใช้งานยังไม่ตรงกับโหมดที่เลือก",
              systemImage: active.matches(requested)
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(active.matches(requested) ? Color.green : Color.orange)
          }
        }

        if !camera.rearCameraFormats.isEmpty {
          Section {
            DisclosureGroup(
              "รูปแบบกล้องหลังทั้งหมด \(camera.rearCameraFormats.count) แบบ",
              isExpanded: $isShowingFormatCatalog
            ) {
              ForEach(camera.rearCameraFormats) { format in
                VStack(alignment: .leading, spacing: 3) {
                  Text(format.resolutionText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                  Text(
                    format.capabilityText.isEmpty
                      ? "ไม่มีข้อมูลช่วงภาพต่อวินาที"
                      : format.capabilityText
                  )
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
              }
            }
          }
        }

        Section("เสียงระหว่างซ้อม") {
          Picker("เสียง AI Coach", selection: audioDeviceBinding) {
            Text("พูดที่ Mac").tag(GolfCoachAudioDevice.mac)
            Text("ปิดเสียง").tag(GolfCoachAudioDevice.muted)
          }

          Text(
            "เสียงวิเคราะห์และเสียงเตือนจะออกจาก Mac ซึ่งเป็นเครื่องประมวลผล "
              + "ส่วน iPhone ทำหน้าที่ส่งภาพ 120 FPS"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        Section("การทำงาน") {
          Text(
            "เปิดแอปนี้ค้างไว้ด้านหน้า ระบบจะเปิดกล้อง ค้นหา Mac และเชื่อมต่อใหม่ให้อัตโนมัติ ภาพไม่ถูกบันทึกลง iPhone"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)

          Text(
            "สาย USB-C ใช้ชาร์จไฟได้ แต่ภาพสดส่งผ่านเครือข่ายระหว่าง iPhone และ Mac"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
      .scrollContentBackground(.hidden)
      .background(Color.black)
      .navigationTitle("การตั้งค่าทั้งหมด")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("เสร็จแล้ว") {
            isShowingDiagnostics = false
          }
        }
      }
    }
    .preferredColorScheme(.dark)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var clubBinding: Binding<GolfClub> {
    Binding(
      get: { camera.practiceSettings.club },
      set: { camera.selectClub($0) }
    )
  }

  private var cameraViewBinding: Binding<GolfCameraView> {
    Binding(
      get: { camera.practiceSettings.cameraView },
      set: { camera.selectCameraView($0) }
    )
  }

  private var guidelineBinding: Binding<GolfGuideline> {
    Binding(
      get: { camera.practiceSettings.guideline },
      set: { camera.selectGuideline($0) }
    )
  }

  private var coachBinding: Binding<GolfCoachProfileID> {
    Binding(
      get: { camera.practiceSettings.coach },
      set: { camera.selectCoach($0) }
    )
  }

  private var audioDeviceBinding: Binding<GolfCoachAudioDevice> {
    Binding(
      get: { camera.practiceSettings.audioDevice },
      set: { camera.selectCoachAudioDevice($0) }
    )
  }

  private var isReady: Bool {
    camera.state == .running
      && camera.macStreamState.isStreaming
      && isHighSpeedFrameRate
  }

  private var isHighSpeedFrameRate: Bool {
    guard let rate = camera.deliveredFrameRate else { return false }
    return rate >= 100
  }

  private var isFrameRateDegraded: Bool {
    guard camera.state == .running,
      camera.macStreamState.isStreaming,
      let rate = camera.deliveredFrameRate,
      rate > 0
    else {
      return false
    }
    return rate < 100
  }

  private var frameRateStatusColor: Color {
    isFrameRateDegraded ? .orange : CameraTheme.blue
  }

  private var readinessTitle: String {
    if isReady {
      return "พร้อมส่งภาพ"
    }
    if isFrameRateDegraded {
      return "ความเร็วภาพต่ำ"
    }
    if camera.state == .running && camera.macStreamState.isStreaming {
      return "กำลังยืนยัน 120 FPS"
    }
    return mainStatus.title
  }

  private var readinessSubtitle: String {
    if isReady {
      return "ระบบจะจับวงให้อัตโนมัติ"
    }
    if isFrameRateDegraded {
      return "\(shortFrameRateText(camera.deliveredFrameRate)) · แตะเลือกโหมด 120 FPS"
    }
    if camera.state == .running && camera.macStreamState.isStreaming {
      return "รอค่าความเร็วภาพจริงจากกล้อง"
    }
    if let detail = camera.state.detail {
      return detail
    }
    if case .failed(let message) = camera.macStreamState {
      return message
    }
    return "แตะเพื่อ\(primaryActionTitle)"
  }

  private var primaryActionTitle: String {
    if camera.state != .running {
      return "เปิดกล้อง"
    }
    if isFrameRateDegraded {
      return "เลือกโหมด 120 FPS"
    }
    return "เชื่อมต่อ Mac"
  }

  private var macConnectionText: String {
    guard camera.macStreamState.isStreaming else {
      switch camera.macStreamState {
      case .discoveringMac: return "กำลังค้นหา"
      case .connecting: return "กำลังเชื่อม"
      case .failed: return "เชื่อมไม่สำเร็จ"
      case .stopped: return "ยังไม่เชื่อม"
      case .streaming: break
      }
      return "ยังไม่เชื่อม"
    }

    return "เชื่อมต่อ Mac แล้ว"
  }

  private var headerFrameRateText: String {
    if let delivered = camera.deliveredFrameRate, delivered > 0 {
      return "\(format(delivered)) FPS"
    }
    if let requested = camera.requestedProfile {
      return "\(format(requested.framesPerSecond)) FPS"
    }
    return "120 FPS"
  }

  private var compactDeliveredFrameRateText: String {
    guard let delivered = camera.deliveredFrameRate, delivered > 0 else {
      return "—"
    }
    return format(delivered)
  }

  private var mainStatus: MainStatus {
    switch camera.state {
    case .requestingPermission:
      return MainStatus(title: "กำลังขอสิทธิ์กล้อง", symbol: "camera.badge.clock", color: .orange)
    case .preparing:
      return MainStatus(title: "กำลังเตรียมกล้อง", symbol: "camera.fill", color: .orange)
    case .denied, .restricted:
      return MainStatus(title: "กล้องยังไม่ได้รับอนุญาต", symbol: "camera.fill", color: .red)
    case .unavailable, .failed:
      return MainStatus(title: "กล้องไม่พร้อม", symbol: "exclamationmark.triangle.fill", color: .red)
    case .idle, .stopped:
      return MainStatus(title: "รอเปิดกล้อง", symbol: "pause.circle.fill", color: .gray)
    case .running:
      break
    }

    if camera.macStreamState.isStreaming && isFrameRateDegraded {
      return MainStatus(
        title: "ภาพยังไม่ถึง 120 FPS",
        symbol: "exclamationmark.triangle.fill",
        color: .orange
      )
    }

    if camera.macStreamState.isStreaming && !isHighSpeedFrameRate {
      return MainStatus(
        title: "กำลังตรวจสอบ 120 FPS",
        symbol: "speedometer",
        color: CameraTheme.blue
      )
    }

    if camera.macStreamState.isStreaming {
      return MainStatus(
        title: "พร้อมซ้อม",
        symbol: "checkmark.circle.fill",
        color: CameraTheme.green
      )
    }

    switch camera.macStreamState {
    case .discoveringMac:
      return MainStatus(title: "กำลังหา Mac", symbol: "magnifyingglass", color: .orange)
    case .connecting:
      return MainStatus(title: "กำลังเชื่อม Mac", symbol: "link", color: .orange)
    case .failed:
      return MainStatus(
        title: "ส่งภาพไม่สำเร็จ",
        symbol: "exclamationmark.triangle.fill",
        color: .red
      )
    case .stopped:
      return MainStatus(title: "รอส่งภาพไป Mac", symbol: "arrow.up.right.video", color: .gray)
    case .streaming:
      return MainStatus(
        title: "พร้อมซ้อม",
        symbol: "checkmark.circle.fill",
        color: CameraTheme.green
      )
    }
  }

  private var recoveryAction: RecoveryAction? {
    switch camera.state {
    case .denied:
      return .openSettings
    case .restricted:
      return nil
    case .unavailable, .failed:
      return .restartCamera
    case .idle, .requestingPermission, .preparing, .running, .stopped:
      break
    }

    if case .failed = camera.macStreamState {
      return .reconnectMac
    }
    return nil
  }

  @ViewBuilder
  private func recoveryButton(_ action: RecoveryAction, compact: Bool) -> some View {
    Button {
      switch action {
      case .openSettings:
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
      case .restartCamera:
        camera.startPreview()
      case .reconnectMac:
        camera.startMacStream()
      }
    } label: {
      Label(action.title, systemImage: action.symbol)
        .font(compact ? .caption.weight(.bold) : .subheadline.weight(.bold))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 7 : 9)
        .padding(.horizontal, 10)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white)
    .background(.red.opacity(0.86), in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 1))
    .accessibilityHint(action.accessibilityHint)
  }

  private func configurationRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
    }
    .font(.subheadline)
    .accessibilityElement(children: .combine)
  }

  private func isRequested(_ profile: CameraService.CaptureProfile) -> Bool {
    camera.requestedProfile?.id == profile.id
  }

  private func frameRateText(_ value: Double?) -> String {
    guard let value, value > 0 else { return "กำลังวัด" }
    return "\(format(value)) ภาพ/วินาที"
  }

  private func shortFrameRateText(_ value: Double?) -> String {
    guard let value, value > 0 else { return "กำลังวัด" }
    return "\(format(value)) FPS"
  }

  private func format(_ value: Double) -> String {
    String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
  }
}

private struct SwingFramingGuide: View {
  let cameraView: GolfCameraView

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let isPortrait = size.height > size.width
      // กรอบนอกคือพื้นที่วงสวิงทั้งหมด ไม่ใช่กรอบลำตัว จึงต้องเกือบเต็มภาพ
      // ส่วนโครงผู้เล่นต้องเล็กพอให้เหลือพื้นที่สำหรับหัวไม้ตลอด backswing/follow-through
      let guideWidth = max(0, size.width * (isPortrait ? 0.98 : 0.97))
      let guideHeight = max(0, size.height * (isPortrait ? 0.96 : 0.98))
      let silhouetteHeight = guideHeight * (isPortrait ? 0.62 : 0.72)
      // ครอปขอบว่างของภาพต้นฉบับให้โครงร่างมีสัดส่วนเท่าผู้เล่นจริงในเฟรม
      let silhouetteAspect: CGFloat = cameraView == .faceOn ? 0.50 : 0.58

      ZStack {
        RoundedRectangle(cornerRadius: isPortrait ? 22 : 18, style: .continuous)
          .stroke(
            CameraTheme.green.opacity(0.78),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 9])
          )
          .frame(width: guideWidth, height: guideHeight)
          .shadow(color: .black.opacity(0.56), radius: 2)

        guideLines(size: CGSize(width: guideWidth, height: guideHeight))
          .stroke(
            CameraTheme.green.opacity(0.72),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 7])
          )
          .frame(width: guideWidth, height: guideHeight)
          .shadow(color: .black.opacity(0.65), radius: 2)

        GolferFramingSilhouette(cameraView: cameraView)
          .frame(
            width: min(silhouetteHeight * silhouetteAspect, guideWidth * 0.54),
            height: silhouetteHeight
          )
          .offset(y: guideHeight * (isPortrait ? 0.12 : 0.08))

        GuideCornerBrackets()
          .stroke(
            CameraTheme.blue,
            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
          )
          .frame(width: guideWidth, height: guideHeight)
          .shadow(color: .black.opacity(0.56), radius: 3)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .offset(y: isPortrait ? 8 : 0)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("กรอบเผื่อพื้นที่วงสวิงมุม\(cameraView.displayName)")
    .accessibilityHint("ถอยกล้องจนผู้เล่นอยู่ช่วงกลางล่างและหัวไม้ไม่หลุดกรอบตลอดวง")
  }

  private func guideLines(size: CGSize) -> Path {
    var path = Path()
    if cameraView == .faceOn {
      path.move(to: CGPoint(x: size.width / 2, y: size.height * 0.25))
      path.addLine(to: CGPoint(x: size.width / 2, y: size.height * 0.91))
      path.move(to: CGPoint(x: size.width * 0.06, y: size.height * 0.91))
      path.addLine(to: CGPoint(x: size.width * 0.94, y: size.height * 0.91))
    } else {
      path.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.91))
      path.addLine(to: CGPoint(x: size.width * 0.50, y: size.height * 0.24))
      path.move(to: CGPoint(x: size.width * 0.92, y: size.height * 0.91))
      path.addLine(to: CGPoint(x: size.width * 0.50, y: size.height * 0.24))
    }
    return path
  }
}

private struct GuideCornerBrackets: Shape {
  func path(in rect: CGRect) -> Path {
    let length = min(max(min(rect.width, rect.height) * 0.13, 22), 45)
    let radius = min(length * 0.30, 13)
    var path = Path()

    path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + radius, y: rect.minY),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

    path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + radius),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

    path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
      control: CGPoint(x: rect.maxX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

    path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - radius),
      control: CGPoint(x: rect.minX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))

    return path
  }
}

private struct PracticeContextItem: View {
  let value: String
  let artwork: CameraReferenceArtwork
  let compact: Bool

  var body: some View {
    if compact {
      HStack(spacing: 5) {
        CameraReferenceArtworkView(artwork: artwork, size: 24)
        Text(value)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.white.opacity(0.82))
          .lineLimit(1)
          .minimumScaleFactor(0.58)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .padding(.horizontal, 5)
      .contentShape(Rectangle())
    } else {
      VStack(spacing: 5) {
        CameraReferenceArtworkView(artwork: artwork, size: 36)
        Text(value)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.76))
          .lineLimit(1)
          .minimumScaleFactor(0.55)
      }
      .frame(maxWidth: .infinity, minHeight: 58)
      .padding(.horizontal, 3)
      .contentShape(Rectangle())
    }
  }
}

private struct CameraActionTile: View {
  let title: String
  let artwork: CameraReferenceArtwork
  let accent: Color
  let compact: Bool
  let emphasized: Bool

  var body: some View {
    Group {
      if compact {
        HStack(spacing: 5) {
          CameraReferenceArtworkView(artwork: artwork, size: 22)
          Text(title)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
        }
      } else {
        VStack(spacing: 5) {
          CameraReferenceArtworkView(artwork: artwork, size: 40)
          Text(title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
        }
      }
    }
    .foregroundStyle(accent)
    .frame(maxWidth: .infinity, minHeight: compact ? 44 : 75)
    .padding(.horizontal, compact ? 5 : 8)
    .background {
      let shape = RoundedRectangle(cornerRadius: compact ? 13 : 14, style: .continuous)
      ZStack {
        shape.fill(Color(red: 0.025, green: 0.055, blue: 0.10).opacity(0.90))
        if emphasized {
          shape.fill(CameraTheme.blue.opacity(0.08))
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: compact ? 13 : 14, style: .continuous)
        .stroke(
          emphasized ? CameraTheme.blue.opacity(0.88) : Color.white.opacity(0.14),
          lineWidth: 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: compact ? 13 : 14))
  }
}

private struct CameraGlassPanelModifier: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    content
      .background {
        ZStack {
          shape.fill(.ultraThinMaterial)
          shape.fill(Color(red: 0.025, green: 0.055, blue: 0.10).opacity(0.82))
        }
      }
      .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
      .shadow(color: .black.opacity(0.30), radius: 12, y: 6)
  }
}

private extension View {
  func cameraGlassPanel(cornerRadius: CGFloat) -> some View {
    modifier(CameraGlassPanelModifier(cornerRadius: cornerRadius))
  }
}

private struct MainStatus {
  let title: String
  let symbol: String
  let color: Color
}

private enum RecoveryAction {
  case openSettings
  case restartCamera
  case reconnectMac

  var title: String {
    switch self {
    case .openSettings:
      return "เปิดการตั้งค่าเพื่ออนุญาตกล้อง"
    case .restartCamera:
      return "ลองเปิดกล้องอีกครั้ง"
    case .reconnectMac:
      return "ลองเชื่อมต่อ Mac อีกครั้ง"
    }
  }

  var symbol: String {
    switch self {
    case .openSettings:
      return "gear"
    case .restartCamera:
      return "camera.fill"
    case .reconnectMac:
      return "arrow.clockwise"
    }
  }

  var accessibilityHint: String {
    switch self {
    case .openSettings:
      return "เปิดหน้าการตั้งค่าของ iPhone เพื่ออนุญาตให้แอปใช้กล้อง"
    case .restartCamera:
      return "ให้แอปตรวจและเปิดกล้องหลังใหม่"
    case .reconnectMac:
      return "ค้นหาและเชื่อมต่อแอปวิเคราะห์วงสวิงบน Mac ใหม่"
    }
  }
}

#Preview {
  ContentView(camera: CameraService())
}
