import AVFoundation
import SwiftUI

struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession

  func makeNSView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    return view
  }

  func updateNSView(_ view: PreviewView, context: Context) {
    if view.previewLayer.session !== session {
      view.previewLayer.session = session
    }
  }
}

final class PreviewView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = AVCaptureVideoPreviewLayer()
    previewLayer.videoGravity = .resizeAspect
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    guard let layer = layer as? AVCaptureVideoPreviewLayer else {
      fatalError("PreviewView layer must be AVCaptureVideoPreviewLayer")
    }
    return layer
  }
}
