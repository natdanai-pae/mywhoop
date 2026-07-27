import Foundation

struct OpenRouterGenerationUsage: Equatable, Sendable {
  let generationID: String?
  let costUSD: Double?
  let promptTokens: Int
  let completionTokens: Int
  let totalTokens: Int

  static let empty = OpenRouterGenerationUsage(
    generationID: nil,
    costUSD: nil,
    promptTokens: 0,
    completionTokens: 0,
    totalTokens: 0
  )
}

struct OpenRouterAccountSnapshot: Equatable, Sendable {
  let limitUSD: Double?
  let limitReset: String?
  let limitRemainingUSD: Double?
  let weeklyUsageUSD: Double
  let isFreeTier: Bool
  let checkedAt: Date

  func hasWeeklyServerLimit(atOrBelow budgetUSD: Double) -> Bool {
    guard limitReset?.lowercased() == "weekly", let limitUSD else { return false }
    return limitUSD <= max(0, budgetUSD)
  }

  func thaiSummary(localBudgetUSD: Double) -> String {
    let usage = weeklyUsageUSD.formatted(.number.precision(.fractionLength(2)))
    if hasWeeklyServerLimit(atOrBelow: localBudgetUSD), let limitUSD {
      let limit = limitUSD.formatted(.number.precision(.fractionLength(2)))
      return "เชื่อมต่อ OpenRouter แล้ว · ใช้สัปดาห์นี้ $\(usage) · key จำกัด $\(limit)/สัปดาห์"
    }
    if isFreeTier {
      return "เชื่อมต่อ OpenRouter แล้ว · บัญชี Free tier · ใช้สัปดาห์นี้ $\(usage)"
    }
    return "เชื่อมต่อ OpenRouter แล้ว · ใช้สัปดาห์นี้ $\(usage) · ใช้งบในแอปช่วยคุมอีกชั้น"
  }
}

enum OpenRouterAccountError: LocalizedError, Equatable {
  case missingAPIKey
  case invalidResponse
  case untrustedResponse
  case responseTooLarge
  case unsupportedResponseType
  case unauthorized
  case paymentRequired
  case rateLimited
  case unavailable
  case server(status: Int)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "ยังไม่มี API key ของ OpenRouter"
    case .invalidResponse:
      return "OpenRouter ส่งข้อมูลบัญชีกลับมาในรูปแบบที่อ่านไม่ได้"
    case .untrustedResponse:
      return "OpenRouter พยายามเปลี่ยนปลายทาง จึงหยุดเพื่อป้องกัน API key"
    case .responseTooLarge:
      return "OpenRouter ส่งข้อมูลบัญชีกลับมาใหญ่เกินขอบเขตที่แอปรับได้"
    case .unsupportedResponseType:
      return "OpenRouter ไม่ได้ส่งข้อมูลบัญชีกลับมาเป็น JSON"
    case .unauthorized:
      return "API key ของ OpenRouter ไม่ถูกต้องหรือถูกยกเลิกแล้ว"
    case .paymentRequired:
      return "บัญชี OpenRouter ไม่มีเครดิตหรือถึงขีดจำกัดแล้ว"
    case .rateLimited:
      return "OpenRouter จำกัดการเรียกชั่วคราว กรุณารอสักครู่"
    case .unavailable:
      return "OpenRouter ยังไม่พร้อมให้บริการ กรุณาลองใหม่ภายหลัง"
    case .server(let status):
      return "OpenRouter ตรวจบัญชีไม่สำเร็จ (รหัส \(status))"
    }
  }
}

protocol OpenRouterAccountChecking: Sendable {
  func fetchAccount(apiKey: String) async throws -> OpenRouterAccountSnapshot
}

final class OpenRouterNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private struct OpenRouterAccountURLSessionTransport: AICoachHTTPTransporting {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    session = URLSession(
      configuration: configuration,
      delegate: OpenRouterNoRedirectDelegate(),
      delegateQueue: nil
    )
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

actor OpenRouterAccountClient: OpenRouterAccountChecking {
  static let endpoint = URL(string: "https://openrouter.ai/api/v1/key")!
  static let maximumResponseBytes = 64 * 1_024

  private let transport: any AICoachHTTPTransporting
  private let now: @Sendable () -> Date

  init() {
    transport = OpenRouterAccountURLSessionTransport()
    now = Date.init
  }

  init(
    transport: any AICoachHTTPTransporting,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.transport = transport
    self.now = now
  }

  func fetchAccount(apiKey: String) async throws -> OpenRouterAccountSnapshot {
    let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedKey.isEmpty else { throw OpenRouterAccountError.missingAPIKey }

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(normalizedKey)", forHTTPHeaderField: "Authorization")
    request.setValue("GolfTrace/1.0", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await transport.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw OpenRouterAccountError.invalidResponse
    }
    guard http.url == Self.endpoint else {
      throw OpenRouterAccountError.untrustedResponse
    }
    guard http.expectedContentLength <= Self.maximumResponseBytes,
      data.count <= Self.maximumResponseBytes
    else {
      throw OpenRouterAccountError.responseTooLarge
    }

    switch http.statusCode {
    case 200..<300:
      break
    case 401, 403:
      throw OpenRouterAccountError.unauthorized
    case 402:
      throw OpenRouterAccountError.paymentRequired
    case 429:
      throw OpenRouterAccountError.rateLimited
    case 500...599:
      throw OpenRouterAccountError.unavailable
    default:
      throw OpenRouterAccountError.server(status: http.statusCode)
    }

    guard Self.isJSONResponse(http) else {
      throw OpenRouterAccountError.unsupportedResponseType
    }
    guard let envelope = try? JSONDecoder().decode(AccountEnvelope.self, from: data),
      envelope.data.usageWeekly >= 0,
      envelope.data.limit.map({ $0 >= 0 }) ?? true,
      envelope.data.limitRemaining.map({ $0 >= 0 }) ?? true
    else {
      throw OpenRouterAccountError.invalidResponse
    }

    return OpenRouterAccountSnapshot(
      limitUSD: envelope.data.limit,
      limitReset: envelope.data.limitReset,
      limitRemainingUSD: envelope.data.limitRemaining,
      weeklyUsageUSD: envelope.data.usageWeekly,
      isFreeTier: envelope.data.isFreeTier,
      checkedAt: now()
    )
  }

  private static func isJSONResponse(_ response: HTTPURLResponse) -> Bool {
    guard let mimeType = response.mimeType?.lowercased() else { return false }
    return mimeType == "application/json" || mimeType.hasSuffix("+json")
  }
}

private struct AccountEnvelope: Decodable {
  let data: AccountData
}

private struct AccountData: Decodable {
  let limit: Double?
  let limitReset: String?
  let limitRemaining: Double?
  let usageWeekly: Double
  let isFreeTier: Bool

  enum CodingKeys: String, CodingKey {
    case limit
    case limitReset = "limit_reset"
    case limitRemaining = "limit_remaining"
    case usageWeekly = "usage_weekly"
    case isFreeTier = "is_free_tier"
  }
}
