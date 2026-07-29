import Foundation
import XCTest

@testable import GolfTrace

final class GX10VLMClientTests: XCTestCase {
  override func tearDown() {
    MockVLMURLProtocol.handler = nil
    super.tearDown()
  }

  @MainActor
  func testSettingsDefaultOffAndKeepVLMSeparateFromGatewayKey() throws {
    let suiteName = "GX10VLMClientTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)

    let settings = GolfAISettings(defaults: defaults)
    XCTAssertFalse(settings.vlmEnabled)
    XCTAssertEqual(settings.vlmEndpoint, "")
    XCTAssertEqual(settings.vlmModel, "Qwen/Qwen3-VL-8B-Instruct")
    XCTAssertNil(settings.vlmURL)

    settings.vlmEnabled = true
    settings.vlmEndpoint = "http://100.104.228.23:8000/v1/chat/completions"
    settings.vlmModel = "local/qwen-vl"
    XCTAssertEqual(
      settings.vlmURL,
      URL(string: "http://100.104.228.23:8000/v1/chat/completions")
    )

    let restored = GolfAISettings(defaults: defaults)
    XCTAssertTrue(restored.vlmEnabled)
    XCTAssertEqual(restored.vlmEndpoint, settings.vlmEndpoint)
    XCTAssertEqual(restored.vlmModel, "local/qwen-vl")
  }

  func testPrivateHTTPUsesOpenAIMultimodalJSONSchemaWithoutAuthorization() async throws {
    let endpoint = URL(string: "http://100.104.228.23:8000/v1/chat/completions")!
    MockVLMURLProtocol.handler = { request in
      XCTAssertEqual(request.url, endpoint)
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

      let body = try Self.bodyData(for: request)
      XCTAssertLessThanOrEqual(body.count, GX10VLMClient.maximumRequestBytes)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      XCTAssertEqual(object["model"] as? String, "Qwen/Qwen3-VL-8B-Instruct")
      XCTAssertEqual(object["temperature"] as? Double, 0)
      XCTAssertEqual(object["max_tokens"] as? Int, 1_200)
      let responseFormat = try XCTUnwrap(object["response_format"] as? [String: String])
      XCTAssertEqual(responseFormat, ["type": "json_object"])

      let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 2)
      XCTAssertEqual(messages[0]["role"] as? String, "system")
      let systemPrompt = try XCTUnwrap(messages[0]["content"] as? String)
      XCTAssertTrue(systemPrompt.localizedCaseInsensitiveContains("untrusted"))

      XCTAssertEqual(messages[1]["role"] as? String, "user")
      let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
      XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "text", "image_url"])
      let evidencePrompt = try XCTUnwrap(content[0]["text"] as? String)
      XCTAssertTrue(evidencePrompt.localizedCaseInsensitiveContains("untrusted"))
      XCTAssertTrue(evidencePrompt.contains("claim-1"))
      let image = try XCTUnwrap(content[2]["image_url"] as? [String: String])
      XCTAssertTrue(image["url"]?.hasPrefix("data:image/jpeg;base64,") == true)

      return (
        try Self.response(
          url: endpoint,
          headers: ["Content-Type": "application/json; charset=utf-8"]
        ),
        try Self.openAIResponse(
          grounding: Self.validGrounding(
            supportedClaimIDs: ["claim-1"]
          )
        )
      )
    }

    let client = GX10VLMClient(session: Self.mockSession())
    let result = try await client.analyze(
      frames: [Self.frame()],
      transcript: "รักษาจังหวะแบ็กสวิง",
      claims: [Self.claim()],
      endpoint: endpoint,
      model: " Qwen/Qwen3-VL-8B-Instruct "
    )

    XCTAssertTrue(result.id.hasPrefix("vlm-"))
    XCTAssertEqual(result.visiblePeople, 1)
    XCTAssertEqual(result.swingPhase, "top")
    XCTAssertEqual(result.clubVisible, true)
    XCTAssertEqual(result.supportedClaimIDs, ["claim-1"])
    XCTAssertEqual(result.contradictedClaimIDs, [])
    XCTAssertEqual(result.confidence, 0.82)
    XCTAssertEqual(result.model, "Qwen/Qwen3-VL-8B-Instruct")
    XCTAssertEqual(result.analyzedFrameHashes, [String(repeating: "a", count: 64)])
    XCTAssertLessThan(abs(result.analyzedAt.timeIntervalSinceNow), 5)
  }

  func testVLMAcceptsHTTPSAndPrivateHTTPButRejectsPublicHTTP() async {
    for value in [
      "https://vlm.example/v1/chat/completions",
      "http://127.0.0.1:8000/v1/chat/completions",
      "http://192.168.1.20:8000/v1/chat/completions",
      "http://100.104.228.23:8000/v1/chat/completions",
      "http://gx10-bda:8000/v1/chat/completions",
    ] {
      XCTAssertNotNil(AICoachEndpointPolicy.validated(value, for: .vlm), value)
    }
    XCTAssertNil(
      AICoachEndpointPolicy.validated(
        "http://attacker.example/v1/chat/completions",
        for: .vlm
      )
    )

    let client = GX10VLMClient(session: Self.mockSession())
    await assertThrowsVLMError(.invalidEndpoint) {
      try await client.analyze(
        frames: [Self.frame()],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: URL(string: "http://attacker.example/v1/chat/completions")!,
        model: "qwen-vl"
      )
    }
  }

  func testRedirectPolicyAndFinalOriginRejectCrossOrigin() async throws {
    let endpoint = URL(string: "http://100.104.228.23:8000/v1/chat/completions")!
    let redirectResponse = try Self.response(
      url: endpoint,
      statusCode: 307,
      headers: ["Location": "/v1/chat/completions/"]
    )
    XCTAssertNotNil(
      AICoachEndpointPolicy.validatedRedirect(
        URLRequest(
          url: URL(string: "http://100.104.228.23:8000/v1/chat/completions/")!
        ),
        from: redirectResponse
      )
    )
    XCTAssertNil(
      AICoachEndpointPolicy.validatedRedirect(
        URLRequest(url: URL(string: "https://attacker.example/collect")!),
        from: redirectResponse
      )
    )

    MockVLMURLProtocol.handler = { _ in
      (
        try Self.response(
          url: URL(string: "https://attacker.example/collect")!
        ),
        try Self.openAIResponse(grounding: Self.validGrounding())
      )
    }
    let client = GX10VLMClient(session: Self.mockSession())
    await assertThrowsVLMError(.untrustedResponse) {
      try await client.analyze(
        frames: [Self.frame()],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: endpoint,
        model: "qwen-vl"
      )
    }
  }

  func testRejectsMoreThanThreeFramesAndRequestOverTwelveMegabytes() async {
    let client = GX10VLMClient(session: Self.mockSession())
    let endpoint = URL(string: "http://127.0.0.1:8000/v1/chat/completions")!

    await assertThrowsVLMError(.invalidFrames) {
      try await client.analyze(
        frames: Array(repeating: Self.frame(), count: 4),
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: endpoint,
        model: "qwen-vl"
      )
    }

    let largeFrame = GX10VLMFrameInput(
      data: Data(repeating: 0xAB, count: 9 * 1_024 * 1_024),
      mimeType: "image/jpeg",
      timestampSeconds: 12,
      sha256: String(repeating: "b", count: 64)
    )
    await assertThrowsVLMError(.requestTooLarge) {
      try await client.analyze(
        frames: [largeFrame],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: endpoint,
        model: "qwen-vl"
      )
    }
  }

  func testRejectsResponseLargerThan512KiB() async {
    MockVLMURLProtocol.handler = { request in
      let size = GX10VLMClient.maximumResponseBytes + 1
      return (
        try Self.response(
          url: request.url!,
          headers: [
            "Content-Type": "application/json",
            "Content-Length": "\(size)",
          ]
        ),
        Data(repeating: 0x20, count: size)
      )
    }
    let client = GX10VLMClient(session: Self.mockSession())
    await assertThrowsVLMError(.responseTooLarge) {
      try await client.analyze(
        frames: [Self.frame()],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
        model: "qwen-vl"
      )
    }
  }

  func testRejectsNonJSONMalformedAndUngroundedClaims() async {
    let endpoint = URL(string: "http://127.0.0.1:8000/v1/chat/completions")!
    let client = GX10VLMClient(session: Self.mockSession())

    MockVLMURLProtocol.handler = { request in
      (
        try Self.response(
          url: request.url!,
          headers: ["Content-Type": "text/html"]
        ),
        try Self.openAIResponse(grounding: Self.validGrounding())
      )
    }
    await assertThrowsVLMError(.invalidResponse) {
      try await client.analyze(
        frames: [Self.frame()],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: endpoint,
        model: "qwen-vl"
      )
    }

    MockVLMURLProtocol.handler = { request in
      let fencedContent = "```json\n{}\n```"
      return (
        try Self.response(url: request.url!),
        try JSONSerialization.data(withJSONObject: [
          "choices": [["message": ["content": fencedContent]]]
        ])
      )
    }
    await assertThrowsVLMError(.groundingInvalid) {
      try await client.analyze(
        frames: [Self.frame()],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: endpoint,
        model: "qwen-vl"
      )
    }

    MockVLMURLProtocol.handler = { request in
      (
        try Self.response(url: request.url!),
        try Self.openAIResponse(
          grounding: Self.validGrounding(
            supportedClaimIDs: ["invented-claim"]
          )
        )
      )
    }
    await assertThrowsVLMError(.groundingInvalid) {
      try await client.analyze(
        frames: [Self.frame()],
        transcript: "transcript",
        claims: [Self.claim()],
        endpoint: endpoint,
        model: "qwen-vl"
      )
    }
  }

  func testVisualClaimGroundingCodableRoundTrip() throws {
    let value = VisualClaimGrounding(
      id: "vlm-test",
      visiblePeople: nil,
      swingPhase: nil,
      clubVisible: nil,
      onScreenGuides: [],
      description: "มองเห็นร่างกายบางส่วน",
      supportedClaimIDs: [],
      contradictedClaimIDs: [],
      confidence: 0.25,
      limitations: ["ไม้ถูกบัง"],
      model: "qwen-vl",
      analyzedFrameHashes: [String(repeating: "c", count: 64)],
      analyzedAt: Date(timeIntervalSince1970: 1_234)
    )
    let decoded = try JSONDecoder().decode(
      VisualClaimGrounding.self,
      from: JSONEncoder().encode(value)
    )
    XCTAssertEqual(decoded, value)
  }

  private static func frame() -> GX10VLMFrameInput {
    GX10VLMFrameInput(
      data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xD9]),
      mimeType: "image/jpeg",
      timestampSeconds: 12.5,
      sha256: String(repeating: "a", count: 64)
    )
  }

  private static func claim() -> GolfTeachingClaim {
    GolfTeachingClaim(
      id: "claim-1",
      text: "รักษาจังหวะแบ็กสวิงให้สม่ำเสมอ",
      sourceChunkID: "chunk-1",
      startSeconds: 10,
      clubFamilies: ["iron"],
      cameraViews: ["downTheLine"],
      topics: ["tempo"],
      limitations: []
    )
  }

  private static func validGrounding(
    supportedClaimIDs: [String] = []
  ) -> [String: Any] {
    [
      "visiblePeople": 1,
      "swingPhase": "top",
      "clubVisible": true,
      "onScreenGuides": ["เส้นแนวไหล่"],
      "description": "เห็นนักกอล์ฟหนึ่งคนอยู่ช่วงบนสุดของแบ็กสวิง",
      "supportedClaimIDs": supportedClaimIDs,
      "contradictedClaimIDs": [],
      "confidence": 0.82,
      "limitations": ["เฟรมเดี่ยวไม่ยืนยันลำดับการเคลื่อนไหว"],
    ]
  }

  private static func openAIResponse(grounding: [String: Any]) throws -> Data {
    let groundingData = try JSONSerialization.data(withJSONObject: grounding)
    let content = try XCTUnwrap(String(data: groundingData, encoding: .utf8))
    return try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["role": "assistant", "content": content]]]
    ])
  }

  private static func response(
    url: URL,
    statusCode: Int = 200,
    headers: [String: String] = ["Content-Type": "application/json"]
  ) throws -> HTTPURLResponse {
    try XCTUnwrap(
      HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
    )
  }

  private static func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockVLMURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func bodyData(for request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else {
        throw try XCTUnwrap(stream.streamError)
      }
      if count == 0 { break }
      body.append(buffer, count: count)
    }
    return body
  }
}

private func assertThrowsVLMError<T>(
  _ expected: GX10VLMError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("ควร throw \(expected)", file: file, line: line)
  } catch let error as GX10VLMError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("ได้ error ผิดชนิด: \(error)", file: file, line: line)
  }
}

private final class MockVLMURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try XCTUnwrap(Self.handler)
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
