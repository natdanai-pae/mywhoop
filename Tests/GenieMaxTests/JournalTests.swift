import Testing
import Foundation
@testable import GenieMax

@Test func journalImpactDetectsNegativeBehavior() {
  var h = DailyHistory(); var j = [JournalEntry]()
  // 12 days: on "alcohol" days recovery ~40, otherwise ~75
  for i in 0..<12 {
    let date = String(format: "d%02d", i)
    let drank = i % 2 == 0
    h.upsert(DailyRecord(date: date, dayStrain: 8, recovery: (drank ? 40 : 75) + Double(i % 3) * 3))
    j.append(JournalEntry(date: date, behaviors: drank ? ["alcohol"] : []))
  }
  let imp = JournalEngine.impact(behavior: "alcohol", journal: j, history: h)
  #expect(imp != nil)
  #expect(imp!.d < -0.8)                      // large negative effect on recovery
  #expect(imp!.label.contains("lower"))
}

@Test func journalImpactNilUntilEnoughData() {
  var h = DailyHistory(); var j = [JournalEntry]()
  for i in 0..<3 { let d = String(format: "d%02d", i)
    h.upsert(DailyRecord(date: d, dayStrain: 8, recovery: 70)); j.append(JournalEntry(date: d, behaviors: ["x"])) }
  #expect(JournalEngine.impact(behavior: "x", journal: j, history: h) == nil)  // <3 without-days
}

@Test func persistedStateWithJournalCodable() throws {
  var s = PersistedState()
  s.journal.append(JournalEntry(date: "2026-06-08", behaviors: ["caffeine", "late_meal"]))
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back == s)
}

// Phase 2 — levels.
@Test func journalEntryDecodesPreLevelsDataAsEmpty() throws {
  // an entry persisted before phase 2 has no "levels" key — must decode (not throw) with levels == [:].
  let old = #"{"date":"2026-06-08","behaviors":["alcohol"]}"#.data(using: .utf8)!
  let e = try JSONDecoder().decode(JournalEntry.self, from: old)
  #expect(e.behaviors == ["alcohol"])
  #expect(e.levels.isEmpty)
}

@Test func journalEntryLevelsRoundTrip() throws {
  let e = JournalEntry(date: "2026-06-08", behaviors: ["alcohol", "meditated"], levels: ["alcohol": 3])
  let back = try JSONDecoder().decode(JournalEntry.self, from: JSONEncoder().encode(e))
  #expect(back == e)
  #expect(back.levels["alcohol"] == 3)
}

@Test func behaviorLevelsTableAndLabels() {
  #expect(BehaviorLevels.hasLevels("alcohol"))
  #expect(!BehaviorLevels.hasLevels("meditated"))
  #expect(BehaviorLevels.count("alcohol") == 3)
  #expect(BehaviorLevels.label("alcohol", 3) == "5+")
  #expect(BehaviorLevels.label("alcohol", 0) == nil)   // out of range (1-based)
  #expect(BehaviorLevels.label("alcohol", 4) == nil)
  #expect(BehaviorLevels.label("meditated", 1) == nil) // unleveled
}
