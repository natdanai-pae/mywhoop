import Testing
import Foundation
@testable import WhoopCore

@Test func stepCounterCountsPeaks() {
  var sc = StepCounter(threshold: 0.1, refractory: 2)
  for _ in 0..<20 { sc.feed(0.2); sc.feed(0.0) }     // 20 above/below cycles = 20 rising crossings
  #expect(sc.steps == 20)
}

@Test func stepCounterIgnoresBelowThresholdJitter() {
  var sc = StepCounter(threshold: 0.1, refractory: 2)
  for _ in 0..<50 { sc.feed(0.03) }                  // quiet (below threshold) → no steps
  #expect(sc.steps == 0)
}

@Test func keytelCaloriesPhysiological() {
  let hard = Physiology.kcalPerMin(hr: 120, weightKg: 83, age: 25)   // vigorous
  #expect(hard > 8 && hard < 13)
  let rest = Physiology.kcalPerMin(hr: 55, weightKg: 83, age: 25)    // near rest
  #expect(rest >= 0 && rest < 2)
  #expect(hard > rest)                                                // monotone in HR
}

@Test func mifflinBMRMatchesFormula() {
  // Tata 83kg/183cm/25/M: 10·83 + 6.25·183 − 5·25 + 5 = 1853.75 kcal/day
  let bmr = Physiology.mifflinBMR(weightKg: 83, heightCm: 183, age: 25, male: true)
  #expect(abs(bmr - 1853.75) < 0.01)
  // female is lower (166 kcal offset)
  #expect(Physiology.mifflinBMR(weightKg: 83, heightCm: 183, age: 25, male: false) < bmr)
}

@Test func branchedKcalRestingFloor() {
  // At rest, Keytel clamps to ~0 → branched must still accrue ≈ resting metabolic rate (BMR/min).
  let rmrMin = Physiology.mifflinBMR(weightKg: 83, heightCm: 183, age: 25, male: true) / 1440  // ≈1.287
  let restNoIMU = Physiology.branchedKcalPerMin(hr: 53, accelG: nil, weightKg: 83, heightCm: 183,
                    age: 25, male: true, hrMax: 190.5, hrRest: 53)
  #expect(abs(restNoIMU - rmrMin) < 0.05)
  let restIMU = Physiology.branchedKcalPerMin(hr: 53, accelG: 0, weightKg: 83, heightCm: 183,
                    age: 25, male: true, hrMax: 190.5, hrRest: 53)
  #expect(abs(restIMU - rmrMin) < 0.05)
  #expect(restNoIMU > 1.0)                                            // > Keytel's clamped-to-0 result
}

@Test func branchedKcalHRPathAtHighIntensity() {
  // High HR → HR-reserve weight w=1 → branched == max(rmr, Keytel) == Keytel here.
  let keytel = Physiology.kcalPerMin(hr: 170, weightKg: 83, age: 25)
  let branched = Physiology.branchedKcalPerMin(hr: 170, accelG: nil, weightKg: 83, heightCm: 183,
                    age: 25, male: true, hrMax: 190.5, hrRest: 53)
  #expect(abs(branched - keytel) < 0.01)
}

@Test func branchedKcalAccelLiftsLowHR() {
  // Low HR but moving (high accel) → accel path lifts EE above the resting floor.
  let still = Physiology.branchedKcalPerMin(hr: 70, accelG: 0, weightKg: 83, heightCm: 183,
                age: 25, male: true, hrMax: 190.5, hrRest: 53)
  let moving = Physiology.branchedKcalPerMin(hr: 70, accelG: 0.2, weightKg: 83, heightCm: 183,
                 age: 25, male: true, hrMax: 190.5, hrRest: 53)
  #expect(moving > still)
}
