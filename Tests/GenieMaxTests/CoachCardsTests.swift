import Testing
import Foundation
@testable import GenieMax

/// The Coach page's chart cards gate on FINALIZED-NIGHT history, not live HR volume. These pin the exact gates so
/// the "I have lots of data but the card is empty" bug class is caught without a device.
struct CoachCardsTests {
  func hist(_ recs: [DailyRecord]) -> DailyHistory { var h = DailyHistory(); recs.forEach { h.upsert($0) }; return h }
  func day(_ d: Int, recovery: Double? = nil, ridx: Int? = nil, strain: Double = 0, stages: Bool = false) -> DailyRecord {
    DailyRecord(date: String(format: "2026-06-%02d", d), dayStrain: strain, recovery: recovery,
                deep: stages ? 60 : nil, rem: stages ? 30 : nil, light: stages ? 120 : nil, recoveryIndexScore: ridx)
  }

  @Test func emptyHistoryShowsNothing() {
    let p = CoachCards.populated(history: hist([]), acwr: nil)
    #expect(p.isEmpty)
  }

  // ⭐ Regression for the real device case (s#7 p14): 8 days, strain everywhere + sleep stages + 6 HRV nights, but
  // recovery on only 2 days (baseline warm-up) and recoveryIndexScore on 0 (the two bugs). Only the cards that DON'T
  // need recovery should show.
  @Test func realWarmupCaseOnlyShowsStageAndStrainCards() {
    let recs = (1...8).map { d in
      day(d, recovery: d >= 7 ? 60 : nil,      // recovery only on the last 2 days
          ridx: nil,                            // Recovery Index never computed (the bug)
          strain: 8, stages: true)              // strain + sleep stages every day
    }
    let p = CoachCards.populated(history: hist(recs), acwr: 1.0)
    #expect(p.contains(.sleepConsistency))      // has stages → shows
    #expect(p.contains(.trainingBalance))       // 8 strain days → shows
    #expect(!p.contains(.recoveryTrend))        // needs ≥3 recovery, has 2
    #expect(!p.contains(.strainVsRecovery))     // needs ≥5 recovery, has 2
    #expect(!p.contains(.heatmap))              // needs ≥5 recovery, has 2
    #expect(!p.contains(.recoverySpeed))        // needs ≥3 recoveryIndexScore, has 0
  }

  @Test func recoveryCardsAppearOnceEnoughNightsHaveRecovery() {
    let recs = (1...6).map { day($0, recovery: 55, ridx: 70, strain: 6, stages: true) }   // 6 full days
    let p = CoachCards.populated(history: hist(recs), acwr: nil)
    #expect(p.contains(.recoveryTrend))         // 6 ≥ 3
    #expect(p.contains(.strainVsRecovery))      // 6 ≥ 5
    #expect(p.contains(.heatmap))               // 6 ≥ 5
    #expect(p.contains(.recoverySpeed))         // 6 ≥ 3 recoveryIndexScore — the card the p14 fix unblocks
    #expect(p.contains(.sleepConsistency))
    #expect(p.contains(.trainingBalance))
  }

  @Test func boundaryThreeRecoveryDays() {
    let recs = (1...3).map { day($0, recovery: 55, strain: 5) }   // exactly 3 recovery days, no ridx
    let p = CoachCards.populated(history: hist(recs), acwr: nil)
    #expect(p.contains(.recoveryTrend))         // 3 ≥ 3 → on
    #expect(!p.contains(.heatmap))              // 3 < 5 → off
    #expect(!p.contains(.strainVsRecovery))     // 3 < 5 → off
    #expect(!p.contains(.recoverySpeed))        // 0 recoveryIndexScore → off
  }

  @Test func acwrAlonePopulatesTrainingBalanceWithoutHistory() {
    #expect(CoachCards.isPopulated(.trainingBalance, history: hist([day(1, strain: 3)]), acwr: 1.1))
    #expect(!CoachCards.isPopulated(.trainingBalance, history: hist([day(1, strain: 3)]), acwr: nil))  // 1 day, no acwr
  }

  // Sleep consistency only looks at the last 7 days — stages older than that don't count.
  @Test func sleepConsistencyOnlyCountsLastSevenDays() {
    var recs = [day(1, stages: true)]                              // stages on the OLDEST day only
    recs += (2...8).map { day($0, strain: 5) }                     // 7 newer days with no stages
    #expect(!CoachCards.isPopulated(.sleepConsistency, history: hist(recs), acwr: nil))
    #expect(CoachCards.isPopulated(.sleepConsistency, history: hist([day(8, stages: true)]), acwr: nil))
  }
}
