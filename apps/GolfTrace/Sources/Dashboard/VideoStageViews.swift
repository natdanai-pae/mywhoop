import SwiftUI

struct RapsodoMirrorStage: View {
  @ObservedObject var iphoneMirroring: IPhoneMirroringCaptureModel
  @ObservedObject var usbMirror: RapsodoScreenMirrorModel

  private var isShowingMirroringWindow: Bool {
    iphoneMirroring.isRunning && iphoneMirroring.hasReceivedFrame
  }

  private var isShowingUSBMirror: Bool {
    !isShowingMirroringWindow && usbMirror.isRunning && usbMirror.hasReceivedFrame
  }

  private var waitingStatus: String {
    if usbMirror.isBusy || !usbMirror.devices.isEmpty {
      return usbMirror.status
    }
    if iphoneMirroring.isBusy || iphoneMirroring.hasAvailableWindow {
      return iphoneMirroring.status
    }
    return "เสียบ K ด้วย USB, ปลดล็อกและกด Trust แล้วเปิด Rapsodo"
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 16)
        .fill(Color.black)

      // Keep the ScreenCaptureKit renderer attached before the first frame.
      // Mounting it only after `hasReceivedFrame` can lose a static first frame.
      IPhoneMirroringPreview(model: iphoneMirroring)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(isShowingMirroringWindow ? 1 : 0)
        .allowsHitTesting(false)

      CameraPreview(session: usbMirror.session)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(isShowingUSBMirror ? 1 : 0)
        .allowsHitTesting(false)

      if !isShowingMirroringWindow && !isShowingUSBMirror {
        VStack(spacing: 13) {
          WaitingSourceIcon(
            systemName: "iphone.gen3",
            color: GolfTraceTheme.blue,
            symbolSize: 42,
            accessibilityLabel: "Rapsodo MLM2Pro"
          )
          Text("รอ Rapsodo MLM2Pro")
            .font(.title3.weight(.bold))
          Text(waitingStatus)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(GolfTraceTheme.mutedText)
            .frame(maxWidth: 360)

          HStack(spacing: 10) {
            Button {
              iphoneMirroring.stop()
              usbMirror.startAutomatic()
            } label: {
              Label(
                usbMirror.isBusy ? "กำลังค้นหา K…" : "เชื่อม K ผ่าน USB",
                systemImage: "cable.connector"
              )
            }
            .buttonStyle(.borderedProminent)
            .tint(GolfTraceTheme.blue)
            .disabled(usbMirror.isBusy)

            Button {
              usbMirror.stop()
              iphoneMirroring.startAutomatically()
            } label: {
              Label("ใช้ Apple Mirroring", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(iphoneMirroring.isBusy)
          }
          .controlSize(.small)

          Text("Apple Mirroring ต้องใช้ Apple Account เดียวกับ Mac และ iPhone ต้องล็อกอยู่")
            .font(.caption2)
            .foregroundStyle(GolfTraceTheme.mutedText.opacity(0.78))
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -24)
      }

      HStack(spacing: 8) {
        Image(
          systemName: isShowingMirroringWindow
            ? "rectangle.on.rectangle"
            : (isShowingUSBMirror ? "cable.connector" : "iphone")
        )
        .foregroundStyle(GolfTraceTheme.blue)
        Text("Rapsodo MLM2Pro")
          .foregroundStyle(.white)

        if isShowingMirroringWindow {
          Text("Mirroring")
            .foregroundStyle(GolfTraceTheme.mutedText)
        } else if isShowingUSBMirror {
          Text("K · USB")
            .foregroundStyle(GolfTraceTheme.mutedText)
        }
      }
      .font(.system(size: 15, weight: .semibold))
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.black.opacity(0.78), in: Capsule())
      .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
      .padding(22)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(GolfTraceTheme.border, lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("หน้าจอ Rapsodo MLM2Pro")
  }
}

enum LiveVideoStagePresentationTint: Equatable {
  case blue
  case orange
  case red
  case muted

  var color: Color {
    switch self {
    case .blue:
      return GolfTraceTheme.blue
    case .orange:
      return .orange
    case .red:
      return .red
    case .muted:
      return GolfTraceTheme.mutedText
    }
  }
}

struct LiveVideoStagePresentation: Equatable {
  let title: String
  let detail: String
  let systemImage: String
  let tint: LiveVideoStagePresentationTint
  let actionTitle: String?

  var allowsReconnectAction: Bool {
    actionTitle != nil
  }
}

enum LiveVideoStagePresentationResolver {
  /// Resolves only the empty-state presentation. Once a decoded frame exists,
  /// the live preview owns the entire stage and no connection card is shown.
  static func resolve(
    receiverState: HighSpeedReceiverState,
    decodedFrames: Int
  ) -> LiveVideoStagePresentation? {
    switch receiverState {
    case .advertising:
      return LiveVideoStagePresentation(
        title: "กำลังค้นหา GolfTrace Camera",
        detail:
          "เปิดแอป GolfTrace Camera บน iPhone และให้ iPhone อยู่บนเครือข่ายเดียวกับ Mac ระบบจะเชื่อมต่อให้อัตโนมัติ",
        systemImage: "iphone.radiowaves.left.and.right",
        tint: .orange,
        actionTitle: nil
      )

    case .connected where decodedFrames <= 0:
      return LiveVideoStagePresentation(
        title: "เชื่อมต่อ GolfTrace Camera แล้ว",
        detail: "กำลังเตรียมภาพจากกล้อง iPhone ให้เปิดแอปไว้ด้านหน้าอีกครู่",
        systemImage: "camera.aperture",
        tint: .blue,
        actionTitle: nil
      )

    case .connected:
      return nil

    case .stalled:
      return LiveVideoStagePresentation(
        title: "ภาพจาก GolfTrace Camera หยุดชั่วคราว",
        detail:
          "กำลังเชื่อมต่อใหม่อัตโนมัติ ให้เปิด GolfTrace Camera ค้างไว้และอย่าล็อกหน้าจอ iPhone",
        systemImage: "arrow.triangle.2.circlepath",
        tint: .orange,
        actionTitle: nil
      )

    case .failed(let message):
      let failureDetail = message.trimmingCharacters(in: .whitespacesAndNewlines)
      let nextStep =
        "ตรวจว่า iPhone และ Mac อยู่บนเครือข่ายเดียวกัน เปิด GolfTrace Camera แล้วลองใหม่"
      return LiveVideoStagePresentation(
        title: "เชื่อมต่อ GolfTrace Camera ไม่สำเร็จ",
        detail: failureDetail.isEmpty ? nextStep : "\(failureDetail)\n\(nextStep)",
        systemImage: "wifi.exclamationmark",
        tint: .red,
        actionTitle: "เชื่อมต่อใหม่"
      )

    case .stopped:
      return LiveVideoStagePresentation(
        title: "กล้อง iPhone ยังไม่ได้เชื่อมต่อ",
        detail: "เปิดแอป GolfTrace Camera บน iPhone แล้วกดเชื่อมต่อใหม่บน Mac",
        systemImage: "camera.fill",
        tint: .muted,
        actionTitle: "เชื่อมต่อใหม่"
      )
    }
  }
}

enum LiveSwingOverlayContextResolver {
  static func canReuseCompletedSwing(
    last: LiveSwingCaptureContext?,
    current: LiveSwingCaptureContext,
    displayedOrientation: GolfTraceVideoOrientation
  ) -> Bool {
    guard let last else { return false }
    return last.sourceID == current.sourceID
      && last.cameraView == current.cameraView
      && last.orientation == current.orientation
      && current.orientation == SwingStoryboardCaptureOrientation(displayedOrientation)
  }
}

struct LiveVideoStage: View {
  @ObservedObject var camera: CameraCaptureModel
  @ObservedObject var receiver: HighSpeedVideoReceiver
  @ObservedObject private var liveState: CameraLiveState

  init(camera: CameraCaptureModel, receiver: HighSpeedVideoReceiver) {
    self.camera = camera
    self.receiver = receiver
    _liveState = ObservedObject(wrappedValue: camera.liveState)
  }

  private var usesDirectIPhoneInput: Bool {
    switch receiver.state {
    case .advertising, .connected, .stalled:
      return true
    case .stopped, .failed:
      return false
    }
  }

  private var rawSourceDimensions: CGSize {
    let dimensions =
      usesDirectIPhoneInput
      ? receiver.metrics.dimensions : liveState.frameMetrics.dimensions
    return dimensions
  }

  private func sourceDimensions(for orientation: GolfTraceVideoOrientation) -> CGSize {
    let dimensions = rawSourceDimensions
    guard usesDirectIPhoneInput, orientation.swapsDimensions else { return dimensions }
    return CGSize(width: dimensions.height, height: dimensions.width)
  }

  private var displayedVideoOrientation: GolfTraceVideoOrientation {
    let rawOrientation =
      usesDirectIPhoneInput
      ? receiver.presentedVideoOrientation : GolfTraceVideoOrientation.degrees0
    return rawOrientation.addingHalfTurn(camera.videoHalfTurn == .rotated180)
  }

  private var liveOverlayDimensions: CGSize {
    sourceDimensions(for: displayedVideoOrientation)
  }

  /// Suppress the pose for only the short orientation-boundary interval when
  /// Vision and the display layer refer to different samples. Rendering it in
  /// the wrong epoch stretches the skeleton across swapped dimensions.
  private var overlayPose: PoseFrame? {
    guard let pose = liveState.pose,
      pose.videoOrientation == displayedVideoOrientation
    else {
      return nil
    }
    return pose
  }

  private var isLive: Bool {
    if usesDirectIPhoneInput {
      return receiver.state == .connected && receiver.metrics.decodedFrames > 0
    }
    return camera.isRunning && liveState.frameMetrics.receivedFrames > 0
  }

  private var emptyStatePresentation: LiveVideoStagePresentation? {
    LiveVideoStagePresentationResolver.resolve(
      receiverState: receiver.state,
      decodedFrames: receiver.metrics.decodedFrames
    )
  }

  private var retainedSwingPoints: [SwingMotionPoint]? {
    guard
      LiveSwingOverlayContextResolver.canReuseCompletedSwing(
        last: camera.lastSwingCaptureContext,
        current: camera.currentLiveSwingCaptureContext,
        displayedOrientation: displayedVideoOrientation
      )
    else { return nil }

    switch camera.swingSessionState {
    case .confirmingSwing, .swinging:
      return nil
    case .waitingForStillness, .armed, .completed:
      return camera.lastSwingSummary?.pointHistory
    }
  }

  private var stageSourceLabel: String {
    guard !usesDirectIPhoneInput else { return "iPhone กล้อง" }
    return camera.activeFallbackDevice?.localizedName ?? "กล้องสำรอง"
  }

  private var stageSourceIcon: String {
    usesDirectIPhoneInput ? "camera.fill" : "video.fill"
  }

  private var stageSourceColor: Color {
    usesDirectIPhoneInput ? .orange : GolfTraceTheme.blue
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      ZStack {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.black)

        Group {
          if usesDirectIPhoneInput {
            HighSpeedVideoPreview(
              receiver: receiver,
              rotationDegrees: displayedVideoOrientation.clockwiseDegrees
            )
          } else {
            CameraPreview(session: camera.session)
              .rotationEffect(.degrees(camera.videoHalfTurn.degrees))
          }
        }

        GolfGuidelineOverlay(
          guideline: receiver.practiceSettings.guideline,
          cameraView: receiver.practiceSettings.cameraView,
          pose: overlayPose,
          personalBaseline: retainedSwingPoints,
          sourceDimensions: liveOverlayDimensions
        )

        SwingTraceOverlay(
          motion: overlayPose == nil ? nil : liveState.swingMotion,
          retainedPoints: retainedSwingPoints,
          sourceDimensions: liveOverlayDimensions
        )

        PoseOverlay(pose: overlayPose, sourceDimensions: liveOverlayDimensions)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16))

      HStack(spacing: 8) {
        Image(systemName: stageSourceIcon)
          .foregroundStyle(stageSourceColor)
        Text(stageSourceLabel)
          .foregroundStyle(.white)
      }
      .font(.system(size: 15, weight: .semibold))
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.black.opacity(0.78), in: Capsule())
      .overlay(Capsule().stroke(Color.white.opacity(0.09), lineWidth: 1))
      .padding(22)

      if !isLive, let presentation = emptyStatePresentation {
        VStack(spacing: 13) {
          CameraConnectionStatusIcon(
            systemName: presentation.systemImage,
            color: presentation.tint.color
          )
          Text(presentation.title)
            .font(.title3.weight(.bold))
          Text(presentation.detail)
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(GolfTraceTheme.mutedText)
            .frame(maxWidth: 420)

          if let actionTitle = presentation.actionTitle {
            Button {
              camera.startHighSpeedInput()
            } label: {
              Label(actionTitle, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(GolfTraceTheme.blue)
            .accessibilityHint("เปิดตัวรับภาพแล้วรอ GolfTrace Camera เชื่อมต่ออีกครั้ง")
          }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(GolfTraceTheme.raisedPanel.opacity(0.94))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(presentation.tint.color.opacity(0.32), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 20, y: 8)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(GolfTraceTheme.border, lineWidth: 1)
    )
  }

}

private struct CameraConnectionStatusIcon: View {
  let systemName: String
  let color: Color

  var body: some View {
    ZStack {
      Circle()
        .fill(color.opacity(0.13))
        .frame(width: 72, height: 72)
      Circle()
        .stroke(color.opacity(0.38), lineWidth: 1)
        .frame(width: 72, height: 72)
      Image(systemName: systemName)
        .font(.system(size: 31, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(color)
    }
    .shadow(color: color.opacity(0.16), radius: 12)
    .accessibilityHidden(true)
  }
}

private struct WaitingSourceIcon: View {
  let systemName: String
  let color: Color
  let symbolSize: CGFloat
  let accessibilityLabel: String

  var body: some View {
    HStack(spacing: 6) {
      WaitingSignalWaves(isLeading: true)
        .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .frame(width: 24, height: 56)

      Image(systemName: systemName)
        .font(.system(size: symbolSize, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(color)
        .frame(width: 50, height: 62)

      WaitingSignalWaves(isLeading: false)
        .stroke(color.opacity(0.78), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        .frame(width: 24, height: 56)
    }
    .frame(width: 110, height: 66)
    .shadow(color: color.opacity(0.18), radius: 10)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct WaitingSignalWaves: Shape {
  let isLeading: Bool

  func path(in rect: CGRect) -> Path {
    let anchorX = isLeading ? rect.maxX : rect.minX
    let outerControlX = isLeading ? rect.minX : rect.maxX
    let middleY = rect.midY
    var path = Path()

    path.move(to: CGPoint(x: anchorX, y: rect.minY + 2))
    path.addQuadCurve(
      to: CGPoint(x: anchorX, y: rect.maxY - 2),
      control: CGPoint(x: outerControlX, y: middleY)
    )

    return path
  }
}
