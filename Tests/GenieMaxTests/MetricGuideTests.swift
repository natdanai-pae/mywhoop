import Testing
import Foundation
@testable import GenieMax

@Test func everyMetricKindHasAGuide() {
  // keys mirror MetricKind case names used by the UI ("\(metric)")
  let keys = ["hr", "rhr", "hrv", "sdnn", "stress", "resp", "temp", "vo2",
              "ctl", "atl", "tsb", "strain", "steps", "kcal", "recovery", "weight"]
  for k in keys { #expect(MetricGuides.guide(k) != nil, "missing guide for \(k)") }
}

@Test func featureGuidesExist() {
  for k in ["readiness", "sleep", "sri", "sleepDebt", "zones", "pmc", "scatter", "journal", "workout"] {
    #expect(MetricGuides.guide(k) != nil, "missing guide for \(k)")
  }
}

@Test func guideFieldsArePopulated() {
  let g = MetricGuides.guide("hrv")!
  #expect(!g.purpose.isEmpty && !g.benefit.isEmpty && !g.compare.isEmpty)
  #expect(MetricGuides.guide("does_not_exist") == nil)
}
