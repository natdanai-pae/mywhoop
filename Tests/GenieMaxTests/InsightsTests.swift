import Testing
import Foundation
@testable import GenieMax

@Test func strainTargetScalesWithRecovery() {
  #expect(InsightEngine.strainTarget(recovery: 80).lowerBound > InsightEngine.strainTarget(recovery: 30).lowerBound)
  #expect(InsightEngine.strainTarget(recovery: nil) == 8...12)
}

@Test func dailyInsightsCoverKeyAreas() {
  let ins = InsightEngine.daily(recovery: 72, tsb: -2, sleepScore: 84, sleepDebt: 1)
  #expect(ins.count >= 3)
  #expect(ins.contains { $0.kind == .recovery })
  #expect(ins.contains { $0.kind == .strain })
  #expect(ins.allSatisfy { !$0.text.isEmpty })
}

@Test func sleepDebtInsightFires() {
  let ins = InsightEngine.daily(recovery: 50, tsb: 0, sleepScore: 70, sleepDebt: 7)
  #expect(ins.contains { $0.kind == .sleep && $0.text.contains("debt") })
}
