import Testing
import Foundation
@testable import WhoopCore

// (4) Resilience: consistent high recovery → high level; needs ≥5 days.
@Test func resilienceHighWhenConsistent() {
  var h = DailyHistory()
  for i in 0..<10 { h.upsert(DailyRecord(date: String(format: "d%02d", i), sleepScore: 85, recovery: 80 + Double(i % 3))) }
  let r = DailyMetricsEngine.resilience(h)
  #expect(r != nil)
  #expect(r!.0 >= 65)                          // strong/exceptional
  #expect(["Exceptional", "Strong", "Solid"].contains(r!.1))
}

@Test func resilienceNeedsFiveDays() {
  var h = DailyHistory()
  for i in 0..<3 { h.upsert(DailyRecord(date: "d\(i)", recovery: 70)) }
  #expect(DailyMetricsEngine.resilience(h) == nil)
}

// (5) Recovery Index: HR drops to its low early → high score; flat-high HR → settles late/low score.
@Test func recoveryIndexEarlyStabilization() {
  var rows: [SleepSample] = []
  for i in 0..<120 {                            // HR drops to ~50 within ~10 min, stays low
    let hr = i < 10 ? 70.0 - Double(i) * 2 : 50.0 + Double(i % 3)
    rows.append(SleepSample(ts: Double(i) * 60, hr: hr, hrv: nil, motion: 0.01, resp: 14, temp: 33))
  }
  let ri = SleepStaging.recoveryIndex(rows)
  #expect(ri != nil)
  #expect(ri!.score >= 80)                      // settled early → high
  #expect(ri!.h < 1.0)
}

// Robustness: a real night settles ~52±2 bpm but has ONE spurious-low artifact minute (42) + a couple of brief
// arousal blips. The old raw-min reference made trough=42 → band too tight → nil. The percentile/tolerant version
// must still detect the stabilization.
@Test func recoveryIndexRobustToOutlierLowAndBlips() {
  var rows: [SleepSample] = []
  for i in 0..<180 {
    var hr = i < 12 ? 72.0 - Double(i) * 2 : 52.0 + Double(i % 3)   // wind-down then settle ~52–54
    if i == 40 { hr = 42 }                       // single spurious-low artifact (BLE glitch)
    if i == 70 || i == 71 { hr = 60 }            // brief arousal blip
    rows.append(SleepSample(ts: Double(i) * 60, hr: hr, hrv: nil, motion: 0.01, resp: 14, temp: 33))
  }
  let ri = SleepStaging.recoveryIndex(rows)
  #expect(ri != nil)                             // would be nil under the old raw-min + strict-consecutive rule
  #expect(ri!.h < 1.5)
}
