import AVFoundation
import SwiftUI

/// Renders the decoded direct iPhone feed owned by `HighSpeedVideoReceiver`.
///
/// The receiver keeps only a weak reference to the display layer, so the view
/// remains the owner of all AppKit drawing resources. The attachment registry
/// also prevents a retiring SwiftUI view from detaching a newer replacement
/// view during a view-identity transition.
@MainActor
struct HighSpeedVideoPreview: NSViewRepresentable {
  let receiver: HighSpeedVideoReceiver
  let rotationDegrees: Double

  func makeCoordinator() -> Coordinator {
    Coordinator(receiver: receiver)
  }

  func makeNSView(context: Context) -> HighSpeedPreviewView {
    let view = HighSpeedPreviewView()
    view.rotationDegrees = rotationDegrees
    context.coordinator.attach(receiver: receiver, layer: view.displayLayer)
    return view
  }

  func updateNSView(_ view: HighSpeedPreviewView, context: Context) {
    view.rotationDegrees = rotationDegrees
    context.coordinator.attach(receiver: receiver, layer: view.displayLayer)
  }

  static func dismantleNSView(_ view: HighSpeedPreviewView, coordinator: Coordinator) {
    coordinator.detach(layer: view.displayLayer)
  }

  @MainActor
  final class Coordinator {
    private weak var receiver: HighSpeedVideoReceiver?
    private weak var layer: AVSampleBufferDisplayLayer?

    init(receiver: HighSpeedVideoReceiver) {
      self.receiver = receiver
    }

    func attach(receiver: HighSpeedVideoReceiver, layer: AVSampleBufferDisplayLayer) {
      guard self.receiver !== receiver || self.layer !== layer else { return }

      if let previousReceiver = self.receiver,
        previousReceiver !== receiver
      {
        HighSpeedPreviewAttachmentRegistry.detach(previousReceiver, ifCurrentLayerIs: self.layer)
      }

      self.receiver = receiver
      self.layer = layer
      HighSpeedPreviewAttachmentRegistry.attach(receiver, layer: layer)
    }

    func detach(layer: AVSampleBufferDisplayLayer) {
      layer.flushAndRemoveImage()

      guard self.layer === layer, let receiver else { return }
      HighSpeedPreviewAttachmentRegistry.detach(receiver, ifCurrentLayerIs: layer)
      self.layer = nil
    }
  }
}

/// A lightweight AppKit host that owns the display layer and keeps it fitted
/// to SwiftUI's proposed size without implicit Core Animation resize actions.
@MainActor
final class HighSpeedPreviewView: NSView {
  let displayLayer = AVSampleBufferDisplayLayer()
  var rotationDegrees = 0.0 {
    didSet {
      guard abs(rotationDegrees - oldValue) > 0.001 else { return }
      needsLayout = true
    }
  }

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
    let normalized = (rotationDegrees.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)
    let swapsDimensions = abs(normalized - 90) < 0.1 || abs(normalized - 270) < 0.1
    displayLayer.bounds = CGRect(
      origin: .zero,
      size: swapsDimensions
        ? CGSize(width: bounds.height, height: bounds.width)
        : bounds.size
    )
    displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    // AVCaptureDevice.RotationCoordinator reports a clockwise display angle.
    // Core Animation on macOS uses the opposite sign for its affine rotation,
    // so applying the iPhone value directly turns portrait feeds 180 degrees
    // away from their intended orientation (90 becomes the visual 270).
    displayLayer.setAffineTransform(
      CGAffineTransform(rotationAngle: -rotationDegrees * .pi / 180)
    )
    CATransaction.commit()
  }

}

/// SwiftUI may create a replacement `NSView` before dismantling the old one.
/// Track the currently attached layer per receiver so the old coordinator
/// cannot clear the replacement's live preview attachment.
@MainActor
private enum HighSpeedPreviewAttachmentRegistry {
  private static var currentLayers: [ObjectIdentifier: WeakDisplayLayer] = [:]

  static func attach(_ receiver: HighSpeedVideoReceiver, layer: AVSampleBufferDisplayLayer) {
    removeReleasedLayers()
    currentLayers[ObjectIdentifier(receiver)] = WeakDisplayLayer(layer)
    receiver.attachPreviewLayer(layer)
  }

  static func detach(
    _ receiver: HighSpeedVideoReceiver,
    ifCurrentLayerIs layer: AVSampleBufferDisplayLayer?
  ) {
    let key = ObjectIdentifier(receiver)
    guard currentLayers[key]?.layer === layer else { return }

    receiver.attachPreviewLayer(nil)
    currentLayers.removeValue(forKey: key)
  }

  private static func removeReleasedLayers() {
    currentLayers = currentLayers.filter { _, attachment in
      attachment.layer != nil
    }
  }
}

@MainActor
private final class WeakDisplayLayer {
  weak var layer: AVSampleBufferDisplayLayer?

  init(_ layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
  }
}
