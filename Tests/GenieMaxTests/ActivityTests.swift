import Testing
import Foundation
@testable import GenieMax

@Test func strainBands() {
  #expect(Physiology.strainBand(5) == "Light")
  #expect(Physiology.strainBand(12) == "Moderate")
  #expect(Physiology.strainBand(15) == "High")
  #expect(Physiology.strainBand(19) == "All-out")
}

@Test func trainingEffectAeroVsAnaero() {
  let easy = [60.0, 40, 10, 0, 0]      // mostly Z1-Z2 → aerobic-dominant, low anaerobic
  let hard = [5.0, 5, 10, 20, 15]      // lots of Z4-Z5 → high anaerobic
  #expect(Physiology.trainingEffectAerobic(zoneMin: easy) > Physiology.trainingEffectAnaerobic(zoneMin: easy))
  #expect(Physiology.trainingEffectAnaerobic(zoneMin: hard) > Physiology.trainingEffectAnaerobic(zoneMin: easy))
  #expect(Physiology.trainingEffectAerobic(zoneMin: hard) <= 5)   // capped
}

@Test func activityGroupingAndRollup() {
  let day0 = 1_700_000_000.0                         // fixed ts (deterministic)
  func w(_ id: String, _ start: Double, _ type: String, _ strain: Double, _ dur: Double) -> WorkoutSession {
    WorkoutSession(id: id, start: start, end: start + dur, durationSec: dur, hrMin: 60, hrAvg: 130, hrMax: 160,
                   zoneSec: [0, dur, 0, 0, 0], strain: strain, kcal: 200, type: type)
  }
  let ws = [w("a", day0 + 8 * 3600, "Cardio", 6, 1800),       // same day, morning
            w("b", day0 + 13 * 3600, "Strength", 9, 2400),    // same day, noon
            w("c", day0 + 86400 + 9 * 3600, "Run", 12, 2700)] // next day
  let days = Analytics.activityDays(ws)
  #expect(days.count == 2)                            // grouped into 2 calendar days
  #expect(days.first!.sessions.count == 1)            // newest day first (the Run)
  let twoSessionDay = days.first { $0.count == 2 }!
  #expect(twoSessionDay.sessions.first!.id == "a")    // ordered by start within the day (morning first)
  let sports = Analytics.activityByType(ws, sinceDays: 3650, now: day0 + 2 * 86400)
  #expect(sports.count == 3)                          // Cardio / Strength / Run
  #expect(sports.first!.count == 1)
  // all count==1 here → tiebreak by name MUST be deterministic (was flickering: non-deterministic dict order)
  #expect(sports.map { $0.type } == ["Cardio", "Run", "Strength"])
  #expect(Analytics.activityByType(ws, sinceDays: 3650, now: day0 + 2 * 86400).map { $0.type } == sports.map { $0.type })
}

@Test func activityBehaviorPatternsAndMonotony() {
  let now = 1_700_000_000.0
  let day = 86400.0
  func w(_ start: Double, _ type: String, _ strain: Double, _ dur: Double, _ zones: [Double]) -> WorkoutSession {
    WorkoutSession(id: "\(Int(start))", start: start, end: start + dur, durationSec: dur,
                   hrMin: 60, hrAvg: 130, hrMax: 160, zoneSec: zones, strain: strain, kcal: 200, type: type)
  }
  // 3 sessions this week on 3 distinct days, all aerobic-zone-heavy; one prior-week session for baseline
  let ws = [
    w(now - 1 * day, "Run", 10, 1800, [200, 600, 400, 0, 0]),
    w(now - 3 * day, "Bike", 8, 2400, [300, 700, 300, 0, 0]),
    w(now - 5 * day, "Run", 12, 2000, [100, 500, 600, 0, 0]),
    w(now - 10 * day, "Strength", 6, 1500, [0, 0, 0, 400, 200]),   // last week + anaerobic
  ]
  let b = Analytics.behavior(ws, now: now, windowDays: 7)
  #expect(b.hasData)
  #expect(b.sessions == 3)
  #expect(b.activeDays == 3)
  #expect(b.minutesThis > b.minutesPrev)                    // 3 sessions this week vs 0 last week
  #expect(b.aerobicPct != nil && b.aerobicPct! > 0.5)       // mostly Z1-Z3
  #expect(b.monotony != nil)                                // rest days create variance → defined monotony
  #expect(b.windowLoad == 30)                               // 10 + 8 + 12
  // month window picks up the prior-week Strength session too (4 sessions in 30d)
  let bm = Analytics.behavior(ws, now: now, windowDays: 30)
  #expect(bm.sessions == 4)
  #expect(bm.aerobicPct != nil && bm.aerobicPct! < b.aerobicPct!)   // month includes the anaerobic Strength block
}

@Test func dataReadinessGates() {
  // day 1 (no history): trends/recovery/ctl locked; instantaneous metrics not modeled here
  #expect(DataReadiness.locked(.trends, nights: 0, days: 1, activities: 0))
  #expect(DataReadiness.locked(.recovery, nights: 0, days: 1, activities: 0))
  #expect(DataReadiness.remaining(.recovery, nights: 0, days: 1, activities: 0) == 7)
  #expect(DataReadiness.remaining(.acwr, nights: 0, days: 4, activities: 0) == 24)   // 28 − 4
  // vo2max needs an activity, not days
  #expect(DataReadiness.locked(.vo2max, nights: 30, days: 30, activities: 0))
  #expect(!DataReadiness.locked(.vo2max, nights: 0, days: 0, activities: 1))
  // unlocks once enough accrues
  #expect(!DataReadiness.locked(.trends, nights: 0, days: 3, activities: 0))
  #expect(!DataReadiness.locked(.recovery, nights: 7, days: 7, activities: 0))
  #expect(DataReadiness.remaining(.sleepScore, nights: 1, days: 1, activities: 0) == 0)
}

@Test func workoutTypePersists() {
  let s = WorkoutSession(id: "x", start: 0, end: 60, durationSec: 60, hrMin: 60, hrAvg: 120, hrMax: 150,
                         zoneSec: [60, 0, 0, 0, 0], strain: 5, kcal: 50, type: "Run")
  #expect(s.type == "Run")
  // back-compat: omitting type defaults to Cardio
  let d = WorkoutSession(id: "y", start: 0, end: 60, durationSec: 60, hrMin: 60, hrAvg: 120, hrMax: 150,
                         zoneSec: [60, 0, 0, 0, 0], strain: 5, kcal: 50)
  #expect(d.type == "Cardio")
}
