import SwiftUI
import GenieMax
import SceneKit
import CoreBluetooth
import Combine

@main
struct KiriTaraMaruApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootTabView()
        .environmentObject(model)
    }
  }
}

final class AppModel: ObservableObject {
  @Published var connector = WhoopConnector()
  let history: DailyHistory
  let metrics: DashboardMetrics
  let insights: [Insight]
  let hasRealMetrics = false
  private var cancellables = Set<AnyCancellable>()

  init() {
    var state = PersistedState()
    var history = DailyHistory()
    let records: [DailyRecord] = [
      .init(date: "2026-06-24", dayStrain: 9.8, rhr: 58, lnRMSSD: log(48), resp: 14.5, skinTemp: 33.0, sleepScore: 72, recovery: 58, readiness: 61, deep: 86, rem: 94, light: 248, wake: 38, steps: 7600, kcal: 2280),
      .init(date: "2026-06-25", dayStrain: 13.4, rhr: 57, lnRMSSD: log(53), resp: 14.2, skinTemp: 33.1, sleepScore: 80, recovery: 68, readiness: 70, deep: 91, rem: 101, light: 262, wake: 28, steps: 10400, kcal: 2520),
      .init(date: "2026-06-26", dayStrain: 15.8, rhr: 60, lnRMSSD: log(43), resp: 14.8, skinTemp: 33.4, sleepScore: 67, recovery: 42, readiness: 48, deep: 68, rem: 83, light: 231, wake: 51, steps: 12100, kcal: 2760),
      .init(date: "2026-06-27", dayStrain: 7.2, rhr: 56, lnRMSSD: log(57), resp: 14.0, skinTemp: 33.0, sleepScore: 86, recovery: 76, readiness: 78, deep: 99, rem: 107, light: 275, wake: 22, steps: 6200, kcal: 2160),
      .init(date: "2026-06-28", dayStrain: 10.6, rhr: 59, lnRMSSD: log(50), resp: 14.6, skinTemp: 33.2, sleepScore: 74, recovery: 63, readiness: 64, deep: 82, rem: 98, light: 242, wake: 35, steps: 8800, kcal: 2350),
      .init(date: "2026-06-29", dayStrain: 12.1, rhr: 61, lnRMSSD: log(40), resp: 15.1, skinTemp: 33.5, sleepScore: 69, recovery: 39, readiness: 45, deep: 73, rem: 88, light: 236, wake: 47, steps: 9300, kcal: 2410),
      .init(date: "2026-06-30", dayStrain: 8.4, rhr: 58, lnRMSSD: log(52), resp: 14.4, skinTemp: 33.1, sleepScore: 78, recovery: 66, readiness: 68, deep: 88, rem: 96, light: 250, wake: 30, steps: 7100, kcal: 2240)
    ]
    records.forEach { record in
      history.upsert(record)
      if let hrv = record.lnRMSSD { state.hrvBaseline.update(hrv) }
      if let rhr = record.rhr { state.rhrBaseline.update(rhr) }
      if let resp = record.resp { state.respBaseline.update(resp) }
      if let temp = record.skinTemp { state.tempBaseline.update(temp) }
      if let sleep = record.sleepScore { state.sleepBaseline.update(sleep) }
    }

    let daily = DailyMetricsEngine.compute(history, state: state)
    let latest = history.last
    self.history = history
    self.metrics = DashboardMetrics(
      recovery: latest?.recovery ?? 0,
      readiness: latest?.readiness ?? 0,
      strain: latest?.dayStrain ?? 0,
      sleep: latest?.sleepScore ?? 0,
      rhr: latest?.rhr ?? 0,
      rmssd: latest?.lnRMSSD.map(exp) ?? 0,
      steps: latest?.steps ?? 0,
      sleepDebt: daily.sleepDebtH,
      tsb: daily.tsb,
      acwr: daily.acwr,
      resilience: daily.resilience,
      resilienceLevel: daily.resilienceLevel
    )
    self.insights = InsightEngine.daily(
      recovery: latest?.recovery,
      tsb: daily.tsb,
      sleepScore: latest?.sleepScore,
      sleepDebt: daily.sleepDebtH
    )

    connector.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

struct DashboardMetrics {
  let recovery: Double
  let readiness: Double
  let strain: Double
  let sleep: Double
  let rhr: Double
  let rmssd: Double
  let steps: Int
  let sleepDebt: Double
  let tsb: Double?
  let acwr: Double?
  let resilience: Double?
  let resilienceLevel: String?
}

struct RootTabView: View {
  var body: some View {
    TabView {
      TodayView()
        .tabItem { Label("Today", systemImage: "heart.text.square") }
      PetView()
        .tabItem { Label("Pet", systemImage: "pawprint") }
      InsightsView()
        .tabItem { Label("Insights", systemImage: "sparkles") }
      HistoryView()
        .tabItem { Label("History", systemImage: "chart.line.uptrend.xyaxis") }
      ConnectView()
        .tabItem { Label("WHOOP", systemImage: "dot.radiowaves.left.and.right") }
    }
  }
}

struct TodayView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HeaderBlock(title: "Today", subtitle: connectionSubtitle)

          VStack(spacing: 12) {
            ScoreCard(title: "Recovery", value: scoreText(model.metrics.recovery), suffix: model.hasRealMetrics ? "%" : "", progress: model.hasRealMetrics ? model.metrics.recovery : nil, total: 100, tint: recoveryTint)
            ScoreCard(title: "Readiness", value: scoreText(model.metrics.readiness), suffix: model.hasRealMetrics ? "%" : "", progress: model.hasRealMetrics ? model.metrics.readiness : nil, total: 100, tint: .teal)
            ScoreCard(title: "Strain", value: model.hasRealMetrics ? String(format: "%.1f", model.metrics.strain) : "--", suffix: model.hasRealMetrics ? "/21" : "", progress: model.hasRealMetrics ? model.metrics.strain : nil, total: 21, tint: .orange)
          }

          SectionHeader("Vitals")
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            MetricTile(title: "RMSSD", value: metricText("\(Int(model.metrics.rmssd)) ms"), icon: "waveform.path.ecg")
            MetricTile(title: "RHR", value: metricText("\(Int(model.metrics.rhr)) bpm"), icon: "heart")
            MetricTile(title: "Sleep", value: metricText("\(Int(model.metrics.sleep))%"), icon: "moon.zzz")
            MetricTile(title: "Steps", value: metricText(model.metrics.steps.formatted()), icon: "figure.walk")
          }

          PetMiniPanel()
        }
        .padding(20)
        .padding(.bottom, 88)
      }
      .navigationTitle("KiriTaraMaru")
    }
  }

  private var connectionSubtitle: String {
    model.connector.connectedName.map { "Connected to \($0)" } ?? "WHOOP not connected - real metrics unavailable"
  }

  private var recoveryTint: Color {
    if model.metrics.recovery >= 67 { return .green }
    if model.metrics.recovery >= 34 { return .yellow }
    return .red
  }

  private func scoreText(_ value: Double) -> String {
    model.hasRealMetrics ? "\(Int(value))" : "--"
  }

  private func metricText(_ value: String) -> String {
    model.hasRealMetrics ? value : "--"
  }
}

struct PetView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let state = PetState(score: model.petScore)
    NavigationStack {
      GeometryReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            HeaderBlock(title: "Jack Russell : Maruchan", subtitle: model.hasRealMetrics ? "Health companion" : "Waiting for WHOOP data")

            PetSceneView(state: state)
              .frame(height: sceneHeight(for: proxy.size))
              .clipShape(RoundedRectangle(cornerRadius: 8))
              .overlay(alignment: .topLeading) {
                Text(model.hasRealMetrics ? state.label : "Waiting")
                  .font(.headline)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(.thinMaterial, in: Capsule())
                  .padding(14)
              }
              .accessibilityLabel("Jack Russell Maruchan companion")

            VStack(alignment: .leading, spacing: 14) {
              HStack(alignment: .lastTextBaseline) {
                Text("Maruchan vitality")
                  .font(.title2.bold())
                Spacer()
                Text("\(model.petScore)")
                  .font(.system(size: 44, weight: .bold, design: .rounded))
              }

              ProgressView(value: Double(model.petScore), total: 100)
                .tint(state.tint)

              Text(model.hasRealMetrics ? state.message : "Connect WHOOP to let Maruchan react to real recovery and activity.")
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
          }
          .padding(20)
          .padding(.bottom, 88)
        }
      }
      .navigationTitle("Pet")
    }
  }

  private func sceneHeight(for size: CGSize) -> CGFloat {
    min(max(size.height * 0.46, 360), 480)
  }
}

struct PetMiniPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let state = PetState(score: model.petScore)
    NavigationLink {
      PetView()
    } label: {
      HStack(spacing: 14) {
        Image(systemName: "pawprint.fill")
          .font(.title2)
          .foregroundStyle(state.tint)
          .frame(width: 42, height: 42)
          .background(state.tint.opacity(0.14), in: Circle())
        VStack(alignment: .leading, spacing: 4) {
          Text("Maruchan vitality")
            .font(.headline)
          Text(model.hasRealMetrics ? state.label : "Waiting for WHOOP")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(model.hasRealMetrics ? "\(model.petScore)" : "--")
          .font(.title.bold())
      }
      .padding()
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
  }
}

struct InsightsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationStack {
      List {
        Section("Coach") {
          ForEach(Array(model.insights.enumerated()), id: \.offset) { _, insight in
            Label(insight.text, systemImage: icon(for: insight.kind))
          }
        }
        Section("Training") {
          MetricRow(title: "Sleep debt", value: String(format: "%.1fh", model.metrics.sleepDebt))
          MetricRow(title: "TSB", value: model.metrics.tsb.map { String(format: "%+.1f", $0) } ?? "Warming up")
          MetricRow(title: "ACWR", value: model.metrics.acwr.map { String(format: "%.2f", $0) } ?? "Warming up")
          MetricRow(title: "Resilience", value: resilienceText)
        }
      }
      .navigationTitle("Insights")
    }
  }

  private var resilienceText: String {
    guard let score = model.metrics.resilience else { return "Warming up" }
    return "\(Int(score)) \(model.metrics.resilienceLevel ?? "")"
  }

  private func icon(for kind: Insight.Kind) -> String {
    switch kind {
    case .recovery: return "battery.75percent"
    case .strain: return "figure.run"
    case .sleep: return "bed.double"
    case .form: return "chart.line.uptrend.xyaxis"
    case .general: return "sparkles"
    }
  }
}

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.history.days.reversed(), id: \.date) { day in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(day.date)
                .font(.headline)
              Spacer()
              Text(String(format: "%.1f strain", day.dayStrain))
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
              HistoryPill(title: "Recovery", value: day.recovery.map { "\(Int($0))%" } ?? "--")
              HistoryPill(title: "Sleep", value: day.sleepScore.map { "\(Int($0))%" } ?? "--")
              HistoryPill(title: "Steps", value: day.steps?.formatted() ?? "--")
            }
          }
          .padding(.vertical, 6)
        }
      }
      .navigationTitle("History")
    }
  }
}

struct ConnectView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationStack {
      List {
        Section("Status") {
          Label(model.connector.statusText, systemImage: model.connector.statusIcon)
          if let name = model.connector.connectedName {
            MetricRow(title: "Device", value: name)
          }
          if model.connector.isScanning {
            ProgressView("Scanning nearby Bluetooth devices")
          }
        }

        Section("Pair WHOOP") {
          Button {
            model.connector.isScanning ? model.connector.stopScan() : model.connector.scan()
          } label: {
            Label(model.connector.isScanning ? "Stop scanning" : "Scan for WHOOP", systemImage: "dot.radiowaves.left.and.right")
          }
          .disabled(!model.connector.canScan && !model.connector.isScanning)

          ForEach(model.connector.devices) { device in
            Button {
              model.connector.connect(device)
            } label: {
              HStack {
                VStack(alignment: .leading) {
                  Text(device.name)
                    .fontWeight(device.isLikelyWhoop ? .semibold : .regular)
                  Text(device.detailText)
                    .font(.caption)
                    .foregroundStyle(device.isLikelyWhoop ? .green : .secondary)
                  Text(device.id.uuidString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                Image(systemName: "link")
              }
            }
          }

          if !model.connector.isScanning && model.connector.devices.isEmpty {
            Text("Keep your WHOOP close to the phone. If it does not show a name, it may appear as an unnamed nearby device.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Section("Sync") {
          Link(destination: URL(string: "https://whoop-e2ee-sync.paewhoop.workers.dev")!) {
            Label("Cloudflare backend online", systemImage: "cloud")
          }
          Text("Next build step: map WHOOP characteristics from the connected strap into the GenieMax decoder, then persist encrypted sync.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("WHOOP")
    }
  }
}

struct HeaderBlock: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.largeTitle.bold())
      Text(subtitle)
        .font(.title3)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SectionHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.headline)
      .padding(.top, 4)
  }
}

struct ScoreCard: View {
  let title: String
  let value: String
  let suffix: String
  let progress: Double?
  let total: Double
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .lastTextBaseline) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
        Text(value)
          .font(.system(size: 44, weight: .bold, design: .rounded))
        Text(suffix)
          .font(.title3.bold())
          .foregroundStyle(.secondary)
      }
      ProgressView(value: progress ?? 0, total: total)
        .tint(progress == nil ? .gray : tint)
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

struct MetricTile: View {
  let title: String
  let value: String
  let icon: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.teal)
      Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.bold())
        .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}

struct MetricRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.semibold)
    }
  }
}

struct HistoryPill: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.subheadline.bold())
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }
}

extension AppModel {
  var petScore: Int {
    let recoveryPart = metrics.recovery * 0.45
    let readinessPart = metrics.readiness * 0.35
    let sleepPart = metrics.sleep * 0.2
    return min(100, max(0, Int((recoveryPart + readinessPart + sleepPart).rounded())))
  }
}

enum PetState {
  case thriving
  case steady
  case tired
  case fragile

  init(score: Int) {
    switch score {
    case 80...:
      self = .thriving
    case 55..<80:
      self = .steady
    case 30..<55:
      self = .tired
    default:
      self = .fragile
    }
  }

  var label: String {
    switch self {
    case .thriving:
      return "Thriving"
    case .steady:
      return "Steady"
    case .tired:
      return "Tired"
    case .fragile:
      return "Needs care"
    }
  }

  var message: String {
    switch self {
    case .thriving:
      return "Maruchan looks bright today. Keep the streak going."
    case .steady:
      return "Maruchan is doing okay. A little movement and sleep will help."
    case .tired:
      return "Maruchan feels low energy. Recovery matters today."
    case .fragile:
      return "Maruchan needs care. Rest, hydrate, and take it gently."
    }
  }

  var tint: Color {
    switch self {
    case .thriving:
      return .green
    case .steady:
      return .blue
    case .tired:
      return .orange
    case .fragile:
      return .red
    }
  }
}

struct PetSceneView: UIViewRepresentable {
  let state: PetState

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.backgroundColor = UIColor.systemBackground
    view.allowsCameraControl = false
    view.autoenablesDefaultLighting = false
    view.isPlaying = true
    view.loops = true
    view.scene = makeScene()
    view.pointOfView = view.scene?.rootNode.childNode(withName: "petCamera", recursively: false)
    return view
  }

  func updateUIView(_ view: SCNView, context: Context) {
    view.scene?.rootNode.childNode(withName: "petRoot", recursively: false)?.opacity = opacity
    view.pointOfView = view.scene?.rootNode.childNode(withName: "petCamera", recursively: false)
  }

  private var opacity: CGFloat {
    switch state {
    case .thriving, .steady:
      return 1
    case .tired:
      return 0.82
    case .fragile:
      return 0.62
    }
  }

  private func makeScene() -> SCNScene {
    let scene = SCNScene()
    scene.background.contents = UIColor.systemBackground

    let petRoot = SCNNode()
    petRoot.name = "petRoot"
    petRoot.opacity = opacity

    if let url = Bundle.main.url(forResource: "JRTWalking", withExtension: "usdz"),
       let petScene = try? SCNScene(url: url) {
      for node in petScene.rootNode.childNodes {
        petRoot.addChildNode(node)
      }
      fit(node: petRoot)
      petRoot.eulerAngles.y = .pi
      animateAnchoredIdle(node: petRoot)
      scene.rootNode.addChildNode(petRoot)
    }

    let camera = SCNNode()
    camera.name = "petCamera"
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = 34
    camera.camera?.zNear = 0.01
    camera.camera?.zFar = 100
    camera.position = SCNVector3(0, 0.08, 2.35)
    scene.rootNode.addChildNode(camera)

    let keyLight = SCNNode()
    keyLight.light = SCNLight()
    keyLight.light?.type = .omni
    keyLight.light?.intensity = 900
    keyLight.position = SCNVector3(1.4, 2.2, 2.4)
    scene.rootNode.addChildNode(keyLight)

    let fillLight = SCNNode()
    fillLight.light = SCNLight()
    fillLight.light?.type = .ambient
    fillLight.light?.intensity = 350
    scene.rootNode.addChildNode(fillLight)

    return scene
  }

  private func fit(node: SCNNode) {
    let (minimum, maximum) = node.boundingBox
    let width = maximum.x - minimum.x
    let height = maximum.y - minimum.y
    let depth = maximum.z - minimum.z
    let largest = Swift.max(width, Swift.max(height, depth))
    if largest > 0 {
      let scale = 1.25 / largest
      node.scale = SCNVector3(scale, scale, scale)
    }
    let center = SCNVector3(
      (minimum.x + maximum.x) / 2,
      (minimum.y + maximum.y) / 2,
      (minimum.z + maximum.z) / 2
    )
    node.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
    node.position = SCNVector3(0, -0.08, 0)
  }

  private func animateAnchoredIdle(node: SCNNode) {
    let breatheUp = SCNAction.moveBy(x: 0, y: 0.018, z: 0, duration: 1.15)
    breatheUp.timingMode = .easeInEaseOut

    let breatheDown = SCNAction.moveBy(x: 0, y: -0.018, z: 0, duration: 1.25)
    breatheDown.timingMode = .easeInEaseOut

    let lookLeft = SCNAction.rotateBy(x: 0, y: .pi / 28, z: 0, duration: 1.4)
    lookLeft.timingMode = .easeInEaseOut
    let lookRight = SCNAction.rotateBy(x: 0, y: -.pi / 14, z: 0, duration: 2.8)
    lookRight.timingMode = .easeInEaseOut
    let lookCenter = SCNAction.rotateBy(x: 0, y: .pi / 28, z: 0, duration: 1.4)
    lookCenter.timingMode = .easeInEaseOut

    node.runAction(.repeatForever(.sequence([breatheUp, breatheDown])), forKey: "breathing")
    node.runAction(.repeatForever(.sequence([lookLeft, lookRight, lookCenter])), forKey: "lookingAround")
  }
}

struct WhoopDevice: Identifiable, Equatable {
  let id: UUID
  let name: String
  let rssi: Int
  let isLikelyWhoop: Bool
  fileprivate let peripheral: CBPeripheral

  var detailText: String {
    "\(isLikelyWhoop ? "Likely WHOOP" : "Nearby device") · RSSI \(rssi)"
  }
}

final class WhoopConnector: NSObject, ObservableObject {
  @Published private(set) var devices: [WhoopDevice] = []
  @Published private(set) var isScanning = false
  @Published private(set) var connectedName: String?
  @Published private(set) var statusText = "Bluetooth warming up"
  @Published private(set) var statusIcon = "hourglass"

  private var central: CBCentralManager!
  private var connectedPeripheral: CBPeripheral?

  override init() {
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  var canScan: Bool {
    central.state == .poweredOn && !isScanning
  }

  func scan() {
    guard central.state == .poweredOn else {
      statusText = bluetoothUnavailableText
      statusIcon = "exclamationmark.triangle"
      return
    }
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(finishScan), object: nil)
    central.stopScan()
    devices.removeAll()
    connectedName = nil
    isScanning = true
    statusText = "Scanning for WHOOP nearby"
    statusIcon = "dot.radiowaves.left.and.right"
    central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    perform(#selector(finishScan), with: nil, afterDelay: 12)
  }

  func stopScan() {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(finishScan), object: nil)
    finishScan()
  }

  func connect(_ device: WhoopDevice) {
    stopScan()
    statusText = "Connecting to \(device.name)"
    statusIcon = "link"
    connectedPeripheral = device.peripheral
    central.connect(device.peripheral)
  }

  @objc private func finishScan() {
    central.stopScan()
    isScanning = false
    if connectedName != nil {
      statusText = "Connected"
      statusIcon = "checkmark.circle.fill"
    } else if devices.isEmpty {
      statusText = "No nearby Bluetooth devices found"
      statusIcon = "questionmark.circle"
    } else {
      statusText = "Found \(devices.count) nearby device\(devices.count == 1 ? "" : "s")"
      statusIcon = "checkmark.circle"
    }
  }

  private var bluetoothUnavailableText: String {
    switch central.state {
    case .poweredOff:
      return "Bluetooth is off"
    case .unauthorized:
      return "Bluetooth permission needed"
    case .unsupported:
      return "Bluetooth unsupported"
    case .resetting:
      return "Bluetooth is resetting"
    default:
      return "Bluetooth is not ready"
    }
  }
}

extension WhoopConnector: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      statusText = "Ready to scan"
      statusIcon = "checkmark.circle"
    case .poweredOff:
      isScanning = false
      statusText = "Bluetooth is off"
      statusIcon = "bluetooth.slash"
    case .unauthorized:
      isScanning = false
      statusText = "Bluetooth permission needed"
      statusIcon = "lock"
    case .unsupported:
      statusText = "Bluetooth unsupported"
      statusIcon = "xmark.circle"
    default:
      statusText = "Bluetooth warming up"
      statusIcon = "hourglass"
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let name = advertisedName ?? peripheral.name ?? "Unnamed device"
    let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let likelyWhoop = name.localizedCaseInsensitiveContains("WHOOP") ||
      services.contains { $0.uuidString.localizedCaseInsensitiveContains("FE") }
    let device = WhoopDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, isLikelyWhoop: likelyWhoop, peripheral: peripheral)
    if let index = devices.firstIndex(where: { $0.id == device.id }) {
      devices[index] = device
    } else {
      devices.append(device)
      devices.sort {
        if $0.isLikelyWhoop != $1.isLikelyWhoop { return $0.isLikelyWhoop && !$1.isLikelyWhoop }
        return $0.rssi > $1.rssi
      }
      statusText = "Found \(devices.count) nearby device\(devices.count == 1 ? "" : "s")"
      statusIcon = "checkmark.circle"
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    central.stopScan()
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(finishScan), object: nil)
    isScanning = false
    connectedPeripheral = peripheral
    connectedName = peripheral.name ?? devices.first(where: { $0.id == peripheral.identifier })?.name ?? "WHOOP"
    statusText = "Connected"
    statusIcon = "checkmark.circle.fill"
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    isScanning = false
    connectedPeripheral = nil
    statusText = error?.localizedDescription ?? "Connection failed"
    statusIcon = "exclamationmark.triangle"
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    connectedName = nil
    connectedPeripheral = nil
    statusText = "Disconnected"
    statusIcon = "xmark.circle"
  }
}
