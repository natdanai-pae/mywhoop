import Testing
import Foundation
@testable import WhoopCore

private func ppgGolden() throws -> ([Double], [String: Any]) {
  let url = Bundle.module.url(forResource: "ppg_golden", withExtension: "json", subdirectory: "Fixtures")!
  let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  let ppg = (j["ppg"] as! [Any]).map { ($0 as! NSNumber).doubleValue }
  return (ppg, j["expect"] as! [String: Any])
}

@Test func ppgHRVMatchesGolden() throws {
  let (ppg, exp) = try ppgGolden()
  let r = PPGHRV.compute(ppg, accelRms: 0.0)
  #expect(r.ppgHR == exp["ppg_hr"] as! Int)              // 80 (robust integer)
  #expect(abs((r.rmssd ?? -99) - (exp["ppg_hrv_rmssd"] as! Double)) < 0.2)
  #expect(r.quality == exp["ppg_hrv_q"] as! Int)         // 100
}

@Test func ppgHRVMotionGatesHRV() throws {
  let (ppg, exp) = try ppgGolden()
  let r = PPGHRV.compute(ppg, accelRms: 0.10)            // high motion → HRV suppressed, HR still ok
  #expect(r.ppgHR == exp["ppg_hr"] as! Int)
  #expect(r.rmssd == nil)
}

@Test func ppgHRVTooShortReturnsNil() {
  #expect(PPGHRV.compute(Array(repeating: 1000, count: 100), accelRms: 0.0).ppgHR == nil)
}
