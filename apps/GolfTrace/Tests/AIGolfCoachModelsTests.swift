import Foundation
import XCTest

@testable import GolfTrace

final class AIGolfCoachModelsTests: XCTestCase {
  func testFallbackDoesNotInventSwingMetricsWhenNoSwingExists() {
    let context = GolfCoachRequestContext(
      language: "th-TH",
      playerQuestion: "ช่วยดูวงให้หน่อย",
      club: "เหล็ก 7",
      clubFamily: "เหล็กกลาง",
      cameraView: "หลังแนวตี",
      guideline: "วงดีของฉัน",
      coachProfile: "โปรของฉัน",
      coachTeachingStyle: "แก้ทีละหนึ่งเรื่อง",
      swing: nil,
      launch: nil,
      evidence: [],
      citations: []
    )

    let result = GolfCoachAdvice.localFallback(for: context)

    XCTAssertEqual(result.confidence, 1)
    XCTAssertTrue(result.focusTitle.contains("จัดกล้อง"))
    XCTAssertTrue(result.citationIDs.isEmpty)
    XCTAssertTrue(result.limitations.contains(where: { $0.contains("AI") }))
  }

  func testEverySupportedClubHasThaiNameShortNameAndFamily() {
    for club in GolfClub.allCases {
      XCTAssertFalse(club.displayName.isEmpty, club.rawValue)
      XCTAssertFalse(club.shortName.isEmpty, club.rawValue)
      XCTAssertFalse(club.familyName.isEmpty, club.rawValue)
    }
  }

  func testDSV4RequiresHTTPSAndRejectsCredentialsInURL() {
    XCTAssertNotNil(
      AICoachEndpointPolicy.validated(
        "https://ai-local.scmc.digital/v1/chat/completions",
        for: .dsv4
      )
    )
    for endpoint in [
      "http://ai-local.scmc.digital/v1/chat/completions",
      "https://user:password@ai-local.scmc.digital/v1/chat/completions",
      "https://ai-local.scmc.digital/v1/chat/completions#fragment",
    ] {
      XCTAssertNil(AICoachEndpointPolicy.validated(endpoint, for: .dsv4), endpoint)
    }
  }

  func testWhisperAllowsPrivateHTTPButRejectsPublicHTTP() {
    for endpoint in [
      "http://127.0.0.1:8080/inference",
      "http://192.168.1.20:8080/inference",
      "http://100.104.228.23:8080/inference",
      "http://gx10-bda:8080/inference",
      "https://ai-local.scmc.digital/v1/audio/transcriptions",
    ] {
      XCTAssertNotNil(AICoachEndpointPolicy.validated(endpoint, for: .whisper), endpoint)
    }
    XCTAssertNil(
      AICoachEndpointPolicy.validated(
        "http://attacker.example/audio/transcriptions",
        for: .whisper
      )
    )
  }

  func testRedirectPolicyAllowsOnlySameOriginWithoutDowngrade() throws {
    let source = URL(string: "https://ai-local.scmc.digital/v1/chat/completions")!
    let response = HTTPURLResponse(
      url: source,
      statusCode: 302,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!

    var sameOrigin = URLRequest(
      url: URL(string: "https://ai-local.scmc.digital/v1/chat/completions/")!
    )
    sameOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    XCTAssertNotNil(AICoachEndpointPolicy.validatedRedirect(sameOrigin, from: response))

    for destination in [
      URL(string: "https://attacker.example/collect")!,
      URL(string: "http://ai-local.scmc.digital/collect")!,
      URL(string: "https://ai-local.scmc.digital:444/collect")!,
    ] {
      var redirected = URLRequest(url: destination)
      redirected.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
      XCTAssertNil(AICoachEndpointPolicy.validatedRedirect(redirected, from: response))
    }
  }

  func testGatewayKeyIsBoundToExactHTTPSOrigin() {
    let boundOrigin = "https://ai-local.scmc.digital:443"
    XCTAssertTrue(
      AICoachEndpointPolicy.maySendGatewayKey(
        to: URL(string: "https://ai-local.scmc.digital/v1/audio/transcriptions")!,
        boundOrigin: boundOrigin
      )
    )
    XCTAssertFalse(
      AICoachEndpointPolicy.maySendGatewayKey(
        to: URL(string: "https://attacker.example/v1/audio/transcriptions")!,
        boundOrigin: boundOrigin
      )
    )
    XCTAssertFalse(
      AICoachEndpointPolicy.maySendGatewayKey(
        to: URL(string: "http://ai-local.scmc.digital/v1/audio/transcriptions")!,
        boundOrigin: boundOrigin
      )
    )
  }

  @MainActor
  func testDefaultsDoNotImpersonateAnEmployeeAndRecordingIsBounded() {
    let employeeCode = GolfAISettings.defaultEmployeeCode
    let duration = AIGolfProController.maximumQuestionDurationSeconds
    XCTAssertEqual(employeeCode, "")
    XCTAssertEqual(duration, 30)
  }

  func testDSV4OmitsEmptyEmployeeCodeFromPayload() async throws {
    let recorder = AIRequestRecorder()
    let transport = AIStubTransport { request in
      await recorder.record(request)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (Self.validAdviceResponse, response)
    }
    let client = DSV4GolfCoachClient(transport: transport)

    _ = try await client.requestAdvice(
      context: Self.emptyContext,
      configuration: DSV4GolfCoachConfiguration(
        endpoint: URL(string: "https://ai-local.scmc.digital/v1/chat/completions")!,
        model: OpenRouterGolfModelCatalog.primaryCoach.id,
        apiKey: "secret",
        employeeCode: "  "
      )
    )

    let recordedRequest = await recorder.lastRequest()
    let request = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    XCTAssertNil(object["user"])
    let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
    XCTAssertNil(metadata["employee_code"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
  }

  func testOpenRouterRequestFailsClosedToZDRAndRequiredParameters() async throws {
    let recorder = AIRequestRecorder()
    let transport = AIStubTransport { request in
      await recorder.record(request)
      return (
        Self.validAdviceResponse,
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
      )
    }
    let client = DSV4GolfCoachClient(transport: transport)

    _ = try await client.requestAdvice(
      context: Self.emptyContext,
      configuration: DSV4GolfCoachConfiguration(
        endpoint: URL(string: GolfAISettings.defaultCoachEndpoint)!,
        model: OpenRouterGolfModelCatalog.primaryCoach.id,
        apiKey: "secret",
        employeeCode: ""
      )
    )

    let recordedRequest = await recorder.lastRequest()
    let request = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let provider = try XCTUnwrap(object["provider"] as? [String: Bool])
    XCTAssertEqual(provider["zdr"], true)
    XCTAssertEqual(provider["require_parameters"], true)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "GolfTrace")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
  }

  func testOpenRouterUsageAndGenerationIDAreReturnedWithoutEstimation() async throws {
    let response = Data(
      #"{"id":"gen-test-123","choices":[{"message":{"role":"assistant","content":"{\"speech\":\"ลองรักษาจังหวะเดิมครับ\",\"focusTitle\":\"จังหวะ\",\"evidenceSummary\":\"ข้อมูลทดสอบ\",\"drill\":\"ตีสามลูก\",\"confidence\":0.8,\"limitations\":[],\"citationIDs\":[]}"}}],"usage":{"prompt_tokens":321,"completion_tokens":87,"total_tokens":408,"cost":0.001234}}"#
        .utf8
    )
    let client = DSV4GolfCoachClient(
      transport: AIStubTransport { request in
        (
          response,
          HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
        )
      }
    )

    let result = try await client.requestAdvice(
      context: Self.emptyContext,
      configuration: DSV4GolfCoachConfiguration(
        endpoint: URL(string: GolfAISettings.defaultCoachEndpoint)!,
        model: OpenRouterGolfModelCatalog.primaryCoach.id,
        apiKey: "secret",
        employeeCode: ""
      )
    )

    XCTAssertEqual(result.usage.generationID, "gen-test-123")
    XCTAssertEqual(result.usage.costUSD, 0.001234)
    XCTAssertEqual(result.usage.promptTokens, 321)
    XCTAssertEqual(result.usage.completionTokens, 87)
    XCTAssertEqual(result.usage.totalTokens, 408)
  }

  func testUnknownCoachModelIsRejectedBeforeNetworkCall() async {
    let counter = AICallCounter()
    let client = DSV4GolfCoachClient(
      transport: AIStubTransport { request in
        await counter.increment()
        return (
          Data(),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    )

    do {
      _ = try await client.requestAdvice(
        context: Self.emptyContext,
        configuration: DSV4GolfCoachConfiguration(
          endpoint: URL(string: GolfAISettings.defaultCoachEndpoint)!,
          model: "provider/unreviewed-model",
          apiKey: "secret",
          employeeCode: ""
        )
      )
      XCTFail("Expected unsupportedModel")
    } catch DSV4GolfCoachError.unsupportedModel {
      // Expected: no player data is sent to a model outside the reviewed allow-list.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let callCount = await counter.value()
    XCTAssertEqual(callCount, 0)
  }

  func testKnowledgeMappingKeepsOnlyGroundingForItsClaim() throws {
    let matching = Self.makeGrounding(id: "matching", claimID: "claim-1")
    let unrelated = Self.makeGrounding(id: "unrelated", claimID: "claim-2")
    let excerpt = GolfKnowledgeExcerpt(
      id: "claim-1",
      sourceID: UUID(),
      sourceTitle: "Golf lesson",
      sourceURL: "https://www.youtube.com/watch?v=Do05z9G-ev4",
      startSeconds: 12,
      text: "Keep the takeaway connected.",
      limitations: ["Single camera view"],
      visualGroundings: [matching, unrelated]
    )

    let context = GolfCoachRequestContext.make(
      question: "ช่วยดู takeaway",
      settings: .default,
      summary: nil,
      analysis: nil,
      launch: nil,
      knowledgeExcerpts: [excerpt]
    )

    let evidence = try XCTUnwrap(context.knowledge.first)
    XCTAssertEqual(evidence.id, "claim-1")
    XCTAssertEqual(evidence.visualGroundings, [matching])
  }

  func testDSV4PayloadIncludesTypedGroundingWithoutPixelsBase64OrFilePaths() async throws {
    let recorder = AIRequestRecorder()
    let transport = AIStubTransport { request in
      await recorder.record(request)
      return (
        Self.validAdviceResponse,
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
      )
    }
    let client = DSV4GolfCoachClient(transport: transport)
    let frame = ReferenceFrameObservation(
      id: "frame-secret",
      timestampSeconds: 12.5,
      relativeImagePath: "Do05z9G-ev4/private-local-frame.jpg",
      mimeType: "image/jpeg",
      sha256: Self.testFrameHash,
      pixelWidth: 640,
      pixelHeight: 360,
      joints: [],
      metrics: Self.emptyReferenceMetrics,
      recognizedText: ["Takeaway"],
      linkedClaimIDs: ["claim-1"],
      qualityFlags: [],
      poseModelVersion: "Vision test"
    )
    let grounding = Self.makeGrounding(id: "grounding-1", claimID: "claim-1")
    let context = GolfCoachRequestContext.make(
      question: "ช่วยดู takeaway",
      settings: .default,
      summary: nil,
      analysis: nil,
      launch: nil,
      knowledgeExcerpts: [
        GolfKnowledgeExcerpt(
          id: "claim-1",
          sourceID: UUID(),
          sourceTitle: "Golf lesson",
          sourceURL: "https://www.youtube.com/watch?v=Do05z9G-ev4",
          startSeconds: 12,
          text: "Keep the takeaway connected.",
          limitations: ["Single camera view"],
          visualEvidence: [frame],
          visualGroundings: [grounding]
        )
      ]
    )

    _ = try await client.requestAdvice(
      context: context,
      configuration: DSV4GolfCoachConfiguration(
        endpoint: URL(string: "https://ai-local.scmc.digital/v1/chat/completions")!,
        model: OpenRouterGolfModelCatalog.primaryCoach.id,
        apiKey: "secret",
        employeeCode: ""
      )
    )

    let recordedRequest = await recorder.lastRequest()
    let request = try XCTUnwrap(recordedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
    let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
    XCTAssertTrue(systemPrompt.contains("ai_inferred"))
    XCTAssertTrue(systemPrompt.contains("limitations"))

    let userContent = try XCTUnwrap(messages.last?["content"] as? String)
    let contextJSON = try XCTUnwrap(userContent.split(separator: "\n", maxSplits: 1).last)
    let encodedContext = Data(String(contextJSON).utf8)
    let contextObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encodedContext) as? [String: Any]
    )
    let knowledge = try XCTUnwrap(contextObject["knowledge"] as? [[String: Any]])
    let firstKnowledge = try XCTUnwrap(knowledge.first)
    let typedGroundings = try XCTUnwrap(
      firstKnowledge["visualGroundings"] as? [[String: Any]]
    )
    XCTAssertEqual(typedGroundings.first?["id"] as? String, "grounding-1")
    XCTAssertEqual(typedGroundings.first?["model"] as? String, "Qwen/Qwen3-VL-8B-Instruct")
    XCTAssertEqual(typedGroundings.first?["analyzedFrameHashes"] as? [String], [Self.testFrameHash])
    XCTAssertEqual(typedGroundings.first?["limitations"] as? [String], ["Single 2D view"])

    let lowercased = userContent.lowercased()
    XCTAssertFalse(lowercased.contains("data:image"))
    XCTAssertFalse(lowercased.contains("base64"))
    XCTAssertFalse(lowercased.contains("private-local-frame.jpg"))
    XCTAssertFalse(lowercased.contains("relativeimagepath"))
    XCTAssertFalse(lowercased.contains("file://"))
    XCTAssertFalse(lowercased.contains("/users/"))
  }

  func testWhisperRefusesKeyOverPrivateHTTPBeforeNetworkCall() async {
    let counter = AICallCounter()
    let transport = AIStubTransport { request in
      await counter.increment()
      return (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: nil
        )!
      )
    }
    let client = GX10WhisperClient(transport: transport)

    do {
      _ = try await client.transcribe(
        audioURL: URL(fileURLWithPath: "/tmp/does-not-matter.wav"),
        configuration: GX10WhisperConfiguration(
          endpoint: URL(string: "http://100.104.228.23:8080/inference")!,
          model: "whisper-large-v3",
          apiKey: "must-not-leak"
        )
      )
      XCTFail("Expected insecureAPIKeyTransport")
    } catch GX10WhisperError.insecureAPIKeyTransport {
      // Expected: validation happens before reading the file or opening the network.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let callCount = await counter.value()
    XCTAssertEqual(callCount, 0)
  }

  private static let emptyContext = GolfCoachRequestContext(
    language: "th-TH",
    playerQuestion: "ช่วยดูวงให้หน่อย",
    club: "เหล็ก 7",
    clubFamily: "เหล็กกลาง",
    cameraView: "หลังแนวตี",
    guideline: "วงดีของฉัน",
    coachProfile: "โปรของฉัน",
    coachTeachingStyle: "แก้ทีละหนึ่งเรื่อง",
    swing: nil,
    launch: nil,
    evidence: [],
    citations: []
  )

  private static let validAdviceResponse = Data(
    #"{"choices":[{"message":{"role":"assistant","content":"{\"speech\":\"ลองรักษาจังหวะเดิมครับ\",\"focusTitle\":\"จังหวะ\",\"evidenceSummary\":\"ข้อมูลทดสอบ\",\"drill\":\"ตีสามลูก\",\"confidence\":0.8,\"limitations\":[],\"citationIDs\":[]}"}}]}"#
      .utf8
  )

  private static func makeGrounding(id: String, claimID: String) -> VisualClaimGrounding {
    VisualClaimGrounding(
      id: id,
      visiblePeople: 1,
      swingPhase: "takeaway",
      clubVisible: true,
      onScreenGuides: ["shoulder line"],
      description: "The hands and club appear to move together.",
      supportedClaimIDs: [claimID],
      contradictedClaimIDs: [],
      confidence: 0.78,
      limitations: ["Single 2D view"],
      model: "Qwen/Qwen3-VL-8B-Instruct",
      analyzedFrameHashes: [testFrameHash],
      analyzedAt: Date(timeIntervalSince1970: 300)
    )
  }

  private static let emptyReferenceMetrics = ReferencePoseMetrics(
    handCenterX: nil,
    handCenterY: nil,
    headCenterX: nil,
    headCenterY: nil,
    pelvisCenterX: nil,
    pelvisCenterY: nil,
    torsoTilt2DDegrees: nil,
    shoulderSpan2D: nil,
    hipSpan2D: nil,
    leftElbowAngle2DDegrees: nil,
    rightElbowAngle2DDegrees: nil,
    leftKneeAngle2DDegrees: nil,
    rightKneeAngle2DDegrees: nil
  )

  private static let testFrameHash = String(repeating: "a", count: 64)
}

final class DSV4KnowledgeIndexerSecurityTests: XCTestCase {
  private let endpoint = URL(string: GolfAISettings.defaultCoachEndpoint)!

  func testRejectsHTTPDSV4EndpointsBeforeSendingAPIKey() async {
    let counter = AICallCounter()
    let transport = AIStubTransport { request in
      await counter.increment()
      return (
        Data(),
        HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )!
      )
    }
    let indexer = DSV4KnowledgeIndexer(transport: transport)

    for endpoint in [
      URL(string: "http://attacker.example/v1/chat/completions")!,
      URL(string: "http://192.168.1.20:8000/v1/chat/completions")!,
    ] {
      do {
        _ = try await indexer.index(
          source: makeSource(),
          configuration: makeConfiguration(endpoint: endpoint)
        )
        XCTFail("Expected invalidConfiguration for \(endpoint)")
      } catch DSV4KnowledgeIndexError.invalidConfiguration {
        // DSV4 follows the app-wide policy: HTTPS only, including on a private LAN.
      } catch {
        XCTFail("Unexpected error for \(endpoint): \(error)")
      }
    }

    let callCount = await counter.value()
    XCTAssertEqual(callCount, 0)
  }

  func testRejectsMissingAPIKeyBeforeNetworkCall() async {
    let counter = AICallCounter()
    let indexer = DSV4KnowledgeIndexer(
      transport: AIStubTransport { request in
        await counter.increment()
        return (
          Data(),
          HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
          )!
        )
      }
    )

    do {
      _ = try await indexer.index(
        source: makeSource(),
        configuration: makeConfiguration(apiKey: "  ")
      )
      XCTFail("Expected missingAPIKey")
    } catch DSV4KnowledgeIndexError.missingAPIKey {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    let callCount = await counter.value()
    XCTAssertEqual(callCount, 0)
  }

  func testRejectsCrossOriginResponse() async {
    let indexer = DSV4KnowledgeIndexer(
      transport: AIStubTransport { _ in
        let response = HTTPURLResponse(
          url: URL(string: "https://attacker.example/collect")!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (Self.validKnowledgeResponse, response)
      }
    )

    do {
      _ = try await indexer.index(
        source: makeSource(),
        configuration: makeConfiguration()
      )
      XCTFail("Expected untrustedResponse")
    } catch DSV4KnowledgeIndexError.untrustedResponse {
      // The production transport also blocks this redirect before following it.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRejectsOversizedAndNonJSONResponses() async {
    let oversizedIndexer = DSV4KnowledgeIndexer(
      transport: AIStubTransport { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(repeating: 0x20, count: 512 * 1_024 + 1), response)
      }
    )

    do {
      _ = try await oversizedIndexer.index(
        source: makeSource(),
        configuration: makeConfiguration()
      )
      XCTFail("Expected responseTooLarge")
    } catch DSV4KnowledgeIndexError.responseTooLarge {
      // Expected.
    } catch {
      XCTFail("Unexpected oversized-response error: \(error)")
    }

    let htmlIndexer = DSV4KnowledgeIndexer(
      transport: AIStubTransport { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/html"]
        )!
        return (Self.validKnowledgeResponse, response)
      }
    )

    do {
      _ = try await htmlIndexer.index(
        source: makeSource(),
        configuration: makeConfiguration()
      )
      XCTFail("Expected invalidResponse")
    } catch DSV4KnowledgeIndexError.invalidResponse {
      // Expected.
    } catch {
      XCTFail("Unexpected content-type error: \(error)")
    }
  }

  func testValidRequestUsesBearerJSONModeAndOmitsBlankEmployeeCode() async throws {
    let recorder = AIRequestRecorder()
    let indexer = DSV4KnowledgeIndexer(
      transport: AIStubTransport { request in
        await recorder.record(request)
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )!
        return (Self.validKnowledgeResponse, response)
      }
    )

    let claims = try await indexer.index(
      source: makeSource(),
      configuration: makeConfiguration(employeeCode: "  ")
    )

    XCTAssertEqual(claims.count, 1)
    XCTAssertEqual(claims.first?.sourceChunkID, "chunk-1")
    let recordedRequest = await recorder.lastRequest()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.url, endpoint)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let responseFormat = try XCTUnwrap(object["response_format"] as? [String: String])
    XCTAssertEqual(responseFormat["type"], "json_object")
    let provider = try XCTUnwrap(object["provider"] as? [String: Bool])
    XCTAssertEqual(provider["zdr"], true)
    XCTAssertEqual(provider["require_parameters"], true)
    XCTAssertNil(object["user"])
  }

  func testServerErrorNeverReflectsUpstreamTranscriptOrPrompt() async {
    let indexer = DSV4KnowledgeIndexer(
      transport: AIStubTransport { request in
        let data = Data(
          #"{"error":{"message":"sensitive transcript and player prompt"}}"#.utf8
        )
        return (
          data,
          HTTPURLResponse(
            url: request.url!,
            statusCode: 400,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
        )
      }
    )

    do {
      _ = try await indexer.index(source: makeSource(), configuration: makeConfiguration())
      XCTFail("Expected sanitized server error")
    } catch {
      let message = error.localizedDescription.lowercased()
      XCTAssertFalse(message.contains("sensitive transcript"))
      XCTAssertFalse(message.contains("player prompt"))
      XCTAssertTrue(message.contains("หน้าตั้งค่า"))
    }
  }

  private func makeConfiguration(
    endpoint: URL? = nil,
    apiKey: String = "test-secret",
    employeeCode: String = "EMP-TEST"
  ) -> DSV4KnowledgeIndexConfiguration {
    DSV4KnowledgeIndexConfiguration(
      endpoint: endpoint ?? self.endpoint,
      model: OpenRouterGolfModelCatalog.primaryCoach.id,
      apiKey: apiKey,
      employeeCode: employeeCode
    )
  }

  private func makeSource() -> YouTubeKnowledgeSource {
    YouTubeKnowledgeSource(
      id: UUID(uuidString: "36F5A237-E273-4320-BE95-95D28B9CA68E")!,
      videoID: "Do05z9G-ev4",
      canonicalURL: "https://www.youtube.com/watch?v=Do05z9G-ev4",
      title: "Golf lesson",
      language: "th",
      providerName: "youtube-context-mcp",
      status: .transcriptReady,
      importedAt: nil,
      transcriptHash: "hash",
      characterCount: 42,
      chunks: [
        YouTubeTranscriptChunk(
          id: "chunk-1",
          startSeconds: 30,
          endSeconds: 40,
          text: "รักษาจังหวะแบ็กสวิงให้สม่ำเสมอ แล้วค่อยเริ่มดาวน์สวิง"
        )
      ],
      claims: []
    )
  }

  private static let validKnowledgeResponse = Data(
    #"{"choices":[{"message":{"role":"assistant","content":"{\"claims\":[{\"text\":\"รักษาจังหวะแบ็กสวิงให้สม่ำเสมอ\",\"sourceChunkID\":\"chunk-1\",\"clubFamilies\":[\"iron\"],\"cameraViews\":[\"downTheLine\"],\"topics\":[\"tempo\"],\"limitations\":[\"อ้างอิงจากคำพูดช่วงนี้เท่านั้น\"]}]}"}}]}"#
      .utf8
  )
}

private struct AIStubTransport: AICoachHTTPTransporting {
  let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await handler(request)
  }
}

private actor AIRequestRecorder {
  private var request: URLRequest?

  func record(_ request: URLRequest) {
    self.request = request
  }

  func lastRequest() -> URLRequest? { request }
}

private actor AICallCounter {
  private var count = 0

  func increment() { count += 1 }
  func value() -> Int { count }
}
