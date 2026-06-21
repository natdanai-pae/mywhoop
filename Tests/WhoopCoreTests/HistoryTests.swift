import Testing
import Foundation
@testable import WhoopCore

@Test func historyUpsertDedupesSortsAndCaps() {
  var h = DailyHistory(cap: 3)
  h.upsert(DailyRecord(date: "2026-06-03", dayStrain: 8))
  h.upsert(DailyRecord(date: "2026-06-01", dayStrain: 5))
  h.upsert(DailyRecord(date: "2026-06-02", dayStrain: 6))
  #expect(h.days.map { $0.date } == ["2026-06-01", "2026-06-02", "2026-06-03"])   // sorted
  // upsert same date → replace, not duplicate
  h.upsert(DailyRecord(date: "2026-06-02", dayStrain: 99))
  #expect(h.days.count == 3)
  #expect(h.days[1].dayStrain == 99)
  // exceeding cap drops the oldest
  h.upsert(DailyRecord(date: "2026-06-04", dayStrain: 10))
  #expect(h.days.map { $0.date } == ["2026-06-02", "2026-06-03", "2026-06-04"])
  #expect(h.last?.date == "2026-06-04")
}

@Test func historySeriesSkipsNils() {
  var h = DailyHistory()
  h.upsert(DailyRecord(date: "2026-06-01", dayStrain: 5, rhr: 52))
  h.upsert(DailyRecord(date: "2026-06-02", dayStrain: 7, rhr: nil))
  h.upsert(DailyRecord(date: "2026-06-03", dayStrain: 9, rhr: 54))
  #expect(h.series(\.dayStrain) == [5, 7, 9])      // non-optional keypath
  #expect(h.series(\.rhr) == [52, 54])             // optional keypath skips nil
}

@Test func persistedStateWithHistoryCodableRoundTrip() throws {
  var s = PersistedState()
  _ = RecoveryEngine.process(hrv: 50, rhr: 55, resp: 14, sleepScore: 80, state: &s)
  s.history.upsert(DailyRecord(date: "2026-06-08", dayStrain: 12.3, rhr: 51, lnRMSSD: log(50),
    rhrSource: "standard_hr", hrvSource: "ppg", hrvQuality: 82, recovery: 70))
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back == s)
  #expect(back.history.days.count == 1)
  #expect(back.history.last?.rhrSource == "standard_hr")
  #expect(back.history.last?.hrvSource == "ppg")
  #expect(back.history.last?.hrvQuality == 82)
}

@Test func persistedStateDecodesLegacyWithoutHistory() throws {
  // simulate an older saved blob that predates the `history` field
  let s = PersistedState()
  var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
  obj.removeValue(forKey: "history")
  let legacy = try JSONSerialization.data(withJSONObject: obj)
  let back = try JSONDecoder().decode(PersistedState.self, from: legacy)
  #expect(back.history.days.isEmpty)               // defaulted, not a decode failure
}
