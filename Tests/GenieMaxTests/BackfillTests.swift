import Testing
import Foundation
@testable import GenieMax

@Test func backfillAggregatesByDayWithStrainAndRHR() {
  let utc = TimeZone(identifier: "UTC")!
  let day1 = 1_748_822_400.0          // exact UTC midnight (1748822400 / 86400 = 20241)
  var rows = [Backfill.HistRow]()
  // day 1: 30 min sleeping (HR 50) then 30 min active (HR 120)
  for i in 0..<60 { rows.append(.init(ts: day1 + Double(i) * 60, hr: i < 30 ? 50 : 120, temp: 34.0, resp: 14)) }
  // day 2: quiet (HR 55)
  for i in 0..<60 { rows.append(.init(ts: day1 + 86400 + Double(i) * 60, hr: 55, temp: 34.2, resp: 15)) }

  let recs = Backfill.aggregate(rows, hrMax: 190, hrRest: 50, tau: 100, tz: utc)
  #expect(recs.count == 2)
  #expect(recs[0].date < recs[1].date)                 // sorted
  #expect(recs[0].dayStrain > 0)                       // active block produces strain
  #expect(recs[1].dayStrain < recs[0].dayStrain)       // quiet day < active day
  #expect(recs[0].rhr != nil && recs[0].rhr! <= 55)    // sleeping trough
  #expect(recs[0].rhrSource == nil)                     // test rows have no source unless provided
  #expect(recs[0].skinTemp == 34.0)                    // median temp
  #expect(recs.allSatisfy { $0.resp == nil })           // K18 resp is candidate-only by default
  #expect(recs.allSatisfy { $0.lnRMSSD == nil })       // no HRV from k18 history

  let candidateResp = Backfill.aggregate(rows, hrMax: 190, hrRest: 50, tau: 100, tz: utc,
                                         includeCandidateResp: true)
  #expect(candidateResp[0].resp == 14)
}

@Test func backfillEmptyIsEmpty() {
  #expect(Backfill.aggregate([], hrMax: 190, hrRest: 50, tau: 100).isEmpty)
}

@Test func backfillAggregateUsesSexSpecificTRIMP() {
  let utc = TimeZone(identifier: "UTC")!
  let day = 1_748_822_400.0
  let rows = (0..<30).map {
    Backfill.HistRow(ts: day + Double($0) * 60, hr: 150, temp: nil, resp: nil)
  }
  let male = Backfill.aggregate(rows, hrMax: 190, hrRest: 50, tau: 100, tz: utc, male: true)
  let female = Backfill.aggregate(rows, hrMax: 190, hrRest: 50, tau: 100, tz: utc, male: false)
  #expect(female.first!.dayStrain > male.first!.dayStrain)
}

@Test func flashSleepSamplesReconstructNightWithoutMotion() {
  // 16 h of flash HR (no motion) with an ~8 h low-HR night → HR-proxy lets the motion-pipeline detect sleep.
  let base = 1_700_000_000.0
  var rows = [Backfill.HistRow]()
  for s in stride(from: 0, to: 16 * 3600, by: 2) {
    let night = s > 3 * 3600 && s < 11 * 3600
    rows.append(.init(ts: base + Double(s), hr: night ? 52 + Double(s % 4) : 76, temp: 34, resp: 14,
      hrSource: "k18_candidate_hr"))
  }
  let samples = Backfill.sleepSamples(rows)
  #expect(samples.count > 120)
  #expect(samples.allSatisfy { $0.hrv == nil })          // flash has no HRV
  #expect(samples.allSatisfy { $0.hrSource == "k18_candidate_hr" })
  #expect(samples.allSatisfy { $0.resp == nil })         // K18 resp is not promoted by default
  #expect(Backfill.sleepSamples(rows, includeCandidateResp: true).contains { $0.resp != nil })
  let sleep = SleepStaging.stage(samples)
  #expect(sleep.ok)
  #expect(sleep.tstH > 3 && sleep.tstH < 12)             // finds the ~8 h block, not all 16 h
}

// P2/P5 guarantee (real two-strap case): once the evening is excluded by the circadian window, the non-active
// strap's flash night is downsampled (~1 sample / 8 min ≈ 7.5/hr). That's below the 120-sample staging floor →
// `sleepSamples` returns [] → SleepStaging produces NO night → "not captured", never a bogus 13-16 h "sleep".
@Test func sparseFlashNightYieldsNoStageableSleep() {
  let base = 1_700_000_000.0
  let rows = stride(from: 0, to: 8 * 3600, by: 8 * 60).map {   // every 8 min over 8 h ≈ 60 samples
    Backfill.HistRow(ts: base + Double($0), hr: 54, temp: 34, resp: nil, hrSource: "flash")
  }
  let samples = Backfill.sleepSamples(rows)
  #expect(samples.count < 120)                           // sparse → below the staging floor
  #expect(!SleepStaging.stage(samples).ok)               // → no stageable (garbage) night
}

@Test func backfillPreservesK18HRSourceInDailyRecord() {
  let utc = TimeZone(identifier: "UTC")!
  let day = 1_748_822_400.0
  let rows = (0..<10).map {
    Backfill.HistRow(ts: day + Double($0) * 60, hr: 55, temp: 34, resp: 14,
      hrSource: "k18_candidate_hr")
  }
  let recs = Backfill.aggregate(rows, hrMax: 190, hrRest: 50, tau: 100, tz: utc)
  #expect(recs.first?.rhrSource == "k18_candidate_hr")
  #expect(recs.first?.hrvSource == nil)
}
