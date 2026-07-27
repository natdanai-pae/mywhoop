import Foundation
import Security
import XCTest

@testable import GolfTrace

final class OpenRouterAccountClientTests: XCTestCase {
  func testDecodesAccountAndUsesMetadataOnlyGET() async throws {
    let recorder = AccountRequestRecorder()
    let payload = Data(
      #"{"data":{"limit":10,"limit_reset":"weekly","limit_remaining":7.75,"usage_weekly":2.25,"is_free_tier":false}}"#
        .utf8
    )
    let client = OpenRouterAccountClient(
      transport: AccountStubTransport { request in
        await recorder.record(request)
        return (
          payload,
          Self.response(url: request.url!, status: 200, mime: "application/json")
        )
      },
      now: { Date(timeIntervalSince1970: 123) }
    )

    let account = try await client.fetchAccount(apiKey: "test-key")

    XCTAssertEqual(account.limitUSD, 10)
    XCTAssertEqual(account.limitReset, "weekly")
    XCTAssertEqual(account.limitRemainingUSD, 7.75)
    XCTAssertEqual(account.weeklyUsageUSD, 2.25)
    XCTAssertFalse(account.isFreeTier)
    XCTAssertTrue(account.hasWeeklyServerLimit(atOrBelow: 10))
    XCTAssertEqual(account.checkedAt, Date(timeIntervalSince1970: 123))
    let capturedRequest = await recorder.lastRequest()
    let recorded = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(recorded.httpMethod, "GET")
    XCTAssertNil(recorded.httpBody)
    XCTAssertEqual(recorded.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(recorded.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
  }

  func testMapsAuthenticationCreditRateAndAvailabilityErrorsWithoutBodyReflection() async {
    let cases: [(Int, OpenRouterAccountError)] = [
      (401, .unauthorized),
      (403, .unauthorized),
      (402, .paymentRequired),
      (429, .rateLimited),
      (503, .unavailable),
      (418, .server(status: 418)),
    ]

    for (status, expected) in cases {
      let client = OpenRouterAccountClient(
        transport: AccountStubTransport { request in
          (
            Data(#"{"error":{"message":"must never reach UI"}}"#.utf8),
            Self.response(url: request.url!, status: status, mime: "application/json")
          )
        }
      )
      do {
        _ = try await client.fetchAccount(apiKey: "test-key")
        XCTFail("Expected HTTP error for \(status)")
      } catch let error as OpenRouterAccountError {
        XCTAssertEqual(error, expected)
        XCTAssertFalse(error.localizedDescription.contains("must never reach UI"))
      } catch {
        XCTFail("Unexpected error for \(status): \(error)")
      }
    }
  }

  func testRejectsRedirectedDifferentURLNonJSONAndOversizedResponses() async {
    let validPayload = Data(
      #"{"data":{"limit":null,"limit_reset":null,"limit_remaining":null,"usage_weekly":0,"is_free_tier":true}}"#
        .utf8
    )

    let redirected = OpenRouterAccountClient(
      transport: AccountStubTransport { _ in
        (
          validPayload,
          Self.response(
            url: URL(string: "https://attacker.example/key")!,
            status: 200,
            mime: "application/json"
          )
        )
      }
    )
    await assertError(.untrustedResponse, from: redirected)

    let nonJSON = OpenRouterAccountClient(
      transport: AccountStubTransport { request in
        (validPayload, Self.response(url: request.url!, status: 200, mime: "text/html"))
      }
    )
    await assertError(.unsupportedResponseType, from: nonJSON)

    let oversized = OpenRouterAccountClient(
      transport: AccountStubTransport { request in
        (
          Data(repeating: 0x20, count: OpenRouterAccountClient.maximumResponseBytes + 1),
          Self.response(url: request.url!, status: 200, mime: "application/json")
        )
      }
    )
    await assertError(.responseTooLarge, from: oversized)
  }

  private func assertError(
    _ expected: OpenRouterAccountError,
    from client: OpenRouterAccountClient
  ) async {
    do {
      _ = try await client.fetchAccount(apiKey: "test-key")
      XCTFail("Expected \(expected)")
    } catch let error as OpenRouterAccountError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private static func response(
    url: URL,
    status: Int,
    mime: String
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": mime]
    )!
  }
}

final class GolfAISettingsSecurityTests: XCTestCase {
  func testLoginKeychainFallbackWhenProtectedLookupReturnsItemNotFound() throws {
    let security = LoginFallbackSecurityItemAccess(
      loginValue: "dummy-not-a-real-key"
    )
    let keychain = GolfAIKeychainStore(
      service: "com.bda.golftrace.tests.login-fallback",
      account: "dummy-openrouter-key",
      security: security
    )

    XCTAssertTrue(try keychain.containsAPIKey())
    XCTAssertEqual(try keychain.loadAPIKey(), "dummy-not-a-real-key")
    XCTAssertEqual(try keychain.storedAPIKeySuffix(), "-key")

    try keychain.deleteAPIKey()

    XCTAssertFalse(try keychain.containsAPIKey())
    let calls = security.callSnapshot
    XCTAssertEqual(calls.protectedCopies, 4)
    XCTAssertEqual(calls.loginCopies, 4)
    XCTAssertEqual(calls.protectedDeletes, 1)
    XCTAssertEqual(calls.loginDeletes, 1)
  }

  func testSaveFallbackVerifiesLoginKeychainReadBack() throws {
    let security = LoginFallbackSecurityItemAccess()
    let keychain = GolfAIKeychainStore(
      service: "com.bda.golftrace.tests.save-fallback",
      account: "dummy-openrouter-key",
      security: security
    )

    try keychain.saveAPIKey("  dummy-not-a-real-key  \n")

    XCTAssertEqual(security.storedLoginValue, "dummy-not-a-real-key")
    let calls = security.callSnapshot
    XCTAssertEqual(calls.protectedUpdates, 1)
    XCTAssertEqual(calls.loginUpdates, 1)
    XCTAssertEqual(calls.loginAdds, 1)
    XCTAssertEqual(calls.protectedCopies, 1)
    XCTAssertEqual(calls.loginCopies, 1)
  }

  func testSaveFallbackFailsWhenSuccessfulAddCannotBeReadBack() {
    let security = LoginFallbackSecurityItemAccess(persistWrites: false)
    let keychain = GolfAIKeychainStore(
      service: "com.bda.golftrace.tests.failed-readback",
      account: "dummy-openrouter-key",
      security: security
    )

    XCTAssertThrowsError(try keychain.saveAPIKey("dummy-not-a-real-key")) { error in
      guard case GolfAISettingsError.invalidStoredAPIKey = error else {
        return XCTFail("Expected invalidStoredAPIKey, got \(error)")
      }
    }
  }

  func testSystemKeychainCanRoundTripWithLocalDevelopmentSigning() throws {
    let uniqueID = UUID().uuidString
    let keychain = GolfAIKeychainStore(
      service: "com.bda.golftrace.tests.\(uniqueID)",
      account: "dummy-openrouter-key"
    )
    defer { try? keychain.deleteAPIKey() }

    XCTAssertFalse(try keychain.containsAPIKey())
    try keychain.saveAPIKey("dummy-not-a-real-key")
    XCTAssertTrue(try keychain.containsAPIKey())
    XCTAssertEqual(try keychain.loadAPIKey(), "dummy-not-a-real-key")
    try keychain.deleteAPIKey()
    XCTAssertFalse(try keychain.containsAPIKey())
  }

  @MainActor
  func testStatusExposesOnlyLastFourCharactersOfStoredKey() {
    let defaults = makeDefaults()
    defaults.set(
      "https://openrouter.ai:443",
      forKey: "GolfTrace.AI.openRouterAPIKeyOrigin"
    )
    let keychain = MockGolfAIKeychain(hasKey: true)

    let settings = GolfAISettings(defaults: defaults, keychain: keychain)

    XCTAssertTrue(settings.hasStoredAPIKey)
    XCTAssertEqual(settings.storedAPIKeySuffix, "-key")
    XCTAssertEqual(keychain.containsCallCount, 1)
    XCTAssertEqual(keychain.loadCallCount, 0)
    XCTAssertEqual(keychain.suffixCallCount, 1)
    XCTAssertEqual(settings.openRouterHealth, .notChecked)
  }

  @MainActor
  func testDefaultsExposeAIAndAllThreeSoundControls() {
    let settings = GolfAISettings(
      defaults: makeDefaults(),
      keychain: MockGolfAIKeychain(hasKey: false)
    )

    XCTAssertTrue(settings.aiEnabled)
    XCTAssertTrue(settings.automaticCoachEnabled)
    XCTAssertEqual(settings.weeklyBudgetUSD, 10)
    XCTAssertTrue(settings.aiVoiceEnabled)
    XCTAssertEqual(settings.aiVoiceVolume, 0.9)
    XCTAssertEqual(settings.aiVoiceRate, 0.47)
    XCTAssertTrue(settings.tempoCueEnabled)
    XCTAssertTrue(settings.guidelineCueEnabled)
    XCTAssertTrue(settings.handsFreeCaptureEnabled)
    XCTAssertEqual(settings.soundEffectsVolume, 0.8)
  }

  @MainActor
  func testExactReturnedCostTripsLocalWeeklyGate() async {
    let defaults = makeDefaults()
    let keychain = MockGolfAIKeychain(hasKey: false)
    let settings = GolfAISettings(defaults: defaults, keychain: keychain)
    XCTAssertTrue(settings.saveAPIKey("test-key"))
    settings.weeklyBudgetUSD = 0.01

    settings.recordUsage(
      OpenRouterGenerationUsage(
        generationID: "gen-1",
        costUSD: 0.01,
        promptTokens: 100,
        completionTokens: 20,
        totalTokens: 120
      )
    )

    XCTAssertEqual(settings.localWeeklyCostUSD, 0.01)
    XCTAssertEqual(settings.localWeeklyPromptTokens, 100)
    XCTAssertEqual(settings.localWeeklyCompletionTokens, 20)
    let gate = await settings.prepareForAIRequest()
    XCTAssertEqual(gate, .localWeeklyBudgetReached)

    settings.weeklyBudgetUSD = 0.02
    XCTAssertEqual(settings.openRouterHealth, .notChecked)
    XCTAssertEqual(settings.localWeeklyBudgetRemainingUSD, 0.01, accuracy: 0.000_001)
  }

  @MainActor
  func testInvalidKeyIsStoppedByFreeAccountCheckBeforePaidRequest() async {
    let defaults = makeDefaults()
    defaults.set(
      "https://openrouter.ai:443",
      forKey: "GolfTrace.AI.openRouterAPIKeyOrigin"
    )
    let settings = GolfAISettings(
      defaults: defaults,
      keychain: MockGolfAIKeychain(hasKey: true),
      accountClient: RejectingAccountChecker(error: .unauthorized)
    )

    let gate = await settings.prepareForAIRequest()

    XCTAssertEqual(gate, .invalidAPIKey)
    XCTAssertEqual(
      settings.openRouterHealth, .failed(OpenRouterAccountError.unauthorized.localizedDescription))
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "GolfAISettingsSecurityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}

private struct AccountStubTransport: AICoachHTTPTransporting {
  let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await handler(request)
  }
}

private actor AccountRequestRecorder {
  private var request: URLRequest?

  func record(_ request: URLRequest) { self.request = request }
  func lastRequest() -> URLRequest? { request }
}

private struct RejectingAccountChecker: OpenRouterAccountChecking {
  let error: OpenRouterAccountError

  func fetchAccount(apiKey: String) async throws -> OpenRouterAccountSnapshot {
    _ = apiKey
    throw error
  }
}

private final class LoginFallbackSecurityItemAccess: GolfAISecurityItemAccessing,
  @unchecked Sendable
{
  struct CallSnapshot {
    let protectedCopies: Int
    let loginCopies: Int
    let protectedUpdates: Int
    let loginUpdates: Int
    let loginAdds: Int
    let protectedDeletes: Int
    let loginDeletes: Int
  }

  private let lock = NSLock()
  private let persistWrites: Bool
  private var loginData: Data?
  private var protectedCopies = 0
  private var loginCopies = 0
  private var protectedUpdates = 0
  private var loginUpdates = 0
  private var loginAdds = 0
  private var protectedDeletes = 0
  private var loginDeletes = 0

  init(loginValue: String? = nil, persistWrites: Bool = true) {
    loginData = loginValue.map { Data($0.utf8) }
    self.persistWrites = persistWrites
  }

  var storedLoginValue: String? {
    synchronized {
      loginData.flatMap { String(data: $0, encoding: .utf8) }
    }
  }

  var callSnapshot: CallSnapshot {
    synchronized {
      CallSnapshot(
        protectedCopies: protectedCopies,
        loginCopies: loginCopies,
        protectedUpdates: protectedUpdates,
        loginUpdates: loginUpdates,
        loginAdds: loginAdds,
        protectedDeletes: protectedDeletes,
        loginDeletes: loginDeletes
      )
    }
  }

  func copyMatching(
    _ query: CFDictionary,
    result: UnsafeMutablePointer<CFTypeRef?>?
  ) -> OSStatus {
    synchronized {
      if usesDataProtectionKeychain(query) {
        protectedCopies += 1
        return errSecItemNotFound
      }

      loginCopies += 1
      guard let loginData else { return errSecItemNotFound }
      if requestsData(query) {
        result?.pointee = loginData as CFData
      }
      return errSecSuccess
    }
  }

  func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
    synchronized {
      if usesDataProtectionKeychain(query) {
        protectedUpdates += 1
        return errSecMissingEntitlement
      }

      loginUpdates += 1
      guard loginData != nil else { return errSecItemNotFound }
      guard let value = valueData(attributes) else { return errSecParam }
      if persistWrites { loginData = value }
      return errSecSuccess
    }
  }

  func add(
    _ attributes: CFDictionary,
    result: UnsafeMutablePointer<CFTypeRef?>?
  ) -> OSStatus {
    _ = result
    return synchronized {
      guard !usesDataProtectionKeychain(attributes) else {
        return errSecMissingEntitlement
      }
      loginAdds += 1
      guard loginData == nil else { return errSecDuplicateItem }
      guard let value = valueData(attributes) else { return errSecParam }
      if persistWrites { loginData = value }
      return errSecSuccess
    }
  }

  func delete(_ query: CFDictionary) -> OSStatus {
    synchronized {
      if usesDataProtectionKeychain(query) {
        protectedDeletes += 1
        return errSecItemNotFound
      }

      loginDeletes += 1
      guard loginData != nil else { return errSecItemNotFound }
      loginData = nil
      return errSecSuccess
    }
  }

  private func usesDataProtectionKeychain(_ attributes: CFDictionary) -> Bool {
    let value = (attributes as NSDictionary)[kSecUseDataProtectionKeychain as String]
    return (value as? NSNumber)?.boolValue == true
  }

  private func requestsData(_ attributes: CFDictionary) -> Bool {
    let value = (attributes as NSDictionary)[kSecReturnData as String]
    return (value as? NSNumber)?.boolValue == true
  }

  private func valueData(_ attributes: CFDictionary) -> Data? {
    (attributes as NSDictionary)[kSecValueData as String] as? Data
  }

  private func synchronized<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private final class MockGolfAIKeychain: GolfAIKeychainStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var storedKey: String?
  private var containsCalls = 0
  private var suffixCalls = 0
  private var loadCalls = 0

  init(hasKey: Bool) {
    storedKey = hasKey ? "unread-test-key" : nil
  }

  var containsCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return containsCalls
  }

  var loadCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return loadCalls
  }

  var suffixCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return suffixCalls
  }

  func containsAPIKey() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    containsCalls += 1
    return storedKey != nil
  }

  func storedAPIKeySuffix() throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    suffixCalls += 1
    return storedKey.map { String($0.suffix(4)) }
  }

  func loadAPIKey() throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    loadCalls += 1
    return storedKey
  }

  func saveAPIKey(_ value: String) throws {
    lock.lock()
    defer { lock.unlock() }
    storedKey = value
  }

  func deleteAPIKey() throws {
    lock.lock()
    defer { lock.unlock() }
    storedKey = nil
  }
}
