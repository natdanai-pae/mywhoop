import Testing
import Foundation
@testable import GenieMax

// 8 calm baseline days, then a day with RHR up + temp up + HRV down → 2-signal alert.
private func days(rhrLast: Double, lnLast: Double, tempLast: Double) -> [DailyRecord] {
  var d: [DailyRecord] = []
  for i in 0..<8 {                                  // small day-to-day variance so baseline SD > 0
    d.append(DailyRecord(date: String(format: "d%02d", i), rhr: 54 + Double(i % 3),
                         lnRMSSD: log(53 + Double(i % 4)), resp: 13.5 + Double(i % 2) * 0.5,
                         skinTemp: 33.2 + Double(i % 3) * 0.1))
  }
  d.append(DailyRecord(date: "d99", rhr: rhrLast, lnRMSSD: lnLast, resp: 14, skinTemp: tempLast))
  return d
}

@Test func healthContextIllnessTwoSignal() {
  let r = HealthContext.read(days(rhrLast: 65, lnLast: log(35), tempLast: 34.6), thai: false)
  #expect(r?.status == 2)                       // RHR up + HRV down + temp up = alert
}

@Test func healthContextAligned() {
  let r = HealthContext.read(days(rhrLast: 55, lnLast: log(55), tempLast: 33.3), thai: false)
  #expect(r?.status == 0)                       // everything near baseline
}

@Test func healthContextNeedsBaseline() {
  let few = [DailyRecord(date: "d0", rhr: 55, lnRMSSD: log(55))]
  #expect(HealthContext.read(few, thai: false) == nil)   // <7 prior points → no judgment
}

@Test func chartReadingLiveWindow() {
  let r = ChartNarrator.read([70, 72, 74, 80, 90, 88], higherBetter: nil, thai: false, unit: .live, metricKey: "hr")
  #expect(r.window.contains("min"))             // live window expressed in minutes
  #expect(r.signal.contains("Heart rate"))
}
