import Foundation

/// The chart-bearing Coach cards whose visibility depends on how much FINALIZED-NIGHT history exists (not on live
/// HR volume). Pulled out of the SwiftUI `CoachView` so the exact "is there enough data to draw the chart?" gate is
/// PURE and unit-testable — the class of bug a user hits as "I have lots of data but the card is empty".
public enum CoachCard: String, CaseIterable, Sendable {
  case recoveryTrend      // 30-day recovery trend (needs ≥3 days WITH a recovery score)
  case trainingBalance    // PMC CTL/ATL + ACWR
  case sleepConsistency   // 7-night sleep-stage bars (needs ≥1 finalized night)
  case strainVsRecovery   // scatter (needs ≥5 days WITH recovery)
  case recoverySpeed      // Recovery-Index trend (needs ≥3 days WITH a recoveryIndexScore)
  case weeklyReport       // this-week-vs-last deltas
  case heatmap            // 35-day recovery consistency calendar (needs ≥5 days WITH recovery)
}

public enum CoachCards {
  /// Does this card have enough data to render its chart (vs. show the empty-state hint)? PURE mirror of the gates
  /// in `CoachView` — the view calls THIS, so the UI and these tests share one source of truth and can't drift.
  /// `acwr` is the only live (non-history) input: today's acute:chronic workload ratio (lets Training balance show
  /// from the gauge alone before a PMC series exists).
  public static func isPopulated(_ card: CoachCard, history h: DailyHistory, acwr: Double?) -> Bool {
    let days = h.days
    switch card {
    case .recoveryTrend:    return Array(days.compactMap { $0.recovery }.suffix(30)).count >= 3
    case .trainingBalance:  return Scores.performanceModel(dailyLoads: days.map { $0.dayStrain }).count > 1 || acwr != nil
    case .sleepConsistency: return days.suffix(7).contains { (($0.deep ?? 0) + ($0.rem ?? 0) + ($0.light ?? 0)) > 0 }
    case .strainVsRecovery: return days.filter { $0.recovery != nil }.count >= 5
    case .recoverySpeed:    return Array(days.compactMap { $0.recoveryIndexScore }.suffix(30)).count >= 3
    case .weeklyReport:     return !Analytics.weeklyDeltas(h).isEmpty
    case .heatmap:          return days.compactMap { $0.recovery }.count >= 5
    }
  }

  /// The set of cards that would render a chart for this history — handy for "how complete is the Coach page?" checks.
  public static func populated(history h: DailyHistory, acwr: Double?) -> Set<CoachCard> {
    Set(CoachCard.allCases.filter { isPopulated($0, history: h, acwr: acwr) })
  }
}
