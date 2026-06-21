import Testing
import Foundation
@testable import WhoopCore

// P1 — build a session from a (ts,hr) window (manual-log / auto-detect path).
// Regression guard: 1-min-spaced samples must NOT be under-counted by the live 5s gap-clamp — a 30-min
// Z3+ effort has to integrate real strain (>8), not the ~1.3 the clamp produced before maxGapSec was added.
@Test func buildSessionFromWindow() {
  let samples = (0..<30).map { (ts: Double($0) * 60, hr: 150) }   // 30 min @150 bpm, 1-min spacing
  let s = WorkoutAccumulator.build(samples: samples, hrMax: 190, hrRest: 55, tau: 100,
                                   weightKg: 80, age: 25, heightCm: 180, male: true, type: "Run")
  #expect(s != nil)
  #expect(s!.type == "Run")
  #expect(s!.strain > 8)               // would be ~1.3 with the old 5s dt-clamp
  #expect(s!.hrAvg == 150)
}

// P2 — strain target rises with recovery; sleep need rises with strain
@Test func strainTargetAndSleepNeed() {
  #expect(Scores.strainTarget(recovery: 90) > Scores.strainTarget(recovery: 30))
  #expect((6...20).contains(Scores.strainTarget(recovery: 50)))
  #expect(Scores.sleepNeedH(base: 8, dayStrain: 18, debtH: 0) > Scores.sleepNeedH(base: 8, dayStrain: 2, debtH: 0))
}

// P3 — auto-detect finds an elevated block ≥15 min that returns to baseline; ignores short/flat
@Test func autoDetectFindsBlock() {
  // 5 min rest, 20 min elevated, 5 min rest
  var hr = [Double](repeating: 60, count: 5)
  hr += [Double](repeating: 150, count: 20)
  hr += [Double](repeating: 60, count: 5)
  let win = AutoDetect.scan(hr: hr, hrRest: 55, hrMax: 190)
  #expect(win != nil)
  #expect(win!.end - win!.start + 1 >= 15)
}

@Test func autoDetectIgnoresShort() {
  var hr = [Double](repeating: 60, count: 10)
  hr += [Double](repeating: 150, count: 8)     // only 8 min elevated → below 15-min floor
  hr += [Double](repeating: 60, count: 5)
  #expect(AutoDetect.scan(hr: hr, hrRest: 55, hrMax: 190) == nil)
}
