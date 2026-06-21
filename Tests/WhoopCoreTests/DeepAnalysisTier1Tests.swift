import Testing
import Foundation
@testable import WhoopCore

// (1) SWC gating: within ±0.5 SD reads as "normal range", beyond is above/below.
@Test func swcGating() {
  #expect(Analysis.zlabel(0.3, false) == "within your normal range")   // inside SWC = noise
  #expect(Analysis.zlabel(0.8, false) == "above")
  #expect(Analysis.zlabel(-1.8, false) == "well below")
  #expect(Analysis.withinSWC(0.4) && !Analysis.withinSWC(0.6))
}

// (3) Contributor decomposition: HRV up + RHR up → HRV lifts (+), RHR drags (−).
@Test func recoveryContributors() {
  var s = PersistedState()
  for i in 0..<10 {                                   // baselines w/ variance (sd>0) around RHR ~54 / HRV ~ln(50) / sleep ~80
    s.hrvBaseline.update(log(48 + Double(i % 5)))
    s.rhrBaseline.update(53 + Double(i % 4))
    s.sleepBaseline.update(78 + Double(i % 5))
    s.respBaseline.update(13.5 + Double(i % 2) * 0.5)
  }
  let r = DailyRecord(date: "d", rhr: 62, lnRMSSD: log(62), resp: 14, sleepScore: 80)
  let c = RecoveryEngine.contributors(r, state: s)
  #expect(c != nil)
  let hrv = c!.first { $0.key == "HRV" }!, rhr = c!.first { $0.key == "RHR" }!
  #expect(hrv.weighted > 0)                            // HRV above baseline → boosts
  #expect(rhr.weighted < 0)                            // RHR above baseline → drags
}
