import Testing
import Foundation
@testable import GenieMax

// C3 — Katch-McArdle uses lean mass; for a lean body it should differ from Mifflin, and rise with lean mass.
@Test func katchMcArdleFromLeanMass() {
  let lean = Physiology.katchMcArdleBMR(weightKg: 83, bodyFatPct: 12)
  let fat = Physiology.katchMcArdleBMR(weightKg: 83, bodyFatPct: 30)
  #expect(lean > fat)                              // same weight, less fat → more lean mass → higher BMR
  #expect(lean > 370 && lean < 3000)               // sane kcal/day
}

@Test func profileBMRSwitchesToKatchWithBodyFat() {
  var p = Profile(age: 25, male: true, weightKg: 83, heightCm: 183, activity: 2)
  #expect(p.bmrMethod == "Mifflin-St Jeor")
  p.bodyFatPct = 12
  #expect(p.bmrMethod == "Katch-McArdle")
  #expect(p.bmr == Physiology.katchMcArdleBMR(weightKg: 83, bodyFatPct: 12))
  #expect(p.tdee > p.bmr)                          // PAL multiplier
}

// C2 — EPOC scales with strain and is a bounded fraction of active kcal.
@Test func epocScalesWithStrain() {
  let easy = Physiology.epocKcal(strain: 4, activeKcal: 400)
  let hard = Physiology.epocKcal(strain: 18, activeKcal: 400)
  #expect(hard > easy)
  #expect(hard <= 400 * 0.15 + 0.001)              // capped at ~15%
  #expect(easy >= 400 * 0.03 - 0.001)              // floored at ~3%
}

// D1 — MET differs by activity type; kcal = MET·kg·h.
@Test func metByActivityType() {
  #expect(Physiology.metForActivity("Run") > Physiology.metForActivity("Walk"))
  #expect(Physiology.metForActivity("Yoga") < Physiology.metForActivity("HIIT"))
  let run30 = Physiology.metKcal(type: "Run", weightKg: 80, minutes: 30)   // 9 MET, 80kg, 0.5h
  #expect(abs(run30 - 9 * 3.5 * 80 / 200 * 30) < 0.01)
  #expect(run30 > Physiology.metKcal(type: "Walk", weightKg: 80, minutes: 30))
}

// D2/G1 — HR-gate, now type-aware: cardio trusts elevated HR; flat HR or HR-unreliable types fall back to MET.
@Test func hrGateReconciliation() {
  let elevated = Physiology.reconcileSessionKcal(hrKcal: 300, type: "Run", weightKg: 80, minutes: 40, avgHRR: 0.55)
  #expect(elevated.method == "HR" && elevated.kcal == 300)             // cardio + elevated → trust HR
  let flat = Physiology.reconcileSessionKcal(hrKcal: 9, type: "Run", weightKg: 80, minutes: 40, avgHRR: 0.10)
  #expect(flat.method == "MET")                                        // cardio but HR flat → MET
  #expect(flat.kcal == Physiology.metKcal(type: "Run", weightKg: 80, minutes: 40))
  // G1 — Strength is HR-unreliable → MET even when HR is elevated (static lifts).
  let strength = Physiology.reconcileSessionKcal(hrKcal: 300, type: "Strength", weightKg: 80, minutes: 40, avgHRR: 0.55)
  #expect(strength.method == "MET")
  #expect(strength.kcal == Physiology.metKcal(type: "Strength", weightKg: 80, minutes: 40))
}

// G3 — rule-based classification from cadence + intensity.
@Test func activityClassifier() {
  #expect(ActivityClassifier.classify(cadenceSPM: 165, avgHRR: 0.7) == "Run")
  #expect(ActivityClassifier.classify(cadenceSPM: 100, avgHRR: 0.4) == "Walk")
  #expect(ActivityClassifier.classify(cadenceSPM: 5, avgHRR: 0.7) == "Bike")     // high HR, ~no steps
  #expect(ActivityClassifier.classify(cadenceSPM: 5, avgHRR: 0.35) == "Strength")
}

// G3 — HRMin decodes legacy rings (no `steps` key) with steps defaulting to 0.
@Test func hrMinLegacyDecode() throws {
  let legacy = #"{"ts":1000,"hr":120}"#
  let m = try JSONDecoder().decode(HRMin.self, from: Data(legacy.utf8))
  #expect(m.hr == 120 && m.steps == 0)
}

// D3 — steps→kcal rises with steps & weight; 10k steps lands in the cited 300-500 range.
@Test func stepsToCalories() {
  let k = Physiology.stepsKcal(steps: 10000, weightKg: 80, heightCm: 180)
  #expect(k > 250 && k < 550)
  #expect(Physiology.stepsKcal(steps: 10000, weightKg: 100, heightCm: 180) > k)   // heavier burns more
}

// D2 — back-compat: a session encoded WITHOUT kcalMethod/type still decodes (defaults applied).
@Test func workoutDecodesLegacyWithoutNewFields() throws {
  let legacy = #"{"id":"x","start":0,"end":600,"durationSec":600,"hrMin":60,"hrAvg":120,"hrMax":150,"zoneSec":[60,0,0,0,0],"strain":5,"kcal":50}"#
  let s = try JSONDecoder().decode(WorkoutSession.self, from: Data(legacy.utf8))
  #expect(s.type == "Cardio")        // default
  #expect(s.kcalMethod == "HR")      // default
  #expect(s.kcal == 50)
}

// E3 — per-day intake log persists (round-trip) and a legacy blob (no intakeLog key) still decodes.
@Test func intakeLogRoundTripsAndBackCompat() throws {
  var s = PersistedState(); s.intakeLog["2026-06-09"] = 2100; s.intakeLog["2026-06-08"] = 1950
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back.intakeLog["2026-06-09"] == 2100 && back.intakeLog["2026-06-08"] == 1950)
  // legacy: empty intakeLog + old single-day fields → migrates into the log on decode
  var legacy = PersistedState(); legacy.intakeKcal = 1800; legacy.intakeDate = "2026-06-01"; legacy.intakeLog = [:]
  let migrated = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(legacy))
  #expect(migrated.intakeLog["2026-06-01"] == 1800)
}

// F1 — meal entries + favorites persist (round-trip) and a legacy blob without them still decodes.
@Test func intakeEntriesAndFavoritesPersist() throws {
  var s = PersistedState()
  s.intakeEntries["2026-06-09"] = [
    IntakeEntry(id: "a", meal: "Lunch", name: "Fried rice", kcal: 600, ts: 1),
    IntakeEntry(id: "b", meal: "Snack", name: "Banana", kcal: 105, ts: 2)]
  s.favoriteFoods = [IntakeEntry(id: "fav-Egg", meal: "Snack", name: "Egg", kcal: 78, ts: 0)]
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back.intakeEntries["2026-06-09"]?.count == 2)
  #expect(back.intakeEntries["2026-06-09"]?.reduce(0) { $0 + $1.kcal } == 705)
  #expect(back.favoriteFoods.first?.name == "Egg")
  // common foods table is non-empty and sane
  #expect(!CommonFoods.items.isEmpty && CommonFoods.items.allSatisfy { $0.kcal > 0 })
}

// AI backend config persists (provider/baseURL/model) + defaults to Anthropic; legacy blob decodes.
@Test func aiBackendPersists() throws {
  var s = PersistedState(); s.aiProvider = 1
  s.aiBaseURL = "https://openrouter.ai/api/v1"; s.aiModel = "google/gemini-2.5-flash"
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back.aiProvider == 1 && back.aiBaseURL.contains("openrouter") && back.aiModel.contains("gemini"))
  #expect(PersistedState().aiProvider == 0)   // default = Anthropic native
}

// C4 — energy balance: deficit → loss, surplus → gain, with safe-rate flagging.
@Test func energyBalanceStatuses() {
  let healthy = Physiology.EnergyBalance(expended: 2500, intake: 2100, weightKg: 83)   // −400/day
  #expect(healthy.balance == -400)
  #expect(healthy.lbPerWeek < 0)                   // losing
  #expect(healthy.status == "deficit_healthy")
  let aggressive = Physiology.EnergyBalance(expended: 2500, intake: 1100, weightKg: 83) // −1400/day
  #expect(aggressive.status == "deficit_aggressive")
  let surplus = Physiology.EnergyBalance(expended: 2500, intake: 3200, weightKg: 83)
  #expect(surplus.status == "surplus" && surplus.balance > 0)
  let maint = Physiology.EnergyBalance(expended: 2500, intake: 2550, weightKg: 83)
  #expect(maint.status == "maintenance")
}
