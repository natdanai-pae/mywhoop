import Testing
import Foundation
@testable import GenieMax

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

// golden RR set; expected values computed via numpy (see export run)
private let RR: [Double] = [800, 810, 790, 805, 795, 815, 785]

@Test func hrvFromSharedRRSet() {
  let m = HRV.metrics(RR)!
  #expect(approx(m.rmssd, 18.8193163177))
  #expect(approx(m.sdnn, 10.0, 1e-9))
  #expect(approx(m.sd1, 13.3072661856))   // gateway def: RMSSD/√2
  #expect(approx(m.sd2, 4.7871355388))
}

@Test func poincareIdentityIsExactOnSharedRR() {
  // prototype bug: stored SD1 vs RMSSD/√2 were ~18% apart (different windows).
  // Gateway-consistent def from ONE shared RR set → identity is EXACT.
  let m = HRV.metrics(RR)!
  #expect(approx(m.sd1, m.rmssd / (2.0).squareRoot(), 1e-12))
}

@Test func hrvNilOnTooFew() {
  #expect(HRV.metrics([800, 810]) == nil)
}

@Test func baevskyStressIndex() {
  // spread RR (hist 750:6, 800:16, 850:2) → mode800 AMo66.67 VR0.1 → SI 417
  let rr: [Double] = [750,755,760,800,805,810,795,790,850,840,800,805,
                      760,750,800,795,810,800,755,805,800,790,800,810]
  #expect(HRV.baevskySI(rr) == 417)
  #expect(HRV.baevskySI([800, 810, 790]) == nil)   // <20 → nil
}

@Test func physiologyGolden() {
  #expect(approx(Physiology.tanakaHRmax(age: 25), 190.5, 1e-9))
  #expect(approx(Physiology.karvonenHRR(hr: 140, hrMax: 190.5, hrRest: 53), 0.632727, 1e-5))
  #expect(Physiology.karvonenZone(hr: 140, hrMax: 190.5, hrRest: 53) == 2)   // r≈0.63 → Z3
  #expect(Physiology.karvonenZone(hr: 53, hrMax: 190.5, hrRest: 53) == 0)    // rest → Z1
  #expect(Physiology.karvonenZone(hr: 200, hrMax: 190.5, hrRest: 53) == 4)   // ≥max → Z5
  #expect(approx(Physiology.uthVO2max(hrMax: 190.5, hrRest: 53), 54.993396, 1e-5))
}

// Fitness age composition modifiers (measured InBody body fat + skeletal-muscle index). vo2max 30 keeps the
// base (≈44.6) clear of the [18,85] clamp so the modifiers are observable.
@Test func fitnessAgeMeasuredCompositionModifiers() {
  let base = Physiology.fitnessAge(vo2max: 30, rhr: 60, bodyFatPct: nil, age: 30, male: true)
  // SMI 2 kg/m² above the 8.5 male healthy ref → 2 × 1.5 = 3 yr younger; 2 below → 3 yr older.
  let muscular = Physiology.fitnessAge(vo2max: 30, rhr: 60, bodyFatPct: nil, smi: 10.5, age: 30, male: true)
  let frail    = Physiology.fitnessAge(vo2max: 30, rhr: 60, bodyFatPct: nil, smi: 6.5, age: 30, male: true)
  #expect(approx(base - muscular, 3.0, 1e-6))
  #expect(approx(frail - base, 3.0, 1e-6))
  // Leaner than the 18% male healthy point → younger; fatter → older.
  let lean = Physiology.fitnessAge(vo2max: 30, rhr: 60, bodyFatPct: 12, age: 30, male: true)
  let fat  = Physiology.fitnessAge(vo2max: 30, rhr: 60, bodyFatPct: 28, age: 30, male: true)
  #expect(lean < base && base < fat)
}

// The detail-page decomposition: VO₂ baseline + each term's signed year delta sums (clamped) to the final age.
@Test func fitnessAgeBreakdownDecomposes() {
  let b = Physiology.fitnessAgeBreakdown(vo2max: 30, rhr: 50, bodyFatPct: 28, smi: 6.5, measured: true, age: 30, male: true)
  #expect(approx(b.vo2BaselineAge, 44.615384, 1e-4))               // 20 + (38−30)/0.325
  #expect(b.terms.count == 3)
  let sum = b.vo2BaselineAge + b.terms.reduce(0) { $0 + $1.deltaYears }
  #expect(approx(b.fitnessAge, min(85, max(18, sum)), 1e-9))       // terms reconstruct the final age
  #expect(b.terms.first { $0.key == "rhr" }!.deltaYears < 0)       // RHR 50 < 60 → younger
  #expect(b.terms.first { $0.key == "muscle" }!.measured)          // scan composition tagged measured
  #expect(b.fitnessAge == Physiology.fitnessAge(vo2max: 30, rhr: 50, bodyFatPct: 28, smi: 6.5, age: 30, male: true))
}
