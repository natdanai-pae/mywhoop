import Combine
import Foundation
import Security

enum GolfAISettingsError: LocalizedError {
  case emptyAPIKey
  case invalidDSV4Endpoint
  case invalidStoredAPIKey
  case keychainFailure(OSStatus)

  var errorDescription: String? {
    switch self {
    case .emptyAPIKey:
      return "กรุณากรอก API key ของ OpenRouter"
    case .invalidDSV4Endpoint:
      return "กรุณาใช้ที่อยู่ OpenRouter แบบ HTTPS ที่ถูกต้องก่อนบันทึก API key"
    case .invalidStoredAPIKey:
      return "API key ที่เก็บไว้ใน Keychain อ่านไม่ได้ กรุณาบันทึกใหม่"
    case .keychainFailure(let status):
      if status == errSecMissingEntitlement {
        return "แอปยังไม่มีสิทธิ์ใช้ Keychain (รหัส -34018) กรุณาติดตั้ง GolfTrace รุ่นล่าสุด"
      }
      if status == errSecInteractionNotAllowed {
        return "Keychain ยังถูกล็อก กรุณาปลดล็อก Mac แล้วลองบันทึกอีกครั้ง"
      }
      return "ไม่สามารถเข้าถึง API key ใน Keychain ได้ (รหัส \(status))"
    }
  }
}

enum AICoachEndpointPurpose {
  case dsv4
  case whisper
  case vlm
}

/// กติกากลางสำหรับ endpoint ที่อาจรับข้อมูลหรือ credential ของ AI Coach
/// DSV4 ต้องเป็น HTTPS เสมอ ส่วน Whisper แบบ HTTP ใช้ได้เฉพาะปลายทางภายใน
/// และจะไม่ได้รับ API key ของ BDA Gateway
enum AICoachEndpointPolicy {
  static func validated(_ value: String, for purpose: AICoachEndpointPurpose) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    return isAllowed(url, for: purpose) ? url : nil
  }

  static func isAllowed(_ url: URL?, for purpose: AICoachEndpointPurpose) -> Bool {
    guard let url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.fragment == nil
    else {
      return false
    }

    switch purpose {
    case .dsv4:
      return scheme == "https"
    case .whisper, .vlm:
      return scheme == "https" || (scheme == "http" && isPrivateOrLocalHost(host))
    }
  }

  static func origin(for url: URL?) -> String? {
    guard let url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased()
    else {
      return nil
    }
    let effectivePort = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
    guard effectivePort > 0 else { return nil }
    return "\(scheme)://\(host):\(effectivePort)"
  }

  static func isSameOrigin(_ first: URL?, _ second: URL?) -> Bool {
    guard let firstOrigin = origin(for: first), let secondOrigin = origin(for: second) else {
      return false
    }
    return firstOrigin == secondOrigin
  }

  static func validatedRedirect(
    _ request: URLRequest,
    from response: HTTPURLResponse
  ) -> URLRequest? {
    guard isSameOrigin(response.url, request.url) else { return nil }
    return request
  }

  static func maySendGatewayKey(
    to endpoint: URL,
    boundOrigin: String?
  ) -> Bool {
    guard endpoint.scheme?.lowercased() == "https",
      let boundOrigin,
      origin(for: endpoint) == boundOrigin
    else {
      return false
    }
    return true
  }

  private static func isPrivateOrLocalHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
      return true
    }
    if !host.contains(".") && !host.contains(":") {
      return true
    }

    if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd")
      || host.hasPrefix("fe80:")
    {
      return true
    }

    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }
    switch octets[0] {
    case 10, 127:
      return true
    case 100:
      return (64...127).contains(octets[1])
    case 169:
      return octets[1] == 254
    case 172:
      return (16...31).contains(octets[1])
    case 192:
      return octets[1] == 168
    default:
      return false
    }
  }
}

protocol GolfAIKeychainStoring: Sendable {
  /// ตรวจเฉพาะว่ามีรายการ Keychain หรือไม่ โดยไม่ขอคืน plaintext
  func containsAPIKey() throws -> Bool
  /// รหัสยืนยันที่ปลอดภัยสำหรับแสดงใน UI (สูงสุด 4 ตัวท้าย) โดยไม่คืน API key เต็ม
  func storedAPIKeySuffix() throws -> String?
  func loadAPIKey() throws -> String?
  func saveAPIKey(_ value: String) throws
  func deleteAPIKey() throws
}

protocol GolfAISecurityItemAccessing: Sendable {
  func copyMatching(
    _ query: CFDictionary,
    result: UnsafeMutablePointer<CFTypeRef?>?
  ) -> OSStatus
  func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
  func add(_ attributes: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemGolfAISecurityItemAccess: GolfAISecurityItemAccessing {
  func copyMatching(
    _ query: CFDictionary,
    result: UnsafeMutablePointer<CFTypeRef?>?
  ) -> OSStatus {
    SecItemCopyMatching(query, result)
  }

  func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
    SecItemUpdate(query, attributes)
  }

  func add(
    _ attributes: CFDictionary,
    result: UnsafeMutablePointer<CFTypeRef?>?
  ) -> OSStatus {
    SecItemAdd(attributes, result)
  }

  func delete(_ query: CFDictionary) -> OSStatus {
    SecItemDelete(query)
  }
}

struct GolfAIKeychainStore: GolfAIKeychainStoring, Sendable {
  static let service = "com.bda.golftrace.ai"
  /// แยก account จาก BDA Gateway เดิมเพื่อไม่ให้ credential คนละระบบปะปนกัน
  static let account = "openrouter-api-key-v1"

  private let service: String
  private let account: String
  private let security: any GolfAISecurityItemAccessing

  init(
    service: String = Self.service,
    account: String = Self.account,
    security: any GolfAISecurityItemAccessing = SystemGolfAISecurityItemAccess()
  ) {
    self.service = service
    self.account = account
    self.security = security
  }

  func containsAPIKey() throws -> Bool {
    do {
      if try containsAPIKey(in: protectedLookup) { return true }
    } catch GolfAISettingsError.keychainFailure(let status)
      where status == errSecMissingEntitlement
    {
      return try containsAPIKey(in: loginKeychainLookup)
    }
    return try containsAPIKey(in: loginKeychainLookup)
  }

  func storedAPIKeySuffix() throws -> String? {
    guard let key = try loadAPIKey() else { return nil }
    return String(key.suffix(4))
  }

  private func containsAPIKey(in lookup: [String: Any]) throws -> Bool {
    var query = lookup
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = false

    let status = security.copyMatching(query as CFDictionary, result: nil)
    switch status {
    case errSecSuccess:
      return true
    case errSecItemNotFound:
      return false
    default:
      throw GolfAISettingsError.keychainFailure(status)
    }
  }

  func loadAPIKey() throws -> String? {
    do {
      if let value = try loadAPIKey(from: protectedLookup) { return value }
    } catch GolfAISettingsError.keychainFailure(let status)
      where status == errSecMissingEntitlement
    {
      return try loadAPIKey(from: loginKeychainLookup)
    }
    return try loadAPIKey(from: loginKeychainLookup)
  }

  private func loadAPIKey(from lookup: [String: Any]) throws -> String? {
    var query = lookup
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    var item: CFTypeRef?
    let status = security.copyMatching(query as CFDictionary, result: &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data,
        let value = String(data: data, encoding: .utf8)
      else {
        throw GolfAISettingsError.invalidStoredAPIKey
      }
      let normalized = normalize(value)
      guard !normalized.isEmpty else {
        throw GolfAISettingsError.invalidStoredAPIKey
      }
      return normalized
    case errSecItemNotFound:
      return nil
    default:
      throw GolfAISettingsError.keychainFailure(status)
    }
  }

  func saveAPIKey(_ value: String) throws {
    let normalized = normalize(value)
    guard !normalized.isEmpty else { throw GolfAISettingsError.emptyAPIKey }
    let data = Data(normalized.utf8)

    do {
      try upsert(data, in: protectedLookup)
    } catch GolfAISettingsError.keychainFailure(let status)
      where status == errSecMissingEntitlement
    {
      try upsert(data, in: loginKeychainLookup)
    }

    guard try loadAPIKey() == normalized else {
      throw GolfAISettingsError.invalidStoredAPIKey
    }
  }

  private func upsert(_ data: Data, in lookup: [String: Any]) throws {
    let update =
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ] as [String: Any]

    let updateStatus = security.update(
      lookup as CFDictionary,
      attributes: update as CFDictionary
    )
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw GolfAISettingsError.keychainFailure(updateStatus)
    }

    var item = lookup
    for (key, value) in update {
      item[key] = value
    }
    let addStatus = security.add(item as CFDictionary, result: nil)
    guard addStatus == errSecSuccess else {
      throw GolfAISettingsError.keychainFailure(addStatus)
    }
  }

  func deleteAPIKey() throws {
    do {
      _ = try deleteAPIKey(from: protectedLookup)
    } catch GolfAISettingsError.keychainFailure(let status)
      where status == errSecMissingEntitlement
    {
      // Local development builds may not be entitled to the Data Protection
      // Keychain. The login Keychain may still hold a key saved by a previous
      // run, so continue with the fallback store.
    }
    _ = try deleteAPIKey(from: loginKeychainLookup)
  }

  @discardableResult
  private func deleteAPIKey(from lookup: [String: Any]) throws -> Bool {
    let status = security.delete(lookup as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw GolfAISettingsError.keychainFailure(status)
    }
    return status == errSecSuccess
  }

  /// Data Protection Keychain เป็นตัวเลือกหลักสำหรับ build ที่มี provisioning
  /// entitlement ครบ ส่วน build พัฒนาที่เครื่อง Mac ยังไม่ถูกลงทะเบียนจะ fallback
  /// ไปยัง login Keychain ของ macOS ซึ่งยังเก็บ secret นอก source/UserDefaults
  /// และไม่ sync ผ่าน iCloud (`kSecAttrSynchronizable = false`).
  private var protectedLookup: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  private var loginKeychainLookup: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: false,
    ]
  }

  private func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum OpenRouterHealthState: Equatable, Sendable {
  case notConfigured
  case notChecked
  case checking
  case ready
  case warning(String)
  case failed(String)

  var title: String {
    switch self {
    case .notConfigured: return "ยังไม่ได้ตั้งค่า OpenRouter"
    case .notChecked: return "บันทึก API key แล้ว · ยังไม่ได้ตรวจบัญชี"
    case .checking: return "กำลังตรวจบัญชี OpenRouter"
    case .ready: return "OpenRouter พร้อมใช้งาน"
    case .warning(let message), .failed(let message): return message
    }
  }
}

enum GolfAIRequestGate: Equatable, Sendable {
  case allowed
  case aiDisabled
  case missingAPIKey
  case invalidAPIKey
  case invalidKeyBinding
  case localWeeklyBudgetReached
  case serverLimitReached

  var thaiMessage: String {
    switch self {
    case .allowed: return "AI พร้อมใช้งาน"
    case .aiDisabled: return "ปิด AI Golf Pro อยู่ในหน้าตั้งค่า"
    case .missingAPIKey: return "ยังไม่มี API key ของ OpenRouter"
    case .invalidAPIKey: return "API key ของ OpenRouter ไม่ถูกต้องหรือถูกยกเลิกแล้ว"
    case .invalidKeyBinding: return "API key ไม่ได้ผูกกับปลายทาง OpenRouter นี้ กรุณาบันทึกใหม่"
    case .localWeeklyBudgetReached: return "ถึงงบ AI รายสัปดาห์ที่ตั้งไว้แล้ว"
    case .serverLimitReached: return "API key ของ OpenRouter ถึงขีดจำกัดแล้ว"
    }
  }
}

@MainActor
final class GolfAISettings: ObservableObject {
  @Published var aiEnabled: Bool {
    didSet { defaults.set(aiEnabled, forKey: Keys.aiEnabled) }
  }
  @Published var automaticCoachEnabled: Bool {
    didSet { defaults.set(automaticCoachEnabled, forKey: Keys.automaticCoachEnabled) }
  }
  @Published var handsFreeCaptureEnabled: Bool {
    didSet { defaults.set(handsFreeCaptureEnabled, forKey: Keys.handsFreeCaptureEnabled) }
  }
  @Published var dsv4Endpoint: String {
    didSet {
      defaults.set(dsv4Endpoint, forKey: Keys.dsv4Endpoint)
      refreshStatus()
    }
  }
  @Published var dsv4Model: String {
    didSet { defaults.set(dsv4Model, forKey: Keys.dsv4Model) }
  }
  @Published var whisperEndpoint: String {
    didSet { defaults.set(whisperEndpoint, forKey: Keys.whisperEndpoint) }
  }
  @Published var whisperModel: String {
    didSet { defaults.set(whisperModel, forKey: Keys.whisperModel) }
  }
  @Published var vlmEnabled: Bool {
    didSet { defaults.set(vlmEnabled, forKey: Keys.vlmEnabled) }
  }
  @Published var vlmEndpoint: String {
    didSet { defaults.set(vlmEndpoint, forKey: Keys.vlmEndpoint) }
  }
  @Published var vlmModel: String {
    didSet { defaults.set(vlmModel, forKey: Keys.vlmModel) }
  }
  @Published var employeeCode: String {
    didSet { defaults.set(employeeCode, forKey: Keys.employeeCode) }
  }
  @Published var weeklyBudgetUSD: Double {
    didSet {
      let clamped = min(max(weeklyBudgetUSD, 0), 100)
      if weeklyBudgetUSD != clamped {
        weeklyBudgetUSD = clamped
        return
      }
      defaults.set(weeklyBudgetUSD, forKey: Keys.weeklyBudgetUSD)
      updateBudgetStatus()
    }
  }
  @Published var aiVoiceEnabled: Bool {
    didSet { defaults.set(aiVoiceEnabled, forKey: Keys.aiVoiceEnabled) }
  }
  @Published var aiVoiceVolume: Double {
    didSet {
      let clamped = min(max(aiVoiceVolume, 0), 1)
      if aiVoiceVolume != clamped {
        aiVoiceVolume = clamped
        return
      }
      defaults.set(aiVoiceVolume, forKey: Keys.aiVoiceVolume)
    }
  }
  @Published var aiVoiceRate: Double {
    didSet {
      let clamped = min(max(aiVoiceRate, 0.35), 0.6)
      if aiVoiceRate != clamped {
        aiVoiceRate = clamped
        return
      }
      defaults.set(aiVoiceRate, forKey: Keys.aiVoiceRate)
    }
  }
  @Published var tempoCueEnabled: Bool {
    didSet { defaults.set(tempoCueEnabled, forKey: Keys.tempoCueEnabled) }
  }
  @Published var guidelineCueEnabled: Bool {
    didSet { defaults.set(guidelineCueEnabled, forKey: Keys.guidelineCueEnabled) }
  }
  @Published var soundEffectsVolume: Double {
    didSet {
      let clamped = min(max(soundEffectsVolume, 0), 1)
      if soundEffectsVolume != clamped {
        soundEffectsVolume = clamped
        return
      }
      defaults.set(soundEffectsVolume, forKey: Keys.soundEffectsVolume)
    }
  }
  @Published private(set) var hasStoredAPIKey = false
  /// ใช้เทียบกับหน้า OpenRouter เท่านั้น; ไม่เก็บหรือเผย API key เต็มใน UI
  @Published private(set) var storedAPIKeySuffix: String?
  @Published private(set) var statusText = "ยังไม่ได้บันทึก API key ของ OpenRouter"
  @Published private(set) var openRouterHealth: OpenRouterHealthState = .notConfigured
  @Published private(set) var openRouterAccount: OpenRouterAccountSnapshot?
  @Published private(set) var localWeeklyCostUSD = 0.0
  @Published private(set) var localWeeklyPromptTokens = 0
  @Published private(set) var localWeeklyCompletionTokens = 0

  private let defaults: UserDefaults
  private let keychain: any GolfAIKeychainStoring
  private let accountClient: any OpenRouterAccountChecking
  private let now: @Sendable () -> Date
  private var localWeekStartedAt: Date
  private var accountFailureGate: GolfAIRequestGate?

  init(
    defaults: UserDefaults = .standard,
    keychain: any GolfAIKeychainStoring = GolfAIKeychainStore(),
    accountClient: any OpenRouterAccountChecking = OpenRouterAccountClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.keychain = keychain
    self.accountClient = accountClient
    self.now = now
    aiEnabled = defaults.object(forKey: Keys.aiEnabled) as? Bool ?? true
    automaticCoachEnabled = defaults.object(forKey: Keys.automaticCoachEnabled) as? Bool ?? true
    handsFreeCaptureEnabled =
      defaults.object(forKey: Keys.handsFreeCaptureEnabled) as? Bool ?? true
    let storedCoachEndpoint = defaults.string(forKey: Keys.dsv4Endpoint)
    dsv4Endpoint =
      storedCoachEndpoint == nil || storedCoachEndpoint != Self.defaultCoachEndpoint
      ? Self.defaultCoachEndpoint : storedCoachEndpoint!
    let storedCoachModel = defaults.string(forKey: Keys.dsv4Model)
    dsv4Model =
      storedCoachModel != OpenRouterGolfModelCatalog.primaryCoach.id
      ? OpenRouterGolfModelCatalog.primaryCoach.id : storedCoachModel!
    whisperEndpoint =
      defaults.string(forKey: Keys.whisperEndpoint)
      ?? "https://ai-local.scmc.digital/v1/audio/transcriptions"
    whisperModel = defaults.string(forKey: Keys.whisperModel) ?? "whisper-large-v3"
    vlmEnabled = defaults.bool(forKey: Keys.vlmEnabled)
    vlmEndpoint = defaults.string(forKey: Keys.vlmEndpoint) ?? ""
    vlmModel =
      defaults.string(forKey: Keys.vlmModel)
      ?? "Qwen/Qwen3-VL-8B-Instruct"
    employeeCode = defaults.string(forKey: Keys.employeeCode) ?? Self.defaultEmployeeCode
    let storedBudget = defaults.object(forKey: Keys.weeklyBudgetUSD) as? Double
    weeklyBudgetUSD = min(max(storedBudget ?? 10, 0), 100)
    aiVoiceEnabled = defaults.object(forKey: Keys.aiVoiceEnabled) as? Bool ?? true
    let storedVoiceVolume = defaults.object(forKey: Keys.aiVoiceVolume) as? Double
    aiVoiceVolume = min(max(storedVoiceVolume ?? 0.9, 0), 1)
    let storedVoiceRate = defaults.object(forKey: Keys.aiVoiceRate) as? Double
    aiVoiceRate = min(max(storedVoiceRate ?? 0.47, 0.35), 0.6)
    tempoCueEnabled = defaults.object(forKey: Keys.tempoCueEnabled) as? Bool ?? true
    guidelineCueEnabled = defaults.object(forKey: Keys.guidelineCueEnabled) as? Bool ?? true
    let storedEffectsVolume = defaults.object(forKey: Keys.soundEffectsVolume) as? Double
    soundEffectsVolume = min(max(storedEffectsVolume ?? 0.8, 0), 1)
    let currentWeek = Self.weekStart(containing: now())
    let storedWeek = defaults.object(forKey: Keys.localWeekStartedAt) as? Date
    localWeekStartedAt = storedWeek == currentWeek ? storedWeek! : currentWeek
    if storedWeek == currentWeek {
      localWeeklyCostUSD = max(0, defaults.double(forKey: Keys.localWeeklyCostUSD))
      localWeeklyPromptTokens = max(0, defaults.integer(forKey: Keys.localWeeklyPromptTokens))
      localWeeklyCompletionTokens = max(
        0,
        defaults.integer(forKey: Keys.localWeeklyCompletionTokens)
      )
    }
    persistLocalUsage()
    refreshStatus()
  }

  nonisolated static let defaultEmployeeCode = ""
  nonisolated static let defaultCoachEndpoint =
    "https://openrouter.ai/api/v1/chat/completions"

  var dsv4URL: URL? {
    AICoachEndpointPolicy.validated(dsv4Endpoint, for: .dsv4)
  }
  var whisperURL: URL? {
    AICoachEndpointPolicy.validated(whisperEndpoint, for: .whisper)
  }
  var vlmURL: URL? {
    AICoachEndpointPolicy.validated(vlmEndpoint, for: .vlm)
  }

  func loadAPIKey() throws -> String? {
    guard let endpoint = dsv4URL else { return nil }
    return try loadAPIKey(for: endpoint)
  }

  /// คืน key เฉพาะเมื่อ endpoint ยังเป็น origin เดียวกับตอนที่ผู้ใช้บันทึก key
  /// ป้องกันการแก้ endpoint แล้วพา credential เดิมไปยังเซิร์ฟเวอร์อื่นโดยไม่ตั้งใจ
  func loadAPIKey(for endpoint: URL) throws -> String? {
    guard
      AICoachEndpointPolicy.maySendGatewayKey(
        to: endpoint,
        boundOrigin: defaults.string(forKey: Keys.apiKeyOrigin)
      )
    else {
      return nil
    }
    return try keychain.loadAPIKey()
  }

  @discardableResult
  func saveAPIKey(_ value: String) -> Bool {
    do {
      guard let endpoint = dsv4URL,
        let origin = AICoachEndpointPolicy.origin(for: endpoint)
      else {
        throw GolfAISettingsError.invalidDSV4Endpoint
      }
      try keychain.saveAPIKey(value)
      defaults.set(origin, forKey: Keys.apiKeyOrigin)
      hasStoredAPIKey = true
      storedAPIKeySuffix = try keychain.storedAPIKeySuffix()
      openRouterAccount = nil
      accountFailureGate = nil
      openRouterHealth = .notChecked
      statusText = "เก็บ API key ของ OpenRouter ไว้ใน Keychain แล้ว"
      return true
    } catch {
      statusText = error.localizedDescription
      return false
    }
  }

  func deleteAPIKey() {
    do {
      try keychain.deleteAPIKey()
      defaults.removeObject(forKey: Keys.apiKeyOrigin)
      hasStoredAPIKey = false
      storedAPIKeySuffix = nil
      openRouterAccount = nil
      accountFailureGate = nil
      openRouterHealth = .notConfigured
      statusText = "ลบ API key ออกจากเครื่องแล้ว"
    } catch {
      statusText = error.localizedDescription
    }
  }

  /// ผู้ใช้กดตรวจเองได้โดยไม่ส่ง prompt และไม่เรียกโมเดลเสียเงิน
  @discardableResult
  func checkOpenRouterConnection() async -> Bool {
    await refreshOpenRouterAccount(force: true)
  }

  /// Controller เรียกก่อนยิงโมเดล เพื่อคุมสวิตช์ key binding และงบท้องถิ่น
  func prepareForAIRequest() async -> GolfAIRequestGate {
    rolloverLocalUsageIfNeeded()
    guard aiEnabled else { return .aiDisabled }
    guard hasStoredAPIKey else { return .missingAPIKey }
    guard isKeyBoundToCurrentEndpoint else { return .invalidKeyBinding }
    guard weeklyBudgetUSD > 0, localWeeklyCostUSD < weeklyBudgetUSD else {
      return .localWeeklyBudgetReached
    }

    if let remaining = openRouterAccount?.limitRemainingUSD, remaining <= 0 {
      return .serverLimitReached
    }
    if shouldRefreshAccount {
      let refreshed = await refreshOpenRouterAccount(force: false)
      if !refreshed, let accountFailureGate { return accountFailureGate }
      if let remaining = openRouterAccount?.limitRemainingUSD, remaining <= 0 {
        return .serverLimitReached
      }
    }
    return .allowed
  }

  func recordUsage(_ usage: OpenRouterGenerationUsage) {
    rolloverLocalUsageIfNeeded()
    if let cost = usage.costUSD, cost.isFinite, cost >= 0 {
      localWeeklyCostUSD += cost
    }
    localWeeklyPromptTokens += max(0, usage.promptTokens)
    localWeeklyCompletionTokens += max(0, usage.completionTokens)
    persistLocalUsage()
    updateBudgetStatus()
  }

  var localWeeklyBudgetRemainingUSD: Double {
    max(0, weeklyBudgetUSD - localWeeklyCostUSD)
  }

  var serverKeyHasWeeklyLimitWithinAppBudget: Bool {
    openRouterAccount?.hasWeeklyServerLimit(atOrBelow: weeklyBudgetUSD) ?? false
  }

  private var isKeyBoundToCurrentEndpoint: Bool {
    guard let endpoint = dsv4URL else { return false }
    return AICoachEndpointPolicy.maySendGatewayKey(
      to: endpoint,
      boundOrigin: defaults.string(forKey: Keys.apiKeyOrigin)
    )
  }

  @discardableResult
  private func refreshOpenRouterAccount(force: Bool) async -> Bool {
    guard aiEnabled else {
      openRouterHealth = .warning(GolfAIRequestGate.aiDisabled.thaiMessage)
      statusText = openRouterHealth.title
      return false
    }
    guard hasStoredAPIKey else {
      openRouterHealth = .notConfigured
      statusText = openRouterHealth.title
      return false
    }
    guard isKeyBoundToCurrentEndpoint, let endpoint = dsv4URL else {
      openRouterHealth = .failed(GolfAIRequestGate.invalidKeyBinding.thaiMessage)
      statusText = openRouterHealth.title
      return false
    }
    if !force, !shouldRefreshAccount { return openRouterAccount != nil }

    openRouterHealth = .checking
    statusText = openRouterHealth.title
    do {
      guard let key = try loadAPIKey(for: endpoint) else {
        throw GolfAISettingsError.invalidStoredAPIKey
      }
      let account = try await accountClient.fetchAccount(apiKey: key)
      openRouterAccount = account
      accountFailureGate = nil
      openRouterHealth =
        account.limitRemainingUSD.map({ $0 <= 0 }) == true
        ? .warning(GolfAIRequestGate.serverLimitReached.thaiMessage) : .ready
      statusText = account.thaiSummary(localBudgetUSD: weeklyBudgetUSD)
      return true
    } catch {
      openRouterAccount = nil
      if let accountError = error as? OpenRouterAccountError {
        switch accountError {
        case .unauthorized:
          accountFailureGate = .invalidAPIKey
        case .paymentRequired:
          accountFailureGate = .serverLimitReached
        case .missingAPIKey:
          accountFailureGate = .missingAPIKey
        case .invalidResponse, .untrustedResponse, .responseTooLarge,
          .unsupportedResponseType, .rateLimited, .unavailable, .server:
          accountFailureGate = nil
        }
      } else {
        accountFailureGate = nil
      }
      let message = error.localizedDescription
      openRouterHealth = .failed(message)
      statusText = message
      return false
    }
  }

  private var shouldRefreshAccount: Bool {
    guard let checkedAt = openRouterAccount?.checkedAt else { return true }
    return now().timeIntervalSince(checkedAt) >= 300
  }

  private func refreshStatus() {
    do {
      hasStoredAPIKey = try keychain.containsAPIKey()
      guard hasStoredAPIKey else {
        storedAPIKeySuffix = nil
        openRouterHealth = .notConfigured
        statusText = "ยังไม่ได้บันทึก API key ของ OpenRouter"
        return
      }
      storedAPIKeySuffix = try keychain.storedAPIKeySuffix()
      guard isKeyBoundToCurrentEndpoint else {
        openRouterHealth = .failed(GolfAIRequestGate.invalidKeyBinding.thaiMessage)
        statusText = "API key ยังไม่ผูกกับ endpoint นี้ กรุณาบันทึกใหม่"
        return
      }
      if openRouterAccount == nil { openRouterHealth = .notChecked }
      statusText = "มี API key ของ OpenRouter ใน Keychain แล้ว"
    } catch {
      hasStoredAPIKey = false
      storedAPIKeySuffix = nil
      statusText = error.localizedDescription
    }
  }

  private func rolloverLocalUsageIfNeeded() {
    let currentWeek = Self.weekStart(containing: now())
    guard currentWeek != localWeekStartedAt else { return }
    localWeekStartedAt = currentWeek
    localWeeklyCostUSD = 0
    localWeeklyPromptTokens = 0
    localWeeklyCompletionTokens = 0
    persistLocalUsage()
  }

  private func persistLocalUsage() {
    defaults.set(localWeekStartedAt, forKey: Keys.localWeekStartedAt)
    defaults.set(localWeeklyCostUSD, forKey: Keys.localWeeklyCostUSD)
    defaults.set(localWeeklyPromptTokens, forKey: Keys.localWeeklyPromptTokens)
    defaults.set(localWeeklyCompletionTokens, forKey: Keys.localWeeklyCompletionTokens)
  }

  private func updateBudgetStatus() {
    rolloverLocalUsageIfNeeded()
    let budgetMessage = GolfAIRequestGate.localWeeklyBudgetReached.thaiMessage
    if weeklyBudgetUSD <= 0 || localWeeklyCostUSD >= weeklyBudgetUSD {
      openRouterHealth = .warning(budgetMessage)
      statusText = openRouterHealth.title
    } else if openRouterHealth == .warning(budgetMessage) {
      if let account = openRouterAccount {
        openRouterHealth = .ready
        statusText = account.thaiSummary(localBudgetUSD: weeklyBudgetUSD)
      } else if hasStoredAPIKey {
        openRouterHealth = .notChecked
        statusText = openRouterHealth.title
      } else {
        openRouterHealth = .notConfigured
        statusText = openRouterHealth.title
      }
    }
  }

  private static func weekStart(containing date: Date) -> Date {
    Calendar(identifier: .iso8601).dateInterval(of: .weekOfYear, for: date)?.start ?? date
  }

  private enum Keys {
    static let aiEnabled = "GolfTrace.AI.enabled"
    static let automaticCoachEnabled = "GolfTrace.AI.automaticCoachEnabled"
    static let handsFreeCaptureEnabled = "GolfTrace.Capture.handsFreeEnabled"
    static let dsv4Endpoint = "GolfTrace.AI.dsv4Endpoint"
    static let dsv4Model = "GolfTrace.AI.dsv4Model"
    static let whisperEndpoint = "GolfTrace.AI.whisperEndpoint"
    static let whisperModel = "GolfTrace.AI.whisperModel"
    static let vlmEnabled = "GolfTrace.AI.vlmEnabled"
    static let vlmEndpoint = "GolfTrace.AI.vlmEndpoint"
    static let vlmModel = "GolfTrace.AI.vlmModel"
    static let employeeCode = "GolfTrace.AI.employeeCode"
    static let apiKeyOrigin = "GolfTrace.AI.openRouterAPIKeyOrigin"
    static let weeklyBudgetUSD = "GolfTrace.AI.weeklyBudgetUSD"
    static let aiVoiceEnabled = "GolfTrace.AI.voiceEnabled"
    static let aiVoiceVolume = "GolfTrace.AI.voiceVolume"
    static let aiVoiceRate = "GolfTrace.AI.voiceRate"
    static let tempoCueEnabled = "GolfTrace.Sound.tempoCueEnabled"
    static let guidelineCueEnabled = "GolfTrace.Sound.guidelineCueEnabled"
    static let soundEffectsVolume = "GolfTrace.Sound.effectsVolume"
    static let localWeekStartedAt = "GolfTrace.AI.localWeekStartedAt"
    static let localWeeklyCostUSD = "GolfTrace.AI.localWeeklyCostUSD"
    static let localWeeklyPromptTokens = "GolfTrace.AI.localWeeklyPromptTokens"
    static let localWeeklyCompletionTokens = "GolfTrace.AI.localWeeklyCompletionTokens"
  }
}
