import Testing
import Foundation
@testable import WhoopCore

@Test func sleepStagingMatchesGolden() throws {
  let url = Bundle.module.url(forResource: "sleep_golden", withExtension: "json", subdirectory: "Fixtures")!
  let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  let rowsJSON = j["rows"] as! [[String: Any]]
  let exp = j["expect"] as! [String: Any]
  let rows = rowsJSON.map { r in
    SleepSample(ts: (r["ts"] as! NSNumber).doubleValue,
                hr: (r["hr"] as? NSNumber)?.doubleValue,
                hrv: (r["hrv"] as? NSNumber)?.doubleValue,
                motion: (r["motion"] as! NSNumber).doubleValue,
                resp: (r["respiratory"] as? NSNumber)?.doubleValue,
                temp: (r["skin_temp"] as? NSNumber)?.doubleValue)
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.nEp == exp["nEp"] as! Int)                          // window detection exact
  // rank-allocation tie-breaking can differ JS↔Swift sort → allow ±2 epochs per stage
  func near(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 2 }
  #expect(near(s.deep, exp["deep"] as! Int))
  #expect(near(s.rem, exp["rem"] as! Int))
  #expect(near(s.light, exp["light"] as! Int))
  #expect(near(s.wake, exp["wake"] as! Int))
  #expect(s.deep + s.rem + s.light + s.wake == s.nEp)           // partition is complete
  // hypnogram track present, downsampled ≤120, codes in 0...3
  #expect(!s.hypnogram.isEmpty && s.hypnogram.count <= 120)
  #expect(s.hypnogram.allSatisfy { (0...3).contains($0) })
  // AASM structural sanity on the golden night
  let pc = { (x: Int) in Double(x) / Double(s.nEp) * 100 }
  #expect(pc(s.deep) >= 10 && pc(s.deep) <= 25)
  #expect(pc(s.rem) >= 18 && pc(s.rem) <= 28)
}

@Test func hypnogramHRTrackAligns() {
  // P2: the HR overlay track is sampled at the same stride as the hypnogram → 1:1, gap-free, physiological.
  var rows = [SleepSample]()
  for i in 0..<420 {
    let asleep = i > 10 && i < 400
    rows.append(SleepSample(ts: Double(i * 60), hr: asleep ? 50 + Double(i % 6) : 72,
      hrv: nil, motion: asleep ? 0.0 : 0.3, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.hrTrack.count == s.hypnogram.count)        // aligned 1:1 with the stage track
  #expect(s.hrTrack.allSatisfy { $0 > 30 && $0 < 120 }) // forward-fill leaves no 0/nil hole, values physiological
  // Phase A: clock anchor present — start ts inside the data, epoch span ≥ 1 min, hypnogram spans ~the window
  #expect(s.hypnoStartTs != nil && s.hypnoStartTs! >= 0 && s.hypnoStartTs! < 420 * 60)
  #expect(s.hypnoEpochSec >= 60)
}

@Test func sleepStagingPreservesRHRAndHRVSources() {
  var rows = [SleepSample]()
  for i in 0..<420 {
    let asleep = i > 10 && i < 400
    rows.append(SleepSample(ts: Double(i * 60),
      hr: asleep ? 52 + Double(i % 5) : 72,
      hrv: asleep ? 48 + Double(i % 4) : nil,
      motion: asleep ? 0.0 : 0.3,
      resp: 14,
      temp: 34,
      hrSource: "standard_hr",
      hrvSource: asleep ? "rr" : nil,
      hrvQuality: asleep ? 83 : nil))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.rhrSource == "standard_hr")
  #expect(s.sleepHRVSource == "rr")
  #expect(s.sleepHRVQuality == 83)
}

@Test func stagesSaveEvenWithoutHRV() {
  // a full night of HR + motion but NO HRV (RR didn't flow) → staging still OK + a sleep score/stages,
  // even though Recovery can't compute. (Regression guard for the finalize decoupling.)
  var rows = [SleepSample]()
  for i in 0..<420 {                                   // 7h, one sample/min
    let asleep = i > 10 && i < 400
    rows.append(SleepSample(ts: Double(i * 60), hr: asleep ? 52 + Double(i % 5) : 70,
      hrv: nil, motion: asleep ? 0.0 : 0.3, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.sleepScore != nil)
  #expect(s.sleepHRV == nil)                           // no HRV available
  #expect(!s.partial)                                  // a clean contiguous night is NOT a gap-truncated fragment
  // time-in-bed window (for the bedtime→wake clock) is set and is ≥ the asleep total → clock agrees with duration
  #expect(s.winStartTs != nil && s.winEndTs != nil)
  if let a = s.winStartTs, let b = s.winEndTs { #expect(b > a && (b - a) / 3600 >= s.tstH - 0.05) }
  #expect(s.deep + s.rem + s.light + s.wake == s.nEp)
  // Recovery can't be produced without HRV → nil, but the sleep itself is usable.
  var st = PersistedState()
  #expect(RecoveryEngine.processNight(s, state: &st) == nil)
}

@Test func pass2HRRefinementTrimsStillButAwake() {
  // 30 min lying still but HR elevated (awake in bed) before真sleep → actigraphy counts it as sleep,
  // HR-refinement (pass 2) should trim it: refined TST < actigraphy TST, onset trimmed.
  var rows = [SleepSample]()
  for i in 0..<420 {
    let edge = i <= 10 || i >= 401          // moving (awake)
    let preSleep = i > 10 && i <= 40        // still but HR high (awake in bed)
    let hr: Double = edge ? 70 : (preSleep ? 72 : 53 + Double(i % 4))
    rows.append(SleepSample(ts: Double(i * 60), hr: hr, hrv: nil,
      motion: edge ? 0.3 : 0.0, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.tstRefinedH < s.tstH)           // HR-refined removes still-but-awake → less sleep
  #expect(s.onsetTrimMin > 0)               // onset pushed later
  #expect(s.effRefined <= s.eff)
}

@Test func onsetExcludesPreSleepWorkout() {
  // Buffer BEGINS with a 60-min workout (high motion + high HR) then a real night. The detected sleep
  // onset must land at the sleep start, NOT the buffer start — regression for the IMU batch-peak motion
  // fix + absolute onsetTs exposure (previously a pre-sleep workout was swallowed into "sleep onset").
  var rows = [SleepSample]()
  let base = 1_000_000.0
  for i in 0..<480 {
    let workout = i < 60                                   // first hour: exercising
    let hr: Double = workout ? 145 : (i < 70 ? 75 : 52 + Double(i % 4))
    let mot: Double = workout ? 0.6 : (i >= 470 ? 0.3 : 0.0)
    rows.append(SleepSample(ts: base + Double(i * 60), hr: hr, hrv: nil, motion: mot, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.onsetTs != nil)
  if let on = s.onsetTs { #expect(on - base >= 30 * 60) }   // onset ≥30 min after buffer start → workout excluded
}

@Test func gapTruncatedNightSplitsAndFlagsPartial() {
  // A 4-h night fragment, then the strap stops streaming (a multi-hour data hole), then a little awake wear.
  // The hole must NOT be merged into the sleep block (the merge produced a bogus far-too-early "onset" when a
  // rolling buffer lost hours mid-stream), and the fragment must be flagged `partial` so the UI warns instead
  // of presenting it as a confident full night.
  var rows = [SleepSample]()
  for i in 0..<240 {                                     // 4 h asleep (low motion, low HR)
    rows.append(SleepSample(ts: Double(i * 60), hr: 52 + Double(i % 4), hrv: nil, motion: 0.0, resp: 14, temp: 34))
  }
  let resume = Double(240 * 60) + 11 * 3600              // ~11 h gap with no samples at all
  for i in 0..<40 {                                      // awake wear after the gap (high motion)
    rows.append(SleepSample(ts: resume + Double(i * 60), hr: 72, hrv: nil, motion: 0.3, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  #expect(s.partial)                                    // gap-truncated fragment → flagged
  #expect(s.tibH <= 5)                                  // only the ~4 h fragment, NOT merged across the hole
  if let on = s.onsetTs { #expect(on < resume) }        // onset stays in the night fragment, not after the hole
}

@Test func trailingMorningDozeTrimmedFromMainSleep() {
  // Main sleep, then a ~9-min awakening (merged as WASO since the gap ≤10), then a ~40-min morning doze. The night
  // must END at the real morning wake (end of main sleep), NOT extend through the doze (it shows as a nap instead).
  var rows = [SleepSample]()
  for i in 0..<441 {
    let mainSleep = i >= 11 && i <= 380      // ~6.15 h main sleep
    let doze = i >= 390 && i <= 430          // ~40-min doze, 9-min wake gap (381..389) before it
    let asleep = mainSleep || doze
    rows.append(SleepSample(ts: Double(i * 60), hr: asleep ? 52 + Double(i % 4) : 72,
      hrv: nil, motion: asleep ? 0.0 : 0.3, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  // wake (winEndTs) lands at the end of the MAIN sleep (~epoch 380), NOT the doze end (~epoch 430)
  if let we = s.winEndTs { #expect(we < 410 * 60 && we > 340 * 60) }
}

@Test func trailingMorningLieInTrimmed() {
  // Real-night shape: ~6 h main sleep, ~9-min wake, then a long ~1h40m morning LIE-IN (still + low HR). The lie-in
  // exceeds any short-doze cap, so a RATIO rule (bout ≪ main sleep before it) is what trims it. Wake = end of main.
  var rows = [SleepSample]()
  for i in 0..<560 {
    let mainSleep = i >= 11 && i <= 372     // ~6 h main sleep, ends ~epoch 372
    let lieIn = i >= 382 && i <= 482        // ~1h40m lie-in after a ~9-min wake (373..381)
    let asleep = mainSleep || lieIn
    rows.append(SleepSample(ts: Double(i * 60), hr: asleep ? 52 + Double(i % 4) : 74,
      hrv: nil, motion: asleep ? 0.0 : 0.3, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  if let we = s.winEndTs { #expect(we < 400 * 60 && we > 350 * 60) }   // ~main wake (372), NOT the lie-in end (482)
}

@Test func midNightWASODoesNotTrim() {
  // Guard: a brief mid-night stir with a comparable second sleep block must NOT be trimmed (the following bout is
  // ~as long as the first → ratio rule leaves it intact; the whole night is kept). Keep the wake short so the
  // Cole-Kripke window doesn't widen it past the 10-epoch block-merge limit (that would split the night upstream).
  var rows = [SleepSample]()
  for i in 0..<470 {
    let first = i >= 11 && i <= 230        // ~3.6 h
    let second = i >= 234 && i <= 450      // ~3.6 h after a brief ~3-min stir (231..233)
    let asleep = first || second
    rows.append(SleepSample(ts: Double(i * 60), hr: asleep ? 52 + Double(i % 4) : 74,
      hrv: nil, motion: asleep ? 0.0 : 0.3, resp: 14, temp: 34))
  }
  let s = SleepStaging.stage(rows)
  #expect(s.ok)
  if let we = s.winEndTs { #expect(we > 430 * 60) }   // wake stays near the SECOND block's end (~450), night intact
}

@Test func sleepStagingRejectsShortData() {
  let rows = (0..<50).map { SleepSample(ts: Double($0 * 30), hr: 60, hrv: 50, motion: 0.01, resp: 14, temp: 34) }
  #expect(SleepStaging.stage(rows).ok == false)
}

// s#7 p14c ("นอนหลายรอบ"): a ~25-min mid-night awakening (a bathroom trip) between two comparable sleep blocks.
// With the DEFAULT 10-min WASO-merge the >10-min wake run SPLITS the night → staging keeps only the first block
// (truncation — exactly the symptom the user saw). With the night-finalize `wasoMergeMin: 60`, the awakening stays
// a Wake band INSIDE one night → the whole night is staged, the hypnogram carries Wake, and it counts as 1 awakening.
@Test func midNightAwakeningStaysInOneNightWithLargerWASOMerge() {
  var rows = [SleepSample]()
  for i in 0..<482 {
    let onsetWake = i <= 10                      // onset latency (moving)
    let bathroom  = i >= 231 && i <= 255         // ~25-min mid-night awakening
    let finalWake = i >= 471                      // morning wake (moving)
    let awake = onsetWake || bathroom || finalWake
    rows.append(SleepSample(ts: Double(i * 60), hr: awake ? 74 : 52 + Double(i % 4),
      hrv: nil, motion: awake ? 0.3 : 0.0, resp: 14, temp: 34))
  }
  // default: >10-min wake splits the block → the night is truncated at the first block (~epoch 230)
  let def = SleepStaging.stage(rows)
  #expect(def.ok)
  if let we = def.winEndTs { #expect(we < 256 * 60) }            // truncated before the second sleep

  // wasoMergeMin 60: one night spanning both blocks, awakening kept as Wake
  let merged = SleepStaging.stage(rows, wasoMergeMin: 60)
  #expect(merged.ok)
  if let we = merged.winEndTs { #expect(we > 440 * 60) }         // whole night kept (wake near the SECOND block end)
  #expect(merged.wake >= 15)                                     // the ~25-min bathroom counts as Wake within the night
  #expect(merged.hypnogram.contains(3))                          // hypnogram carries the Wake band → SleepArchitecture.awakenings ≥ 1 → "นอน 2 รอบ"
}

// s#7 p14c — the anti-premature-finalize "seal" gate: a sustained morning wake confirms a get-up; a brief
// mid-night arousal (bathroom trip back to sleep) does NOT, so the night isn't sealed+truncated at 4 am.
@Test func sustainedWakeDistinguishesGetUpFromArousal() {
  let floor = 50.0                                   // floor + 8 = 58 bpm cutoff
  #expect(SleepStaging.isSustainedWake(recentHR: Array(repeating: 64, count: 25), floor: floor))     // up the whole 25 min
  let arousal = Array(repeating: 64.0, count: 10) + Array(repeating: 50.0, count: 15)                 // ~10 min up, back to floor
  #expect(!SleepStaging.isSustainedWake(recentHR: arousal, floor: floor))
  #expect(!SleepStaging.isSustainedWake(recentHR: Array(repeating: 64, count: 10), floor: floor))     // too few (BLE churn)
  #expect(!SleepStaging.isSustainedWake(recentHR: Array(repeating: 55, count: 25), floor: floor))     // below the cutoff = asleep
}

/// Shared loader for the golden night.
private func goldenSleepRows() throws -> [SleepSample] {
  let url = Bundle.module.url(forResource: "sleep_golden", withExtension: "json", subdirectory: "Fixtures")!
  let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
  return (j["rows"] as! [[String: Any]]).map { r in
    SleepSample(ts: (r["ts"] as! NSNumber).doubleValue, hr: (r["hr"] as? NSNumber)?.doubleValue,
                hrv: (r["hrv"] as? NSNumber)?.doubleValue, motion: (r["motion"] as! NSNumber).doubleValue,
                resp: (r["respiratory"] as? NSNumber)?.doubleValue, temp: (r["skin_temp"] as? NSNumber)?.doubleValue)
  }
}

@Test func sleepWindowVitalsArePhysiological() throws {
  let s = SleepStaging.stage(try goldenSleepRows())
  #expect(s.ok)
  // RHR = min 5-min moving-avg sleeping HR → a low value, ≤ the night's mean HR (~62)
  #expect(s.rhr != nil); if let r = s.rhr { #expect(r >= 45 && r <= 62) }
  #expect(s.sleepHRV != nil); if let h = s.sleepHRV { #expect(h >= 25 && h <= 90) }
  #expect(s.sleepResp != nil); if let rr = s.sleepResp { #expect(rr >= 8 && rr <= 22) }
  #expect(s.sleepScore != nil); if let sc = s.sleepScore { #expect(sc >= 0 && sc <= 100 && sc > 70) }
}

@Test func processNightFromStagedSleep() throws {
  // unusable night (too short) → nil, baseline untouched
  var s0 = PersistedState()
  let shortRows = (0..<50).map { SleepSample(ts: Double($0 * 30), hr: 60, hrv: 50, motion: 0.01, resp: 14, temp: 34) }
  #expect(RecoveryEngine.processNight(SleepStaging.stage(shortRows), state: &s0) == nil)
  #expect(s0.hrvBaseline.n == 0)

  // warm up 7 nights, then a real staged night → ready Recovery
  var st = PersistedState()
  let hrvs = [45.0, 52, 48, 55, 50, 47, 53], rhrs = [56.0, 54, 57, 53, 55, 58, 52]
  for i in 0..<7 { _ = RecoveryEngine.process(hrv: hrvs[i], rhr: rhrs[i], resp: 14, sleepScore: 80, state: &st) }
  let staged = SleepStaging.stage(try goldenSleepRows())
  let r = RecoveryEngine.processNight(staged, state: &st)
  #expect(r != nil)
  #expect(r!.ready)
  #expect(r!.recovery != nil)
  #expect(r!.readiness != nil)
}
