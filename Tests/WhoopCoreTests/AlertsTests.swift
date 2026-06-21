import Testing
@testable import WhoopCore

private func ids(_ a: [Alert]) -> Set<String> { Set(a.map { $0.id }) }

@Test func illnessTwoSignalFires() {
  let a = Alerts.evaluate(AlertSignals(rhrCusumHigh: true, tempCusumHigh: true, recovery: 40))
  #expect(ids(a).contains("illness"))
  #expect(a.first { $0.id == "illness" }?.severity == .watch)     // no resp → watch
}

@Test func illnessEscalatesWithResp() {
  let a = Alerts.evaluate(AlertSignals(rhrCusumHigh: true, tempCusumHigh: true, respHigh: true, recovery: 40))
  #expect(a.first { $0.id == "illness" }?.severity == .warn)       // resp confirms → warn
}

@Test func illnessNeedsBothSignals() {
  let a = Alerts.evaluate(AlertSignals(rhrCusumHigh: true, tempCusumHigh: false))
  #expect(!ids(a).contains("illness"))                              // single signal → no fire
}

@Test func overreachingFiresOnCombo() {
  let a = Alerts.evaluate(AlertSignals(hrvCusumLow: true, tsb: -15, acwr: 1.6, recovery: 30))
  #expect(ids(a).contains("overreaching"))
}

@Test func optimalTrainFiresWhenFreshAndRecovered() {
  let a = Alerts.evaluate(AlertSignals(tsb: 5, recovery: 75))
  #expect(ids(a).contains("optimal_train"))
}

@Test func detrainingAndCleanDay() {
  #expect(ids(Alerts.evaluate(AlertSignals(acwr: 0.6, recovery: 50))).contains("detraining"))
  // a benign mid-range day fires no warn/watch alerts
  let benign = Alerts.evaluate(AlertSignals(tsb: -2, acwr: 1.0, recovery: 55))
  #expect(benign.allSatisfy { $0.severity == .info })
}
