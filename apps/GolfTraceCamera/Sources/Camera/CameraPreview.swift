import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.videoGravity = .resizeAspectFill
    view.bind(to: session)
    return view
  }

  func updateUIView(_ uiView: PreviewView, context: Context) {
    uiView.bind(to: session)
  }
}

final class PreviewView: UIView {
  private var sessionStartedToken: NSObjectProtocol?
  private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
  private var rotationObservation: NSKeyValueObservation?

  override class var layerClass: AnyClass {
    AVCaptureVideoPreviewLayer.self
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    guard let layer = layer as? AVCaptureVideoPreviewLayer else {
      fatalError("PreviewView must use AVCaptureVideoPreviewLayer")
    }
    return layer
  }

  func bind(to session: AVCaptureSession) {
    guard previewLayer.session !== session else {
      configureRotationIfPossible()
      return
    }

    removeSessionObservation()
    resetRotationCoordinator()
    previewLayer.session = session

    sessionStartedToken = NotificationCenter.default.addObserver(
      forName: AVCaptureSession.didStartRunningNotification,
      object: session,
      queue: .main
    ) { [weak self] _ in
      self?.configureRotationIfPossible()
    }

    configureRotationIfPossible()
  }

  private func configureRotationIfPossible() {
    guard let session = previewLayer.session,
      let deviceInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first
    else {
      return
    }

    if rotationCoordinator?.device?.uniqueID == deviceInput.device.uniqueID {
      applyPreviewRotation()
      return
    }

    resetRotationCoordinator()
    let coordinator = AVCaptureDevice.RotationCoordinator(
      device: deviceInput.device,
      previewLayer: previewLayer
    )
    rotationCoordinator = coordinator
    rotationObservation = coordinator.observe(
      \.videoRotationAngleForHorizonLevelPreview,
      options: [.initial, .new]
    ) { [weak self] _, _ in
      self?.applyPreviewRotation()
    }
  }

  private func applyPreviewRotation() {
    guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
      let connection = previewLayer.connection,
      connection.isVideoRotationAngleSupported(angle)
    else {
      return
    }
    connection.videoRotationAngle = angle
  }

  private func resetRotationCoordinator() {
    rotationObservation?.invalidate()
    rotationObservation = nil
    rotationCoordinator = nil
  }

  private func removeSessionObservation() {
    if let sessionStartedToken {
      NotificationCenter.default.removeObserver(sessionStartedToken)
      self.sessionStartedToken = nil
    }
  }

  deinit {
    removeSessionObservation()
    resetRotationCoordinator()
  }
}
