import Foundation

/// A detected DAYTIME nap — a separate, lighter-weight sleep block than the main nightly sleep.
/// v1 = detection + display only (NOT yet folded into recovery / sleep-need).
public struct Nap: Equatable, Identifiable, Codable, Sendable {
  public enum Confidence: String, Codable, Sendable { case high, low }
  public var start: Double, end: Double      // unix ts (end = last asleep minute + 60)
  public var avgHR: Int
  public var confidence: Confidence          // high = clear HR drop + stable (low-volatility) HR; low = borderline
  public var hrVolatility: Double            // rolling-10-min-SD-median of HR through the nap (bpm) — sleep is stable/low
  public var id: String { String(Int(start)) }
  public var durationMin: Int { max(0, Int((end - start) / 60)) }
  public init(start: Double, end: Double, avgHR: Int, confidence: Confidence = .high, hrVolatility: Double = 0) {
    self.start = start; self.end = end; self.avgHR = avgHR; self.confidence = confidence; self.hrVolatility = hrVolatility
  }
}

/// Rule-based nap detection, the way Fitbit/Google describe it: "movement below a threshold + heart rate
/// settles into a predictable (near-resting) pattern". We don't have a dedicated nap sensor, so we scan the
/// all-day per-minute (HR, cumulative-steps) ring: a nap = a sustained STILL + HR-near-resting block ≥ minMin.
/// The main nightly sleep already has its own pipeline (`SleepStaging`), which requires ≥2 h of data / a ≥1 h
/// main block — so naps (20–40 min) fall through it entirely; this fills that gap.
public enum NapDetector {
  /// `rows`: per-minute (ts, hr, cumulative steps), any order. `restHR`: the user's sleeping resting HR.
  /// A minute is "quiet" if its step delta ≤ stillSteps AND hr ≤ restHR + hrMargin. Quiet runs (merging
  /// ≤ gapTol non-quiet minutes) of ≥ minMin that don't overlap an `exclude` window (the main night, a logged
  /// workout) become naps.
  // hrMargin = how far above the sleeping resting HR still counts as "rest". 10 bpm (was 12): sitting
  // awake at a desk settles a touch above resting, and +12 let those borderline-still stretches through
  // as bogus naps; +10 keeps genuine naps (HR near resting) while rejecting awake-sedentary periods.
  /// Median of the rolling W-minute SD of HR — the frontier "HR volatility" signal (Sci Reports 2022, 2000+ nights).
  /// Real sleep settles into a LOW, stable pulse (small SD); awake-sedentary (reading in bed) wanders more (larger SD)
  /// even when the mean HR is low. Used to separate "asleep" from "still but awake", which motion alone cannot.
  public static func hrVolatility(_ hr: [Double], window: Int = 10) -> Double {
    let xs = hr.filter { $0 > 0 }
    guard xs.count >= 2 else { return 0 }
    func sd(_ a: ArraySlice<Double>) -> Double {
      let m = a.reduce(0, +) / Double(a.count)
      return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
    }
    if xs.count <= window { return sd(xs[...]) }
    var sds = [Double]()
    for i in 0...(xs.count - window) { sds.append(sd(xs[i..<i + window])) }
    return sds.sorted()[sds.count / 2]                                 // median window SD (robust to a 1-window blip)
  }

  /// `minHRDrop` (>0) demands the run's mean HR be ≥ that many bpm BELOW the pre-onset awake context (real nap dips
  /// into sleep; awake-still holds a flat low plateau). `maxHRVolatility` (>0) demands a LOW, stable pulse (rolling
  /// 10-min SD) — the frontier sedentary-vs-sleep splitter; a run jitterier than ~2× the threshold is rejected as
  /// awake, between the threshold and 2× is kept as LOW-confidence. Both default to 0 (off) so the sleep-bout caller
  /// is unchanged; the nap card enables them. A kept nap is `.high` confidence only with a real drop AND stable HR.
  public static func detect(_ rows: [(ts: Double, hr: Double, steps: Int)],
                            restHR: Double, minMin: Int = 20, stillSteps: Int = 3,
                            hrMargin: Double = 10, gapTol: Int = 3,
                            minHRDrop: Double = 0, preWindowMin: Int = 12, maxHRVolatility: Double = 0,
                            exclude: [(start: Double, end: Double)] = []) -> [Nap] {
    let rows = rows.sorted { $0.ts < $1.ts }
    guard rows.count >= minMin else { return [] }
    // per-minute quietness: little movement + HR near the resting baseline (the nap signature)
    var quiet = [Bool](repeating: false, count: rows.count)
    for i in 0..<rows.count {
      let mv = i == 0 ? 0 : max(0, rows[i].steps - rows[i - 1].steps)   // step delta (negative = midnight reset → 0)
      quiet[i] = rows[i].hr > 0 && mv <= stillSteps && rows[i].hr <= restHR + hrMargin
    }
    var naps = [Nap](); var i = 0
    while i < rows.count {
      if !quiet[i] { i += 1; continue }
      var j = i, lastQuiet = i, gap = 0                                  // extend the run, tolerating short breaks
      while j + 1 < rows.count {
        j += 1
        if quiet[j] { lastQuiet = j; gap = 0 } else { gap += 1; if gap > gapTol { break } }
      }
      let s = rows[i].ts, e = rows[lastQuiet].ts + 60
      if Int((e - s) / 60) >= minMin, !exclude.contains(where: { s < $0.end && e > $0.start }) {
        let hrs = rows[i...lastQuiet].map { $0.hr }.filter { $0 > 0 }
        let runAvg = hrs.isEmpty ? 0 : hrs.reduce(0, +) / Double(hrs.count)
        var keep = true
        var conf: Nap.Confidence = .high
        var vol = 0.0
        if minHRDrop > 0 || maxHRVolatility > 0 {
          // (1) HR-DROP: real nap dips INTO the run; awake-still holds a flat low plateau.
          var droppedEnough = true
          if minHRDrop > 0 {
            let preStart = max(0, i - preWindowMin)
            let preHRs = (preStart..<i).map { rows[$0].hr }.filter { $0 > 0 }
            let preAvg = preHRs.isEmpty ? nil : preHRs.reduce(0, +) / Double(preHRs.count)
            droppedEnough = preAvg.map { runAvg <= $0 - minHRDrop } ?? true     // no awake context → can't reject
          }
          let clearlyAsleep = runAvg > 0 && runAvg <= restHR + 3
          // (2) HR-VOLATILITY: sleep = low, stable pulse; awake-sedentary wanders. Jitterier than 2× → reject as awake.
          var stable = true, volOK = true
          if maxHRVolatility > 0 {
            vol = hrVolatility(hrs)
            stable = vol <= maxHRVolatility
            volOK = vol <= maxHRVolatility * 2
          }
          keep = (droppedEnough || clearlyAsleep) && volOK
          conf = (droppedEnough && stable) ? .high : .low                       // both signals strong → high
        }
        if keep {
          naps.append(Nap(start: s, end: e, avgHR: Int(runAvg.rounded()), confidence: conf, hrVolatility: vol))
        }
      }
      i = lastQuiet + 1
    }
    return naps
  }
}
