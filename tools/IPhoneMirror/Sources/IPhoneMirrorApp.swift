import AVFoundation
import CoreMediaIO
import SwiftUI

@main
struct IPhoneMirrorApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 920, minHeight: 640)
    }
    .windowStyle(.titleBar)
  }
}

@MainActor
final class MirrorModel: ObservableObject {
  @Published var devices: [AVCaptureDevice] = []
  @Published var selectedDeviceID: String?
  @Published var status = "เสียบ iPhone ด้วย USB แล้วกด Refresh"
  @Published var isRunning = false

  let session = AVCaptureSession()
  private var currentInput: AVCaptureDeviceInput?

  var selectedDevice: AVCaptureDevice? {
    devices.first { $0.uniqueID == selectedDeviceID }
  }

  init() {
    enableIPhoneScreenCaptureDevices()
    refreshDevices()
  }

  func refreshDevices() {
    enableIPhoneScreenCaptureDevices()

    var deviceTypes: [AVCaptureDevice.DeviceType] = [.externalUnknown]
    deviceTypes.insert(.external, at: 0)

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes,
      mediaType: .muxed,
      position: .unspecified
    )

    var seen = Set<String>()
    devices = discovery.devices.filter { device in
      guard !seen.contains(device.uniqueID) else { return false }
      seen.insert(device.uniqueID)
      return true
    }

    if let current = selectedDeviceID, devices.contains(where: { $0.uniqueID == current }) {
      return
    }

    selectedDeviceID = preferredIPhoneDevice()?.uniqueID ?? devices.first?.uniqueID
    status = devices.isEmpty ? "ยังไม่เจอจอ iPhone: เสียบ USB, ปลดล็อก, กด Trust แล้วลอง QuickTime > New Movie Recording" : "เจอ iPhone screen \(devices.count) รายการ แล้วกด Start Mirror"
  }

  func start() {
    guard let device = selectedDevice else {
      status = "ยังไม่เจออุปกรณ์วิดีโอ"
      return
    }

    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession(device)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in
          guard let self else { return }
          granted ? self.configureSession(device) : (self.status = "ต้องอนุญาต Camera permission ก่อน")
        }
      }
    default:
      status = "เปิดสิทธิ์ Camera ให้ IPhoneMirror ใน System Settings > Privacy & Security > Camera"
    }
  }

  func stop() {
    session.stopRunning()
    isRunning = false
    status = "หยุด mirror แล้ว"
  }

  private func preferredIPhoneDevice() -> AVCaptureDevice? {
    devices.first { device in
      let name = device.localizedName.lowercased()
      return name.contains("iphone") || name.contains("ipad")
    }
  }

  private func enableIPhoneScreenCaptureDevices() {
    var propertyAddress = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(
      CMIOObjectID(kCMIOObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      UInt32(MemoryLayout.size(ofValue: allow)),
      &allow
    )
  }

  private func configureSession(_ device: AVCaptureDevice) {
    do {
      let input = try AVCaptureDeviceInput(device: device)

      session.beginConfiguration()
      session.sessionPreset = .high
      if let currentInput {
        session.removeInput(currentInput)
      }
      if session.canAddInput(input) {
        session.addInput(input)
        currentInput = input
      }
      session.commitConfiguration()

      DispatchQueue.global(qos: .userInitiated).async { [session] in
        session.startRunning()
        DispatchQueue.main.async {
          self.isRunning = true
          self.status = "Mirroring: \(device.localizedName)"
        }
      }
    } catch {
      status = "เปิดอุปกรณ์ไม่ได้: \(error.localizedDescription)"
    }
  }
}

struct ContentView: View {
  @StateObject private var model = MirrorModel()

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("iPhone USB Mirror")
          .font(.title2.bold())

        Spacer()

        Picker("Device", selection: $model.selectedDeviceID) {
          if model.devices.isEmpty {
            Text("No iPhone screen").tag(Optional<String>.none)
          }
          ForEach(model.devices, id: \.uniqueID) { device in
            Text(device.localizedName).tag(Optional(device.uniqueID))
          }
        }
        .frame(width: 260)

        Button("Refresh") {
          model.refreshDevices()
        }

        Button(model.isRunning ? "Stop" : "Start Mirror") {
          model.isRunning ? model.stop() : model.start()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding()
      .background(.regularMaterial)

      PreviewView(session: model.session)
        .overlay(alignment: .bottomLeading) {
          Text(model.status)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
            .padding()
        }
    }
  }
}

struct PreviewView: NSViewRepresentable {
  let session: AVCaptureSession

  func makeNSView(context: Context) -> PreviewContainerView {
    let view = PreviewContainerView()
    view.previewLayer.session = session
    return view
  }

  func updateNSView(_ nsView: PreviewContainerView, context: Context) {
    nsView.previewLayer.session = session
  }
}

final class PreviewContainerView: NSView {
  let previewLayer = AVCaptureVideoPreviewLayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.black.cgColor
    previewLayer.videoGravity = .resizeAspect
    layer?.addSublayer(previewLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    previewLayer.frame = bounds
  }
}
