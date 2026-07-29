import Foundation
import XCTest

@testable import GolfTrace

final class YouTubeFrameMCPClientTests: XCTestCase {
  override func tearDown() {
    MockFrameMCPURLProtocol.handler = nil
    super.tearDown()
  }

  func testYouTubeContextInitializesSessionAndReturnsImage() async throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9])
    MockFrameMCPURLProtocol.handler = Self.rpcHandler(
      tools: ["get_video_frame", "get_video_preview"]
    ) { request, name, arguments in
      XCTAssertEqual(name, "get_video_frame")
      XCTAssertEqual(
        arguments["video"] as? String,
        "https://www.youtube.com/watch?v=Do05z9G-ev4"
      )
      XCTAssertEqual(arguments["at"] as? Double, 12.5)
      XCTAssertEqual(arguments["max_width"] as? Double, 640)
      return try Self.toolResponse(
        request: request,
        content: [
          [
            "type": "image",
            "data": jpeg.base64EncodedString(),
            "mimeType": "image/jpeg",
          ]
        ]
      )
    }

    let client = YouTubeFrameMCPClient(session: Self.mockSession())
    let tools = try await client.verify(
      endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint)
    XCTAssertEqual(tools, ["get_video_frame", "get_video_preview"])

    let videoURL = try XCTUnwrap(URL(string: "https://youtu.be/Do05z9G-ev4?si=test"))
    let preparedID = try await client.addVideo(
      url: videoURL,
      endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint
    )
    XCTAssertEqual(preparedID, "Do05z9G-ev4")

    let result = try await client.fetchFrame(
      videoURL: videoURL,
      timestamp: 12.5,
      endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint
    )
    XCTAssertEqual(result.videoID, "Do05z9G-ev4")
    XCTAssertEqual(result.timestamp, 12.5)
    XCTAssertEqual(result.mimeType, "image/jpeg")
    XCTAssertEqual(result.data, jpeg)
    XCTAssertEqual(result.sha256.count, 64)
  }

  func testYouTubeContextFetchesTimestampedTranscriptWithExpectedSchema() async throws {
    MockFrameMCPURLProtocol.handler = Self.rpcHandler(
      tools: ["get_transcript", "get_video_frame"]
    ) { request, name, arguments in
      XCTAssertEqual(name, "get_transcript")
      XCTAssertEqual(
        arguments["video"] as? String,
        "https://www.youtube.com/watch?v=Do05z9G-ev4"
      )
      XCTAssertEqual(arguments["languages"] as? [String], ["th"])
      XCTAssertEqual(arguments["include_timestamps"] as? Bool, true)
      return try Self.toolResponse(
        request: request,
        content: [
          [
            "type": "text",
            "text": "[00:05] ตั้งท่าให้สมดุล\n[00:20] เริ่มหมุนลำตัว\n[00:40] รักษามุมสะโพกตอนลงไม้",
          ]
        ]
      )
    }

    let client = YouTubeFrameMCPClient(session: Self.mockSession())
    let reference = try XCTUnwrap(YouTubeVideoReference.parse("Do05z9G-ev4"))
    let result = try await client.fetchTranscript(
      for: reference,
      endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint,
      language: "th"
    )

    XCTAssertEqual(result.chunks.count, 2)
    XCTAssertEqual(result.chunks[0].startSeconds, 5)
    XCTAssertEqual(result.chunks[0].endSeconds, 20)
    XCTAssertEqual(result.chunks[1].startSeconds, 40)
    XCTAssertEqual(result.chunks[1].endSeconds, 40)
    XCTAssertTrue(result.chunks[1].text.contains("มุมสะโพก"))
    XCTAssertEqual(result.transcriptHash.count, 64)
  }

  func testMcpTubeFallbackUsesTextOnlyIngestAndGetFrameSchema() async throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xDB])
    MockFrameMCPURLProtocol.handler = Self.rpcHandler(
      tools: ["add_video", "get_frame"]
    ) { request, name, arguments in
      switch name {
      case "add_video":
        XCTAssertEqual(arguments["text_only"] as? Bool, true)
        XCTAssertEqual(
          arguments["url"] as? String,
          "https://www.youtube.com/watch?v=Do05z9G-ev4"
        )
        return try Self.toolResponse(
          request: request,
          content: [["type": "text", "text": #"{"video_id":"Do05z9G-ev4"}"#]],
          structuredContent: ["video_id": "Do05z9G-ev4"]
        )
      case "get_frame":
        XCTAssertEqual(arguments["video_id"] as? String, "Do05z9G-ev4")
        XCTAssertEqual(arguments["timestamp"] as? Double, 8)
        return try Self.toolResponse(
          request: request,
          content: [
            [
              "type": "image",
              "data": jpeg.base64EncodedString(),
              "mimeType": "image/jpeg",
            ]
          ]
        )
      default:
        XCTFail("เรียก tool ผิด: \(name)")
        return try Self.toolResponse(request: request, content: [])
      }
    }

    let client = YouTubeFrameMCPClient(session: Self.mockSession())
    let videoURL = try XCTUnwrap(
      URL(string: "https://www.youtube.com/watch?v=Do05z9G-ev4")
    )
    let videoID = try await client.addVideo(
      url: videoURL,
      endpoint: YouTubeFrameMCPProvider.mcpTube.defaultEndpoint,
      provider: .mcpTube
    )
    XCTAssertEqual(videoID, "Do05z9G-ev4")

    let result = try await client.fetchFrame(
      videoID: videoID,
      timestamp: 8,
      endpoint: YouTubeFrameMCPProvider.mcpTube.defaultEndpoint,
      provider: .mcpTube
    )
    XCTAssertEqual(result.data, jpeg)
  }

  func testRejectsImageOverConfiguredLimit() async throws {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    Self.installFrameContent([
      "type": "image",
      "data": jpeg.base64EncodedString(),
      "mimeType": "image/jpeg",
    ])
    let client = YouTubeFrameMCPClient(
      session: Self.mockSession(),
      maximumImageBytes: 3
    )

    await assertThrowsFrameError(.responseTooLarge) {
      try await client.fetchFrame(
        videoID: "Do05z9G-ev4",
        timestamp: 1,
        endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint,
        provider: .youtubeContext
      )
    }
  }

  func testRejectsUnknownMIMEType() async throws {
    Self.installFrameContent([
      "type": "image",
      "data": Data("GIF89a".utf8).base64EncodedString(),
      "mimeType": "image/gif",
    ])
    let client = YouTubeFrameMCPClient(session: Self.mockSession())

    await assertThrowsFrameError(.unsupportedMIMEType("image/gif")) {
      try await client.fetchFrame(
        videoID: "Do05z9G-ev4",
        timestamp: 1,
        endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint,
        provider: .youtubeContext
      )
    }
  }

  func testRejectsTextOnlyToolResult() async throws {
    Self.installFrameContent(["type": "text", "text": "frame unavailable"])
    let client = YouTubeFrameMCPClient(session: Self.mockSession())

    await assertThrowsFrameError(.noImage) {
      try await client.fetchFrame(
        videoID: "Do05z9G-ev4",
        timestamp: 1,
        endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint,
        provider: .youtubeContext
      )
    }
  }

  func testRejectsRemoteMediaURLWithoutFetchingIt() async throws {
    Self.installFrameContent([
      "type": "image",
      "url": "https://cdn.example.test/frame.jpg",
      "data": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(),
      "mimeType": "image/jpeg",
    ])
    let client = YouTubeFrameMCPClient(session: Self.mockSession())

    await assertThrowsFrameError(.remoteMediaNotAllowed) {
      try await client.fetchFrame(
        videoID: "Do05z9G-ev4",
        timestamp: 1,
        endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint,
        provider: .youtubeContext
      )
    }
  }

  func testEndpointAllowsHTTPSAndPrivateHTTPOnly() throws {
    XCTAssertNoThrow(try YouTubeFrameMCPClient.validatedEndpoint("https://mcp.example.test/mcp"))
    XCTAssertNoThrow(try YouTubeFrameMCPClient.validatedEndpoint("http://127.0.0.1:8000/mcp"))
    XCTAssertNoThrow(try YouTubeFrameMCPClient.validatedEndpoint("http://192.168.1.20:8000/mcp"))
    XCTAssertNoThrow(try YouTubeFrameMCPClient.validatedEndpoint("http://100.82.7.23:8000/mcp"))
    XCTAssertThrowsError(
      try YouTubeFrameMCPClient.validatedEndpoint("http://mcp.example.test/mcp")
    ) { error in
      XCTAssertEqual(error as? YouTubeFrameMCPError, .insecureEndpoint)
    }
    XCTAssertThrowsError(
      try YouTubeFrameMCPClient.validatedEndpoint("http://fc-public.example.test/mcp")
    ) { error in
      XCTAssertEqual(error as? YouTubeFrameMCPError, .insecureEndpoint)
    }
    XCTAssertThrowsError(
      try YouTubeFrameMCPClient.validatedEndpoint("http://010.0.0.1:8000/mcp")
    ) { error in
      XCTAssertEqual(error as? YouTubeFrameMCPError, .insecureEndpoint)
    }
    XCTAssertThrowsError(
      try YouTubeFrameMCPClient.validatedEndpoint("https://user:pass@mcp.example.test/mcp")
    ) { error in
      XCTAssertEqual(error as? YouTubeFrameMCPError, .invalidEndpoint)
    }
  }

  func testSurfacesMCPRPCError() async throws {
    MockFrameMCPURLProtocol.handler = Self.rpcHandler(tools: ["get_video_frame"]) {
      request, _, _ in
      let object = try Self.requestObject(request)
      return [
        "jsonrpc": "2.0",
        "id": object["id"] as Any,
        "error": ["code": -32_603, "message": "ffmpeg could not capture frame"],
      ]
    }
    let client = YouTubeFrameMCPClient(session: Self.mockSession())

    await assertThrowsFrameError(.server("ffmpeg could not capture frame")) {
      try await client.fetchFrame(
        videoID: "Do05z9G-ev4",
        timestamp: 1,
        endpoint: YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint,
        provider: .youtubeContext
      )
    }
  }

  func testLiveYouTubeContextCanaryWhenConfigured() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["GOLFTRACE_LIVE_MCP_URL"],
      !endpoint.isEmpty
    else {
      throw XCTSkip("ตั้ง GOLFTRACE_LIVE_MCP_URL เมื่อต้องการทดสอบ MCP จริง")
    }

    let client = YouTubeFrameMCPClient()
    let tools = try await client.verify(endpoint: endpoint)
    XCTAssertTrue(tools.contains("get_transcript"))
    XCTAssertTrue(tools.contains("get_video_frame"))

    let reference = try XCTUnwrap(YouTubeVideoReference.parse("Do05z9G-ev4"))
    let transcript = try await client.fetchTranscript(
      for: reference,
      endpoint: endpoint,
      language: "en"
    )
    XCTAssertGreaterThan(transcript.characterCount, 5_000)
    XCTAssertFalse(transcript.chunks.isEmpty)

    var frame: YouTubeFrameMCPResult?
    var lastFrameError: Error?
    for timestamp in [15.0, 30.0, 45.0] {
      do {
        frame = try await client.fetchFrame(
          videoURL: reference.canonicalURL,
          timestamp: timestamp,
          endpoint: endpoint
        )
        break
      } catch {
        lastFrameError = error
      }
    }
    guard let frame else {
      let frameErrorText = lastFrameError?.localizedDescription ?? "ไม่ทราบสาเหตุ"
      XCTFail("MCP จริงอ่านเฟรมสำรองทั้ง 3 เวลาไม่สำเร็จ: \(frameErrorText)")
      return
    }
    XCTAssertEqual(frame.mimeType, "image/jpeg")
    XCTAssertGreaterThan(frame.data.count, 10_000)

    let observation = try await ReferenceFramePoseAnalyzer().analyze(
      frameData: frame.data,
      mimeType: frame.mimeType,
      timestampSeconds: frame.timestamp,
      relativeImagePath: "canary/\(frame.sha256).jpg",
      linkedClaimIDs: ["canary-claim"],
      sha256: frame.sha256
    )
    XCTAssertGreaterThan(observation.pixelWidth, 0)
    XCTAssertGreaterThan(observation.pixelHeight, 0)
    XCTAssertEqual(observation.recognizedText == nil, false)
  }

  private static func installFrameContent(_ item: [String: Any]) {
    MockFrameMCPURLProtocol.handler = rpcHandler(tools: ["get_video_frame"]) {
      request, name, _ in
      XCTAssertEqual(name, "get_video_frame")
      return try toolResponse(request: request, content: [item])
    }
  }

  private static func rpcHandler(
    tools: [String],
    toolCall:
      @escaping (
        _ request: URLRequest,
        _ name: String,
        _ arguments: [String: Any]
      ) throws -> [String: Any]
  ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
    { request in
      let object = try requestObject(request)
      let method = try XCTUnwrap(object["method"] as? String)

      switch method {
      case "initialize":
        let response = try httpResponse(
          for: request,
          statusCode: 200,
          headers: [
            "Content-Type": "application/json",
            "Mcp-Session-Id": "golftrace-test-session",
          ]
        )
        let json: [String: Any] = [
          "jsonrpc": "2.0",
          "id": object["id"] as Any,
          "result": [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "serverInfo": ["name": "frame-test", "version": "1.0"],
          ],
        ]
        return (response, try JSONSerialization.data(withJSONObject: json))

      case "notifications/initialized":
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Mcp-Session-Id"),
          "golftrace-test-session"
        )
        return (try httpResponse(for: request, statusCode: 202), Data())

      case "tools/list":
        try assertSessionHeaders(request)
        let json: [String: Any] = [
          "jsonrpc": "2.0",
          "id": object["id"] as Any,
          "result": ["tools": tools.map { ["name": $0] }],
        ]
        return try response(for: request, json: json)

      case "tools/call":
        try assertSessionHeaders(request)
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let name = try XCTUnwrap(params["name"] as? String)
        let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
        return try response(for: request, json: toolCall(request, name, arguments))

      default:
        throw NSError(
          domain: "YouTubeFrameMCPClientTests",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Unexpected method \(method)"]
        )
      }
    }
  }

  private static func toolResponse(
    request: URLRequest,
    content: [[String: Any]],
    structuredContent: [String: Any]? = nil
  ) throws -> [String: Any] {
    let object = try requestObject(request)
    var result: [String: Any] = ["content": content, "isError": false]
    if let structuredContent { result["structuredContent"] = structuredContent }
    return [
      "jsonrpc": "2.0",
      "id": object["id"] as Any,
      "result": result,
    ]
  }

  private static func requestObject(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
      data = body
    } else {
      let stream = try XCTUnwrap(request.httpBodyStream)
      stream.open()
      defer { stream.close() }
      var collected = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        collected.append(buffer, count: count)
      }
      data = collected
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private static func assertSessionHeaders(_ request: URLRequest) throws {
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Mcp-Session-Id"),
      "golftrace-test-session"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "MCP-Protocol-Version"),
      "2025-06-18"
    )
  }

  private static func mockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockFrameMCPURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private static func response(
    for request: URLRequest,
    json: [String: Any]
  ) throws -> (HTTPURLResponse, Data) {
    (
      try httpResponse(
        for: request,
        statusCode: 200,
        headers: ["Content-Type": "application/json"]
      ),
      try JSONSerialization.data(withJSONObject: json)
    )
  }

  private static func httpResponse(
    for request: URLRequest,
    statusCode: Int,
    headers: [String: String]? = nil
  ) throws -> HTTPURLResponse {
    try XCTUnwrap(
      HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
      )
    )
  }
}

private func assertThrowsFrameError<T>(
  _ expected: YouTubeFrameMCPError,
  operation: () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("ควร throw \(expected)", file: file, line: line)
  } catch let error as YouTubeFrameMCPError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("ได้ error ผิดชนิด: \(error)", file: file, line: line)
  }
}

private final class MockFrameMCPURLProtocol: URLProtocol, @unchecked Sendable {
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
