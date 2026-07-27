import CryptoKit
import Foundation

struct YouTubeTranscriptMCPResult: Equatable, Sendable {
  let providerName: String
  let transcriptHash: String
  let characterCount: Int
  let chunks: [YouTubeTranscriptChunk]
}

enum YouTubeTranscriptMCPError: LocalizedError, Equatable {
  case invalidEndpoint
  case insecureEndpoint
  case invalidResponse
  case responseTooLarge
  case noTranscript
  case serviceBusy
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint: return "ที่อยู่ MCP ไม่ถูกต้อง"
    case .insecureEndpoint: return "MCP ต้องใช้ HTTPS หรือเป็นเครื่องภายในที่ไว้ใจได้"
    case .invalidResponse: return "MCP ส่งข้อมูลกลับมาในรูปแบบที่อ่านไม่ได้"
    case .responseTooLarge: return "คำถอดเสียงยาวเกินขนาดที่แอปรับได้"
    case .noTranscript: return "ไม่มีคำถอดเสียง — ระบบจะไม่ดาวน์โหลดเสียงแทน"
    case .serviceBusy: return "บริการคำถอดเสียงไม่ว่าง ลองใหม่อีกครั้ง"
    case .server(let message): return message
    }
  }
}

struct YouTubeFrameMCPResult: Equatable, Sendable {
  let videoID: String
  let timestamp: Double
  let mimeType: String
  let data: Data
  let sha256: String
}

enum YouTubeFrameMCPProvider: String, CaseIterable, Codable, Sendable {
  case youtubeContext
  case mcpTube

  var defaultEndpoint: String {
    switch self {
    case .youtubeContext: return "http://127.0.0.1:8765/mcp"
    case .mcpTube: return "http://127.0.0.1:9093/mcp"
    }
  }

  var frameToolName: String {
    switch self {
    case .youtubeContext: return "get_video_frame"
    case .mcpTube: return "get_frame"
    }
  }
}

enum YouTubeFrameMCPError: LocalizedError, Equatable {
  case invalidEndpoint
  case insecureEndpoint
  case invalidVideoURL
  case invalidVideoID
  case invalidTimestamp
  case invalidMaxWidth
  case invalidResponse
  case responseTooLarge
  case noImage
  case unsupportedMIMEType(String)
  case invalidImageData
  case remoteMediaNotAllowed
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "ที่อยู่ MCP ภาพไม่ถูกต้อง"
    case .insecureEndpoint:
      return "MCP ภาพต้องใช้ HTTPS หรือ HTTP ในเครื่อง/เครือข่ายส่วนตัวเท่านั้น"
    case .invalidVideoURL:
      return "ลิงก์วิดีโอ YouTube ไม่ถูกต้อง"
    case .invalidVideoID:
      return "รหัสวิดีโอ YouTube ไม่ถูกต้อง"
    case .invalidTimestamp:
      return "เวลาของเฟรมไม่ถูกต้อง"
    case .invalidMaxWidth:
      return "ความกว้างภาพต้องอยู่ระหว่าง 64 ถึง 1,280 พิกเซล"
    case .invalidResponse:
      return "MCP ภาพส่งข้อมูลกลับมาในรูปแบบที่อ่านไม่ได้"
    case .responseTooLarge:
      return "ภาพจาก MCP มีขนาดเกิน 12 MB"
    case .noImage:
      return "MCP ไม่ได้ส่งภาพกลับมา"
    case .unsupportedMIMEType(let mimeType):
      return "ไม่รองรับชนิดภาพ \(mimeType) — ใช้ได้เฉพาะ JPEG หรือ PNG"
    case .invalidImageData:
      return "ข้อมูลภาพจาก MCP ไม่สมบูรณ์หรือไม่ตรงกับชนิดไฟล์"
    case .remoteMediaNotAllowed:
      return "MCP ต้องส่งข้อมูลภาพโดยตรง ไม่รับลิงก์ไฟล์ภาพภายนอก"
    case .server(let message):
      return message
    }
  }
}

actor YouTubeFrameMCPClient {
  static let defaultEndpoint = YouTubeFrameMCPProvider.youtubeContext.defaultEndpoint
  static let maximumImageBytes = 12 * 1_024 * 1_024

  private static let protocolVersion = "2025-06-18"

  private let session: URLSession
  private let maximumImageBytes: Int
  private var connections: [String: MCPConnection] = [:]

  init(
    session: URLSession? = nil,
    maximumImageBytes: Int = YouTubeFrameMCPClient.maximumImageBytes
  ) {
    precondition(maximumImageBytes > 0)
    self.maximumImageBytes = maximumImageBytes

    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 45
      configuration.timeoutIntervalForResource = 120
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      self.session = URLSession(
        configuration: configuration,
        delegate: SameOriginRedirectDelegate(),
        delegateQueue: nil
      )
    }
  }

  func verify(endpoint rawEndpoint: String) async throws -> [String] {
    let endpoint = try Self.validatedEndpoint(rawEndpoint)
    let result = try await call(
      method: "tools/list",
      params: .object([:]),
      endpoint: endpoint
    )
    guard
      let tools = result["tools"]?.arrayValue,
      !tools.isEmpty
    else {
      throw YouTubeFrameMCPError.invalidResponse
    }

    let names = tools.compactMap { $0["name"]?.stringValue }
    guard names.count == tools.count else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    return names
  }

  func fetchTranscript(
    for reference: YouTubeVideoReference,
    endpoint rawEndpoint: String,
    language: String
  ) async throws -> YouTubeTranscriptMCPResult {
    let endpoint = try Self.validatedEndpoint(rawEndpoint)
    let preferredLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !preferredLanguage.isEmpty, preferredLanguage.count <= 32 else {
      throw YouTubeTranscriptMCPError.invalidResponse
    }

    let result: MCPJSONValue
    do {
      result = try await callTool(
        name: "get_transcript",
        arguments: .object([
          "video": .string(reference.canonicalURL.absoluteString),
          "languages": .array([.string(preferredLanguage)]),
          "include_timestamps": .bool(true),
        ]),
        endpoint: endpoint
      )
    } catch YouTubeFrameMCPError.server(let message) {
      throw Self.transcriptError(from: message)
    }

    guard
      let content = result["content"]?.arrayValue,
      !content.isEmpty,
      content.allSatisfy({ $0["type"]?.stringValue == "text" })
    else {
      throw YouTubeTranscriptMCPError.invalidResponse
    }
    let transcript = content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !transcript.isEmpty else {
      throw YouTubeTranscriptMCPError.noTranscript
    }
    let data = Data(transcript.utf8)
    guard data.count <= 5 * 1_024 * 1_024 else {
      throw YouTubeTranscriptMCPError.responseTooLarge
    }
    let chunks = Self.makeTranscriptChunks(from: transcript, videoID: reference.videoID)
    guard !chunks.isEmpty else {
      throw YouTubeTranscriptMCPError.noTranscript
    }

    return YouTubeTranscriptMCPResult(
      providerName: endpoint.host ?? "youtube-context MCP",
      transcriptHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      characterCount: transcript.count,
      chunks: chunks
    )
  }

  func addVideo(
    url: URL,
    endpoint rawEndpoint: String,
    provider: YouTubeFrameMCPProvider = .youtubeContext
  ) async throws -> String {
    let endpoint = try Self.validatedEndpoint(rawEndpoint)
    let videoURL = try Self.validatedYouTubeURL(url)
    guard let videoID = Self.videoID(from: videoURL) else {
      throw YouTubeFrameMCPError.invalidVideoURL
    }

    // youtube-context ดึงเฟรมจาก URL ได้ทันที จึงไม่ต้อง ingest หรือเก็บสำเนาวิดีโอก่อน
    guard provider == .mcpTube else { return videoID }

    let result = try await callTool(
      name: "add_video",
      arguments: .object([
        "url": .string(videoURL.absoluteString),
        "text_only": .bool(true),
      ]),
      endpoint: endpoint
    )

    let candidates = Self.structuredCandidates(from: result)
    if let message = candidates.compactMap({ Self.firstString(forKey: "error", in: $0) }).first {
      throw YouTubeFrameMCPError.server(Self.safeMessage(message))
    }
    guard
      let ingestedVideoID = candidates.compactMap({
        Self.firstString(forKey: "video_id", in: $0)
      }).first,
      Self.isValidVideoID(ingestedVideoID)
    else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    return ingestedVideoID
  }

  func fetchFrame(
    videoURL: URL,
    timestamp: Double,
    endpoint rawEndpoint: String,
    provider: YouTubeFrameMCPProvider = .youtubeContext,
    maxWidth: Int = 640
  ) async throws -> YouTubeFrameMCPResult {
    let validatedURL = try Self.validatedYouTubeURL(videoURL)
    guard let videoID = Self.videoID(from: validatedURL) else {
      throw YouTubeFrameMCPError.invalidVideoURL
    }
    return try await fetchFrame(
      videoID: videoID,
      canonicalURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)")!,
      timestamp: timestamp,
      endpoint: rawEndpoint,
      provider: provider,
      maxWidth: maxWidth
    )
  }

  func fetchFrame(
    videoID: String,
    timestamp: Double,
    endpoint rawEndpoint: String,
    provider: YouTubeFrameMCPProvider = .youtubeContext,
    maxWidth: Int = 640
  ) async throws -> YouTubeFrameMCPResult {
    guard Self.isValidVideoID(videoID) else {
      throw YouTubeFrameMCPError.invalidVideoID
    }
    let canonicalURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    return try await fetchFrame(
      videoID: videoID,
      canonicalURL: canonicalURL,
      timestamp: timestamp,
      endpoint: rawEndpoint,
      provider: provider,
      maxWidth: maxWidth
    )
  }

  private func fetchFrame(
    videoID: String,
    canonicalURL: URL,
    timestamp: Double,
    endpoint rawEndpoint: String,
    provider: YouTubeFrameMCPProvider,
    maxWidth: Int
  ) async throws -> YouTubeFrameMCPResult {
    guard timestamp.isFinite, timestamp >= 0 else {
      throw YouTubeFrameMCPError.invalidTimestamp
    }
    guard (64...1_280).contains(maxWidth) else {
      throw YouTubeFrameMCPError.invalidMaxWidth
    }

    let endpoint = try Self.validatedEndpoint(rawEndpoint)
    let arguments: MCPJSONValue
    switch provider {
    case .youtubeContext:
      arguments = .object([
        "video": .string(canonicalURL.absoluteString),
        "at": .number(timestamp),
        "max_width": .number(Double(maxWidth)),
      ])
    case .mcpTube:
      arguments = .object([
        "video_id": .string(videoID),
        "timestamp": .number(timestamp),
      ])
    }
    let result = try await callTool(
      name: provider.frameToolName,
      arguments: arguments,
      endpoint: endpoint
    )

    guard let content = result["content"]?.arrayValue else {
      throw YouTubeFrameMCPError.noImage
    }
    let imageItems = content.filter { $0["type"]?.stringValue == "image" }
    guard imageItems.count == 1 else {
      throw YouTubeFrameMCPError.noImage
    }

    let item = imageItems[0]
    if Self.containsMediaReference(item) {
      throw YouTubeFrameMCPError.remoteMediaNotAllowed
    }
    guard let rawMIMEType = item["mimeType"]?.stringValue else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    let mimeType = Self.normalizedMIMEType(rawMIMEType)
    guard mimeType == "image/jpeg" || mimeType == "image/png" else {
      throw YouTubeFrameMCPError.unsupportedMIMEType(mimeType)
    }
    guard let encoded = item["data"]?.stringValue, !encoded.isEmpty else {
      throw YouTubeFrameMCPError.invalidImageData
    }

    // ตรวจขนาดก่อนถอด base64 เพื่อไม่ให้สร้าง Data ขนาดใหญ่เกินจำเป็น
    let maximumEncodedBytes = 4 * ((maximumImageBytes + 2) / 3)
    guard encoded.utf8.count <= maximumEncodedBytes else {
      throw YouTubeFrameMCPError.responseTooLarge
    }
    guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
      throw YouTubeFrameMCPError.invalidImageData
    }
    guard data.count <= maximumImageBytes else {
      throw YouTubeFrameMCPError.responseTooLarge
    }
    guard Self.hasExpectedSignature(data, mimeType: mimeType) else {
      throw YouTubeFrameMCPError.invalidImageData
    }

    return YouTubeFrameMCPResult(
      videoID: videoID,
      timestamp: timestamp,
      mimeType: mimeType,
      data: data,
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
  }

  static func validatedEndpoint(_ rawValue: String) throws -> URL {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: trimmed),
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.fragment == nil
    else {
      throw YouTubeFrameMCPError.invalidEndpoint
    }

    if scheme == "https" { return url }
    guard scheme == "http", isTrustedLocalHost(host) else {
      throw YouTubeFrameMCPError.insecureEndpoint
    }
    return url
  }

  private func callTool(
    name: String,
    arguments: MCPJSONValue,
    endpoint: URL
  ) async throws -> MCPJSONValue {
    let result = try await call(
      method: "tools/call",
      params: .object([
        "name": .string(name),
        "arguments": arguments,
      ]),
      endpoint: endpoint
    )

    if result["isError"]?.boolValue == true {
      let message = Self.textContent(from: result).first ?? "MCP เรียก \(name) ไม่สำเร็จ"
      throw YouTubeFrameMCPError.server(Self.safeMessage(message))
    }
    return result
  }

  private func call(
    method: String,
    params: MCPJSONValue,
    endpoint: URL
  ) async throws -> MCPJSONValue {
    let connection = try await connection(for: endpoint)
    let requestID = UUID().uuidString
    let payload = MCPRPCRequest(id: requestID, method: method, params: params)
    let response = try await performRPC(
      payload: try JSONEncoder().encode(payload),
      requestID: requestID,
      endpoint: endpoint,
      connection: connection
    )
    return try Self.checkedResult(response.response)
  }

  private func connection(for endpoint: URL) async throws -> MCPConnection {
    let key = endpoint.absoluteString
    if let connection = connections[key] { return connection }

    let requestID = UUID().uuidString
    let payload = MCPRPCRequest(
      id: requestID,
      method: "initialize",
      params: .object([
        "protocolVersion": .string(Self.protocolVersion),
        "capabilities": .object([:]),
        "clientInfo": .object([
          "name": .string("GolfTrace"),
          "version": .string("1.0"),
        ]),
      ])
    )
    let initialized = try await performRPC(
      payload: try JSONEncoder().encode(payload),
      requestID: requestID,
      endpoint: endpoint,
      connection: nil
    )
    let result = try Self.checkedResult(initialized.response)
    guard let returnedVersion = result["protocolVersion"]?.stringValue, !returnedVersion.isEmpty
    else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    let connection = MCPConnection(
      protocolVersion: returnedVersion,
      sessionID: initialized.sessionID
    )

    try await sendInitializedNotification(endpoint: endpoint, connection: connection)
    connections[key] = connection
    return connection
  }

  private func sendInitializedNotification(
    endpoint: URL,
    connection: MCPConnection
  ) async throws {
    let payload = MCPNotification(method: "notifications/initialized")
    var request = Self.makeRequest(endpoint: endpoint, connection: connection)
    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw Self.httpError(statusCode: http.statusCode, data: data)
    }
  }

  private func performRPC(
    payload: Data,
    requestID: String,
    endpoint: URL,
    connection: MCPConnection?
  ) async throws -> MCPHTTPResult {
    var request = Self.makeRequest(endpoint: endpoint, connection: connection)
    request.httpBody = payload

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw Self.httpError(statusCode: http.statusCode, data: data)
    }

    // base64 ของภาพ 12 MB มีขนาดราว 16 MB และเผื่อ JSON/SSE อีก 2 MB
    let maximumWireBytes = 4 * ((maximumImageBytes + 2) / 3) + 2 * 1_024 * 1_024
    guard data.count <= maximumWireBytes else {
      throw YouTubeFrameMCPError.responseTooLarge
    }
    let rpcResponse = try Self.decodeRPCResponse(data, expectedID: requestID)
    return MCPHTTPResult(
      response: rpcResponse,
      sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id")
    )
  }

  private static func makeRequest(
    endpoint: URL,
    connection: MCPConnection?
  ) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let connection {
      request.setValue(connection.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
      if let sessionID = connection.sessionID {
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
      }
    }
    return request
  }

  private static func checkedResult(_ response: MCPRPCResponse) throws -> MCPJSONValue {
    if let error = response.error {
      throw YouTubeFrameMCPError.server(safeMessage(error.message))
    }
    guard let result = response.result else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    return result
  }

  private static func decodeRPCResponse(
    _ data: Data,
    expectedID: String
  ) throws -> MCPRPCResponse {
    let decoder = JSONDecoder()
    if let response = try? decoder.decode(MCPRPCResponse.self, from: data),
      response.id?.stringValue == expectedID
    {
      return response
    }

    // Streamable HTTP อาจตอบเป็น SSE: แต่ละ event มีบรรทัด `data: {JSON-RPC}`
    guard let body = String(data: data, encoding: .utf8) else {
      throw YouTubeFrameMCPError.invalidResponse
    }
    var eventData: [String] = []

    func decodedEvent() -> MCPRPCResponse? {
      guard !eventData.isEmpty else { return nil }
      let candidate = eventData.joined(separator: "\n")
      guard
        let candidateData = candidate.data(using: .utf8),
        let response = try? decoder.decode(MCPRPCResponse.self, from: candidateData),
        response.id?.stringValue == expectedID
      else {
        return nil
      }
      return response
    }

    for line in body.components(separatedBy: .newlines) {
      if line.isEmpty {
        if let response = decodedEvent() { return response }
        eventData.removeAll(keepingCapacity: true)
      } else if line.hasPrefix("data:") {
        eventData.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
      }
    }
    if let response = decodedEvent() { return response }
    throw YouTubeFrameMCPError.invalidResponse
  }

  private static func structuredCandidates(from result: MCPJSONValue) -> [MCPJSONValue] {
    var candidates: [MCPJSONValue] = []
    if let structured = result["structuredContent"] {
      candidates.append(structured)
    }
    if let structured = result["structured_content"] {
      candidates.append(structured)
    }
    for text in textContent(from: result) {
      guard
        let data = text.data(using: .utf8),
        let value = try? JSONDecoder().decode(MCPJSONValue.self, from: data)
      else {
        continue
      }
      candidates.append(value)
    }
    return candidates
  }

  private static func textContent(from result: MCPJSONValue) -> [String] {
    result["content"]?.arrayValue?.compactMap { item in
      guard item["type"]?.stringValue == "text" else { return nil }
      return item["text"]?.stringValue
    } ?? []
  }

  private static func makeTranscriptChunks(
    from transcript: String,
    videoID: String
  ) -> [YouTubeTranscriptChunk] {
    let lines = transcript.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let maximumCharacters = 1_800
    let maximumTimeSpan: TimeInterval = 15
    var chunks: [YouTubeTranscriptChunk] = []
    var buffer: [String] = []
    var characterCount = 0
    var startSeconds: Double?
    var endSeconds: Double?

    func flush() {
      guard !buffer.isEmpty else { return }
      chunks.append(
        YouTubeTranscriptChunk(
          id: "\(videoID)-chunk-\(chunks.count)",
          startSeconds: startSeconds,
          endSeconds: endSeconds,
          text: buffer.joined(separator: " ")
        )
      )
      buffer.removeAll(keepingCapacity: true)
      characterCount = 0
      startSeconds = nil
      endSeconds = nil
    }

    for line in lines {
      let parsed = parseTimestampedTranscriptLine(line)
      let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let exceedsCharacters = characterCount + text.count > maximumCharacters
      let exceedsTimeSpan: Bool
      if let startSeconds, let seconds = parsed.seconds {
        exceedsTimeSpan = seconds - startSeconds > maximumTimeSpan
      } else {
        exceedsTimeSpan = false
      }
      if exceedsCharacters || exceedsTimeSpan, !buffer.isEmpty { flush() }
      if startSeconds == nil { startSeconds = parsed.seconds }
      if let seconds = parsed.seconds { endSeconds = seconds }
      buffer.append(text)
      characterCount += text.count + 1
    }
    flush()
    return chunks
  }

  private static func parseTimestampedTranscriptLine(_ line: String) -> (
    seconds: Double?, text: String
  ) {
    let pattern = #"^\s*\[?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[.,]\d+)?\]?\s*[-–—:]?\s*(.*)$"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let minuteRange = Range(match.range(at: 2), in: line),
      let secondRange = Range(match.range(at: 3), in: line),
      let textRange = Range(match.range(at: 4), in: line),
      let minutes = Double(line[minuteRange]),
      let seconds = Double(line[secondRange])
    else {
      return (nil, line)
    }
    var total = minutes * 60 + seconds
    if let hourRange = Range(match.range(at: 1), in: line),
      let hours = Double(line[hourRange])
    {
      total += hours * 3_600
    }
    return (total, String(line[textRange]))
  }

  private static func transcriptError(from rawMessage: String) -> YouTubeTranscriptMCPError {
    let message = safeMessage(rawMessage)
    let lower = message.lowercased()
    if lower.contains("no transcript") || lower.contains("transcript") && lower.contains("disabled")
      || lower.contains("caption") && lower.contains("not available")
    {
      return .noTranscript
    }
    if lower.contains("temporarily busy") || lower.contains("rate limit")
      || lower.contains("too many requests")
    {
      return .serviceBusy
    }
    return .server(message)
  }

  private static func firstString(forKey key: String, in value: MCPJSONValue) -> String? {
    switch value {
    case .object(let object):
      if let string = object[key]?.stringValue { return string }
      for child in object.values {
        if let found = firstString(forKey: key, in: child) { return found }
      }
    case .array(let values):
      for child in values {
        if let found = firstString(forKey: key, in: child) { return found }
      }
    case .string, .number, .bool, .null:
      break
    }
    return nil
  }

  private static func containsMediaReference(_ value: MCPJSONValue) -> Bool {
    switch value {
    case .object(let object):
      for (key, child) in object {
        if ["url", "uri", "source"].contains(key.lowercased()) {
          return true
        }
        if containsMediaReference(child) { return true }
      }
    case .array(let values):
      return values.contains(where: containsMediaReference)
    case .string, .number, .bool, .null:
      return false
    }
    return false
  }

  private static func validatedYouTubeURL(_ url: URL) throws -> URL {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
        || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    else {
      throw YouTubeFrameMCPError.invalidVideoURL
    }
    return url
  }

  private static func videoID(from url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host?.lowercased()
    else {
      return nil
    }

    if host == "youtu.be" {
      let candidate = url.pathComponents.dropFirst().first ?? ""
      return isValidVideoID(candidate) ? candidate : nil
    }
    if let candidate = components.queryItems?.first(where: { $0.name == "v" })?.value,
      isValidVideoID(candidate)
    {
      return candidate
    }

    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) else {
      return nil
    }
    return isValidVideoID(parts[1]) ? parts[1] : nil
  }

  private static func isValidVideoID(_ value: String) -> Bool {
    value.count == 11
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
      }
  }

  private static func isTrustedLocalHost(_ rawHost: String) -> Bool {
    let host =
      rawHost
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if host == "localhost" || host.hasSuffix(".local") { return true }
    if host.contains(":") {
      if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
      if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea")
        || host.hasPrefix("feb")
      {
        return true
      }
      return false
    }

    let rawOctets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard rawOctets.count == 4 else { return false }
    let octets = rawOctets.compactMap { raw -> Int? in
      guard let value = Int(raw), String(value) == raw else { return nil }
      return value
    }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }
    if octets[0] == 127 || octets[0] == 10 { return true }
    if octets[0] == 192, octets[1] == 168 { return true }
    if octets[0] == 172, (16...31).contains(octets[1]) { return true }
    // 100.64.0.0/10 รองรับเครือข่ายส่วนตัวแบบ Tailscale/CGNAT ของ GX10
    if octets[0] == 100, (64...127).contains(octets[1]) { return true }
    return false
  }

  private static func normalizedMIMEType(_ rawValue: String) -> String {
    rawValue
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
  }

  private static func hasExpectedSignature(_ data: Data, mimeType: String) -> Bool {
    switch mimeType {
    case "image/jpeg":
      return data.starts(with: [0xFF, 0xD8, 0xFF])
    case "image/png":
      return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    default:
      return false
    }
  }

  private static func safeMessage(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "MCP ทำงานไม่สำเร็จ" : String(trimmed.prefix(300))
  }

  private static func httpError(statusCode: Int, data: Data) -> YouTubeFrameMCPError {
    let rawMessage = String(data: data.prefix(500), encoding: .utf8) ?? ""
    let message = safeMessage(rawMessage)
    return .server("MCP HTTP \(statusCode): \(message)")
  }
}

private struct MCPConnection: Sendable {
  let protocolVersion: String
  let sessionID: String?
}

private struct MCPHTTPResult: Sendable {
  let response: MCPRPCResponse
  let sessionID: String?
}

private struct MCPRPCRequest: Encodable, Sendable {
  let jsonrpc = "2.0"
  let id: String
  let method: String
  let params: MCPJSONValue
}

private struct MCPNotification: Encodable, Sendable {
  let jsonrpc = "2.0"
  let method: String
}

private struct MCPRPCResponse: Decodable, Sendable {
  let id: MCPJSONValue?
  let result: MCPJSONValue?
  let error: MCPRPCError?
}

private struct MCPRPCError: Decodable, Sendable {
  let code: Int
  let message: String
}

private indirect enum MCPJSONValue: Codable, Equatable, Sendable {
  case object([String: MCPJSONValue])
  case array([MCPJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([MCPJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: MCPJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  subscript(key: String) -> MCPJSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  var arrayValue: [MCPJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let source = response.url,
      let destination = request.url,
      source.scheme?.lowercased() == destination.scheme?.lowercased(),
      source.host?.lowercased() == destination.host?.lowercased(),
      source.port == destination.port
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
