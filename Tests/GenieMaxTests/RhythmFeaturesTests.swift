import Testing
import Foundation
@testable import GenieMax

// Validate the RR-feature math on known inputs (not clinical thresholds).

@Test func constantSeriesIsFullyOrdered() {
  let c = Array(repeating: 850.0, count: 24)
  #expect(RhythmFeatures.shannonEntropy(c) == 0)        // single value → no spread
  #expect(RhythmFeatures.turningPointRatio(c) == 0)     // no turning points
}

@Test func monotonicRampHasNoTurningPoints() {
  let ramp = (0..<30).map { 800 + Double($0) }
  #expect(RhythmFeatures.turningPointRatio(ramp) == 0)
}

@Test func strictAlternationMaximisesTPR() {
  let alt = (0..<30).map { $0 % 2 == 0 ? 800.0 : 900.0 }
  #expect(RhythmFeatures.turningPointRatio(alt) > 0.95)  // every interior point is an extremum
}

@Test func entropyHigherForWideSpreadThanNarrow() {
  let wide = (0..<32).map { 700 + Double($0) * 10 }       // spread across the full range
  let narrow = (0..<32).map { 850 + Double($0 % 2) }      // two tight values
  #expect(RhythmFeatures.shannonEntropy(wide) > 0.8)
  #expect(RhythmFeatures.shannonEntropy(narrow) < 0.4)
}

// CoSEn captures ORDER (unlike distribution entropy): same values, shuffled, scores higher.
@Test func coSEnHigherForDisorderThanOrder() {
  let vals = (0..<40).map { 800.0 + Double($0) }
  let ordered = vals
  let disordered = (0..<40).map { vals[($0 * 17) % 40] }  // deterministic permutation (17 coprime to 40)
  let cOrdered = RhythmFeatures.coSEn(ordered)
  let cDisordered = RhythmFeatures.coSEn(disordered)
  #expect(cDisordered > cOrdered)
  #expect(cOrdered.isFinite && cDisordered.isFinite)
}

@Test func sampEnZeroGuards() {
  #expect(RhythmFeatures.sampEn([800, 810], m: 2, r: 5) == 0)   // too short
  #expect(RhythmFeatures.coSEn([800, 810, 805]) == 0)           // < 12 beats
}
