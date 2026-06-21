import Testing
import Foundation
@testable import WhoopCore

/// C7 — end-to-end replay parity on REAL Firebase history (7954 rows, the actual collected data).
/// Streams it through WhoopCore and asserts the same numbers the JS dashboard reference produced
/// (a reference exporter). Proves the whole chain on real data, not synthetic.
@Test func replayParityOnRealFirebaseData() throws {
  let url = Bundle.module.url(forResource: "replay_golden", withExtension: "json", subdirectory: "Fixtures")!
  let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]

  // — sleep staging on the real overnight window —
  let rowsJSON = j["rows"] as! [[String: Any]]
  let rows = rowsJSON.map { r in
    SleepSample(ts: (r["ts"] as! NSNumber).doubleValue,
                hr: (r["hr"] as? NSNumber)?.doubleValue,
                hrv: (r["hrv"] as? NSNumber)?.doubleValue,
                motion: (r["motion"] as? NSNumber)?.doubleValue ?? 0,
                resp: (r["respiratory"] as? NSNumber)?.doubleValue,
                temp: (r["skin_temp"] as? NSNumber)?.doubleValue)
  }
  let exp = j["sleep"] as! [String: Any]
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.nEp == exp["nEp"] as! Int)                       // window detection exact on real data
  func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 3 }  // sort tie-break tolerance
  #expect(near(s.deep, exp["deep"] as! Int))
  #expect(near(s.rem, exp["rem"] as! Int))
  #expect(near(s.light, exp["light"] as! Int))
  #expect(near(s.wake, exp["wake"] as! Int))
  #expect(abs(s.eff - (exp["eff"] as! Int)) <= 1)
  #expect(s.deep + s.rem + s.light + s.wake == s.nEp)

  // — CTL/ATL/TSB on the real daily strain —
  let loads = (j["dailyStrain"] as! [Any]).map { ($0 as! NSNumber).doubleValue }
  let expLoad = j["load"] as! [String: Any]
  let model = Scores.performanceModel(dailyLoads: loads)
  let last = model.last!
  #expect(abs(last.ctl - (expLoad["ctl"] as! Double)) < 1e-6)
  #expect(abs(last.atl - (expLoad["atl"] as! Double)) < 1e-6)
  #expect(abs(last.tsb - (expLoad["tsb"] as! Double)) < 1e-6)
}
