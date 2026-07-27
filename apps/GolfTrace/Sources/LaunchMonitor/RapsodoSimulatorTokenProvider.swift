import Foundation
import Security

// MARK: - Secret storage

/// Storage boundary for the Rapsodo simulator API secret.
///
/// The production implementation below uses Keychain. Tests and previews can
/// inject another implementation without placing a secret in source code.
protocol RapsodoSimulatorSecretStoring: Sendable {
  func loadSecret() throws -> String?
  func saveSecret(_ secret: String) throws
  func deleteSecret() throws
}

extension RapsodoSimulatorSecretStoring {
  /// Safe for a settings screen because it reveals only whether a secret is set.
  func hasSecret() throws -> Bool {
    try loadSecret() != nil
  }
}

enum RapsodoSimulatorSecretStoreError: Error, Equatable, LocalizedError {
  case emptySecret
  case invalidStoredSecret
  case keychainFailure(OSStatus)

  var errorDescription: String? {
    switch self {
    case .emptySecret:
      "กรุณากรอกรหัสเชื่อมต่อจาก Rapsodo"
    case .invalidStoredSecret:
      "รหัสเชื่อมต่อที่เก็บไว้ใน Keychain อ่านไม่ได้ กรุณาบันทึกใหม่"
    case .keychainFailure:
      "ไม่สามารถเข้าถึงรหัสเชื่อมต่อใน Keychain ได้"
    }
  }
}

protocol RapsodoSimulatorKeychainAccessing: Sendable {
  func read(service: String, account: String) throws -> Data?
  func upsert(_ data: Data, service: String, account: String) throws
  func delete(service: String, account: String) throws
}

/// Narrow compatibility boundary for moving secrets out of the legacy macOS
/// file-based Keychain. New storage must use the Data Protection Keychain.
protocol RapsodoSimulatorLegacyKeychainAccessing: RapsodoSimulatorKeychainAccessing {
  func readLegacy(service: String, account: String) throws -> Data?
  func deleteLegacy(service: String, account: String) throws
}

struct SystemRapsodoSimulatorKeychainAccess: RapsodoSimulatorLegacyKeychainAccessing {
  static func protectedLookup(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  static func protectedUpdate(data: Data) -> [String: Any] {
    [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
  }

  /// `false` is intentional and isolated to the one-time legacy migration.
  /// All normal read/write/delete operations use the Data Protection Keychain.
  static func legacyLookup(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: false,
    ]
  }

  func read(service: String, account: String) throws -> Data? {
    var query = Self.protectedLookup(service: service, account: account)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    return try copyMatching(query)
  }

  func readLegacy(service: String, account: String) throws -> Data? {
    var query = Self.legacyLookup(service: service, account: account)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    return try copyMatching(query)
  }

  private func copyMatching(_ query: [String: Any]) throws -> Data? {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else {
        throw RapsodoSimulatorSecretStoreError.invalidStoredSecret
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw RapsodoSimulatorSecretStoreError.keychainFailure(status)
    }
  }

  func upsert(_ data: Data, service: String, account: String) throws {
    let lookup = Self.protectedLookup(service: service, account: account)
    let update = Self.protectedUpdate(data: data)

    let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var item = lookup
      for (key, value) in update {
        item[key] = value
      }
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw RapsodoSimulatorSecretStoreError.keychainFailure(addStatus)
      }
    default:
      throw RapsodoSimulatorSecretStoreError.keychainFailure(updateStatus)
    }
  }

  func delete(service: String, account: String) throws {
    let query = Self.protectedLookup(service: service, account: account)
    try delete(query)
  }

  func deleteLegacy(service: String, account: String) throws {
    let query = Self.legacyLookup(service: service, account: account)
    try delete(query)
  }

  private func delete(_ query: [String: Any]) throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RapsodoSimulatorSecretStoreError.keychainFailure(status)
    }
  }
}

/// Keychain-backed settings API used by both the token provider and UI.
struct RapsodoSimulatorKeychainStore: RapsodoSimulatorSecretStoring {
  static let service = "com.bda.golftrace.rapsodo-simulator"
  static let account = "web-api-secret"

  private let keychain: any RapsodoSimulatorKeychainAccessing

  init() {
    keychain = SystemRapsodoSimulatorKeychainAccess()
  }

  init(keychain: any RapsodoSimulatorKeychainAccessing) {
    self.keychain = keychain
  }

  func loadSecret() throws -> String? {
    if let data = try keychain.read(service: Self.service, account: Self.account) {
      let secret = try Self.decodeSecret(data)
      try legacyKeychain?.deleteLegacy(service: Self.service, account: Self.account)
      return secret
    }

    guard let legacyKeychain,
      let legacyData = try legacyKeychain.readLegacy(
        service: Self.service,
        account: Self.account
      )
    else {
      return nil
    }

    let secret = try Self.decodeSecret(legacyData)
    try keychain.upsert(
      Data(secret.utf8),
      service: Self.service,
      account: Self.account
    )
    try legacyKeychain.deleteLegacy(service: Self.service, account: Self.account)
    return secret
  }

  func saveSecret(_ secret: String) throws {
    let normalizedSecret = Self.normalized(secret)
    guard !normalizedSecret.isEmpty else {
      throw RapsodoSimulatorSecretStoreError.emptySecret
    }
    try keychain.upsert(
      Data(normalizedSecret.utf8),
      service: Self.service,
      account: Self.account
    )
    try legacyKeychain?.deleteLegacy(service: Self.service, account: Self.account)
  }

  func deleteSecret() throws {
    try keychain.delete(service: Self.service, account: Self.account)
    try legacyKeychain?.deleteLegacy(service: Self.service, account: Self.account)
  }

  private var legacyKeychain: (any RapsodoSimulatorLegacyKeychainAccessing)? {
    keychain as? any RapsodoSimulatorLegacyKeychainAccessing
  }

  private static func decodeSecret(_ data: Data) throws -> String {
    guard let storedValue = String(data: data, encoding: .utf8) else {
      throw RapsodoSimulatorSecretStoreError.invalidStoredSecret
    }
    let secret = normalized(storedValue)
    guard !secret.isEmpty else {
      throw RapsodoSimulatorSecretStoreError.invalidStoredSecret
    }
    return secret
  }

  private static func normalized(_ secret: String) -> String {
    secret.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - HTTP

protocol RapsodoSimulatorHTTPTransporting: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

enum RapsodoSimulatorEndpointPolicy {
  static let productionHost = "mlm.rapsodo.com"

  static func isTrusted(_ url: URL?) -> Bool {
    guard let url,
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == productionHost,
      url.port == nil || url.port == 443,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil
    else {
      return false
    }
    return true
  }

  static func validatedRedirect(
    _ request: URLRequest,
    from response: HTTPURLResponse
  ) -> URLRequest? {
    guard isTrusted(response.url), isTrusted(request.url) else {
      return nil
    }
    return request
  }
}

final class RapsodoSimulatorRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(RapsodoSimulatorEndpointPolicy.validatedRedirect(request, from: response))
  }
}

struct RapsodoSimulatorURLSessionTransport: RapsodoSimulatorHTTPTransporting {
  private let session: URLSession

  init(configuration: URLSessionConfiguration = .ephemeral) {
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    self.session = URLSession(
      configuration: configuration,
      delegate: RapsodoSimulatorRedirectDelegate(),
      delegateQueue: nil
    )
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    guard RapsodoSimulatorEndpointPolicy.isTrusted(request.url) else {
      throw URLError(.unsupportedURL)
    }
    return try await session.data(for: request)
  }
}

enum RapsodoSimulatorTokenProviderError: Error, Equatable, LocalizedError {
  case secretNotConfigured
  case invalidSecret
  case transportFailure
  case nonHTTPResponse
  case httpStatus(Int)
  case invalidJSON
  case requestRejected
  case missingUser
  case invalidToken
  case expired
  case untrustedEndpoint
  case untrustedResponse

  var errorDescription: String? {
    switch self {
    case .secretNotConfigured:
      "ยังไม่ได้บันทึกรหัสเชื่อมต่อจาก Rapsodo"
    case .invalidSecret:
      "รหัสเชื่อมต่อจาก Rapsodo มีรูปแบบไม่ถูกต้อง"
    case .transportFailure:
      "ติดต่อบริการยืนยันสิทธิ์ของ Rapsodo ไม่สำเร็จ"
    case .nonHTTPResponse:
      "บริการยืนยันสิทธิ์ของ Rapsodo ส่งคำตอบที่อ่านไม่ได้"
    case .httpStatus(let status):
      "บริการยืนยันสิทธิ์ของ Rapsodo ตอบกลับด้วยรหัส \(status)"
    case .invalidJSON:
      "ข้อมูลยืนยันสิทธิ์จาก Rapsodo มีรูปแบบไม่ถูกต้อง"
    case .requestRejected:
      "Rapsodo ไม่อนุมัติคำขอยืนยันสิทธิ์นี้"
    case .missingUser:
      "Rapsodo ไม่ได้ส่งข้อมูลผู้ใช้กลับมา"
    case .invalidToken:
      "รหัสยืนยันชั่วคราวที่ Rapsodo ส่งกลับมาใช้ไม่ได้"
    case .expired:
      "สิทธิ์ Third-party หมดอายุ กรุณายืนยันใหม่ในแอป Rapsodo"
    case .untrustedEndpoint, .untrustedResponse:
      "ปลายทางยืนยันสิทธิ์ของ Rapsodo ไม่ปลอดภัย"
    }
  }
}

struct RapsodoSimulatorTokenResponseDecoder: Sendable {
  private struct APIResponse: Decodable {
    let success: Bool
    let user: APIUser?
  }

  private struct APIUser: Decodable {
    // The upstream `id` is account metadata, not the device challenge ID.
    // Decodable intentionally ignores it because it is not an auth invariant.
    let token: String
    let expireDate: Int64
  }

  func decode(
    _ data: Data,
    now: Date
  ) throws -> MLM2PROAuthorizationCredential {
    let response: APIResponse
    do {
      response = try JSONDecoder().decode(APIResponse.self, from: data)
    } catch {
      throw RapsodoSimulatorTokenProviderError.invalidJSON
    }

    guard response.success else {
      throw RapsodoSimulatorTokenProviderError.requestRejected
    }
    guard let user = response.user else {
      throw RapsodoSimulatorTokenProviderError.missingUser
    }

    let normalizedToken = user.token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let token = UInt64(normalizedToken), token > 0 else {
      throw RapsodoSimulatorTokenProviderError.invalidToken
    }

    let expiresAt = Date(timeIntervalSince1970: TimeInterval(user.expireDate))
    guard expiresAt.timeIntervalSince1970.isFinite, expiresAt > now else {
      throw RapsodoSimulatorTokenProviderError.expired
    }

    return MLM2PROAuthorizationCredential(token: token, expiresAt: expiresAt)
  }
}

// MARK: - Provider

struct RapsodoSimulatorTokenProvider: MLM2PROTokenProvider {
  static let baseURL = URL(string: "https://mlm.rapsodo.com/api/simulator/user/")!

  private let secretStore: any RapsodoSimulatorSecretStoring
  private let transport: any RapsodoSimulatorHTTPTransporting
  private let responseDecoder: RapsodoSimulatorTokenResponseDecoder
  private let baseURL: URL
  private let now: @Sendable () -> Date

  init(
    secretStore: any RapsodoSimulatorSecretStoring = RapsodoSimulatorKeychainStore(),
    transport: any RapsodoSimulatorHTTPTransporting = RapsodoSimulatorURLSessionTransport(),
    responseDecoder: RapsodoSimulatorTokenResponseDecoder = .init(),
    baseURL: URL = Self.baseURL,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.secretStore = secretStore
    self.transport = transport
    self.responseDecoder = responseDecoder
    self.baseURL = baseURL
    self.now = now
  }

  func token(for deviceID: UInt32) async throws -> MLM2PROAuthorizationCredential {
    let endpointURL = baseURL.appendingPathComponent(String(deviceID))
    guard RapsodoSimulatorEndpointPolicy.isTrusted(baseURL),
      RapsodoSimulatorEndpointPolicy.isTrusted(endpointURL)
    else {
      throw RapsodoSimulatorTokenProviderError.untrustedEndpoint
    }

    guard let storedSecret = try secretStore.loadSecret() else {
      throw RapsodoSimulatorTokenProviderError.secretNotConfigured
    }
    let secret = storedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !secret.isEmpty else {
      throw RapsodoSimulatorTokenProviderError.secretNotConfigured
    }
    guard secret.rangeOfCharacter(from: .newlines) == nil else {
      throw RapsodoSimulatorTokenProviderError.invalidSecret
    }

    var request = URLRequest(
      url: endpointURL,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 15
    )
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(secret, forHTTPHeaderField: "Secret")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RapsodoSimulatorTokenProviderError.transportFailure
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw RapsodoSimulatorTokenProviderError.nonHTTPResponse
    }
    guard RapsodoSimulatorEndpointPolicy.isTrusted(httpResponse.url) else {
      throw RapsodoSimulatorTokenProviderError.untrustedResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw RapsodoSimulatorTokenProviderError.httpStatus(httpResponse.statusCode)
    }

    return try responseDecoder.decode(data, now: now())
  }
}
