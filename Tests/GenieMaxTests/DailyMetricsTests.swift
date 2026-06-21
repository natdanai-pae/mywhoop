import Testing
import Foundation
@testable import GenieMax

@Test func dailyMetricsCTLATLTSBAndACWR() {
  var h = DailyHistory()
  // long constant load 10 → CTL & ATL both converge to 10 (CTL τ=42 needs ~6 months), TSB→0, ACWR→1
  let cap = DailyHistory().cap   // history caps at 400 days
  for i in 1...300 { h.upsert(DailyRecord(date: String(format: "d%05d", i), dayStrain: 10)) }
  #expect(h.days.count <= cap)
  let m = DailyMetricsEngine.compute(h, state: PersistedState())
  #expect(m.ctl != nil && abs(m.ctl! - 10) < 0.3)
  #expect(m.atl != nil && abs(m.atl! - 10) < 0.1)
  #expect(m.tsb != nil && abs(m.tsb!) < 0.3)
  #expect(m.acwr != nil && abs(m.acwr! - 1) < 0.01)
  #expect(abs(m.tsbNorm - 50) < 3)
}

@Test func dailyMetricsEmptyHistoryIsNeutral() {
  let m = DailyMetricsEngine.compute(DailyHistory(), state: PersistedState())
  #expect(m.ctl == nil && m.tsb == nil && m.acwr == nil)
  #expect(m.tsbNorm == 50 && m.alerts.isEmpty)
}

@Test func dailyMetricsIllnessAlertFiresOnTwoSignalRise() {
  var s = PersistedState()
  for v in [50.0, 52, 54, 51, 53, 52, 50, 54] { s.rhrBaseline.update(v) }            // mean ~52
  for v in [33.9, 34.0, 34.1, 33.95, 34.05, 34.0, 33.9, 34.1] { s.tempBaseline.update(v) }
  for v in [50.0, 55, 48, 52, 50, 53, 49, 51] { s.hrvBaseline.update(log(v)) }
  var h = DailyHistory()
  for i in 1...10 { h.upsert(DailyRecord(date: String(format: "2026-05-%02d", i),
    dayStrain: 8, rhr: 52, lnRMSSD: log(50), skinTemp: 34.0, recovery: 60)) }
  h.upsert(DailyRecord(date: "2026-05-11", dayStrain: 8, rhr: 60, lnRMSSD: log(50), skinTemp: 34.5, recovery: 55))
  h.upsert(DailyRecord(date: "2026-05-12", dayStrain: 8, rhr: 61, lnRMSSD: log(50), skinTemp: 34.6, recovery: 55))
  let m = DailyMetricsEngine.compute(h, state: s)
  #expect(m.alerts.contains { $0.id == "illness" })       // RHR-CUSUM↑ AND temp-CUSUM↑
}

@Test func analyticsRecordsAndDeltas() {
  var h = DailyHistory()
  for i in 0..<20 { h.upsert(DailyRecord(date: String(format: "d%02d", i), dayStrain: Double(i % 10),
    rhr: 50 + Double(i % 5), lnRMSSD: log(40 + Double(i)), sleepScore: 70 + Double(i % 10), steps: 5000 + i * 100)) }
  let r = Analytics.records(h)
  #expect(r.maxStrain == 9)
  #expect(r.lowestRHR == 50)
  #expect(r.mostSteps == 6900)
  #expect(!Analytics.weeklyDeltas(h).isEmpty)
}

@Test func sriHighWhenRegularLowWhenIrregular() {
  var reg = DailyHistory()
  for i in 0..<7 { reg.upsert(DailyRecord(date: String(format: "d%02d", i), dayStrain: 8, onsetMin: 1380, wakeMin: 420)) }
  #expect((DailyMetricsEngine.sri(reg) ?? 0) > 90)
  var irr = DailyHistory()
  let on: [Double] = [1380, 60, 1200, 200, 1320, 30, 1100]
  for i in 0..<7 { irr.upsert(DailyRecord(date: String(format: "d%02d", i), dayStrain: 8, onsetMin: on[i], wakeMin: 400 + on[i] / 10)) }
  #expect((DailyMetricsEngine.sri(irr) ?? 100) < 60)
}

@Test func chronicUnderRecoveryAlertFires() {
  var h = DailyHistory()
  for i in 0..<5 { h.upsert(DailyRecord(date: String(format: "d%02d", i), dayStrain: 15,
    rhr: 52, lnRMSSD: log(50), recovery: 40)) }
  let m = DailyMetricsEngine.compute(h, state: PersistedState())
  #expect(m.alerts.contains { $0.id == "under_recovery" })
}

@Test func dailyMetricsNoIllnessOnNormalHistory() {
  var s = PersistedState()
  for v in [50.0, 52, 54, 51, 53, 52, 50, 54] { s.rhrBaseline.update(v) }
  for v in [33.9, 34.0, 34.1, 33.95, 34.05, 34.0, 33.9, 34.1] { s.tempBaseline.update(v) }
  for v in [50.0, 55, 48, 52, 50, 53, 49, 51] { s.hrvBaseline.update(log(v)) }
  var h = DailyHistory()
  for i in 1...12 { h.upsert(DailyRecord(date: String(format: "2026-05-%02d", i),
    dayStrain: 8, rhr: 52, lnRMSSD: log(50), skinTemp: 34.0, recovery: 50)) }
  let m = DailyMetricsEngine.compute(h, state: s)
  #expect(!m.alerts.contains { $0.id == "illness" })
}
