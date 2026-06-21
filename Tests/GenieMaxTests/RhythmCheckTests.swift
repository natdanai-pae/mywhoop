import Testing
import Foundation
@testable import GenieMax

// T1b — rule-based rhythm check from RR-intervals (non-diagnostic).

// A steady ~70 bpm sinus rhythm (small ±15 ms jitter) → regular.
@Test func steadySinusIsRegular() {
  var rr: [Double] = []
  for i in 0..<60 { rr.append(857 + (i % 2 == 0 ? 12 : -12)) }   // ~70 bpm, tiny alternation
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.category == .regular)
  #expect(r.meanHR == 70)
  #expect(r.beats == 60)
  #expect(r.cv < 0.06)
}

// Normal sinus arrhythmia (breathing-driven, moderate swing) → variable, not irregular.
@Test func breathingVariabilityIsVariable() {
  var rr: [Double] = []
  for i in 0..<60 { rr.append(900 + 110 * sin(Double(i) * 0.6)) }  // smooth respiratory swing, CV ~0.06–0.12
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.category == .variable)
}

// Big successive jumps (dropped/extra beats from a loose strap / motion) → NOISY, not a false "irregular".
@Test func jumpyRRIsFlaggedNoisy() {
  // alternating very short/long beats = exactly the missed-beat artifact signature
  let pattern: [Double] = [600, 1100, 700, 1300, 520, 980, 1250, 640, 1180, 560]
  var rr: [Double] = []
  for _ in 0..<6 { rr.append(contentsOf: pattern) }
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.category == .noisy)            // must NOT alarm "irregular" on artifact
  #expect(r.artifactFraction > 0.25)
}

// An ORDERED wide drift (680→1080) has high CV but is predictable (TPR≈0) → variable, NOT a false "irregular".
@Test func orderedDriftIsVariableNotIrregular() {
  let rr = (0..<50).map { 680 + (400.0 / 49.0) * Double($0) }
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.category == .variable)
  #expect(r.tpr < 0.25)
}

// DISORDERED variability without big artifact jumps (high CV + high TPR) → irregular.
@Test func disorderedRRIsIrregular() {
  let pattern: [Double] = [700, 1000, 720, 980]      // swings < jump-threshold but constantly reversing
  var rr: [Double] = []
  for _ in 0..<12 { rr.append(contentsOf: pattern) }
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.category == .irregular)
  #expect(r.tpr >= 0.25 && r.artifactFraction < 0.25)
}

// A STEADY core with a few big spikes at the start/end (PPG settling / motion / isolated ectopy) must NOT
// be called "irregular" — the apparent dispersion collapses once the spikes are removed. (Real-device false-positive.)
@Test func steadyCoreWithEdgeSpikesIsNotIrregular() {
  var rr: [Double] = [1350, 420, 1300, 450]                      // start artifact (doubles/halves)
  rr += (0..<50).map { 850 + (($0 % 2 == 0) ? 10.0 : -10.0) }   // steady ~70 bpm core
  rr += [1380, 440, 1320]                                        // end artifact
  let r = RhythmCheck.analyze(rr: rr, minBeats: 30)
  #expect(r.category != .irregular)                              // must NOT false-flag AFib
}

// Sustained moderate swings (no extreme spikes) survive spike-removal → still irregular (don't over-correct).
@Test func sustainedModerateDisorderStaysIrregular() {
  let pattern: [Double] = [700, 1000, 720, 980]                  // every swing < jump threshold, constant reversal
  var rr: [Double] = []
  for _ in 0..<12 { rr.append(contentsOf: pattern) }
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.category == .irregular)
}

// Too few beats → insufficient (no false verdict).
@Test func tooFewBeatsIsInsufficient() {
  let r = RhythmCheck.analyze(rr: [850, 860, 845, 855])
  #expect(r.category == .insufficient)
  #expect(r.meanHR == 0)
}

// Non-physiologic intervals are dropped before analysis.
@Test func nonPhysiologicBeatsDropped() {
  var rr = Array(repeating: 850.0, count: 40)
  rr.append(contentsOf: [50, 50, 9999, 0])     // garbage, must be ignored
  let r = RhythmCheck.analyze(rr: rr)
  #expect(r.beats == 40)
  #expect(r.category == .regular)
}

// SD1 ≡ RMSSD/√2 identity holds (Poincaré parity).
@Test func poincareIdentityHolds() {
  let rr = (0..<50).map { 840 + Double(($0 * 7) % 30) }
  let r = RhythmCheck.analyze(rr: rr)
  #expect(abs(r.sd1 - r.rmssd / 2.0.squareRoot()) < 0.001)
}
