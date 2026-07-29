import Foundation

struct GX10WhisperConfiguration: Sendable {
  let endpoint: URL
  let model: String
  let apiKey: String?
  let language: String
  let requestTimeout: TimeInterval

  init(
    endpoint: URL,
    model: String,
    apiKey: String?,
    language: String = "th",
    requestTimeout: TimeInterval = 45
  ) {
    self.endpoint = endpoint
    self.model = model
    self.apiKey = apiKey
    self.language = language
    self.requestTimeout = max(5, requestTimeout)
  }
}

struct GX10WhisperTranscript: Equatable, Sendable {
  let text: String
  let language: String?
  let durationSeconds: Double?
}

enum GX10WhisperError: LocalizedError {
  case invalidConfiguration
  case audioFileMissing
  case audioFileTooLarge
  case insecureAPIKeyTransport
  case invalidResponse
  case untrustedResponse
  case server(status: Int, message: String)
  case emptyTranscript

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "ที่อยู่ Whisper ไม่ปลอดภัยหรือไม่ถูกต้อง"
    case .audioFileMissing:
      return "ไม่พบไฟล์เสียงที่จะส่งไป Whisper"
    case .audioFileTooLarge:
      return "ไฟล์เสียงยาวหรือใหญ่เกินไป กรุณาถามใหม่ให้สั้นลง"
    case .insecureAPIKeyTransport:
      return "ไม่ส่ง API key ผ่าน Whisper แบบ HTTP กรุณาใช้ HTTPS หรือปล่อยช่อง key ว่าง"
    case .invalidResponse:
      return "Whisper บน GX10 ตอบกลับมาในรูปแบบที่อ่านไม่ได้"
    case .untrustedResponse:
      return "Whisper ตอบกลับมาจากที่อยู่อื่น จึงหยุดเพื่อป้องกันข้อมูลรั่วไหล"
    case .server(let status, let message):
      return "Whisper ตอบรหัส \(status): \(message)"
    case .emptyTranscript:
      return "Whisper ยังไม่ได้ยินคำพูดที่ชัดเจน กรุณาลองอีกครั้ง"
    }
  }
}

actor GX10WhisperClient {
  private let transport: any AICoachHTTPTransporting
  private let maximumAudioBytes = 25 * 1_024 * 1_024

  init(session: URLSession? = nil) {
    transport =
      session.map(AICoachURLSessionTransport.init(session:))
      ?? AICoachURLSessionTransport()
  }

  init(transport: any AICoachHTTPTransporting) {
    self.transport = transport
  }

  func transcribe(
    audioURL: URL,
    configuration: GX10WhisperConfiguration
  ) async throws -> GX10WhisperTranscript {
    guard AICoachEndpointPolicy.isAllowed(configuration.endpoint, for: .whisper) else {
      throw GX10WhisperError.invalidConfiguration
    }
    let normalizedAPIKey = configuration.apiKey?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if let normalizedAPIKey, !normalizedAPIKey.isEmpty,
      configuration.endpoint.scheme?.lowercased() != "https"
    {
      throw GX10WhisperError.insecureAPIKeyTransport
    }
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw GX10WhisperError.audioFileMissing
    }
    let audio = try Data(contentsOf: audioURL, options: [.mappedIfSafe])
    guard audio.count <= maximumAudioBytes else {
      throw GX10WhisperError.audioFileTooLarge
    }

    let boundary = "GolfTrace-\(UUID().uuidString)"
    var body = Data()
    body.appendMultipartField(name: "language", value: configuration.language, boundary: boundary)
    body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)

    let usesWhisperCPP = configuration.endpoint.path.hasSuffix("/inference")
    if usesWhisperCPP {
      body.appendMultipartField(
        name: "prompt",
        value: "บทสนทนาระหว่างนักกอล์ฟกับ AI Golf Pro เรื่องวงสวิงและข้อมูล Rapsodo",
        boundary: boundary
      )
    } else {
      body.appendMultipartField(name: "model", value: configuration.model, boundary: boundary)
    }
    body.appendMultipartFile(
      name: "file",
      filename: audioURL.lastPathComponent,
      mimeType: Self.mimeType(for: audioURL),
      data: audio,
      boundary: boundary
    )
    body.append(Data("--\(boundary)--\r\n".utf8))

    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = configuration.requestTimeout
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("GolfTrace/1.0", forHTTPHeaderField: "User-Agent")
    if let apiKey = normalizedAPIKey, !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = body

    let (data, response) = try await transport.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw GX10WhisperError.invalidResponse
    }
    guard AICoachEndpointPolicy.isSameOrigin(configuration.endpoint, http.url) else {
      throw GX10WhisperError.untrustedResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw GX10WhisperError.server(
        status: http.statusCode,
        message: Self.safeServerMessage(data)
      )
    }

    if let result = try? JSONDecoder().decode(WhisperResponse.self, from: data) {
      return try Self.validated(
        text: result.text,
        language: result.language,
        duration: result.duration
      )
    }
    if let rawText = String(data: data, encoding: .utf8) {
      return try Self.validated(text: rawText, language: nil, duration: nil)
    }
    throw GX10WhisperError.invalidResponse
  }

  private static func validated(
    text: String,
    language: String?,
    duration: Double?
  ) throws -> GX10WhisperTranscript {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw GX10WhisperError.emptyTranscript }
    return GX10WhisperTranscript(
      text: normalized,
      language: language,
      durationSeconds: duration
    )
  }

  private static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "wav": return "audio/wav"
    case "m4a": return "audio/mp4"
    case "mp3": return "audio/mpeg"
    default: return "application/octet-stream"
    }
  }

  private static func safeServerMessage(_ data: Data) -> String {
    if let error = try? JSONDecoder().decode(WhisperErrorEnvelope.self, from: data) {
      return String(error.error.message.prefix(240))
    }
    return "ตรวจสอบ endpoint, API key และสถานะ Whisper บน GX10"
  }
}

private struct WhisperResponse: Decodable {
  let text: String
  let language: String?
  let duration: Double?
}

private struct WhisperErrorEnvelope: Decodable {
  struct ErrorBody: Decodable {
    let message: String
  }

  let error: ErrorBody
}

extension Data {
  fileprivate mutating func appendMultipartField(name: String, value: String, boundary: String) {
    append(Data("--\(boundary)\r\n".utf8))
    append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
    append(Data(value.utf8))
    append(Data("\r\n".utf8))
  }

  fileprivate mutating func appendMultipartFile(
    name: String,
    filename: String,
    mimeType: String,
    data: Data,
    boundary: String
  ) {
    append(Data("--\(boundary)\r\n".utf8))
    append(
      Data(
        "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
      )
    )
    append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
    append(data)
    append(Data("\r\n".utf8))
  }
}
