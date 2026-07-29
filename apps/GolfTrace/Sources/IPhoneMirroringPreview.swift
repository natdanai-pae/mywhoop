@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// SwiftUI host for the Apple iPhone Mirroring ScreenCaptureKit feed.
@MainActor
struct IPhoneMirroringPreview: NSViewRepresentable {
  let model: IPhoneMirroringCaptureModel

  init(model: IPhoneMirroringCaptureModel) {
    self.model = model
  }

  init(capture: IPhoneMirroringCaptureModel) {
    self.model = capture
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(capture: model)
  }

  func makeNSView(context: Context) -> IPhoneMirroringPreviewView {
    let view = IPhoneMirroringPreviewView()
    context.coordinator.attach(capture: model, layer: view.displayLayer)
    return view
  }

  func updateNSView(_ view: IPhoneMirroringPreviewView, context: Context) {
    context.coordinator.attach(capture: model, layer: view.displayLayer)
  }

  static func dismantleNSView(
    _ view: IPhoneMirroringPreviewView,
    coordinator: Coordinator
  ) {
    coordinator.detach(layer: view.displayLayer)
  }

  @MainActor
  final class Coordinator {
    private weak var capture: IPhoneMirroringCaptureModel?
    private weak var layer: AVSampleBufferDisplayLayer?

    init(capture: IPhoneMirroringCaptureModel) {
      self.capture = capture
    }

    func attach(
      capture: IPhoneMirroringCaptureModel,
      layer: AVSampleBufferDisplayLayer
    ) {
      guard self.capture !== capture || self.layer !== layer else { return }

      if let previousCapture = self.capture, previousCapture !== capture {
        IPhoneMirroringPreviewAttachmentRegistry.detach(
          previousCapture,
          ifCurrentLayerIs: self.layer
        )
      }

      self.capture = capture
      self.layer = layer
      IPhoneMirroringPreviewAttachmentRegistry.attach(capture, layer: layer)
    }

    func detach(layer: AVSampleBufferDisplayLayer) {
      layer.sampleBufferRenderer.flush(
        removingDisplayedImage: true,
        completionHandler: nil
      )

      guard self.layer === layer, let capture else { return }
      IPhoneMirroringPreviewAttachmentRegistry.detach(
        capture,
        ifCurrentLayerIs: layer
      )
      self.layer = nil
    }
  }
}

/// AppKit view that keeps the display layer fitted without implicit resize
/// animations. ScreenCaptureKit preserves the source window's aspect ratio.
@MainActor
final class IPhoneMirroringPreviewView: NSView {
  let displayLayer = AVSampleBufferDisplayLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    let rootLayer = CALayer()
    rootLayer.backgroundColor = NSColor.black.cgColor
    rootLayer.masksToBounds = true
    layer = rootLayer

    displayLayer.videoGravity = .resizeAspect
    displayLayer.backgroundColor = NSColor.black.cgColor
    rootLayer.addSublayer(displayLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    displayLayer.frame = bounds
    CATransaction.commit()
  }
}

/// SwiftUI can make a replacement `NSView` before dismantling the old one.
/// Track the current attachment so an old coordinator cannot detach the new
/// live preview renderer during that transition.
@MainActor
private enum IPhoneMirroringPreviewAttachmentRegistry {
  private static var currentLayers: [ObjectIdentifier: WeakIPhoneMirroringLayer] = [:]

  static func attach(
    _ capture: IPhoneMirroringCaptureModel,
    layer: AVSampleBufferDisplayLayer
  ) {
    removeReleasedLayers()
    currentLayers[ObjectIdentifier(capture)] = WeakIPhoneMirroringLayer(layer)
    capture.attachPreviewLayer(layer)
  }

  static func detach(
    _ capture: IPhoneMirroringCaptureModel,
    ifCurrentLayerIs layer: AVSampleBufferDisplayLayer?
  ) {
    let key = ObjectIdentifier(capture)
    guard currentLayers[key]?.layer === layer else { return }

    capture.attachPreviewLayer(nil)
    currentLayers.removeValue(forKey: key)
  }

  private static func removeReleasedLayers() {
    currentLayers = currentLayers.filter { _, attachment in
      attachment.layer != nil
    }
  }
}

@MainActor
private final class WeakIPhoneMirroringLayer {
  weak var layer: AVSampleBufferDisplayLayer?

  init(_ layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
  }
}
