import AVFoundation
import CoreMediaIO
import CoreGraphics
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

@MainActor
final class WDAControlModel: ObservableObject {
  @Published var enabled = false
  @Published var status = "Control Off"
  @Published var debugPoint: CGPoint?
  @Published var debugText = ""
  @Published var screenSize = CGSize(width: 430, height: 932)

  private let baseURLCandidates = [
    URL(string: "http://127.0.0.1:8100")!,
    URL(string: "http://192.168.1.190:8100")!
  ]
  private var baseURL = URL(string: "http://127.0.0.1:8100")!
  private var sessionID: String?

  func toggle() {
    if enabled {
      enabled = false
      sessionID = nil
      status = "Control Off"
      return
    }

    enabled = true
    status = "กำลังต่อ WDA..."
    Task {
      let ready = await connect()
      if !ready {
        enabled = false
      }
    }
  }

  func tap(normalized point: CGPoint) {
    guard enabled else { return }
    showDebug(point, label: "tap")
    Task {
      guard await ensureConnected(), let sessionID else { return }
      let point = devicePoint(from: point)
      let sent = await post("/session/\(sessionID)/wda/tap", body: [
        "x": point.x,
        "y": point.y
      ])
      if sent != nil {
        status = "Tap \(Int(point.x)), \(Int(point.y))"
      }
    }
  }

  func swipe(from start: CGPoint, to end: CGPoint) {
    guard enabled else { return }
    showDebug(end, label: "swipe")
    Task {
      guard await ensureConnected(), let sessionID else { return }
      let start = devicePoint(from: start)
      let end = devicePoint(from: end)
      let sent = await post("/session/\(sessionID)/wda/dragfromtoforduration", body: [
        "duration": 0.12,
        "fromX": start.x,
        "fromY": start.y,
        "toX": end.x,
        "toY": end.y
      ])
      if sent != nil {
        status = "Swipe \(Int(start.x)),\(Int(start.y)) -> \(Int(end.x)),\(Int(end.y))"
      }
    }
  }

  private func connect() async -> Bool {
    var lastError = "unknown"
    for candidate in baseURLCandidates {
      do {
        baseURL = candidate
        let statusJSON = try await requestJSON("/status", method: "GET")
        if let value = statusJSON["value"] as? [String: Any],
           let message = value["message"] as? String {
          status = "WDA: \(message)"
        }

        let sessionJSON = try await requestJSON(
          "/session",
          method: "POST",
          body: ["capabilities": ["alwaysMatch": [:]]]
        )
        if let value = sessionJSON["value"] as? [String: Any],
           let id = value["sessionId"] as? String {
          sessionID = id
        } else if let id = sessionJSON["sessionId"] as? String {
          sessionID = id
        }

        await updateScreenSize()
        status = "Control On: WDA ready via \(candidate.host ?? "localhost")"
        return true
      } catch {
        sessionID = nil
        lastError = error.localizedDescription
      }
    }
    status = "Control ใช้ไม่ได้: เปิด WDA ก่อน (\(lastError))"
    return false
  }

  private func showDebug(_ point: CGPoint, label: String) {
    debugPoint = point
    debugText = "\(label) x \(String(format: "%.3f", point.x)) y \(String(format: "%.3f", point.y))"
    status = "Mouse \(debugText)"
  }

  private func ensureConnected() async -> Bool {
    if sessionID == nil {
      return await connect()
    }
    return true
  }

  private func updateScreenSize() async {
    guard let sessionID else { return }
    do {
      let json = try await requestJSON("/session/\(sessionID)/window/size", method: "GET")
      if let value = json["value"] as? [String: Any],
         let width = number(value["width"]),
         let height = number(value["height"]) {
        screenSize = CGSize(width: width, height: height)
      }
    } catch {
      status = "ต่อ WDA ได้ แต่ยังอ่านขนาดจอไม่ได้"
    }
  }

  @discardableResult
  private func post(_ path: String, body: [String: Any]) async -> [String: Any]? {
    do {
      return try await requestJSON(path, method: "POST", body: body)
    } catch {
      status = "ส่งคำสั่งไม่สำเร็จ: \(error.localizedDescription)"
      return nil
    }
  }

  private func requestJSON(_ path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 3
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, _) = try await URLSession.shared.data(for: request)
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
  }

  private func devicePoint(from normalized: CGPoint) -> CGPoint {
    CGPoint(
      x: max(0, min(screenSize.width, normalized.x * screenSize.width)),
      y: max(0, min(screenSize.height, normalized.y * screenSize.height))
    )
  }

  private func number(_ value: Any?) -> CGFloat? {
    if let value = value as? CGFloat { return value }
    if let value = value as? Double { return CGFloat(value) }
    if let value = value as? Int { return CGFloat(value) }
    return nil
  }
}

struct ContentView: View {
  @StateObject private var model = MirrorModel()
  @StateObject private var control = WDAControlModel()
  @State private var theaterMode = false
  @State private var ratioMode = "Fit"
  @State private var rotationDegrees = 0.0
  @State private var showControls = true
  @State private var gestureStart: CGPoint?

  var body: some View {
    ZStack {
      PreviewView(
        session: model.session,
        videoGravity: videoGravity,
        rotationDegrees: rotationDegrees
      )
      .ignoresSafeArea()

      if control.enabled, let point = control.debugPoint {
        GeometryReader { proxy in
          let mirrorRect = mirrorContentRect(in: proxy.size)
          let x = mirrorRect.minX + mirrorRect.width * point.x
          let y = mirrorRect.minY + mirrorRect.height * point.y
          ZStack(alignment: .topLeading) {
            Circle()
              .stroke(.cyan, lineWidth: 3)
              .frame(width: 34, height: 34)
              .position(x: x, y: y)
            Text(control.debugText)
              .font(.caption.monospacedDigit())
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(.black.opacity(0.75), in: Capsule())
              .foregroundStyle(.cyan)
              .position(x: min(max(x, 95), proxy.size.width - 95), y: min(y + 34, proxy.size.height - 20))
          }
        }
        .allowsHitTesting(false)
      }

      if !theaterMode && showControls {
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

            Button(control.enabled ? "Control On" : "Control Off") {
              control.toggle()
            }

            Picker("Ratio", selection: $ratioMode) {
              Text("Fit").tag("Fit")
              Text("Fill").tag("Fill")
              Text("Stretch").tag("Stretch")
            }
            .pickerStyle(.segmented)
            .frame(width: 210)

            Button("Rotate") {
              rotatePreview()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("Fullscreen") {
              toggleTheaterMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])

            Button("Hide") {
              showControls = false
            }
            .keyboardShortcut("c", modifiers: [])

            Button(model.isRunning ? "Stop" : "Start Mirror") {
              model.isRunning ? model.stop() : model.start()
            }
            .keyboardShortcut(.defaultAction)
          }
          .padding()
          .background(.regularMaterial)

          Spacer()

          HStack {
            Text("\(model.status)  |  \(control.status)")
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

      if theaterMode && showControls {
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
            Button("Rotate") {
              rotatePreview()
            }
            .keyboardShortcut("r", modifiers: [])
            Text("\(Int(rotationDegrees))°")
              .font(.callout.monospacedDigit())
              .frame(width: 44)
            Button("Reset") {
              rotationDegrees = 0
            }
            Button(control.enabled ? "Control On" : "Control Off") {
              control.toggle()
            }
            Button("Hide") {
              showControls = false
            }
            .keyboardShortcut("c", modifiers: [])
          }
          .buttonStyle(.bordered)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.black.opacity(0.55), in: Capsule())
          .padding(.bottom, 24)
        }
      }

      if !showControls {
        VStack {
          Spacer()
          HStack {
            Button("Controls") {
              showControls = true
            }
            .keyboardShortcut("c", modifiers: [])
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(12)
            Spacer()
          }
        }
      }
    }
    .background(.black)
    .contentShape(Rectangle())
    .simultaneousGesture(controlGesture)
    .keyboardShortcut("f", modifiers: [.command, .control])
  }

  private var controlGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        guard control.enabled else { return }
        if gestureStart == nil {
          gestureStart = normalizedPoint(value.startLocation)
        }
      }
      .onEnded { value in
        guard control.enabled else { return }
        let start = gestureStart ?? normalizedPoint(value.startLocation)
        let end = normalizedPoint(value.location)
        gestureStart = nil
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance < 0.025 {
          control.tap(normalized: end)
        } else {
          control.swipe(from: start, to: end)
        }
      }
  }

  private func normalizedPoint(_ location: CGPoint) -> CGPoint {
    guard let window = NSApp.keyWindow else { return .zero }
    let width = max(window.contentView?.bounds.width ?? 1, 1)
    let height = max(window.contentView?.bounds.height ?? 1, 1)
    let mirrorRect = mirrorContentRect(in: CGSize(width: width, height: height))
    return CGPoint(
      x: max(0, min(1, (location.x - mirrorRect.minX) / mirrorRect.width)),
      y: max(0, min(1, (location.y - mirrorRect.minY) / mirrorRect.height))
    )
  }

  private func mirrorContentRect(in size: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else {
      return CGRect(origin: .zero, size: CGSize(width: 1, height: 1))
    }
    let aspect = max(control.screenSize.width / max(control.screenSize.height, 1), 0.01)
    let viewAspect = size.width / size.height

    switch ratioMode {
    case "Stretch":
      return CGRect(origin: .zero, size: size)
    case "Fill":
      if viewAspect > aspect {
        let contentHeight = size.width / aspect
        return CGRect(x: 0, y: (size.height - contentHeight) / 2, width: size.width, height: contentHeight)
      }
      let contentWidth = size.height * aspect
      return CGRect(x: (size.width - contentWidth) / 2, y: 0, width: contentWidth, height: size.height)
    default:
      if viewAspect > aspect {
        let contentWidth = size.height * aspect
        return CGRect(x: (size.width - contentWidth) / 2, y: 0, width: contentWidth, height: size.height)
      }
      let contentHeight = size.width / aspect
      return CGRect(x: 0, y: (size.height - contentHeight) / 2, width: size.width, height: contentHeight)
    }
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

  private func rotatePreview() {
    rotationDegrees = rotationDegrees >= 270 ? 0 : rotationDegrees + 90
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
  let rotationDegrees: Double

  func makeNSView(context: Context) -> PreviewContainerView {
    let view = PreviewContainerView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = videoGravity
    view.rotationDegrees = rotationDegrees
    return view
  }

  func updateNSView(_ nsView: PreviewContainerView, context: Context) {
    nsView.previewLayer.session = session
    nsView.previewLayer.videoGravity = videoGravity
    nsView.rotationDegrees = rotationDegrees
  }
}

final class PreviewContainerView: NSView {
  let previewLayer = AVCaptureVideoPreviewLayer()
  var rotationDegrees = 0.0 {
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

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func layout() {
    super.layout()
    previewLayer.frame = bounds
    previewLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    let radians = CGFloat(rotationDegrees * .pi / 180)
    previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: radians))
  }
}
