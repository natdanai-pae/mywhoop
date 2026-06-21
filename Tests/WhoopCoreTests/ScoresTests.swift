import Testing
import Foundation
@testable import WhoopCore

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@Test func phiGolden() {
  #expect(approx(Scores.phi(0), 0.5, 1e-12))
  #expect(approx(Scores.phi(1), 0.8413447461, 1e-9))
}

@Test func recoveryComposite() {
  // zHRV=1,zSleep=1,zRHR=-1,zRR=-1 → S=0.55+0.20+0.10+0.15=1.0 → 100·Φ(1)=84.1345
  #expect(approx(Scores.recovery(zHRV: 1, zRHR: -1, zRR: -1, zSleep: 1), 84.134475, 1e-4))
  #expect(approx(Scores.recovery(zHRV: 0, zRHR: 0, zRR: 0, zSleep: 0), 50, 1e-9))
}

@Test func recoveryCompositeUsesCustomWeights() {
  #expect(approx(Scores.recovery(zHRV: 1, zRHR: 1, zRR: 1, zSleep: 1, weights: [1, 0, 0, 0]), 84.134475, 1e-4))
  #expect(approx(Scores.recovery(zHRV: 1, zRHR: 1, zRR: 1, zSleep: 1, weights: [0, 1, 0, 0]), 15.865525, 1e-4))
}

@Test func recoveryEngineProcessUsesTunedWeights() {
  var s = PersistedState()
  for i in 0..<10 {
    s.hrvBaseline.update(log(48 + Double(i % 5)))
    s.rhrBaseline.update(53 + Double(i % 4))
    s.respBaseline.update(13.5 + Double(i % 2) * 0.5)
    s.sleepBaseline.update(78 + Double(i % 5))
  }
  s.params.recoveryWeights = [0, 0, 0, 1]
  let zh = s.hrvBaseline.z(log(70))!
  let zr = s.rhrBaseline.z(62)!
  let zrr = s.respBaseline.z(14)!
  let zs = s.sleepBaseline.z(90)!
  let expected = Scores.recovery(zHRV: zh, zRHR: zr, zRR: zrr, zSleep: zs, weights: s.params.recoveryWeights)
  let result = RecoveryEngine.process(hrv: 70, rhr: 62, resp: 14, sleepScore: 90, state: &s)
  #expect(result.recovery != nil)
  #expect(approx(result.recovery!, expected, 1e-9))
}

@Test func strainAndTauCalibration() {
  let tau = Scores.calibrateTau(whoopStrain: 12, trimp: 130)
  #expect(approx(tau, 153.428925, 1e-4))
  #expect(approx(Scores.strain(trimp: 130, tau: tau), 12.0, 1e-6))
}

@Test func performanceModelCTLATLTSB() {
  let r = Scores.performanceModel(dailyLoads: [0.9, 3.3])
  #expect(approx(r[1].ctl, 0.0983206927))
  #expect(approx(r[1].atl, 0.5431634768))
  #expect(approx(r[1].tsb, -0.4448427841))
}

@Test func acwrGuardAndRatio() {
  #expect(Scores.acwr(acute: 10, chronic: 0) == nil)
  #expect(approx(Scores.acwr(acute: 12, chronic: 10)!, 1.2))
}

@Test func readinessWeightsAndBounds() {
  #expect(approx(Scores.readiness(recovery: 80, sleepScore: 80, tsbNorm: 50), 74)) // 40+24+10
  #expect(Scores.readiness(recovery: 100, sleepScore: 100, tsbNorm: 100, illnessPenalty: 0) <= 100)
  #expect(Scores.readiness(recovery: 0, sleepScore: 0, tsbNorm: 0, illnessPenalty: 50) >= 0)
}
