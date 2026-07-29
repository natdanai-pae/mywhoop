import Foundation
import SwiftUI

private enum VideoStageMode {
  case live
  case replay
}

private let golfTraceWindowCoordinateSpace = "GolfTraceWindow"
private let golfTraceReplayPaneTopInset: CGFloat = 64
private let golfTraceReplayPaneBottomInset: CGFloat = 84

struct GolfTraceReplayViewport {
  struct Layout: Equatable {
    let sourceCanvasSize: CGSize
    let renderedSize: CGSize
    let scale: CGFloat
  }

  static func aspectFit(aspectRatio: CGFloat?, in availableSize: CGSize) -> CGSize {
    guard let aspectRatio,
      aspectRatio.isFinite,
      aspectRatio > 0,
      availableSize.width > 0,
      availableSize.height > 0
    else {
      return availableSize
    }

    let availableAspectRatio = availableSize.width / availableSize.height
    if availableAspectRatio > aspectRatio {
      return CGSize(
        width: availableSize.height * aspectRatio,
        height: availableSize.height
      )
    }
    return CGSize(
      width: availableSize.width,
      height: availableSize.width / aspectRatio
    )
  }

  static func layout(
    recordedCanvasSize: CGSize?,
    videoAspectRatio: CGFloat?,
    in availableSize: CGSize
  ) -> Layout {
    if let recordedCanvasSize,
      recordedCanvasSize.width.isFinite,
      recordedCanvasSize.height.isFinite,
      recordedCanvasSize.width > 0,
      recordedCanvasSize.height > 0,
      availableSize.width > 0,
      availableSize.height > 0
    {
      // Never upscale a whole-window recording. Keeping its original point
      // canvas lets every fixed inset and control scale exactly as recorded.
      let scale = min(
        1,
        availableSize.width / recordedCanvasSize.width,
        availableSize.height / recordedCanvasSize.height
      )
      return Layout(
        sourceCanvasSize: recordedCanvasSize,
        renderedSize: CGSize(
          width: recordedCanvasSize.width * scale,
          height: recordedCanvasSize.height * scale
        ),
        scale: scale
      )
    }

    let renderedSize = aspectFit(
      aspectRatio: videoAspectRatio,
      in: availableSize
    )
    return Layout(
      sourceCanvasSize: renderedSize,
      renderedSize: renderedSize,
      scale: 1
    )
  }
}

private enum QuickControlTab: String, CaseIterable, Identifiable {
  case sources
  case camera
  case ai

  var id: Self { self }

  var title: String {
    switch self {
    case .sources: return "แหล่งภาพ"
    case .camera: return "กล้อง"
    case .ai: return "AI"
    }
  }

  var systemImage: String {
    switch self {
    case .sources: return "rectangle.split.2x1"
    case .camera: return "viewfinder"
    case .ai: return "waveform"
    }
  }
}

private struct ReplayViewportStage<Overlay: View>: View {
  @ObservedObject var playback: SwingReplayPlaybackController
  let overlay: Overlay

  @State private var recordedCanvasSize: CGSize?
  @State private var videoAspectRatio: CGFloat?

  init(
    playback: SwingReplayPlaybackController,
    @ViewBuilder overlay: () -> Overlay
  ) {
    _playback = ObservedObject(wrappedValue: playback)
    self.overlay = overlay()
    _recordedCanvasSize = State(initialValue: playback.recordedCanvasSize)
    _videoAspectRatio = State(initialValue: playback.videoAspectRatio)
  }

  var body: some View {
    GeometryReader { geometry in
      let layout = GolfTraceReplayViewport.layout(
        recordedCanvasSize: recordedCanvasSize,
        videoAspectRatio: videoAspectRatio,
        in: geometry.size
      )
      let center = CGPoint(
        x: geometry.size.width / 2,
        y: geometry.size.height / 2
      )

      ZStack {
        Color.black
          .ignoresSafeArea()

        SwingReplayView(playback: playback)
          .frame(width: layout.renderedSize.width, height: layout.renderedSize.height)
          .position(center)

        // Live mode records the timeline 46 points above the window bottom
        // (24 outer + 22 stage padding). Recreate that original point canvas,
        // then scale it together with the movie so the active controls cover
        // the baked controls even after the window is resized.
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          overlay
            .padding(.horizontal, 24)
            .padding(.bottom, 46)
        }
        .frame(
          width: layout.sourceCanvasSize.width,
          height: layout.sourceCanvasSize.height
        )
        .scaleEffect(layout.scale)
        .position(center)

        if playback.isPIPCompositionReady {
          VStack {
            HStack {
              Spacer(minLength: 0)
              HStack(spacing: 9) {
                Text(
                  playback.isRapsodoPrimary
                    ? "ภาพหลัก Rapsodo" : "ภาพหลัก กล้องวงสวิง"
                )
                .font(.caption.weight(.semibold))

                Button {
                  playback.togglePIPPrimary()
                } label: {
                  Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 30)
                    .background(GolfTraceTheme.blue.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("สลับภาพหลักระหว่าง Rapsodo กับกล้องวงสวิง")
                .accessibilityLabel("สลับภาพหลักระหว่าง Rapsodo กับกล้องวงสวิง")
              }
              .padding(.leading, 12)
              .padding(.trailing, 5)
              .frame(height: 40)
              .background(.ultraThinMaterial, in: Capsule())
              .background(Color.black.opacity(0.54), in: Capsule())
              .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
            }
            .padding(18)

            Spacer(minLength: 0)
          }
          .frame(width: layout.renderedSize.width, height: layout.renderedSize.height)
          .position(center)
        }
      }
    }
    .onReceive(playback.$recordedCanvasSize) { nextSize in
      guard recordedCanvasSize != nextSize else { return }
      recordedCanvasSize = nextSize
    }
    .onReceive(playback.$videoAspectRatio) { nextRatio in
      guard videoAspectRatio != nextRatio else { return }
      videoAspectRatio = nextRatio
    }
  }
}

private struct ReplayTimelineControls: View {
  @ObservedObject var playback: SwingReplayPlaybackController
  let isReplayStageActive: Bool
  let hasReplay: Bool
  let replayStatusText: String
  let canSaveReplay: Bool
  @Binding var isReplayPinned: Bool
  let onShowReplay: (_ autoPlay: Bool, _ pinned: Bool) -> Void
  let onReturnToLive: () -> Void
  let onSaveReplay: () -> Void
  let onOpenHistory: () -> Void

  var body: some View {
    let isReplayActive = isReplayStageActive && playback.hasPlayableItem
    let currentTime = isReplayActive ? playback.currentTime : 0
    let duration = isReplayActive ? playback.duration : 0

    HStack(spacing: 14) {
      Label("Timeline", systemImage: "archivebox")
        .font(.caption.weight(.bold))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

      Text(formatReplayTime(currentTime))
        .font(.caption.monospacedDigit())
        .foregroundStyle(GolfTraceTheme.mutedText)

      TimelineScrubber(
        isReady: isReplayActive && duration > 0,
        progress: Binding(
          get: {
            guard duration > 0 else { return 0 }
            return min(1, max(0, currentTime / duration))
          },
          set: { progress in
            guard duration > 0 else { return }
            playback.seek(to: progress * duration)
          }
        ),
        onEditingChanged: playback.setScrubbing
      )
      .frame(minWidth: 180, maxWidth: .infinity)

      Text(formatReplayTime(duration))
        .font(.caption.monospacedDigit())
        .foregroundStyle(GolfTraceTheme.mutedText)

      Button {
        guard hasReplay else { return }
        if isReplayActive {
          playback.togglePlayback()
        } else {
          onShowReplay(true, true)
        }
      } label: {
        Image(systemName: isReplayActive && playback.isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 38, height: 32)
      }
      .buttonStyle(.borderedProminent)
      .tint(GolfTraceTheme.blue)
      .help(replayStatusText)

      Button {
        guard hasReplay else { return }
        if isReplayActive {
          if isReplayPinned {
            isReplayPinned = false
            if playback.hasReachedEnd {
              onReturnToLive()
            }
          } else {
            isReplayPinned = true
          }
        } else {
          onShowReplay(false, true)
        }
      } label: {
        Image(systemName: isReplayPinned ? "bookmark.fill" : "bookmark")
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.bordered)
      .disabled(!hasReplay)

      Menu {
        Button("ภาพสด", systemImage: "dot.radiowaves.left.and.right") {
          onReturnToLive()
        }
        .disabled(!isReplayStageActive)

        Button("ภาพย้อนหลัง", systemImage: "play.rectangle") {
          guard hasReplay else { return }
          onShowReplay(false, true)
        }
        .disabled(!hasReplay)

        Divider()

        Button("ย้อน 1 เฟรม", systemImage: "backward.frame") {
          playback.step(by: -1)
        }
        .disabled(!isReplayActive)

        Button("เดินหน้า 1 เฟรม", systemImage: "forward.frame") {
          playback.step(by: 1)
        }
        .disabled(!isReplayActive)

        Menu("ความเร็วเล่น", systemImage: "gauge.with.dots.needle.33percent") {
          ForEach([Float(0.25), Float(0.5), Float(1)], id: \.self) { rate in
            Button {
              playback.setPlaybackRate(rate)
            } label: {
              if playback.selectedRate == rate {
                Label("\(rate, specifier: "%.2g")×", systemImage: "checkmark")
              } else {
                Text("\(rate, specifier: "%.2g")×")
              }
            }
          }
        }
        .disabled(!isReplayActive)

        Divider()

        Button("บันทึกวิดีโอ", systemImage: "square.and.arrow.down") {
          onSaveReplay()
        }
        .disabled(!canSaveReplay)

        Button("เปิดประวัติ", systemImage: "clock.arrow.circlepath") {
          onOpenHistory()
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 34, height: 30)
      }
      .buttonStyle(.bordered)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 15)
    .frame(maxWidth: 1_120)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
    .shadow(color: .black.opacity(0.42), radius: 14, y: 4)
  }

  private func formatReplayTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00.00" }
    let centiseconds = Int((seconds * 100).rounded(.down))
    let minutes = centiseconds / 6_000
    let remainingSeconds = (centiseconds / 100) % 60
    let remainder = centiseconds % 100
    return String(format: "%02d:%02d.%02d", minutes, remainingSeconds, remainder)
  }
}

struct ContentView: View {
  @StateObject private var camera = CameraCaptureModel()
  @StateObject private var swingCues = SwingCueCoordinator()
  @StateObject private var handsFreeVoice = HandsFreeVoiceCommandController()
  @StateObject private var handsFreeCapture = HandsFreeCaptureCoordinator()
  @StateObject private var screenEvidence = ScreenEvidenceRecorder()
  @StateObject private var rapsodoMirror = RapsodoScreenMirrorModel()
  @StateObject private var iphoneMirroring = IPhoneMirroringCaptureModel()
  @ObservedObject private var rapsodoReplayRecorder: RapsodoSourceReplayRecorder
  private let replayBundleWorkTracker: SwingReplayBundleWorkTracker
  // Keep the controller stable without forwarding its high-frequency
  // objectWillChange stream through the entire dashboard.
  @State private var replayPlayback = SwingReplayPlaybackController()
  @ObservedObject private var stageReplayRecorder: GolfTraceStageReplayRecorder
  @ObservedObject private var replay: SwingReplayController
  @ObservedObject private var history: SwingHistoryController
  @ObservedObject private var launchMonitor: LaunchMonitorController
  @ObservedObject private var rapsodoCredentials: RapsodoCredentialSettings
  @ObservedObject private var aiGolfPro: AIGolfProController
  @ObservedObject private var knowledge: GolfKnowledgeController
  @State private var stageMode: VideoStageMode = .live
  @State private var isReplayPinned = false
  @State private var isShowingSettings = false
  @State private var isShowingHistory = false
  @State private var isShowingQuickControls = false
  @State private var quickControlTab: QuickControlTab = .sources
  @State private var isPracticeModeEnabled = true
  @State private var isHandsFreeCaptureEnabled: Bool
  @State private var sourceSplitFraction: CGFloat = 0.64
  @State private var sourceSplitFractionAtDragStart: CGFloat = 0.64
  @State private var cameraPreviewZoom: CGFloat = 1
  @State private var cameraPreviewZoomAtGestureStart: CGFloat = 1
  @State private var cameraPreviewPan = CGSize.zero
  @State private var cameraPreviewPanAtGestureStart = CGSize.zero
  @State private var aiAnalysisTask: Task<Void, Never>?
  @State private var rapsodoReadinessTask: Task<Void, Never>?
  @State private var latestRecordID: UUID?
  @State private var didReceiveFreshRapsodoForTake = false
  @State private var didAnnounceRapsodoLossForTake = false
  /// One-take replays are opened only by their take-ID completion path, even
  /// when the hands-free setting changes while export is still finishing.
  @State private var handsFreeOwnedReplayRecordID: UUID?

  init(
    history: SwingHistoryController,
    replay: SwingReplayController,
    stageReplayRecorder: GolfTraceStageReplayRecorder,
    rapsodoReplayRecorder: RapsodoSourceReplayRecorder,
    replayBundleWorkTracker: SwingReplayBundleWorkTracker,
    launchMonitor: LaunchMonitorController,
    rapsodoCredentials: RapsodoCredentialSettings,
    aiGolfPro: AIGolfProController,
    knowledge: GolfKnowledgeController
  ) {
    _history = ObservedObject(wrappedValue: history)
    _replay = ObservedObject(wrappedValue: replay)
    _stageReplayRecorder = ObservedObject(wrappedValue: stageReplayRecorder)
    _rapsodoReplayRecorder = ObservedObject(wrappedValue: rapsodoReplayRecorder)
    self.replayBundleWorkTracker = replayBundleWorkTracker
    _launchMonitor = ObservedObject(wrappedValue: launchMonitor)
    _rapsodoCredentials = ObservedObject(wrappedValue: rapsodoCredentials)
    _aiGolfPro = ObservedObject(wrappedValue: aiGolfPro)
    _knowledge = ObservedObject(wrappedValue: knowledge)
    _isHandsFreeCaptureEnabled = State(
      initialValue: aiGolfPro.settings.handsFreeCaptureEnabled
    )
  }

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        topStatusBar

        ZStack {
          // คง preview/renderers ไว้ตลอด เพื่อให้ Rapsodo static frame และกล้อง
          // ไม่ต้อง reattach จนกลายเป็นจอดำเมื่อออกจาก History ไปเริ่มบันทึก
          videoStage
            .opacity(isShowingHistory ? 0 : 1)
            .allowsHitTesting(!isShowingHistory)
            .accessibilityHidden(isShowingHistory)

          if isShowingHistory {
            historyWorkspace
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 24)
      }
      .allowsHitTesting(!(stageMode == .replay && replay.replayURL != nil))
      .accessibilityHidden(stageMode == .replay && replay.replayURL != nil)

      if stageMode == .replay, replay.replayURL != nil {
        fullWindowReplayStage
          .transition(.opacity)
          .zIndex(100)
      }
    }
    .frame(minWidth: 1_080, minHeight: 680)
    .coordinateSpace(name: golfTraceWindowCoordinateSpace)
    .background(
      LinearGradient(
        colors: [GolfTraceTheme.canvas, Color(red: 0.035, green: 0.060, blue: 0.090)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
    )
    .preferredColorScheme(.dark)
    .onChange(of: camera.lastSwingSummary) { _, summary in
      guard let summary else { return }

      guard isPracticeModeEnabled,
        isHandsFreeCaptureEnabled,
        let handsFreeTakeID = handsFreeCapture.handleSwingCompleted()
      else {
        // Live analysis keeps running, but only an explicitly armed one-take
        // may create history, replay, or AI work. Turning hands-free off never
        // restores the old continuous auto-record behavior.
        return
      }

      isReplayPinned = false
      stageMode = .live

      let cueVolume: Float = 0
      if aiGolfPro.settings.guidelineCueEnabled,
        camera.highSpeedReceiver.practiceSettings.guideline != .none,
        let analysis = camera.lastSwingAnalysis
      {
        swingCues.handleSessionState(
          .completed,
          completedSummary: summary,
          volume: cueVolume,
          playCompletedCue: false
        )
        _ = swingCues.provideGuidelineFeedback(
          analysis: analysis,
          guideline: camera.highSpeedReceiver.practiceSettings.guideline,
          volume: cueVolume
        )
      } else {
        swingCues.handleSessionState(
          .completed,
          completedSummary: summary,
          volume: cueVolume,
          playCompletedCue: false
        )
      }

      let evidencePacket = camera.lastSwingEvidencePacket
      let captureSnapshot = evidencePacket.map(makeStoryboardCaptureSnapshot)
      guard
        let recordID = history.captureIfNeeded(
          summary,
          analysis: camera.lastSwingAnalysis,
          evidencePacket: evidencePacket,
          captureSnapshot: captureSnapshot
        )
      else {
        // A completed stage capture must never be left running when history is
        // unavailable (for example while the app is terminating).
        stageReplayRecorder.cancelUnfinishedRecording()
        rapsodoReplayRecorder.cancel()
        _ = handsFreeCapture.handleError(
          "บันทึกประวัติวงสวิงไม่สำเร็จ",
          for: handsFreeTakeID
        )
        return
      }
      latestRecordID = recordID
      if captureSnapshot?.sourceID == SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID {
        // Snapshot the rolling H.264 buffer before stage replay finalization or
        // subsequent swings can age these phase frames out of memory.
        history.materializeStoryboardKeyframes(
          for: recordID,
          summary: summary,
          using: camera.highSpeedReceiver,
          captureOrientation: captureSnapshot?.orientation ?? .unknown
        )
      }
      replay.registerReplayRequest(recordID: recordID)
      let replayCaptureOrientation =
        captureSnapshot?.orientation
        ?? SwingStoryboardCaptureOrientation(camera.videoOrientation)
      finalizeIndependentReplayBundle(
        summary: summary,
        recordID: recordID,
        captureOrientation: replayCaptureOrientation
      )
      finishStageReplayOrUseCameraFallback(
        summary: summary,
        recordID: recordID,
        hasCommittedStageCapture: true,
        captureOrientation: replayCaptureOrientation,
        handsFreeTakeID: handsFreeTakeID
      )
    }
    .onChange(of: replay.replayURL) { _, replayURL in
      guard let replayURL else {
        replayPlayback.unload()
        isReplayPinned = false
        stageMode = .live
        return
      }

      // replay ของวงก่อนอาจ export เสร็จช้าขณะเริ่มวงใหม่ ห้ามสลับมาบังภาพสด
      // In one-take mode only the take-ID completion path may open replay. A
      // late fallback from a cancelled/timed-out take is loaded but never shown.
      if let handsFreeOwnedReplayRecordID,
        handsFreeOwnedReplayRecordID == replay.replayRecordID
      {
        if stageMode == .live {
          loadReplay(replayURL, autoPlay: false)
        }
        return
      }

      if !isReplayPinned,
        !isHandsFreeStageBlockingReplay,
        camera.swingSessionState != .confirmingSwing,
        camera.swingSessionState != .swinging
      {
        showReplay(replayURL, autoPlay: true, pinned: false)
      } else {
        loadReplay(replayURL, autoPlay: false)
      }
    }
    .onChange(of: camera.swingSessionState) { _, state in
      if state == .confirmingSwing || state == .swinging {
        aiGolfPro.invalidateForSwing()
      }
      if state != .completed {
        swingCues.handleSessionState(
          state,
          completedSummary: nil,
          volume: aiGolfPro.settings.guidelineCueEnabled
            ? Float(aiGolfPro.settings.soundEffectsVolume) : 0
        )
      }
      handleStageCaptureTransition(to: state)
    }
    .onChange(of: isPracticeModeEnabled) { _, _ in
      if !isPracticeModeEnabled {
        cancelHandsFreeTake()
      }
      handleStageCaptureTransition(to: camera.swingSessionState)
    }
    .onReceive(aiGolfPro.settings.$handsFreeCaptureEnabled) { isEnabled in
      guard isHandsFreeCaptureEnabled != isEnabled else { return }
      isHandsFreeCaptureEnabled = isEnabled
      if isEnabled, mayStartVoiceListener {
        handsFreeVoice.start()
      } else {
        cancelHandsFreeTake()
        handsFreeVoice.stop()
      }
    }
    .onReceive(aiGolfPro.$state) { state in
      guard isHandsFreeCaptureEnabled else { return }
      if state.isUsingAudio {
        handsFreeVoice.suspend()
      } else if handsFreeVoice.isSuspended {
        handsFreeVoice.resume()
      }
    }
    .onReceive(rapsodoReplayRecorder.$isSourceFresh) { isFresh in
      guard rapsodoReplayRecorder.isRecording else { return }
      if isFresh {
        rapsodoReadinessTask?.cancel()
        rapsodoReadinessTask = nil
        didReceiveFreshRapsodoForTake = true
        return
      }
      guard didReceiveFreshRapsodoForTake,
        !didAnnounceRapsodoLossForTake
      else { return }
      didAnnounceRapsodoLossForTake = true
      handsFreeVoice.speakFeedback("Rapsodo หลุด กำลังเก็บกล้องต่อ")
    }
    .onAppear {
      configureHandsFreeCapture()
      let sourceReplayRecorder = rapsodoReplayRecorder
      iphoneMirroring.setReplaySampleHandler { [weak sourceReplayRecorder] sample in
        sourceReplayRecorder?.append(sample)
      }
      rapsodoMirror.setReplaySampleHandler { [weak sourceReplayRecorder] sample in
        sourceReplayRecorder?.append(sample)
      }
      replay.recoverPendingPersistence { pendingReplay in
        attachReplay(
          pendingReplay.url,
          to: pendingReplay.recordID,
          stagePaneLayout: pendingReplay.stagePaneLayout
        )
      }
      // K is the dedicated Rapsodo display. Keep its USB screen feed ready so
      // the user never has to juggle two phone screens during a session.
      rapsodoMirror.startAutomatic()
    }
    .onDisappear {
      aiAnalysisTask?.cancel()
      rapsodoReadinessTask?.cancel()
      rapsodoReadinessTask = nil
      _ = handsFreeCapture.cancel()
      stageReplayRecorder.cancelUnfinishedRecording()
      // Discard only an unfinished take. A recorder that is already finishing
      // belongs to the app-level work tracker and must survive view teardown.
      rapsodoReplayRecorder.prepareForTermination()
      iphoneMirroring.setReplaySampleHandler(nil)
      rapsodoMirror.setReplaySampleHandler(nil)
      handsFreeCapture.eventHandler = nil
      handsFreeVoice.onCommand = nil
      handsFreeVoice.stop()
      replayPlayback.unload()
      aiGolfPro.cancelAllActivity()
      swingCues.cancelAllCues()
      iphoneMirroring.stop()
      rapsodoMirror.stop()
    }
    .sheet(isPresented: $isShowingSettings) {
      settingsSheet
    }
    .popover(isPresented: $isShowingQuickControls, arrowEdge: .top) {
      quickControlsPopover
    }
  }

  private var topStatusBar: some View {
    let captureStatus = HandsFreeCaptureStatusPresentation.make(
      captureState: handsFreeCapture.state,
      voiceStatus: handsFreeVoice.status,
      voiceError: handsFreeVoice.errorMessage,
      isEnabled: isHandsFreeCaptureEnabled,
      isAskingAI: aiGolfPro.state.isUsingAudio
    )
    let isRecordingRapsodo = rapsodoReplayRecorder.isRecording
    let isRecordingBothSources = isRecordingRapsodo && rapsodoReplayRecorder.isSourceFresh
    let isRecordingWithStaleRapsodo = isRecordingRapsodo && !isRecordingBothSources
    let isWaitingWithoutRapsodo =
      handsFreeCapture.isActive && activeRapsodoReplaySession == nil
    let statusTitle =
      isRecordingBothSources
      ? "กำลังบันทึก 2 แหล่ง"
      : isRecordingWithStaleRapsodo ? "กำลังบันทึกกล้อง" : captureStatus.title
    let statusDetail: String
    if isRecordingBothSources {
      statusDetail = "กล้อง พร้อม • Rapsodo พร้อม"
    } else if isRecordingWithStaleRapsodo {
      statusDetail =
        didReceiveFreshRapsodoForTake
        ? "Rapsodo หลุด · เก็บกล้องต่อ"
        : "กำลังรอภาพ Rapsodo · เก็บกล้องต่อ"
    } else if isWaitingWithoutRapsodo {
      statusDetail = "\(captureStatus.detail) • Rapsodo ไม่พร้อม · จะเก็บกล้อง"
    } else {
      statusDetail = captureStatus.detail
    }
    return DashboardHeader(
      isPracticeModeEnabled: $isPracticeModeEnabled,
      isAIRecording: aiGolfPro.isRecording,
      hasStoredAPIKey: aiGolfPro.settings.hasStoredAPIKey,
      isAIBusy: aiGolfPro.state.isBusy || handsFreeCapture.isActive,
      captureStatusTitle: statusTitle,
      captureStatusDetail: statusDetail,
      captureStatusSystemImage: isRecordingRapsodo
        ? "record.circle.fill" : captureStatus.systemImage,
      captureStatusTint: isRecordingRapsodo ? .red : captureStatus.tint,
      isCaptureStatusActive: captureStatus.isActive || isRecordingRapsodo,
      isCaptureActionEnabled: captureStatus.isActionEnabled,
      onToggleAI: toggleCompactVoiceQuestion,
      onToggleCapture: toggleHandsFreeTake,
      onCaptureScreen: { screenEvidence.capturePrimaryDisplay() },
      onOpenControls: {
        guard !isHandsFreeStageBlockingReplay else { return }
        isShowingQuickControls.toggle()
      }
    )
  }
  private var videoStage: some View {
    ZStack(alignment: .bottom) {
      GeometryReader { geometry in
        let dividerWidth: CGFloat = 20
        let availableWidth = max(1, geometry.size.width - dividerWidth)
        let rapsodoWidth = availableWidth * sourceSplitFraction
        let cameraWidth = availableWidth - rapsodoWidth
        let cameraSize = CGSize(width: cameraWidth, height: geometry.size.height)
        let stageFrame = geometry.frame(in: .named(golfTraceWindowCoordinateSpace))
        let replayPaneHeight = max(
          1,
          stageFrame.height - golfTraceReplayPaneTopInset - golfTraceReplayPaneBottomInset
        )
        let canvasSize = CGSize(
          width: stageFrame.maxX + 24,
          height: stageFrame.maxY + 24
        )
        let paneLayout = GolfTraceStagePaneLayout(
          rapsodoFrame: CGRect(
            x: stageFrame.minX,
            y: stageFrame.minY + golfTraceReplayPaneTopInset,
            width: rapsodoWidth,
            height: replayPaneHeight
          ),
          swingCameraFrame: CGRect(
            x: stageFrame.minX + rapsodoWidth + dividerWidth,
            y: stageFrame.minY + golfTraceReplayPaneTopInset,
            width: cameraWidth,
            height: replayPaneHeight
          ),
          canvasSize: canvasSize
        )

        HStack(spacing: 0) {
          RapsodoMirrorStage(
            iphoneMirroring: iphoneMirroring,
            usbMirror: rapsodoMirror
          )
          .frame(width: rapsodoWidth, height: geometry.size.height)

          sourceResizeDivider(in: geometry.size)
            .zIndex(10)
            .allowsHitTesting(!isStagePaneLayoutLocked)

          ZStack {
            LiveVideoStage(
              camera: camera,
              receiver: camera.highSpeedReceiver
            )
            .scaleEffect(cameraPreviewZoom)
            .offset(cameraPreviewPan)

            if case .countdown(let value) = handsFreeCapture.state {
              HandsFreeCountdownOverlay(
                value: value,
                usesTempo: aiGolfPro.settings.tempoCueEnabled
              )
              .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
          }
          .frame(width: cameraWidth, height: geometry.size.height)
          .clipShape(RoundedRectangle(cornerRadius: 14))
          .allowsHitTesting(!isStagePaneLayoutLocked)
          .simultaneousGesture(cameraPanGesture(in: cameraSize))
          .simultaneousGesture(cameraZoomGesture(in: cameraSize))
          .overlay(alignment: .topTrailing) {
            cameraViewportControls(in: cameraSize)
              .padding(18)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: paneLayout) {
          stageReplayRecorder.updatePaneLayout(paneLayout)
        }
      }

      bottomVideoOverlay
        .padding(.bottom, 22)
    }
  }

  private var isStagePaneLayoutLocked: Bool {
    stageReplayRecorder.isPreparing || stageReplayRecorder.isRecording
  }

  /// The replay movie is a WindowServer-composited recording of the complete
  /// GolfTrace window, not a second player embedded inside the camera pane.
  /// The active shared timeline sits over the timeline baked into that movie.
  private var fullWindowReplayStage: some View {
    ReplayViewportStage(playback: replayPlayback) {
      GeometryReader { geometry in
        VStack(spacing: 8) {
          AdaptivePhaseStrip(
            source: adaptivePhaseSource,
            evidence: adaptivePhaseEvidence,
            onSeek: { replayPlayback.seek(to: $0) }
          )
          .frame(width: min(1_560, geometry.size.width * 0.96))

          // Match the live overlay's exact width rule so these controls still
          // cover the timeline baked into the whole-window recording.
          floatingTimelineControls
            .frame(width: min(1_120, geometry.size.width * 0.73))
        }
        .frame(
          width: geometry.size.width,
          height: geometry.size.height,
          alignment: .bottom
        )
      }
      .frame(height: 284)
    }
  }

  private var bottomVideoOverlay: some View {
    GeometryReader { geometry in
      floatingTimelineControls
        .frame(width: min(1_120, geometry.size.width * 0.73))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    .frame(height: 62)
  }

  private func sourceResizeDivider(in stageSize: CGSize) -> some View {
    ZStack {
      Rectangle()
        .fill(GolfTraceTheme.blue.opacity(0.22))
        .frame(width: 1)

      VStack {
        Spacer()

        Image(systemName: "arrow.left.and.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white.opacity(0.88))
          .frame(width: 36, height: 36)
          .background(GolfTraceTheme.panel.opacity(0.98), in: Circle())
          .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 1))
          .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
          .offset(y: -36)

        Spacer()
      }
    }
    .frame(width: 20)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { value in
          let availableWidth = max(1, stageSize.width - 20)
          sourceSplitFraction = min(
            0.84,
            max(0.40, sourceSplitFractionAtDragStart + value.translation.width / availableWidth)
          )
        }
        .onEnded { _ in
          sourceSplitFractionAtDragStart = sourceSplitFraction
        }
    )
    .accessibilityLabel("ปรับขนาดภาพ Rapsodo และกล้อง")
    .accessibilityHint("ลากซ้ายหรือขวาเพื่อปรับพื้นที่ของ iPhone ทั้งสองเครื่อง")
  }

  private func cameraPanGesture(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        cameraPreviewPan = clampedCameraPan(
          CGSize(
            width: cameraPreviewPanAtGestureStart.width + value.translation.width,
            height: cameraPreviewPanAtGestureStart.height + value.translation.height
          ),
          in: size
        )
      }
      .onEnded { _ in
        cameraPreviewPanAtGestureStart = cameraPreviewPan
      }
  }

  private func cameraZoomGesture(in size: CGSize) -> some Gesture {
    MagnificationGesture()
      .onChanged { value in
        cameraPreviewZoom = min(3, max(1, cameraPreviewZoomAtGestureStart * value))
        cameraPreviewPan = clampedCameraPan(cameraPreviewPan, in: size)
      }
      .onEnded { _ in
        cameraPreviewZoomAtGestureStart = cameraPreviewZoom
        cameraPreviewPanAtGestureStart = cameraPreviewPan
      }
  }

  private func clampedCameraPan(_ candidate: CGSize, in size: CGSize) -> CGSize {
    let limitX = max(0, (cameraPreviewZoom - 1) * size.width * 0.5)
    let limitY = max(0, (cameraPreviewZoom - 1) * size.height * 0.5)
    return CGSize(
      width: min(limitX, max(-limitX, candidate.width)),
      height: min(limitY, max(-limitY, candidate.height))
    )
  }

  private func cameraViewportControls(in size: CGSize) -> some View {
    HStack(spacing: 0) {
      Image(systemName: "minus.magnifyingglass")
        .frame(width: 26, height: 28)

      Menu {
        ForEach([CGFloat(1), 1.25, 1.5, 2, 2.5, 3], id: \.self) { zoom in
          Button(String(format: "%.1fx", zoom)) {
            cameraPreviewZoom = zoom
            cameraPreviewZoomAtGestureStart = zoom
            cameraPreviewPan = clampedCameraPan(cameraPreviewPan, in: size)
            cameraPreviewPanAtGestureStart = cameraPreviewPan
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(String(format: "%.1fx", cameraPreviewZoom))
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.bold))
        }
        .frame(width: 52, height: 28)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
      }
      .menuStyle(.borderlessButton)

      Divider()
        .frame(height: 20)

      Button {
        camera.toggleVideoHalfTurn()
      } label: {
        Image(systemName: "rotate.right")
          .foregroundStyle(
            camera.videoHalfTurn.isEnabled ? GolfTraceTheme.blue : Color.white.opacity(0.88)
          )
          .frame(width: 28, height: 28)
          .background(
            camera.videoHalfTurn.isEnabled
              ? GolfTraceTheme.blue.opacity(0.13) : Color.clear,
            in: Circle()
          )
          .overlay(
            Circle()
              .stroke(
                camera.videoHalfTurn.isEnabled
                  ? GolfTraceTheme.blue.opacity(0.92) : Color.clear,
                lineWidth: 1
              )
          )
      }
      .buttonStyle(.plain)
      .help(
        camera.videoHalfTurn.isEnabled
          ? "กำลังแก้ภาพกลับหัว 180° · กดเพื่อใช้มุมจาก iPhone โดยตรง"
          : "กลับภาพและโครงกระดูก 180°"
      )
      .accessibilityLabel("แก้ภาพกลับหัว 180 องศา")
      .accessibilityValue(camera.videoHalfTurn.isEnabled ? "เปิด" : "ปิด")

      Divider()
        .frame(height: 20)

      Button {
        cameraPreviewZoom = 1
        cameraPreviewZoomAtGestureStart = 1
        cameraPreviewPan = .zero
        cameraPreviewPanAtGestureStart = .zero
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
    }
    .font(.caption.weight(.semibold))
    .padding(3)
    .frame(width: 172, height: 36)
    .background(.black.opacity(0.72), in: Capsule())
    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    .help("Pinch เพื่อ zoom และลากภาพเพื่อ crop จัดกรอบดูบน Mac")
  }

  private func toggleCompactVoiceQuestion() {
    if aiGolfPro.isRecording {
      screenEvidence.capturePrimaryDisplay()
      aiGolfPro.finishQuestionRecording(
        practiceSettings: camera.highSpeedReceiver.practiceSettings,
        summary: camera.lastSwingSummary,
        analysis: camera.lastSwingAnalysis,
        evidencePacket: camera.lastSwingEvidencePacket,
        launch: matchedLatestShot
      )
    } else {
      guard !handsFreeCapture.isActive else {
        handsFreeVoice.speakFeedback("กำลังบันทึกวงอยู่ ถาม AI ได้หลังรีเพลย์พร้อม")
        return
      }
      if isHandsFreeCaptureEnabled {
        handsFreeVoice.suspend()
      }
      aiGolfPro.startQuestionRecording()
    }
  }

  private var isHandsFreeStageBlockingReplay: Bool {
    guard isHandsFreeCaptureEnabled else { return false }
    switch handsFreeCapture.state {
    case .acknowledged, .countdown, .armed, .capturing, .finalizing:
      return true
    case .timedOut(.finalizing):
      return true
    case .listening, .replayReady, .cancelled, .timedOut, .error:
      return false
    }
  }

  private var isSwingCameraReady: Bool {
    if usesDirectIPhoneInput {
      return camera.highSpeedReceiver.state == .connected
        && camera.highSpeedReceiver.metrics.decodedFrames > 0
    }
    return camera.isRunning && camera.frameMetrics.receivedFrames > 0
  }

  private func configureHandsFreeCapture() {
    handsFreeCapture.eventHandler = { event in
      handleHandsFreeCaptureEvent(event)
    }
    handsFreeVoice.onCommand = { command in
      handleHandsFreeVoiceCommand(command)
    }
    if isHandsFreeCaptureEnabled, mayStartVoiceListener {
      handsFreeVoice.start()
    }
  }

  /// XCTest hosts the real app bundle, but must not open CoreAudio hardware just
  /// to run model/store tests. On some Macs AVAudioEngine can wait indefinitely
  /// for a sleeping Continuity microphone before XCTest materializes its worker.
  private var mayStartVoiceListener: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
  }

  private func handleHandsFreeVoiceCommand(_ command: HandsFreeVoiceCommand) {
    switch command {
    case .startSwing:
      startHandsFreeTake()
    case .cancel:
      if isHandsFreeReplayFinalizing {
        handsFreeVoice.speakFeedback("บันทึกวงแล้ว ระบบกำลังเก็บรีเพลย์ กรุณารอสักครู่")
      } else if !cancelHandsFreeTake() {
        handsFreeVoice.speakFeedback("ยังไม่มีวงที่กำลังบันทึก")
      }
    }
  }

  private func toggleHandsFreeTake() {
    if handsFreeCapture.isActive {
      if isHandsFreeReplayFinalizing {
        handsFreeVoice.speakFeedback("บันทึกวงแล้ว ระบบกำลังเก็บรีเพลย์ กรุณารอสักครู่")
      } else {
        _ = cancelHandsFreeTake()
      }
    } else {
      startHandsFreeTake()
    }
  }

  private var isHandsFreeReplayFinalizing: Bool {
    switch handsFreeCapture.state {
    case .finalizing, .timedOut(.finalizing):
      return true
    case .listening, .acknowledged, .countdown, .armed, .capturing, .replayReady,
      .cancelled, .timedOut, .error:
      return false
    }
  }

  private func startHandsFreeTake() {
    guard isHandsFreeCaptureEnabled else { return }
    guard isPracticeModeEnabled else {
      handsFreeVoice.speakFeedback("กรุณาเปิดโหมดฝึกซ้อมก่อน")
      return
    }
    guard !stageReplayRecorder.hasPendingWork else {
      handsFreeVoice.speakFeedback("กำลังสร้างรีเพลย์วงก่อน กรุณารอสักครู่")
      return
    }
    guard !rapsodoReplayRecorder.hasPendingWork else {
      handsFreeVoice.speakFeedback("กำลังปิดไฟล์ Rapsodo วงก่อน กรุณารอสักครู่")
      return
    }
    guard isSwingCameraReady else {
      handsFreeVoice.speakFeedback("ยังไม่ได้รับภาพจากไอโฟนกล้อง กรุณาเปิดกล้องก่อน")
      return
    }
    switch camera.swingSessionState {
    case .confirmingSwing, .swinging, .completed:
      handsFreeVoice.speakFeedback("กล้องกำลังตรวจวงเดิม รอให้นิ่งแล้วสั่งอีกครั้ง")
      return
    case .waitingForStillness, .armed:
      break
    }

    guard
      handsFreeCapture.startOneTake(
        tempoEnabled: aiGolfPro.settings.tempoCueEnabled
      ) != nil
    else {
      handsFreeVoice.speakFeedback("กำลังทำงานกับวงนี้อยู่")
      return
    }
  }

  @discardableResult
  private func cancelHandsFreeTake() -> Bool {
    handsFreeCapture.cancel()
  }

  private func handleHandsFreeCaptureEvent(_ event: HandsFreeCaptureEvent) {
    switch event {
    case .stopSpeech:
      handsFreeVoice.stopSpeakingFeedback()

    case .speak(let cue, _):
      handsFreeVoice.speakFeedback(handsFreeSpeech(for: cue))

    case .prepareStageRecording:
      prepareLiveStageForSwing()

    case .startStageRecording:
      stageReplayRecorder.startIfNeeded()
      startIndependentRapsodoRecordingIfAvailable()

    case .cancelStageRecording:
      stageReplayRecorder.cancelRecording()
      rapsodoReplayRecorder.cancel()

    case .startTempo:
      swingCues.startTempoTrainer(
        volume: Float(aiGolfPro.settings.soundEffectsVolume),
        preserveDuringActiveSwing: true
      )

    case .cancelTempo:
      swingCues.cancelAllCues()
    }
  }

  private func handsFreeSpeech(for cue: HandsFreeCaptureSpeechCue) -> String {
    switch cue {
    case .acknowledged:
      return HandsFreeVoiceCommand.startSwing.feedbackText
    case .countdown(let value):
      switch value {
      case 3: return "สาม"
      case 2: return "สอง"
      case 1: return "หนึ่ง"
      default: return "\(value)"
      }
    case .cancelled:
      return HandsFreeVoiceCommand.cancel.feedbackText
    case .timedOut(let reason):
      switch reason {
      case .waitingForSwing:
        return "ยังไม่พบวง ยกเลิกการบันทึกแล้ว"
      case .capturing:
        return "วงใช้เวลานานเกินไป ยกเลิกการบันทึกแล้ว"
      case .finalizing:
        return "รีเพลย์ใช้เวลานานกว่าปกติ ระบบยังเก็บไฟล์อยู่"
      }
    case .finalizing:
      return "บันทึกวงแล้ว กำลังสร้างรีเพลย์"
    case .replayReady:
      return "บันทึกแล้ว กำลังเปิดรีเพลย์ พร้อมตีวงถัดไป"
    case .error(let message):
      return message
    }
  }

  private var quickControlsPopover: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("ควบคุมการซ้อม")
            .font(.headline)
          Text("ปรับเฉพาะสิ่งที่จำเป็นระหว่างตี")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          isShowingQuickControls = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("ปิดเมนูควบคุม")
      }

      Picker("หมวดควบคุม", selection: $quickControlTab) {
        ForEach(QuickControlTab.allCases) { tab in
          Label(tab.title, systemImage: tab.systemImage).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      Group {
        switch quickControlTab {
        case .sources:
          quickSourcesPanel
        case .camera:
          quickCameraPanel
        case .ai:
          quickAIPanel
        }
      }

      Divider()

      HStack {
        Text("การตั้งค่ารายละเอียดอยู่ในเมนูขั้นสูง")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("ประวัติ", systemImage: "clock.arrow.circlepath") {
          openHistoryWorkspace()
        }
        .buttonStyle(.bordered)

        Button("ขั้นสูง", systemImage: "slider.horizontal.3") {
          isShowingQuickControls = false
          isShowingSettings = true
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(16)
    .frame(width: 480)
  }

  private var quickSourcesPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      quickControlCard(
        title: "Rapsodo MLM2Pro",
        detail: rapsodoSourceStatus,
        icon: "iphone.gen3.radiowaves.left.and.right",
        color: (iphoneMirroring.isRunning || rapsodoMirror.isRunning) ? .green : .orange
      ) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Button(
              rapsodoMirror.isRunning ? "หยุด K · USB" : "เชื่อม K · USB",
              systemImage: rapsodoMirror.isRunning ? "stop.fill" : "cable.connector"
            ) {
              if rapsodoMirror.isRunning {
                rapsodoMirror.stop()
              } else {
                iphoneMirroring.stop()
                rapsodoMirror.startAutomatic()
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(rapsodoMirror.isRunning ? .red : GolfTraceTheme.blue)
            .disabled(rapsodoMirror.isBusy)

            Button("ค้นหา USB ใหม่", systemImage: "arrow.clockwise") {
              rapsodoMirror.refreshDevices()
            }
            .buttonStyle(.bordered)
            .disabled(rapsodoMirror.isBusy)

            Spacer()
          }

          if rapsodoMirror.devices.count > 1 {
            Picker("เครื่อง Rapsodo", selection: $rapsodoMirror.selectedDeviceID) {
              ForEach(rapsodoMirror.devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(Optional(device.uniqueID))
              }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 280, alignment: .leading)
          }

          HStack {
            Text("ทางสำรอง")
              .font(.caption2)
              .foregroundStyle(.secondary)

            Button(
              iphoneMirroring.isRunning ? "หยุด Apple Mirroring" : "ใช้ Apple Mirroring"
            ) {
              if iphoneMirroring.isRunning {
                iphoneMirroring.stop()
              } else {
                rapsodoMirror.stop()
                iphoneMirroring.startAutomatically()
              }
            }
            .buttonStyle(.bordered)
            .disabled(iphoneMirroring.isBusy)

            Button("ค้นหาหน้าต่างใหม่", systemImage: "rectangle.on.rectangle") {
              iphoneMirroring.refreshWindows()
            }
            .buttonStyle(.bordered)
            .disabled(iphoneMirroring.isBusy)

            Spacer()
          }
        }
      } footer: {
        Label(
          "USB เป็นทางหลักสำหรับ K ต่างบัญชี; แอปรับเฉพาะภาพมาแสดง ไม่อ่านค่าหรือควบคุม Rapsodo",
          systemImage: "eye.slash"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      quickControlCard(
        title: "กล้องวงสวิง",
        detail: camera.highSpeedReceiver.state.title,
        icon: "video.fill",
        color: highSpeedSourceColor
      ) {
        HStack {
          Button(
            camera.highSpeedReceiver.state == .stopped ? "เปิดรับภาพ" : "หยุดรับภาพ",
            systemImage: camera.highSpeedReceiver.state == .stopped ? "play.fill" : "stop.fill"
          ) {
            if camera.highSpeedReceiver.state == .stopped {
              camera.startHighSpeedInput()
            } else {
              camera.stopHighSpeedInput()
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(camera.highSpeedReceiver.state == .stopped ? GolfTraceTheme.blue : .red)

          Text(camera.highSpeedReceiver.metrics.fpsText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

          Spacer()
        }
      }
    }
  }

  private var rapsodoSourceStatus: String {
    if rapsodoMirror.isRunning || rapsodoMirror.isBusy || !rapsodoMirror.devices.isEmpty {
      return rapsodoMirror.status
    }
    if iphoneMirroring.isRunning || iphoneMirroring.isBusy {
      return iphoneMirroring.status
    }
    return rapsodoMirror.status
  }

  private var quickCameraPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("จัดกรอบภาพ iPhone 2 บน Mac", systemImage: "crop")
        .font(.subheadline.weight(.semibold))

      HStack(spacing: 10) {
        Text("ขนาดพื้นที่")
          .font(.caption)
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { sourceSplitFraction },
            set: {
              sourceSplitFraction = min(0.84, max(0.40, $0))
              sourceSplitFractionAtDragStart = sourceSplitFraction
            }
          ),
          in: 0.40...0.84
        )
        Text("\(Int((sourceSplitFraction * 100).rounded()))%")
          .font(.caption.monospacedDigit())
          .frame(width: 34, alignment: .trailing)
      }

      HStack(spacing: 8) {
        Button {
          cameraPreviewZoom = max(1, cameraPreviewZoom - 0.25)
          cameraPreviewZoomAtGestureStart = cameraPreviewZoom
          cameraPreviewPan = .zero
          cameraPreviewPanAtGestureStart = .zero
        } label: {
          Image(systemName: "minus.magnifyingglass")
        }
        .buttonStyle(.bordered)
        .disabled(cameraPreviewZoom <= 1)

        Text("Zoom \(Int((cameraPreviewZoom * 100).rounded()))%")
          .font(.caption.monospacedDigit())
          .frame(minWidth: 82)

        Button {
          cameraPreviewZoom = min(3, cameraPreviewZoom + 0.25)
          cameraPreviewZoomAtGestureStart = cameraPreviewZoom
        } label: {
          Image(systemName: "plus.magnifyingglass")
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("จัดกรอบ", systemImage: "arrow.counterclockwise") {
          cameraPreviewZoom = 1
          cameraPreviewZoomAtGestureStart = 1
          cameraPreviewPan = .zero
          cameraPreviewPanAtGestureStart = .zero
        }
        .buttonStyle(.bordered)
      }

      HStack {
        Button("หมุน 180°", systemImage: "rotate.right") {
          camera.toggleVideoHalfTurn()
        }
        .buttonStyle(.bordered)

        Spacer()

        Text("Pinch/ลากบนภาพเพื่อ zoom และ crop")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Label(
        "การจัดกรอบนี้เปลี่ยนเฉพาะภาพที่ดูบน Mac ไม่ได้สั่งโฟกัสหรือเลนส์ iPhone",
        systemImage: "info.circle"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
  }

  private var quickAIPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(
        "สั่งด้วยเสียงแล้วบันทึกหนึ่งวง",
        isOn: Binding(
          get: { aiGolfPro.settings.handsFreeCaptureEnabled },
          set: { aiGolfPro.settings.handsFreeCaptureEnabled = $0 }
        )
      )
      .toggleStyle(.switch)

      HStack {
        Button(
          handsFreeCapture.isActive ? "ยกเลิกวงนี้" : "เริ่มหนึ่งวง",
          systemImage: handsFreeCapture.isActive ? "xmark.circle" : "record.circle"
        ) {
          toggleHandsFreeTake()
        }
        .buttonStyle(.bordered)
        .disabled(!isHandsFreeCaptureEnabled)

        Text("พูด “กอล์ฟเทรซ เริ่มวง” หรือกด Space")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
      }

      Divider()

      HStack(spacing: 10) {
        Image(systemName: aiGolfPro.isRecording ? "waveform" : "waveform.and.person.filled")
          .font(.title2)
          .foregroundStyle(aiGolfPro.isRecording ? .red : GolfTraceTheme.blue)
        VStack(alignment: .leading, spacing: 2) {
          Text(aiGolfPro.state.title)
            .font(.subheadline.weight(.semibold))
          Text(
            aiGolfPro.latestTranscript.isEmpty ? "พร้อมรับคำถามด้วยเสียง" : aiGolfPro.latestTranscript
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        }
      }

      HStack {
        Button(aiGolfPro.isRecording ? "หยุดและส่ง" : "ถาม AI ด้วยเสียง") {
          toggleCompactVoiceQuestion()
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          !aiGolfPro.settings.hasStoredAPIKey
            || (!aiGolfPro.isRecording && aiGolfPro.state.isBusy)
            || (!aiGolfPro.isRecording && handsFreeCapture.isActive)
        )

        if aiGolfPro.state.isBusy, !aiGolfPro.isRecording {
          ProgressView()
            .controlSize(.small)
        }

        Spacer()

        if aiGolfPro.state == .speaking {
          Button("หยุดเสียง", systemImage: "speaker.slash") {
            aiGolfPro.stopSpeaking()
          }
          .buttonStyle(.bordered)
        }
      }

      Label(
        screenEvidence.latestCaptureURL == nil
          ? "คำถามถัดไปจะเก็บ snapshot ในเครื่องพร้อมข้อมูลวง"
          : "snapshot ล่าสุดถูกเก็บในเครื่องพร้อมข้อมูลวง",
        systemImage: "paperclip"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
  }

  private var highSpeedSourceColor: Color {
    switch camera.highSpeedReceiver.state {
    case .connected: return .green
    case .advertising, .stalled: return .orange
    case .failed: return .red
    case .stopped: return .secondary
    }
  }

  private func quickControlCard<Actions: View, Footer: View>(
    title: String,
    detail: String,
    icon: String,
    color: Color,
    @ViewBuilder actions: () -> Actions,
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .font(.title3)
          .foregroundStyle(color)
          .frame(width: 34, height: 34)
          .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.subheadline.weight(.semibold))
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      actions()
      footer()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(GolfTraceTheme.raisedPanel, in: RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(GolfTraceTheme.subtleBorder, lineWidth: 1)
    )
  }

  private var floatingTimelineControls: some View {
    ReplayTimelineControls(
      playback: replayPlayback,
      isReplayStageActive: stageMode == .replay,
      hasReplay: replay.replayURL != nil,
      replayStatusText: replay.statusText,
      canSaveReplay: replay.canSaveReplay,
      isReplayPinned: $isReplayPinned,
      onShowReplay: { autoPlay, pinned in
        showReplay(autoPlay: autoPlay, pinned: pinned)
      },
      onReturnToLive: returnToLiveAfterReplay,
      onSaveReplay: replay.saveReplay,
      onOpenHistory: openHistoryWorkspace
    )
    .disabled(isHandsFreeStageBlockingReplay)
  }

  private var usesDirectIPhoneInput: Bool {
    switch camera.highSpeedReceiver.state {
    case .advertising, .connected, .stalled:
      return true
    case .stopped, .failed:
      return false
    }
  }

  private var activeSourceName: String {
    usesDirectIPhoneInput ? "ส่งตรงจาก iPhone · เป้าหมาย 120 FPS" : "ทางสำรองของ Apple · สูงสุด 60 FPS"
  }

  private var activeSourceFPSText: String {
    usesDirectIPhoneInput ? camera.highSpeedReceiver.metrics.fpsText : camera.frameMetrics.fpsText
  }

  private var activeFrameCount: Int {
    usesDirectIPhoneInput
      ? camera.highSpeedReceiver.metrics.decodedFrames : camera.frameMetrics.receivedFrames
  }

  private var activeDropCount: Int {
    usesDirectIPhoneInput
      ? camera.highSpeedReceiver.metrics.decoderDrops : camera.frameMetrics.droppedFrames
  }

  private var matchedLatestShot: LaunchMonitorShot? {
    guard let latestRecordID else { return nil }
    return history.records.first(where: { $0.id == latestRecordID })?
      .launchMonitorMatch?.shot
  }

  private func makeStoryboardCaptureSnapshot(
    for evidencePacket: SwingEvidencePacket
  ) -> SwingStoryboardCaptureSnapshot {
    let context = camera.lastSwingCaptureContext ?? .initial

    return SwingStoryboardCaptureSnapshot(
      sourceID: context.sourceID,
      cameraView: evidencePacket.cameraView,
      orientation: context.orientation,
      encodedPixelWidth: context.encodedPixelWidth,
      encodedPixelHeight: context.encodedPixelHeight,
      captureFPS: context.captureFPS
    )
  }

  /// `replayRecordID` is the canonical owner for both a freshly exported take
  /// and a replay opened from history. Never substitute the latest record: a
  /// replay without an explicit owner must not display another take's evidence.
  private var activeReplayRecord: SwingRecord? {
    guard let recordID = replay.replayRecordID else { return nil }
    return history.records.first(where: { $0.id == recordID })
  }

  private var adaptivePhaseEvidence: [AdaptivePhaseStripEvidence] {
    guard let record = activeReplayRecord, let artifacts = record.artifacts else { return [] }
    let keyframesBySlot = Dictionary(
      artifacts.keyframes.map { ($0.slot, $0) },
      uniquingKeysWith: { current, candidate in
        current.state == .available ? current : candidate
      }
    )

    return artifacts.phaseMarkers.map { marker in
      let keyframe = keyframesBySlot[marker.slot]
      return AdaptivePhaseStripEvidence(
        phaseID: marker.slot.rawValue,
        sourceTimestampMs: marker.sourceTimestampMs,
        replayTimestampMs: marker.replayTimestampMs,
        confidence: marker.confidence,
        provenanceText: adaptivePhaseProvenanceText(marker.provenance.sourceType),
        limitation: marker.limitation,
        thumbnailURL: adaptivePhaseThumbnailURL(
          recordID: record.id,
          keyframe: keyframe
        )
      )
    }
  }

  private var adaptivePhaseSource: AdaptivePhaseStripSource {
    guard let capture = activeReplayRecord?.artifacts?.capture else {
      return AdaptivePhaseStripSource(
        angleLabel: "มุมเดียว · ยังไม่มีข้อมูล",
        detail: "วงเก่าไม่มีหลักฐาน phase"
      )
    }

    let cameraView =
      GolfCameraView(rawValue: capture.cameraView)?.displayName
      ?? capture.cameraView
    let dimensions: String
    if let width = capture.encodedPixelWidth, let height = capture.encodedPixelHeight {
      dimensions = " · \(width)×\(height)"
    } else {
      dimensions = ""
    }
    let fps = capture.captureFPS.map { " · \(Int($0.rounded())) FPS" } ?? ""
    let sourceName =
      capture.sourceID == SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID
      ? "iPhone กล้อง"
      : "กล้องสำรอง"
    return AdaptivePhaseStripSource(
      angleLabel: "มุมเดียว · \(cameraView)",
      detail:
        "\(sourceName) · \(adaptivePhaseOrientationText(capture.orientation))\(dimensions)\(fps)"
    )
  }

  private func adaptivePhaseProvenanceText(_ sourceType: SwingEvidenceSourceType) -> String {
    switch sourceType {
    case .macVision2D: return "วัดจาก Vision 2D"
    case .macDerived2D: return "ประมาณจากจุดมือ 2D"
    case .rapsodoMeasured: return "วัดจาก Rapsodo"
    case .aiInferred: return "AI ประมาณ"
    }
  }

  private func adaptivePhaseOrientationText(
    _ orientation: SwingStoryboardCaptureOrientation
  ) -> String {
    switch orientation {
    case .degrees0: return "แนวภาพ 0°"
    case .degrees90: return "แนวภาพ 90°"
    case .degrees180: return "แนวภาพ 180°"
    case .degrees270: return "แนวภาพ 270°"
    case .unknown: return "แนวภาพยังไม่ยืนยัน"
    }
  }

  private func adaptivePhaseThumbnailURL(
    recordID: UUID,
    keyframe: SwingStoryboardKeyframeDescriptor?
  ) -> URL? {
    guard keyframe?.state == .available,
      let filename = keyframe?.filename,
      !filename.isEmpty,
      filename == URL(fileURLWithPath: filename).lastPathComponent,
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else { return nil }

    return
      applicationSupport
      .appendingPathComponent("GolfTrace", isDirectory: true)
      .appendingPathComponent("Swings", isDirectory: true)
      .appendingPathComponent(recordID.uuidString.lowercased(), isDirectory: true)
      .appendingPathComponent(filename)
  }

  private func finishStageReplayOrUseCameraFallback(
    summary: SwingSessionSummary,
    recordID: UUID,
    hasCommittedStageCapture: Bool,
    captureOrientation: SwingStoryboardCaptureOrientation,
    handsFreeTakeID: UUID?
  ) {
    guard hasCommittedStageCapture else {
      stageReplayRecorder.cancelUnfinishedRecording()
      exportCameraReplayFallback(
        summary: summary,
        recordID: recordID,
        captureOrientation: captureOrientation,
        handsFreeTakeID: handsFreeTakeID
      )
      return
    }

    let didRequestStageReplay = stageReplayRecorder.finishRecording { result in
      switch result {
      case .success(let url):
        if let clockMapping = SwingReplayClockMapper.makeMapping(
          cameraAnchors: camera.highSpeedReceiver.replayClockAnchorsSnapshot(),
          replayAnchors: stageReplayRecorder.lastCompletedReplayClockAnchors
        ) {
          history.attachReplayClockMapping(
            clockMapping,
            to: recordID,
            summary: summary
          )
        }
        let stagePaneLayout = stageReplayRecorder.lastCompletedPaneLayout
        let managedURL = replay.acceptStageRecording(
          url,
          recordID: recordID,
          stagePaneLayout: stagePaneLayout
        )
        registerHandsFreeReplayOwnership(recordID, takeID: handsFreeTakeID)
        persistReplayThenComplete(
          managedURL,
          takeID: handsFreeTakeID,
          summary: summary,
          recordID: recordID,
          stagePaneLayout: stagePaneLayout
        )
      case .failure:
        exportCameraReplayFallback(
          summary: summary,
          recordID: recordID,
          captureOrientation: captureOrientation,
          handsFreeTakeID: handsFreeTakeID
        )
      }
    }

    if !didRequestStageReplay {
      exportCameraReplayFallback(
        summary: summary,
        recordID: recordID,
        captureOrientation: captureOrientation,
        handsFreeTakeID: handsFreeTakeID
      )
    }
  }

  private func handleStageCaptureTransition(to state: SwingSessionDetectorState) {
    guard isHandsFreeCaptureEnabled, isPracticeModeEnabled else {
      stageReplayRecorder.cancelUnfinishedRecording()
      return
    }

    guard handsFreeCapture.isActive else {
      stageReplayRecorder.cancelUnfinishedRecording()
      return
    }

    guard state == .confirmingSwing || state == .swinging else { return }
    switch handsFreeCapture.state {
    case .acknowledged, .countdown:
      _ = handsFreeCapture.handleError(
        "เริ่มสวิงก่อนนับถอยหลังจบ วงนี้ไม่ได้บันทึก กรุณาสั่งใหม่"
      )
    case .armed:
      _ = handsFreeCapture.handleDetectorStarted()
    case .listening, .capturing, .finalizing, .replayReady, .cancelled, .timedOut,
      .error:
      break
    }
  }

  private func prepareLiveStageForSwing() {
    // A whole-window movie must never start while an older replay or auxiliary
    // panel is covering either source.
    isShowingSettings = false
    isShowingHistory = false
    isShowingQuickControls = false
    replayPlayback.pause()
    isReplayPinned = false
    stageMode = .live
    handsFreeOwnedReplayRecordID = nil
    aiAnalysisTask?.cancel()
    aiAnalysisTask = nil
    aiGolfPro.invalidateForSwing()
  }

  private var activeRapsodoReplaySession: RapsodoReplaySourceSession? {
    if iphoneMirroring.isRunning,
      iphoneMirroring.hasReceivedFrame,
      let session = iphoneMirroring.activeReplaySourceSession
    {
      return session
    }
    if rapsodoMirror.isRunning,
      rapsodoMirror.hasReceivedFrame,
      let session = rapsodoMirror.activeReplaySourceSession
    {
      return session
    }
    return nil
  }

  private func startIndependentRapsodoRecordingIfAvailable() {
    guard let session = activeRapsodoReplaySession else { return }
    do {
      didReceiveFreshRapsodoForTake = false
      didAnnounceRapsodoLossForTake = false
      try rapsodoReplayRecorder.start(
        sourceKind: session.sourceKind,
        generationID: session.generationID
      )
      let sourceRecorder = rapsodoReplayRecorder
      rapsodoReadinessTask?.cancel()
      rapsodoReadinessTask = Task { @MainActor in
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled,
          sourceRecorder.isRecording,
          !sourceRecorder.isSourceFresh,
          !didAnnounceRapsodoLossForTake
        else { return }
        didAnnounceRapsodoLossForTake = true
        handsFreeVoice.speakFeedback("Rapsodo ยังไม่ส่งภาพ กำลังเก็บกล้องต่อ")
      }
    } catch {
      // Camera recording remains authoritative. A Rapsodo setup failure must
      // not interrupt a solo golfer after the spoken countdown has completed.
      print("[GolfTrace] Rapsodo source recorder did not start: \(error.localizedDescription)")
    }
  }

  /// Exports and persists source masters independently from the legacy whole-
  /// window replay. This path deliberately does not gate the current replay UI:
  /// if Rapsodo is absent or loses its generation, the camera master is still
  /// committed and History never advertises a synchronized PIP pair.
  private func finalizeIndependentReplayBundle(
    summary: SwingSessionSummary,
    recordID: UUID,
    captureOrientation: SwingStoryboardCaptureOrientation
  ) {
    let receiver = camera.highSpeedReceiver
    let sourceRecorder = rapsodoReplayRecorder
    let historyController = history
    let rotationDegrees = captureOrientation.clockwiseDegrees ?? 0

    let didSchedule = replayBundleWorkTracker.start {
      async let pendingCamera = Self.exportCameraMasterForBundle(
        summary: summary,
        rotationDegrees: rotationDegrees,
        using: receiver
      )
      let rapsodoResult:
        Result<
          RapsodoReplayExportResult, RapsodoSourceReplayRecorderError
        >? = sourceRecorder.isRecording ? await sourceRecorder.finish() : nil
      let cameraResult = await pendingCamera

      guard case .success(let cameraMaster) = cameraResult else {
        if case .success(let orphanedRapsodo)? = rapsodoResult {
          try? FileManager.default.removeItem(at: orphanedRapsodo.url)
        }
        if case .failure(let error) = cameraResult {
          print("[GolfTrace] Camera master export failed: \(error.localizedDescription)")
        }
        return
      }

      let rapsodoMaster: RapsodoReplayExportResult?
      if case .success(let completedRapsodo)? = rapsodoResult {
        rapsodoMaster = completedRapsodo
      } else {
        rapsodoMaster = nil
      }
      let bundleExport = SwingReplayBundleBuilder.make(
        camera: cameraMaster,
        rapsodo: rapsodoMaster
      )

      historyController.attachReplayBundleIfNeeded(
        cameraURL: bundleExport.cameraURL,
        rapsodoURL: bundleExport.rapsodoURL,
        bundle: bundleExport.bundle,
        to: recordID
      ) { status in
        guard let status else {
          print(
            "[GolfTrace] Source replay bundle persistence failed; temporary camera remains at "
              + bundleExport.cameraURL.path
          )
          return
        }

        for url in [bundleExport.cameraURL, bundleExport.rapsodoURL].compactMap({ $0 }) {
          try? FileManager.default.removeItem(at: url)
        }
        let rapsodoCounters = rapsodoMaster?.counters
        print(
          "[GolfTrace] Source replay bundle persisted"
            + " status=\(status.rawValue)"
            + " cameraFrames=\(cameraMaster.counters.selectedFrames)"
            + " cameraBytes=\(cameraMaster.counters.selectedBytes)"
            + " rapsodoFrames=\(rapsodoCounters?.appended ?? 0)"
            + " rapsodoThrottleDrops=\(rapsodoCounters?.throttleDrops ?? 0)"
            + " syncUncertaintyMs=\(bundleExport.bundle.synchronization?.uncertaintyMilliseconds ?? -1)"
        )
      }
    }
    if !didSchedule {
      sourceRecorder.cancel()
    }
  }

  private static func exportCameraMasterForBundle(
    summary: SwingSessionSummary,
    rotationDegrees: Double,
    using receiver: HighSpeedVideoReceiver
  ) async -> Result<CameraMasterReplayExportResult, Error> {
    let firstAttempt = await exportCameraMaster(
      summary: summary,
      preRoll: 0.75,
      rotationDegrees: rotationDegrees,
      using: receiver
    )
    guard case .failure(let firstError) = firstAttempt else { return firstAttempt }

    if let segmentError = firstError as? H264ReplaySegmentError {
      switch segmentError {
      case .requestedStartNotCovered:
        // Preserve the complete detected swing even when an unusually large IDR
        // aged only the requested pre-roll out of the bounded buffer.
        return await exportCameraMaster(
          summary: summary,
          preRoll: 0,
          rotationDegrees: rotationDegrees,
          using: receiver
        )
      case .requestedEndNotCovered:
        try? await Task.sleep(for: .milliseconds(80))
        return await exportCameraMaster(
          summary: summary,
          preRoll: 0.75,
          rotationDegrees: rotationDegrees,
          using: receiver
        )
      default:
        break
      }
    }
    return firstAttempt
  }

  private static func exportCameraMaster(
    summary: SwingSessionSummary,
    preRoll: TimeInterval,
    rotationDegrees: Double,
    using receiver: HighSpeedVideoReceiver
  ) async -> Result<CameraMasterReplayExportResult, Error> {
    await withCheckedContinuation { continuation in
      receiver.exportCameraMaster(
        swingStart: summary.startTimestamp,
        swingEnd: summary.endTimestamp,
        preRoll: preRoll,
        rotationDegrees: rotationDegrees
      ) { result in
        continuation.resume(returning: result)
      }
    }
  }

  private func exportCameraReplayFallback(
    summary: SwingSessionSummary,
    recordID: UUID,
    captureOrientation: SwingStoryboardCaptureOrientation,
    handsFreeTakeID: UUID? = nil
  ) {
    replay.exportIfNeeded(
      for: summary,
      recordID: recordID,
      rotationDegrees: captureOrientation.clockwiseDegrees ?? 0,
      using: camera.highSpeedReceiver,
      onFailure: { error in
        guard let handsFreeTakeID else { return }
        _ = handsFreeCapture.handleError(
          "สร้างรีเพลย์สำรองไม่สำเร็จ: \(error.localizedDescription)",
          for: handsFreeTakeID
        )
      },
      onReady: { completedReplay in
        registerHandsFreeReplayOwnership(completedReplay.recordID, takeID: handsFreeTakeID)
        persistReplayThenComplete(
          completedReplay.url,
          takeID: handsFreeTakeID,
          summary: summary,
          recordID: completedReplay.recordID
        )
      }
    )
  }

  private func completeHandsFreeReplayIfNeeded(
    _ url: URL,
    takeID: UUID?,
    summary: SwingSessionSummary,
    recordID: UUID
  ) {
    guard let takeID, handsFreeCapture.handleReplayReady(for: takeID) else { return }
    showReplay(url, autoPlay: true, pinned: false)
    scheduleAIAnalysis(for: summary, recordID: recordID, initialDelay: .seconds(3))
  }

  private func registerHandsFreeReplayOwnership(_ recordID: UUID, takeID: UUID?) {
    guard takeID != nil else { return }
    handsFreeOwnedReplayRecordID = recordID
  }

  private func persistReplayThenComplete(
    _ url: URL,
    takeID: UUID?,
    summary: SwingSessionSummary,
    recordID: UUID,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil
  ) {
    attachReplay(url, to: recordID, stagePaneLayout: stagePaneLayout) { succeeded in
      guard succeeded else {
        if let takeID {
          _ = handsFreeCapture.handleError(
            "เก็บคลิปลงประวัติไม่สำเร็จ กรุณาตรวจพื้นที่ว่างแล้วลองใหม่",
            for: takeID
          )
        }
        return
      }
      let canonicalURL = replay.currentReplayURL(for: recordID) ?? url
      completeHandsFreeReplayIfNeeded(
        canonicalURL,
        takeID: takeID,
        summary: summary,
        recordID: recordID
      )
    }
  }

  private func attachReplay(
    _ url: URL,
    to recordID: UUID,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil,
    attempt: Int = 1,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) {
    history.attachReplayIfNeeded(
      url,
      to: recordID,
      stagePaneLayout: stagePaneLayout
    ) { succeeded in
      if succeeded {
        replay.acknowledgePersistence(of: url, succeeded: true)
        completion?(true)
      } else if attempt < 3 {
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(250 * attempt))
          attachReplay(
            url,
            to: recordID,
            stagePaneLayout: stagePaneLayout,
            attempt: attempt + 1,
            completion: completion
          )
        }
      } else {
        replay.acknowledgePersistence(of: url, succeeded: false)
        completion?(false)
      }
    }
  }

  private func loadReplay(_ url: URL, autoPlay: Bool) {
    replayPlayback.load(
      url,
      stagePaneLayout: replay.replayPaneLayout,
      autoPlay: autoPlay,
      rate: replayPlayback.selectedRate
    ) {
      guard !isReplayPinned else { return }
      returnToLiveAfterReplay()
    } onPlaybackFailed: {
      returnToLiveAfterReplay()
    }
  }

  private func showReplay(autoPlay: Bool, pinned: Bool) {
    guard let url = replay.replayURL else { return }
    showReplay(url, autoPlay: autoPlay, pinned: pinned)
  }

  private func showReplay(_ url: URL, autoPlay: Bool, pinned: Bool) {
    guard !isHandsFreeStageBlockingReplay else { return }
    isReplayPinned = pinned
    stageMode = .replay
    loadReplay(url, autoPlay: autoPlay)
    if autoPlay {
      replayPlayback.play()
    } else {
      replayPlayback.pause()
    }
  }

  private func returnToLiveAfterReplay() {
    replayPlayback.pause()
    isReplayPinned = false
    stageMode = .live
  }

  private func openHistoryWorkspace() {
    // History เป็น workspace คนละโหมดกับ replay overlay; ถ้าไม่กลับ live ก่อน
    // replay ที่ zIndex สูงกว่าจะบังหน้า History และทำให้คำสั่งดูเหมือนไม่ทำงาน
    returnToLiveAfterReplay()
    isShowingQuickControls = false
    isShowingHistory = true
  }

  /// รอค่าที่ประวัติจับคู่กับ Rapsodo ก่อนสูงสุดสี่วินาที
  /// ถ้าไม่มี launch monitor ก็ยังขอคำแนะนำจากภาพ โดยไม่บล็อก replay
  private func scheduleAIAnalysis(
    for summary: SwingSessionSummary,
    recordID: UUID,
    initialDelay: Duration = .zero
  ) {
    aiAnalysisTask?.cancel()
    screenEvidence.capturePrimaryDisplay()
    let practiceSettings = camera.highSpeedReceiver.practiceSettings
    let analysis = camera.lastSwingAnalysis
    let evidencePacket = camera.lastSwingEvidencePacket
    aiAnalysisTask = Task { @MainActor in
      if initialDelay > .zero {
        do {
          try await Task.sleep(for: initialDelay)
        } catch {
          return
        }
      }
      for attempt in 0...4 {
        guard !Task.isCancelled else { return }
        if let shot = history.records.first(where: { $0.id == recordID })?
          .launchMonitorMatch?.shot
        {
          aiGolfPro.analyzeLatestSwing(
            practiceSettings: practiceSettings,
            summary: summary,
            analysis: analysis,
            evidencePacket: evidencePacket,
            launch: shot
          )
          return
        }
        if attempt < 4 {
          do {
            try await Task.sleep(for: .seconds(1))
          } catch {
            return
          }
        }
      }
      guard !Task.isCancelled else { return }
      aiGolfPro.analyzeLatestSwing(
        practiceSettings: practiceSettings,
        summary: summary,
        analysis: analysis,
        evidencePacket: evidencePacket,
        launch: nil
      )
    }
  }

  private var historyWorkspace: some View {
    SwingHistoryWorkspace(
      history: history,
      replay: replay,
      onClose: { isShowingHistory = false },
      onOpenReplay: {
        showReplay(autoPlay: false, pinned: true)
        isShowingHistory = false
      }
    )
  }

  private var settingsSheet: some View {
    GolfTraceSettingsSheet(
      camera: camera,
      launchMonitor: launchMonitor,
      rapsodoCredentials: rapsodoCredentials,
      aiGolfPro: aiGolfPro,
      knowledge: knowledge,
      activeSourceName: activeSourceName,
      activeSourceFPSText: activeSourceFPSText,
      activeFrameCount: activeFrameCount,
      activeDropCount: activeDropCount,
      onClose: { isShowingSettings = false }
    )
  }
}

#Preview {
  let settings = GolfAISettings()
  let knowledge = GolfKnowledgeController(aiSettings: settings)
  ContentView(
    history: SwingHistoryController(),
    replay: SwingReplayController(),
    stageReplayRecorder: GolfTraceStageReplayRecorder(),
    rapsodoReplayRecorder: RapsodoSourceReplayRecorder(),
    replayBundleWorkTracker: SwingReplayBundleWorkTracker(),
    launchMonitor: LaunchMonitorController(),
    rapsodoCredentials: RapsodoCredentialSettings(),
    aiGolfPro: AIGolfProController(settings: settings),
    knowledge: knowledge
  )
}
