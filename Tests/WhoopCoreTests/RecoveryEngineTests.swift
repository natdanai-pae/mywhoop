import Testing
import Foundation
@testable import WhoopCore

@Test func recoveryWarmsUpThenReady() {
  var s = PersistedState()
  // varied warm-up nights (need variance so SD>0) — HRV ~50, RHR ~55
  let hrvs = [45.0, 52, 48, 55, 50, 47, 53]
  let rhrs = [56.0, 54, 57, 53, 55, 58, 52]
  var lastReady = false
  for i in 0..<7 {
    let r = RecoveryEngine.process(hrv: hrvs[i], rhr: rhrs[i], resp: nil, sleepScore: nil, state: &s)
    lastReady = r.ready
  }
  // first 7 calls compute z against <7-obs baseline → not ready
  #expect(lastReady == false)
  // 8th call: baseline now has 7 obs → ready
  let r8 = RecoveryEngine.process(hrv: 50, rhr: 55, resp: nil, sleepScore: nil, state: &s)
  #expect(r8.ready)
  #expect(r8.recovery != nil)
}

@Test func goodNightBeatsBadNight() {
  func warmed() -> PersistedState {
    var s = PersistedState()
    let hrvs = [45.0, 52, 48, 55, 50, 47, 53], rhrs = [56.0, 54, 57, 53, 55, 58, 52]
    for i in 0..<7 { _ = RecoveryEngine.process(hrv: hrvs[i], rhr: rhrs[i], resp: nil, sleepScore: nil, state: &s) }
    return s
  }
  var sGood = warmed(), sBad = warmed()
  // good: high HRV, low RHR vs baseline(~50/~55) → recovery up
  let good = RecoveryEngine.process(hrv: 70, rhr: 49, resp: nil, sleepScore: nil, state: &sGood)
  // bad: low HRV, high RHR → recovery down
  let bad = RecoveryEngine.process(hrv: 32, rhr: 64, resp: nil, sleepScore: nil, state: &sBad)
  #expect(good.recovery! > bad.recovery!)
  #expect(good.recovery! > 50)     // above personal average
  #expect(bad.recovery! < 50)      // below
}

@Test func persistedStateWithNewBaselinesCodable() throws {
  var s = PersistedState()
  _ = RecoveryEngine.process(hrv: 50, rhr: 55, resp: 14, sleepScore: 80, state: &s)
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back == s)
}
