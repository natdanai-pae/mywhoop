import Testing
import Foundation
@testable import WhoopCore

@Test func baselineReadinessGate() {
  var b = RollingBaseline(alpha: 0.25)
  for v in [50.0, 52, 48, 51, 49, 53] { b.update(v) }    // 6 obs
  #expect(b.ready == false)
  #expect(b.z(60) == nil)                                  // gray-out before ≥7
  b.update(47)                                             // 7th
  #expect(b.ready == true)
  #expect(b.z(60) != nil)                                  // now surfaces
}

@Test func baselineConstantHasZeroSD() {
  var b = RollingBaseline(alpha: 0.25)
  for _ in 0..<10 { b.update(50) }
  #expect(abs(b.mean - 50) < 1e-9)
  #expect(b.sd < 1e-9)
  #expect(b.z(50) == nil)                                  // sd==0 → nil, no divide-by-zero
}

@Test func measuredHRmaxOverridesTanaka() {
  var p = CalibrationParams()
  #expect(abs(p.hrMax(age: 25) - 190.5) < 1e-9)            // Tanaka fallback
  p.measuredHRmax = 195
  #expect(p.hrMax(age: 25) == 195)                         // measured wins
}

@Test func persistedStateCodableRoundTrip() throws {
  var s = PersistedState()
  for v in [50.0, 52, 48, 51, 49, 53, 47] { s.hrvBaseline.update(v) }
  s.params.strainTau = 153.4
  s.params.measuredHRmax = 192
  let data = try JSONEncoder().encode(s)
  let back = try JSONDecoder().decode(PersistedState.self, from: data)
  #expect(back == s)
}
