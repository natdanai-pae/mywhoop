import Testing
import Foundation
@testable import GenieMax

@Test func detectsTwentyFiveMinNap() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 1_000_000.0; var steps = 0
  for i in 0..<120 {
    let nap = i >= 60 && i < 85                 // 25-min still + low-HR block
    let hr: Double = nap ? 54 : 85
    if !nap { steps += 25 }                     // walking when awake; steps flat during the nap
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  let naps = NapDetector.detect(rows, restHR: 52)
  #expect(naps.count == 1)
  if let n = naps.first {
    #expect(n.durationMin >= 24 && n.durationMin <= 26)
    #expect(abs(n.avgHR - 54) <= 1)
  }
}

@Test func ignoresShortStillBlock() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 2_000_000.0; var steps = 0
  for i in 0..<60 {
    let still = i >= 20 && i < 30               // only 10 min — below the 20-min floor
    let hr: Double = still ? 54 : 85
    if !still { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  #expect(NapDetector.detect(rows, restHR: 52).isEmpty)
}

@Test func ignoresStillButHighHR() {
  // Sitting perfectly still for an hour but HR stays elevated (awake, not napping) → no nap.
  let base = 3_000_000.0
  let rows = (0..<60).map { (ts: base + Double($0 * 60), hr: 72.0, steps: 0) }   // 72 > 52 + 12
  #expect(NapDetector.detect(rows, restHR: 52).isEmpty)
}

@Test func excludesLoggedWorkoutWindow() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 4_000_000.0; var steps = 0
  for i in 0..<120 {
    let quiet = i >= 60 && i < 85
    let hr: Double = quiet ? 54 : 85
    if !quiet { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  let excl = [(start: base + 60 * 60, end: base + 85 * 60)]   // a logged window over the block
  #expect(NapDetector.detect(rows, restHR: 52, exclude: excl).isEmpty)
}

// Fix 2b: a 25-min still block whose HR sits just *above* resting (sitting awake at a desk, not napping)
// is rejected by the tightened +10 margin. restHR 52 → threshold 62; HR 63 is awake-sedentary, not a nap.
@Test func rejectsAwakeSedentaryJustAboveResting() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 5_000_000.0; var steps = 0
  for i in 0..<120 {
    let still = i >= 60 && i < 85
    let hr: Double = still ? 63 : 88          // 63 = 52 + 11 → outside the +10 rest band
    if !still { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  #expect(NapDetector.detect(rows, restHR: 52).isEmpty)
  // a genuine nap one bpm lower (within the band) is still caught — the boundary is meaningful, not blanket
  let napRows = rows.map { (ts: $0.ts, hr: $0.hr == 63 ? 61 : $0.hr, steps: $0.steps) }
  #expect(NapDetector.detect(napRows, restHR: 52).count == 1)
}

// False-nap fix: a 30-min still block where HR holds the SAME low plateau as the awake minutes (sitting at a
// desk, never asleep) is rejected once the HR-drop gate is on — there was no dip INTO sleep.
@Test func rejectsStillWithoutHRDrop() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 7_000_000.0; var steps = 0
  for i in 0..<120 {
    let still = i >= 60 && i < 90
    let hr: Double = 60                          // flat ~60 the whole window — no sleep dip
    if !still { steps += 25 }                    // walking when awake; still during the block
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  // restHR 55 → quiet ≤65 (HR 60 passes the OLD rule), but HR never dropped → with the gate it's NOT a nap.
  #expect(NapDetector.detect(rows, restHR: 55, minHRDrop: 5).isEmpty)
  #expect(NapDetector.detect(rows, restHR: 55).count == 1)        // sanity: gate off (sleep path) → old behavior
}

// A genuine nap shows HR DROP into the still run (active → asleep) → kept even with the gate on.
@Test func acceptsNapWithHRDrop() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 8_000_000.0; var steps = 0
  for i in 0..<120 {
    let still = i >= 60 && i < 90
    let hr: Double = still ? 56 : 76             // HR drops 76 (active) → 56 (asleep)
    if !still { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  #expect(NapDetector.detect(rows, restHR: 55, minHRDrop: 5).count == 1)
}

// HR-VOLATILITY gate: a still block whose pulse keeps WANDERING within the quiet band (reading in bed, not truly
// asleep) is kept but flagged LOW confidence — sleep settles into a steady rhythm, awake-sedentary doesn't.
@Test func lowConfidenceWhenHRWanders() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 9_000_000.0; var steps = 0
  for i in 0..<120 {
    let still = i >= 60 && i < 95
    let hr: Double = still ? (i % 2 == 0 ? 50 : 64) : 88     // wandering pulse (SD≈7) inside the ≤65 quiet band
    if !still { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  let naps = NapDetector.detect(rows, restHR: 55, minHRDrop: 5, maxHRVolatility: 6)
  #expect(naps.count == 1)
  #expect(naps.first?.confidence == .low)
}

// A stable, dropped nap → HIGH confidence.
@Test func highConfidenceWhenStableAndDropped() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 10_000_000.0; var steps = 0
  for i in 0..<120 {
    let still = i >= 60 && i < 95
    let hr: Double = still ? 56 : 88                          // steady low pulse, clearly dropped
    if !still { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  let naps = NapDetector.detect(rows, restHR: 55, minHRDrop: 5, maxHRVolatility: 6)
  #expect(naps.count == 1)
  #expect(naps.first?.confidence == .high)
}

// hrVolatility: a constant series has zero spread; an alternating series has a clear positive SD.
@Test func hrVolatilityMeasuresSpread() {
  #expect(NapDetector.hrVolatility([60, 60, 60, 60, 60]) == 0)
  #expect(NapDetector.hrVolatility([50, 64, 50, 64, 50, 64]) > 5)
}

// Night-bout (boutNightWindow) needs a WIDER HR band than a daytime nap: the night includes the higher-HR
// early-sleep period that sits ~15-25 bpm above the pre-dawn trough (≈ restHR). A low-RHR sleeper (athlete,
// RHR 46) falls asleep at ~64 bpm; the nap default (+10 → ≤56) clips onset to the late-night trough, losing
// hours. +22 (the boutNightWindow setting) captures the whole night onset→wake. Repro of a real device night.
@Test func nightBoutNeedsWideHRMarginForLowRHRSleeper() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 11_000_000.0; var steps = 0
  for i in 0..<480 {
    let asleep = i >= 60                          // awake the first 60 min, then a 7-h night
    let hr: Double
    if !asleep { hr = 80; steps += 20 }           // moving around before bed
    else if i < 180 { hr = 64 }                   // early sleep — ~18 bpm above the RHR-46 trough
    else if i < 360 { hr = 57 }                   // mid sleep
    else { hr = 52 }                              // pre-dawn trough
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  func longestMin(_ ns: [Nap]) -> Int { ns.map { $0.durationMin }.max() ?? 0 }
  // nap default (+10 → ≤56): only the trough third counts → badly truncated (the bug)
  #expect(longestMin(NapDetector.detect(rows, restHR: 46)) < 200)
  // night band (+22 → ≤68): the full onset→wake night is captured
  let night = NapDetector.detect(rows, restHR: 46, minMin: 20, hrMargin: 22)
  #expect(longestMin(night) >= 400)
  // …and it starts at the true onset (minute 60), not the mid-night trough
  if let main = night.max(by: { $0.durationMin < $1.durationMin }) {
    #expect(abs(main.start - (base + 60 * 60)) <= 60)
  }
}

// Fix 2a: the post-wake refractory is modelled as an exclude window covering the morning tail + ~90 min.
// A still+low-HR stretch starting minutes after wake (groggy at a desk) falls inside it and is not a nap.
@Test func excludesPostWakeRefractoryWindow() {
  var rows = [(ts: Double, hr: Double, steps: Int)]()
  let base = 6_000_000.0; var steps = 0
  for i in 0..<120 {
    let quiet = i >= 6 && i < 31                // still + low HR starting 6 min after "wake" (base)
    let hr: Double = quiet ? 56 : 84
    if !quiet { steps += 25 }
    rows.append((ts: base + Double(i * 60), hr: hr, steps: steps))
  }
  let refractory = [(start: base, end: base + 90 * 60)]       // wake .. wake+90min
  #expect(NapDetector.detect(rows, restHR: 52, exclude: refractory).isEmpty)
  #expect(NapDetector.detect(rows, restHR: 52).count == 1)    // sanity: without the refractory it WOULD flag
}
