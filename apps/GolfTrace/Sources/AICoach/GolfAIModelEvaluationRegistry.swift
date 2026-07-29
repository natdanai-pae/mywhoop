import Foundation

protocol GolfAIModelEvaluationChecking: Sendable {
  func hasPassed(
    modelID: String,
    role: GolfAIModelRole,
    input: GolfAIInputClass
  ) -> Bool
}

/// Versioned, bundled approvals produced by GolfTrace's offline regression suite.
///
/// The network client consults this registry before sending player-derived data.
/// Keeping the approval separate from model popularity or settings prevents a
/// newly selected provider model from silently becoming a production coach.
struct BundledGolfAIModelEvaluationRegistry: GolfAIModelEvaluationChecking {
  static let structuredCoachSuiteID = "golftrace-structured-coach-v1"
  static let structuredCoachCanaryEnvironmentKey =
    "GOLFTRACE_OPENROUTER_EVALUATION_SUITE_ID"

  /// This literal is deliberately independent from `primaryCoach`.
  /// Changing the catalog selection must not promote a new model.
  private static let evaluatedStructuredCoachModelID =
    "deepseek/deepseek-v4-flash"

  private let approvedStructuredCoachModelIDs: Set<String>

  init(
    approvedStructuredCoachModelIDs: Set<String> = []
  ) {
    self.approvedStructuredCoachModelIDs = approvedStructuredCoachModelIDs
  }

  static func validationCanary(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Self {
    guard
      environment[structuredCoachCanaryEnvironmentKey] == structuredCoachSuiteID
    else {
      return Self()
    }
    return Self(
      approvedStructuredCoachModelIDs: [evaluatedStructuredCoachModelID]
    )
  }

  func hasPassed(
    modelID: String,
    role: GolfAIModelRole,
    input: GolfAIInputClass
  ) -> Bool {
    role == .coach
      && input == .structuredSwingPacket
      && approvedStructuredCoachModelIDs.contains(modelID)
  }
}
