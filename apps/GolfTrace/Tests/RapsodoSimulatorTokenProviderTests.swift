import Foundation
import Security
import XCTest

@testable import GolfTrace

final class RapsodoSimulatorTokenProviderTests: XCTestCase {
  private let deviceID: UInt32 = 123_456
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testRequestsTokenWithGETAndSecretHeader() async throws {
    let recorder = RequestRecorder()
    let expiresAt: Int64 = 1_700_003_600
    let body = Data(
      """
      {"success":true,"user":{"id":987654,"token":"1043255814","expireDate":\(expiresAt)}}
      """.utf8
    )
    let transport = StubHTTPTransport { request in
      await recorder.record(request)
      return (body, Self.httpResponse(for: request, statusCode: 200))
    }
    let provider = makeProvider(secret: "test-secret", transport: transport)

    let credential = try await provider.token(for: deviceID)

    XCTAssertEqual(credential.token, 1_043_255_814)
    XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: TimeInterval(expiresAt)))
    let recordedRequest = await recorder.lastRequest()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://mlm.rapsodo.com/api/simulator/user/123456"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Secret"), "test-secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(request.httpBody)
  }

  func testRejectsMissingAndWhitespaceOnlySecretsBeforeHTTP() async {
    let counter = CallCounter()
    let transport = StubHTTPTransport { request in
      await counter.increment()
      return (Data(), Self.httpResponse(for: request, statusCode: 200))
    }

    for secret in [nil, "", "  \n\t"] as [String?] {
      let provider = makeProvider(secret: secret, transport: transport)
      await assertProviderError(.secretNotConfigured) {
        try await provider.token(for: self.deviceID)
      }
    }

    let requestCount = await counter.value()
    XCTAssertEqual(requestCount, 0)
  }

  func testRejectsSecretContainingNewlineBeforeHTTP() async {
    let counter = CallCounter()
    let transport = StubHTTPTransport { request in
      await counter.increment()
      return (Data(), Self.httpResponse(for: request, statusCode: 200))
    }
    let provider = makeProvider(secret: "first-line\nsecond-line", transport: transport)

    await assertProviderError(.invalidSecret) {
      try await provider.token(for: self.deviceID)
    }
    let requestCount = await counter.value()
    XCTAssertEqual(requestCount, 0)
  }

  func testRejectsNonHTTPResponse() async {
    let transport = StubHTTPTransport { request in
      (
        Data("{}".utf8),
        URLResponse(
          url: try XCTUnwrap(request.url),
          mimeType: "application/json",
          expectedContentLength: 2,
          textEncodingName: "utf-8"
        )
      )
    }
    let provider = makeProvider(secret: "test-secret", transport: transport)

    await assertProviderError(.nonHTTPResponse) {
      try await provider.token(for: self.deviceID)
    }
  }

  func testRejectsNonSuccessHTTPStatusWithoutDecodingBody() async {
    let transport = StubHTTPTransport { request in
      (Data("not-json".utf8), Self.httpResponse(for: request, statusCode: 401))
    }
    let provider = makeProvider(secret: "test-secret", transport: transport)

    await assertProviderError(.httpStatus(401)) {
      try await provider.token(for: self.deviceID)
    }
  }

  func testMapsTransportErrorWithoutExposingItsDetails() async {
    let transport = StubHTTPTransport { _ in
      throw URLError(.cannotConnectToHost)
    }
    let provider = makeProvider(secret: "test-secret", transport: transport)

    await assertProviderError(.transportFailure) {
      try await provider.token(for: self.deviceID)
    }
  }

  func testRejectsNonProductionEndpointBeforeHTTP() async {
    let counter = CallCounter()
    let transport = StubHTTPTransport { request in
      await counter.increment()
      return (Data(), Self.httpResponse(for: request, statusCode: 200))
    }

    for url in [
      URL(string: "http://mlm.rapsodo.com/api/simulator/user/")!,
      URL(string: "https://mlm.rapsodo.com.attacker.example/api/simulator/user/")!,
    ] {
      let provider = makeProvider(
        secret: "test-secret",
        transport: transport,
        baseURL: url
      )
      await assertProviderError(.untrustedEndpoint) {
        try await provider.token(for: self.deviceID)
      }
    }

    let requestCount = await counter.value()
    XCTAssertEqual(requestCount, 0)
  }

  func testRejectsResponseFromAnotherHost() async {
    let body = Data(
      """
      {"success":true,"user":{"id":987654,"token":"42","expireDate":1700003600}}
      """.utf8
    )
    let transport = StubHTTPTransport { _ in
      (
        body,
        Self.httpResponse(
          url: URL(string: "https://attacker.example/token")!,
          statusCode: 200
        )
      )
    }
    let provider = makeProvider(secret: "test-secret", transport: transport)

    await assertProviderError(.untrustedResponse) {
      try await provider.token(for: self.deviceID)
    }
  }

  func testRedirectPolicyNeverForwardsSecretAcrossHostOrHTTPSDowngrade() throws {
    let sourceURL = URL(string: "https://mlm.rapsodo.com/api/simulator/user/123456")!
    let response = Self.httpResponse(url: sourceURL, statusCode: 302)

    for destination in [
      URL(string: "https://attacker.example/collect")!,
      URL(string: "http://mlm.rapsodo.com/collect")!,
    ] {
      var redirectedRequest = URLRequest(url: destination)
      redirectedRequest.setValue("test-secret", forHTTPHeaderField: "Secret")
      XCTAssertNil(
        RapsodoSimulatorEndpointPolicy.validatedRedirect(
          redirectedRequest,
          from: response
        )
      )
    }

    var sameHostRequest = URLRequest(
      url: URL(string: "https://mlm.rapsodo.com/api/simulator/user/123456/")!
    )
    sameHostRequest.setValue("test-secret", forHTTPHeaderField: "Secret")
    let accepted = try XCTUnwrap(
      RapsodoSimulatorEndpointPolicy.validatedRedirect(sameHostRequest, from: response)
    )
    XCTAssertEqual(accepted.url?.host, "mlm.rapsodo.com")
    XCTAssertEqual(accepted.value(forHTTPHeaderField: "Secret"), "test-secret")
  }

  func testDecoderRejectsMalformedJSON() {
    let decoder = RapsodoSimulatorTokenResponseDecoder()

    XCTAssertThrowsError(
      try decoder.decode(Data("not-json".utf8), now: now)
    ) { error in
      XCTAssertEqual(error as? RapsodoSimulatorTokenProviderError, .invalidJSON)
    }
  }

  func testDecoderRejectsUnsuccessfulOrIncompleteResponse() {
    let decoder = RapsodoSimulatorTokenResponseDecoder()

    XCTAssertThrowsError(
      try decoder.decode(
        Data("{\"success\":false}".utf8),
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? RapsodoSimulatorTokenProviderError, .requestRejected)
    }
    XCTAssertThrowsError(
      try decoder.decode(
        Data("{\"success\":true}".utf8),
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? RapsodoSimulatorTokenProviderError, .missingUser)
    }
  }

  func testDecoderTreatsResponseAccountIDAsMetadataAndRejectsInvalidToken() throws {
    let decoder = RapsodoSimulatorTokenResponseDecoder()
    let futureExpiry = 1_700_003_600

    let credential = try decoder.decode(
      Data(
        """
        {"success":true,"user":{"id":654321,"token":"42","expireDate":\(futureExpiry)}}
        """.utf8
      ),
      now: now
    )
    XCTAssertEqual(credential.token, 42)

    for token in ["", "not-a-number", "0"] {
      XCTAssertThrowsError(
        try decoder.decode(
          Data(
            """
            {"success":true,"user":{"id":123456,"token":"\(token)","expireDate":\(futureExpiry)}}
            """.utf8
          ),
          now: now
        )
      ) { error in
        XCTAssertEqual(error as? RapsodoSimulatorTokenProviderError, .invalidToken)
      }
    }
  }

  func testDecoderRejectsExpiredCredentialAtBoundary() {
    let decoder = RapsodoSimulatorTokenResponseDecoder()

    for expiry in [1_699_999_999, 1_700_000_000] {
      XCTAssertThrowsError(
        try decoder.decode(
          Data(
            """
            {"success":true,"user":{"id":123456,"token":"42","expireDate":\(expiry)}}
            """.utf8
          ),
          now: now
        )
      ) { error in
        XCTAssertEqual(error as? RapsodoSimulatorTokenProviderError, .expired)
      }
    }
  }

  func testKeychainStoreUIAPIUsesFixedServiceAndSupportsSaveInspectDelete() throws {
    let keychain = InMemoryKeychainAccess()
    let store = RapsodoSimulatorKeychainStore(keychain: keychain)

    XCTAssertFalse(try store.hasSecret())
    try store.saveSecret("  pasted-secret \n")
    XCTAssertTrue(try store.hasSecret())
    XCTAssertEqual(try store.loadSecret(), "pasted-secret")
    XCTAssertEqual(keychain.lastService, "com.bda.golftrace.rapsodo-simulator")
    XCTAssertEqual(keychain.lastAccount, "web-api-secret")

    try store.deleteSecret()
    XCTAssertFalse(try store.hasSecret())
  }

  func testKeychainQueriesUseDataProtectionAndWhenUnlockedThisDeviceOnly() {
    let protectedLookup = SystemRapsodoSimulatorKeychainAccess.protectedLookup(
      service: RapsodoSimulatorKeychainStore.service,
      account: RapsodoSimulatorKeychainStore.account
    )
    XCTAssertEqual(protectedLookup[kSecUseDataProtectionKeychain as String] as? Bool, true)

    let protectedUpdate = SystemRapsodoSimulatorKeychainAccess.protectedUpdate(
      data: Data("secret".utf8)
    )
    XCTAssertEqual(
      protectedUpdate[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
    )

    let legacyLookup = SystemRapsodoSimulatorKeychainAccess.legacyLookup(
      service: RapsodoSimulatorKeychainStore.service,
      account: RapsodoSimulatorKeychainStore.account
    )
    XCTAssertEqual(legacyLookup[kSecUseDataProtectionKeychain as String] as? Bool, false)
  }

  func testKeychainStoreMigratesLegacySecretIntoProtectedStorage() throws {
    let keychain = InMemoryKeychainAccess(
      legacyData: Data("  legacy-secret \n".utf8)
    )
    let store = RapsodoSimulatorKeychainStore(keychain: keychain)

    XCTAssertEqual(try store.loadSecret(), "legacy-secret")
    XCTAssertEqual(keychain.protectedData, Data("legacy-secret".utf8))
    XCTAssertNil(keychain.legacyData)
  }

  func testKeychainStoreRejectsEmptySecretAndCorruptStoredValue() throws {
    let keychain = InMemoryKeychainAccess()
    let store = RapsodoSimulatorKeychainStore(keychain: keychain)

    XCTAssertThrowsError(try store.saveSecret(" \n\t ")) { error in
      XCTAssertEqual(error as? RapsodoSimulatorSecretStoreError, .emptySecret)
    }

    try keychain.upsert(
      Data([0xFF, 0xFE]),
      service: RapsodoSimulatorKeychainStore.service,
      account: RapsodoSimulatorKeychainStore.account
    )
    XCTAssertThrowsError(try store.loadSecret()) { error in
      XCTAssertEqual(error as? RapsodoSimulatorSecretStoreError, .invalidStoredSecret)
    }

    let legacyKeychain = InMemoryKeychainAccess(legacyData: Data([0xFF, 0xFE]))
    let legacyStore = RapsodoSimulatorKeychainStore(keychain: legacyKeychain)
    XCTAssertThrowsError(try legacyStore.loadSecret()) { error in
      XCTAssertEqual(error as? RapsodoSimulatorSecretStoreError, .invalidStoredSecret)
    }
    XCTAssertNil(legacyKeychain.protectedData)
    XCTAssertEqual(legacyKeychain.legacyData, Data([0xFF, 0xFE]))
  }

  private func makeProvider(
    secret: String?,
    transport: any RapsodoSimulatorHTTPTransporting,
    baseURL: URL = RapsodoSimulatorTokenProvider.baseURL
  ) -> RapsodoSimulatorTokenProvider {
    let fixedNow = now
    return RapsodoSimulatorTokenProvider(
      secretStore: StaticSecretStore(secret: secret),
      transport: transport,
      baseURL: baseURL,
      now: { fixedNow }
    )
  }

  private func assertProviderError(
    _ expected: RapsodoSimulatorTokenProviderError,
    operation: () async throws -> MLM2PROAuthorizationCredential
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? RapsodoSimulatorTokenProviderError, expected)
    }
  }

  private static func httpResponse(
    for request: URLRequest,
    statusCode: Int
  ) -> HTTPURLResponse {
    httpResponse(url: request.url!, statusCode: statusCode)
  }

  private static func httpResponse(
    url: URL,
    statusCode: Int
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
  }
}

private struct StaticSecretStore: RapsodoSimulatorSecretStoring {
  let secret: String?

  func loadSecret() throws -> String? { secret }
  func saveSecret(_ secret: String) throws {}
  func deleteSecret() throws {}
}

private struct StubHTTPTransport: RapsodoSimulatorHTTPTransporting {
  let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    self.handler = handler
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await handler(request)
  }
}

private actor RequestRecorder {
  private var request: URLRequest?

  func record(_ request: URLRequest) {
    self.request = request
  }

  func lastRequest() -> URLRequest? { request }
}

private actor CallCounter {
  private var count = 0

  func increment() {
    count += 1
  }

  func value() -> Int { count }
}

private final class InMemoryKeychainAccess: RapsodoSimulatorLegacyKeychainAccessing,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var storedProtectedData: Data?
  private var storedLegacyData: Data?
  private var service: String?
  private var account: String?

  init(legacyData: Data? = nil) {
    storedLegacyData = legacyData
  }

  var protectedData: Data? {
    lock.withLock { storedProtectedData }
  }

  var legacyData: Data? {
    lock.withLock { storedLegacyData }
  }

  var lastService: String? {
    lock.withLock { service }
  }

  var lastAccount: String? {
    lock.withLock { account }
  }

  func read(service: String, account: String) throws -> Data? {
    lock.withLock {
      self.service = service
      self.account = account
      return storedProtectedData
    }
  }

  func readLegacy(service: String, account: String) throws -> Data? {
    lock.withLock {
      self.service = service
      self.account = account
      return storedLegacyData
    }
  }

  func upsert(_ data: Data, service: String, account: String) throws {
    lock.withLock {
      storedProtectedData = data
      self.service = service
      self.account = account
    }
  }

  func delete(service: String, account: String) throws {
    lock.withLock {
      storedProtectedData = nil
      self.service = service
      self.account = account
    }
  }

  func deleteLegacy(service: String, account: String) throws {
    lock.withLock {
      storedLegacyData = nil
      self.service = service
      self.account = account
    }
  }
}
