import SwiftUI
import UIKit

/// แปลงทิศที่ผู้ใช้ถือเครื่องให้เป็นทิศของหน้าต่างแอป โดยไม่แตะพิกเซลวิดีโอ 120 FPS
struct PhysicalOrientationRequestPolicy {
  private(set) var lastRequestedMask: UIInterfaceOrientationMask?

  static func interfaceMask(for deviceOrientation: UIDeviceOrientation)
    -> UIInterfaceOrientationMask?
  {
    switch deviceOrientation {
    case .portrait:
      return .portrait
    case .portraitUpsideDown:
      return .portraitUpsideDown
    case .landscapeLeft:
      // ทิศของตัวเครื่องและทิศของหน้าจอใช้ชื่อกลับด้านกัน
      return .landscapeRight
    case .landscapeRight:
      return .landscapeLeft
    case .faceUp, .faceDown, .unknown:
      return nil
    @unknown default:
      return nil
    }
  }

  mutating func requestMask(
    for deviceOrientation: UIDeviceOrientation,
    currentInterfaceOrientation: UIInterfaceOrientation
  ) -> UIInterfaceOrientationMask? {
    guard let mask = Self.interfaceMask(for: deviceOrientation) else { return nil }

    if mask == currentInterfaceOrientation.orientationMask {
      lastRequestedMask = mask
      return nil
    }

    guard mask != lastRequestedMask else { return nil }
    lastRequestedMask = mask
    return mask
  }

  mutating func reset() {
    lastRequestedMask = nil
  }
}

private extension UIInterfaceOrientation {
  var orientationMask: UIInterfaceOrientationMask {
    switch self {
    case .portrait: return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    case .unknown: return []
    @unknown default: return []
    }
  }
}

@MainActor
final class PhysicalOrientationController: ObservableObject {
  private weak var scene: UIWindowScene?
  private var notificationToken: NSObjectProtocol?
  private var pendingRequest: Task<Void, Never>?
  private var requestPolicy = PhysicalOrientationRequestPolicy()
  private var isActive = false
  private var isGeneratingNotifications = false

  func attach(scene: UIWindowScene?) {
    guard self.scene !== scene else { return }
    self.scene = scene
    requestPolicy.reset()
    scheduleRequest(for: UIDevice.current.orientation, delayMilliseconds: 0)
  }

  func activate() {
    guard !isActive else {
      scheduleRequest(for: UIDevice.current.orientation, delayMilliseconds: 0)
      return
    }

    isActive = true
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    isGeneratingNotifications = true
    notificationToken = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification,
      object: UIDevice.current,
      queue: .main
    ) { [weak self] _ in
      let orientation = UIDevice.current.orientation
      Task { @MainActor [weak self] in
        self?.scheduleRequest(for: orientation)
      }
    }

    scheduleRequest(for: UIDevice.current.orientation, delayMilliseconds: 0)
  }

  func deactivate() {
    isActive = false
    pendingRequest?.cancel()
    pendingRequest = nil

    if let notificationToken {
      NotificationCenter.default.removeObserver(notificationToken)
      self.notificationToken = nil
    }

    if isGeneratingNotifications {
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
      isGeneratingNotifications = false
    }
  }

  private func scheduleRequest(
    for orientation: UIDeviceOrientation,
    delayMilliseconds: UInt64 = 130
  ) {
    guard isActive, PhysicalOrientationRequestPolicy.interfaceMask(for: orientation) != nil else {
      return
    }

    pendingRequest?.cancel()
    pendingRequest = Task { @MainActor [weak self] in
      if delayMilliseconds > 0 {
        try? await Task.sleep(for: .milliseconds(delayMilliseconds))
      }
      guard !Task.isCancelled else { return }
      self?.apply(orientation)
    }
  }

  private func apply(_ orientation: UIDeviceOrientation) {
    guard let scene,
      let mask = requestPolicy.requestMask(
        for: orientation,
        currentInterfaceOrientation: scene.interfaceOrientation
      )
    else {
      return
    }

    scene.windows.first(where: \.isKeyWindow)?
      .rootViewController?
      .setNeedsUpdateOfSupportedInterfaceOrientations()

    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
      print("[GolfTraceCamera] หมุนหน้าจอตามเครื่องไม่สำเร็จ: \(error.localizedDescription)")
    }
  }
}

/// ส่ง UIWindowScene ของหน้าต่างที่แสดง ContentView จริงให้ controller
struct WindowSceneAttachmentView: UIViewRepresentable {
  let onSceneChanged: @MainActor (UIWindowScene?) -> Void

  func makeUIView(context: Context) -> SceneAttachmentUIView {
    let view = SceneAttachmentUIView()
    view.onSceneChanged = onSceneChanged
    return view
  }

  func updateUIView(_ uiView: SceneAttachmentUIView, context: Context) {
    uiView.onSceneChanged = onSceneChanged
    uiView.reportSceneIfNeeded()
  }

  static func dismantleUIView(_ uiView: SceneAttachmentUIView, coordinator: ()) {
    uiView.onSceneChanged?(nil)
    uiView.onSceneChanged = nil
  }
}

final class SceneAttachmentUIView: UIView {
  var onSceneChanged: (@MainActor (UIWindowScene?) -> Void)?
  private weak var lastScene: UIWindowScene?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    reportSceneIfNeeded()
  }

  func reportSceneIfNeeded() {
    let currentScene = window?.windowScene
    guard lastScene !== currentScene else { return }
    lastScene = currentScene
    onSceneChanged?(currentScene)
  }
}
