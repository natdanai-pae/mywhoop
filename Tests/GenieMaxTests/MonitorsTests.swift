import Testing
import Foundation
@testable import GenieMax

@Test func motionStateThresholds() {
  #expect(Monitors.motionState(0.0) == .still)
  #expect(Monitors.motionState(0.06) == .moving)
  #expect(Monitors.motionState(0.30) == .active)
}

@Test func motionStateHysteresis() {
  // the SAME value 0.04 resolves differently by prior state → a dead-band that kills boundary chatter
  #expect(Monitors.motionState(0.04, prev: .still) == .still)     // hasn't crossed the 0.05 enter threshold
  #expect(Monitors.motionState(0.06, prev: .still) == .moving)
  #expect(Monitors.motionState(0.04, prev: .moving) == .moving)   // stays moving (no flip back at 0.04)
  #expect(Monitors.motionState(0.02, prev: .moving) == .still)    // only falls back below 0.025
  #expect(Monitors.motionState(0.15, prev: .moving) == .active)
  #expect(Monitors.motionState(0.11, prev: .active) == .active)   // dead-band keeps active
  #expect(Monitors.motionState(0.09, prev: .active) == .moving)   // falls back below 0.10
}

@Test func stressLevelMonotonicAndGated() {
  // higher SI vs baseline → higher stress level
  let calm = Monitors.stress(si: 60, baselineMean: 100, baselineSD: 30, motion: .still)
  let high = Monitors.stress(si: 190, baselineMean: 100, baselineSD: 30, motion: .still)
  #expect(high.level > calm.level)
  #expect(calm.label == "Calm")
  #expect(!high.isActivity)
  // movement → reported as Activity, not psychological stress
  let moving = Monitors.stress(si: 190, baselineMean: 100, baselineSD: 30, motion: .active)
  #expect(moving.isActivity && moving.label == "Exercising")
  // no baseline yet → neutral
  #expect(Monitors.stress(si: 100, baselineMean: 0, baselineSD: 0, motion: .still).label == "Balanced")
}

@Test func stressV2FromHRandHRV() {
  // calm: HR + HRV at baseline → centered ~1.5 "Balanced"
  let calm = Monitors.stressHRHRV(hr: 60, hrv: 50, hrBase: 60, hrSD: 4, hrvBase: 50, hrvSD: 8, ready: true, motion: .still)
  #expect(abs(calm.level - 1.5) < 0.3)
  // stressed: HR elevated + HRV suppressed → markedly higher
  let stressed = Monitors.stressHRHRV(hr: 82, hrv: 25, hrBase: 60, hrSD: 4, hrvBase: 55, hrvSD: 8, ready: true, motion: .still)
  #expect(stressed.level > calm.level && stressed.level >= 2.5 && !stressed.isActivity)
  // HRV absent (RR dropout) → HR-only still produces a sensible elevated reading (graceful, no collapse)
  let hrOnly = Monitors.stressHRHRV(hr: 82, hrv: nil, hrBase: 60, hrSD: 4, hrvBase: nil, hrvSD: 0, ready: true, motion: .still)
  #expect(hrOnly.level > 1.5)
  // mild wobble on a warmed-up baseline must NOT peak (regression for the cold-start "High" over-read)
  let wobble = Monitors.stressHRHRV(hr: 66, hrv: 46, hrBase: 60, hrSD: 3, hrvBase: 52, hrvSD: 6, ready: true, motion: .still)
  #expect(wobble.level < 2.6)
  // not warmed up yet → neutral regardless of the reading
  #expect(Monitors.stressHRHRV(hr: 90, hrv: 20, hrBase: 60, hrSD: 7, hrvBase: 55, hrvSD: 12, ready: false, motion: .still).label == "Balanced")
  // movement → Activity, not psychological stress
  let active = Monitors.stressHRHRV(hr: 140, hrv: nil, hrBase: 60, hrSD: 4, hrvBase: nil, hrvSD: 0, ready: true, motion: .active)
  #expect(active.level == 3 && active.isActivity)
  // no baseline yet → neutral
  #expect(Monitors.stressHRHRV(hr: 70, hrv: 40, hrBase: 0, hrSD: 0, hrvBase: nil, hrvSD: 0, ready: true, motion: .still).label == "Balanced")
  // #5 skin-temp: elevated skin temp nudges stress UP, but only slightly (never dominates HR/HRV)
  let neutralT = Monitors.stressHRHRV(hr: 60, hrv: 50, temp: 34.0, hrBase: 60, hrSD: 7, hrvBase: 50, hrvSD: 12, tempBase: 34.0, tempSD: 0.3, ready: true, motion: .still)
  let warmT = Monitors.stressHRHRV(hr: 60, hrv: 50, temp: 35.0, hrBase: 60, hrSD: 7, hrvBase: 50, hrvSD: 12, tempBase: 34.0, tempSD: 0.3, ready: true, motion: .still)
  #expect(warmT.level > neutralT.level && warmT.level - neutralT.level <= 0.2)
}

@Test func energyDepletesAndRecharges() {
  let start = Monitors.startEnergy(recovery: 80, sleepScore: 80)
  #expect(start > 70 && start <= 100)
  // hard effort drains
  let afterStrain = Monitors.stepEnergy(80, dStrain: 1.0, stressLevel: 2, dtMin: 1, motion: .active)
  #expect(afterStrain < 80)
  // calm rest recharges a touch
  let afterRest = Monitors.stepEnergy(50, dStrain: 0, stressLevel: 0, dtMin: 10, motion: .still)
  #expect(afterRest > 50)
  // clamped 5...100
  #expect(Monitors.stepEnergy(6, dStrain: 50, stressLevel: 3, dtMin: 1, motion: .active) >= 5)
  #expect(Monitors.energyBand(90) == 3 && Monitors.energyBand(10) == 0)
}

@Test func energyGoodNightDoesNotCrater() {
  // warm-up (no Recovery yet) + a great night → high morning seed, not dragged down by the 50 default
  var e = Monitors.startEnergy(recovery: nil, sleepScore: 92)
  #expect(e > 85)
  // ~15h awake, total day strain 9, calm stress, always moving (no rest to recharge)
  for _ in 0..<900 { e = Monitors.stepEnergy(e, dStrain: 9.0 / 900, stressLevel: 1.0, dtMin: 1, motion: .moving) }
  #expect(e > 35 && e < 90)        // drains meaningfully but must NOT hit the 5% floor on a normal day
}

@Test func deriveEnergyTracksStrainAndNeverSticks() {
  let seed = Monitors.startEnergy(recovery: nil, sleepScore: 94)        // great night, recovery warming up
  #expect(seed > 90)
  #expect(Monitors.deriveEnergy(seed: seed, dayStrain: 0) == seed)      // rested day → essentially the seed
  let afterWorkout = Monitors.deriveEnergy(seed: seed, dayStrain: 17)   // a workout drops it…
  #expect(afterWorkout > 25 && afterWorkout < 60)                       // …but doesn't crater
  #expect(Monitors.deriveEnergy(seed: 94, dayStrain: 40) == 5)          // a huge day → floor
  // self-correcting: it's recomputed from seed+strain every update, so a previously stuck-low value is irrelevant
  #expect(Monitors.deriveEnergy(seed: 90, dayStrain: 5) > 70)
}
