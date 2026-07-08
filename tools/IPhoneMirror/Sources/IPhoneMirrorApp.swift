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
  @Published var audioEnabled = true

  let session = AVCaptureSession()
  private var currentInput: AVCaptureDeviceInput?
  private let audioPreviewOutput = AVCaptureAudioPreviewOutput()

  var selectedDevice: AVCaptureDevice? {
    devices.first { $0.uniqueID == selectedDeviceID }
  }

  init() {
    enableIPhoneScreenCaptureDevices()
    refreshDevices()
  }

  func refreshDevices() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      scanDevices()
    case .notDetermined:
      status = "กำลังขอสิทธิ์ Camera เพื่ออ่าน iPhone screen feed"
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor in
          guard let self else { return }
          granted ? self.scanDevices() : (self.status = "ต้องอนุญาต Camera permission ก่อนถึงจะเห็น iPhone screen")
        }
      }
    default:
      status = "เปิดสิทธิ์ Camera ให้ IPhoneMirror ใน System Settings > Privacy & Security > Camera"
    }
  }

  private func scanDevices() {
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
    let names = devices.map(\.localizedName).joined(separator: ", ")
    status = devices.isEmpty ? "ยังไม่เจอจอ iPhone: เสียบ USB, ปลดล็อก, กด Trust แล้วลอง QuickTime > New Movie Recording" : "เจอ iPhone screen: \(names)"
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

  func toggleAudio() {
    audioEnabled.toggle()
    audioPreviewOutput.volume = audioEnabled ? 1.0 : 0.0
    status = audioEnabled ? "เปิดเสียงจาก iPhone เข้า Mac แล้ว" : "ปิดเสียงจาก iPhone แล้ว"
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
      if !session.outputs.contains(audioPreviewOutput), session.canAddOutput(audioPreviewOutput) {
        audioPreviewOutput.outputDeviceUniqueID = nil
        audioPreviewOutput.volume = audioEnabled ? 1.0 : 0.0
        session.addOutput(audioPreviewOutput)
      }
      session.commitConfiguration()

      let audioStatus = session.outputs.contains(audioPreviewOutput) ? " + audio" : " (ยังเปิด audio preview ไม่ได้)"
      DispatchQueue.global(qos: .userInitiated).async { [session] in
        session.startRunning()
        DispatchQueue.main.async {
          self.isRunning = true
          self.status = "Mirroring: \(device.localizedName)\(audioStatus)"
        }
      }
    } catch {
      status = "เปิดอุปกรณ์ไม่ได้: \(error.localizedDescription)"
    }
  }
}

struct ContentView: View {
  @StateObject private var model = MirrorModel()
  @State private var theaterMode = false
  @State private var ratioMode = "Fill"
  @State private var zoom = 1.0

  var body: some View {
    ZStack {
      PreviewView(
        session: model.session,
        videoGravity: videoGravity,
        zoom: zoom
      )
      .ignoresSafeArea()

      if !theaterMode {
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

            Button(model.audioEnabled ? "Audio On" : "Audio Off") {
              model.toggleAudio()
            }

            Picker("Ratio", selection: $ratioMode) {
              Text("Fit").tag("Fit")
              Text("Fill").tag("Fill")
              Text("Stretch").tag("Stretch")
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            HStack(spacing: 8) {
              Button("-") {
                adjustZoom(-0.05)
              }
              Slider(value: $zoom, in: 0.75...1.75, step: 0.01)
                .frame(width: 120)
              Button("+") {
                adjustZoom(0.05)
              }
              Text(String(format: "%.2fx", zoom))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            }

            Button("Fullscreen") {
              toggleTheaterMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])

            Button(model.isRunning ? "Stop" : "Start Mirror") {
              model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)
          }
          .padding()
          .background(.regularMaterial)

          Spacer()

          HStack {
            Text(model.status)
              .font(.callout)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(.black.opacity(0.65), in: Capsule())
              .foregroundStyle(.white)
              .padding()
            Spacer()
          }
        }
      }

      if theaterMode {
        VStack {
          Spacer()
          HStack(spacing: 10) {
            Button("Fit") {
              ratioMode = "Fit"
            }
            Button("Fill") {
              ratioMode = "Fill"
            }
            Button("Stretch") {
              ratioMode = "Stretch"
            }
            Divider()
              .frame(height: 20)
            Button("-") {
              adjustZoom(-0.05)
            }
            Text(String(format: "%.2fx", zoom))
              .font(.callout.monospacedDigit())
              .frame(width: 52)
            Button("+") {
              adjustZoom(0.05)
            }
          }
          .buttonStyle(.bordered)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.black.opacity(0.55), in: Capsule())
          .padding(.bottom, 24)
        }
      }
    }
    .background(.black)
    .keyboardShortcut("f", modifiers: [.command, .control])
  }

  private var videoGravity: AVLayerVideoGravity {
    switch ratioMode {
    case "Fit":
      return .resizeAspect
    case "Stretch":
      return .resize
    default:
      return .resizeAspectFill
    }
  }

  private func adjustZoom(_ delta: Double) {
    zoom = min(1.75, max(0.75, zoom + delta))
  }

  private func toggleTheaterMode() {
    theaterMode.toggle()
    if theaterMode {
      NSApp.presentationOptions.insert([.autoHideDock, .autoHideMenuBar])
    } else {
      NSApp.presentationOptions.remove([.autoHideDock, .autoHideMenuBar])
    }
    NSApp.keyWindow?.toggleFullScreen(nil)
  }
}

struct PreviewView: NSViewRepresentable {
  let session: AVCaptureSession
  let videoGravity: AVLayerVideoGravity
  let zoom: Double

  func makeNSView(context: Context) -> PreviewContainerView {
    let view = PreviewContainerView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = videoGravity
    view.zoom = zoom
    return view
  }

  func updateNSView(_ nsView: PreviewContainerView, context: Context) {
    nsView.previewLayer.session = session
    nsView.previewLayer.videoGravity = videoGravity
    nsView.zoom = zoom
  }
}

final class PreviewContainerView: NSView {
  let previewLayer = AVCaptureVideoPreviewLayer()
  var zoom = 1.0 {
    didSet {
      needsLayout = true
    }
  }

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
    previewLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    previewLayer.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
  }
}
