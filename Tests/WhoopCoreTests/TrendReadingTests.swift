import Testing
import Foundation
@testable import WhoopCore

@Test func chartReadingTooShort() {
  #expect(ChartNarrator.read([1, 2], higherBetter: true, thai: false).good.isEmpty)
}

@Test func chartReadingRisingFavorable() {
  let r = ChartNarrator.read([40, 44, 48, 52, 56, 60], higherBetter: true, thai: false)  // HRV climbing
  #expect(r.headline.contains("↗"))
  #expect(!r.good.isEmpty)            // favorable rise → a good point
}

@Test func chartReadingRisingUnfavorable() {
  let r = ChartNarrator.read([52, 54, 57, 60, 63, 66], higherBetter: false, thai: false) // RHR climbing = bad
  #expect(!r.improve.isEmpty)
}

@Test func chartReadingSwingingFlagsConsistency() {
  let r = ChartNarrator.read([50, 90, 45, 95, 40, 92], higherBetter: nil, thai: false)
  #expect(!r.improve.isEmpty)
}

@Test func chartReadingThai() {
  let r = ChartNarrator.read([40, 44, 48, 52, 56, 60], higherBetter: true, thai: true, metricKey: "hrv")
  #expect(r.window.contains("วัน"))          // lookback window stated in Thai
  #expect(!r.signal.isEmpty)                  // health-indicator meaning present
  #expect(!r.shows.isEmpty)                   // "what the picture shows" bullets present
}

@Test func chartReadingDeepFields() {
  let r = ChartNarrator.read([40, 44, 48, 52, 56, 60], higherBetter: true, thai: false, unit: .day, metricKey: "hrv")
  #expect(r.window.contains("days"))          // window expressed in days
  #expect(r.signal.contains("HRV"))           // metric-specific signal
  #expect(!r.recommendation.isEmpty)          // actionable recommendation
  #expect(r.shows.count >= 3)                 // variability + latest-vs-avg + range
}
