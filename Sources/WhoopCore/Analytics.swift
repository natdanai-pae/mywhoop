import Foundation

/// U5 — long-term analytics over the daily history: personal records + week-over-week deltas.
public struct Records: Equatable {
  public var maxStrain: Double?, lowestRHR: Double?, highestHRV: Double?, bestSleep: Double?, mostSteps: Double?
  public init(maxStrain: Double? = nil, lowestRHR: Double? = nil, highestHRV: Double? = nil,
              bestSleep: Double? = nil, mostSteps: Double? = nil) {
    self.maxStrain = maxStrain; self.lowestRHR = lowestRHR; self.highestHRV = highestHRV
    self.bestSleep = bestSleep; self.mostSteps = mostSteps
  }
}

public struct WeeklyDelta: Equatable, Identifiable {
  public let id = UUID(); public let label: String; public let now: Double; public let prev: Double
  public var delta: Double { now - prev }
}

/// A calendar day's bucket of activity sessions (per-session preserved; day = the group). Multiple sessions
/// (e.g. morning cardio + noon weights) live under one ActivityDay.
public struct ActivityDay: Identifiable, Equatable {
  public let id: String                 // yyyy-MM-dd
  public let sessions: [WorkoutSession] // ordered by start time
  public var date: String { id }
  public var count: Int { sessions.count }
  public var totalSec: Double { sessions.reduce(0) { $0 + $1.durationSec } }
  public var totalKcal: Double { sessions.reduce(0) { $0 + $1.kcal } }
}

/// Per-sport rollup over a window (for cross-type balance: "3 runs, 2 rides this month").
public struct SportSummary: Identifiable, Equatable {
  public let id: String                 // type
  public let count: Int
  public let totalSec: Double
  public let avgStrain: Double
  public var type: String { id }
}

/// Evidence-based thresholds for the behavioral recommendations (tunable in one place; each cited).
public enum BehaviorThresholds {
  public static let monotonyHigh = 2.0        // Foster: monotony >2.0 (+ high strain) → illness/overtraining risk
  public static let monotonyVeryHigh = 2.5    // >2.5 = same load every day → overuse-injury risk
  public static let volumeSpikeRatio = 1.5    // period-over-period ≈ ACWR; >1.5 = danger zone (2-4× injury risk)
  public static let volumeCautionRatio = 1.3  // 1.3-1.5 = approaching danger (cap further increases)
  public static let aerobicHigh = 0.9         // >90% aerobic → add some high-intensity (Z4-5)
  public static let aerobicLow = 0.4          // <40% aerobic → add easy aerobic base
  public static let goodSessionsPerWeek = 4.0 // Garmin: ~4 evenly-distributed sessions/wk beats clustering
}

/// Rule-based behavioral analysis of activity habits over a selectable window (when you train, how consistently,
/// how the period is structured). Deterministic — Foster monotony/strain + WHOOP-WPA-style period compare + Garmin
/// Load Focus. `windowDays` = 7 (week) / 30 (month) / 365 (year).
public struct ActivityBehavior: Equatable {
  public let windowDays: Int
  public let hourHistogram: [Int]            // 24 buckets — session counts by local start hour (over the window)
  public let dominantBlock: String           // "morning" | "midday" | "evening" | "night" | "none"
  public let activeDays: Int                 // distinct active days in the window
  public let sessions: Int                   // sessions in the window
  public let prevSessions: Int               // sessions in the immediately-prior same-length window
  public let sessionsPerWeek: Double         // session rate over the window (sessions ÷ weeks)
  public let minutesThis: Double             // active minutes this window
  public let minutesPrev: Double             // active minutes prior window
  public let aerobicPct: Double?             // aerobic-zone seconds / total zone seconds, nil if no zone data
  public let monotony: Double?               // Foster: mean/SD of daily load over the window (nil if flat)
  public let windowLoad: Double              // sum of daily session strain over the window
  public let fosterStrain: Double?           // windowLoad × monotony
  public var hasData: Bool { sessions > 0 || windowLoad > 0 || hourHistogram.contains { $0 > 0 } }
}

public enum Analytics {
  static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

  /// Behavioral habits over the activity log, for a selectable window (`windowDays` = 7/30/365). `cal`/hour use the
  /// device's local time so "evening" means the user's evening. Daily load buckets include rest days as 0 (that
  /// variance is what Foster monotony rewards). All compares are this-window vs the immediately-prior same-length window.
  public static func behavior(_ w: [WorkoutSession], now: Double, windowDays: Int = 7) -> ActivityBehavior {
    let cal = Calendar.current
    let day: Double = 86400
    let win = Double(windowDays) * day
    func inWindow(_ from: Double, _ to: Double) -> [WorkoutSession] { w.filter { $0.start >= from && $0.start < to } }
    let cur = inWindow(now - win, now)
    let prev = inWindow(now - 2 * win, now - win)
    // B1 — time-of-day histogram + dominant block (over the window)
    var hist = [Int](repeating: 0, count: 24)
    for s in cur {
      let h = cal.component(.hour, from: Date(timeIntervalSince1970: s.start))
      if (0..<24).contains(h) { hist[h] += 1 }
    }
    func blockSum(_ r: Range<Int>) -> Int { r.reduce(0) { $0 + hist[$1] } }
    let blocks: [(String, Int)] = [("morning", blockSum(5..<11)), ("midday", blockSum(11..<16)),
                                   ("evening", blockSum(16..<22)),
                                   ("night", blockSum(22..<24) + blockSum(0..<5))]
    let dominant = (blocks.max { $0.1 < $1.1 }).flatMap { $0.1 > 0 ? $0.0 : nil } ?? "none"
    // B2 — distinct active days
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    let activeDays = Set(cur.map { f.string(from: Date(timeIntervalSince1970: $0.start)) }).count
    // B4 — aerobic vs anaerobic by zone-seconds (Z1-3 aerobic, Z4-5 anaerobic), Garmin Load-Focus style
    var aero = 0.0, anaero = 0.0
    for s in cur { for (i, sec) in s.zoneSec.enumerated() { if i <= 2 { aero += sec } else { anaero += sec } } }
    let totalZone = aero + anaero
    // B5 — Foster monotony & strain over the window's daily load buckets (session strain summed per day, rest = 0)
    var daily = [Double](repeating: 0, count: windowDays)
    for s in cur {
      let idx = Int((now - s.start) / day)                       // 0 = today … windowDays-1 ago
      if (0..<windowDays).contains(idx) { daily[windowDays - 1 - idx] += s.strain }
    }
    let m = mean(daily)
    let variance = daily.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(windowDays)
    let sd = variance.squareRoot()
    let monotony = sd > 0.05 ? m / sd : nil                       // nil when flat (every day identical / all rest)
    let windowLoad = daily.reduce(0, +)
    let weeks = Double(windowDays) / 7.0
    return ActivityBehavior(
      windowDays: windowDays, hourHistogram: hist, dominantBlock: dominant,
      activeDays: activeDays, sessions: cur.count, prevSessions: prev.count,
      sessionsPerWeek: Double(cur.count) / weeks,
      minutesThis: cur.reduce(0) { $0 + $1.durationSec } / 60,
      minutesPrev: prev.reduce(0) { $0 + $1.durationSec } / 60,
      aerobicPct: totalZone > 0 ? aero / totalZone : nil,
      monotony: monotony, windowLoad: windowLoad,
      fosterStrain: monotony.map { windowLoad * $0 })
  }

  /// Group sessions by LOCAL calendar day (newest first); within a day, ordered by start time.
  public static func activityDays(_ w: [WorkoutSession]) -> [ActivityDay] {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
    let groups = Dictionary(grouping: w) { f.string(from: Date(timeIntervalSince1970: $0.start)) }
    return groups.map { ActivityDay(id: $0.key, sessions: $0.value.sorted { $0.start < $1.start }) }
      .sorted { $0.id > $1.id }
  }

  /// Per-sport rollup for the last `sinceDays` (most-frequent first).
  public static func activityByType(_ w: [WorkoutSession], sinceDays: Int = 30, now: Double) -> [SportSummary] {
    let cutoff = now - Double(sinceDays) * 86400
    let groups = Dictionary(grouping: w.filter { $0.start >= cutoff }) { $0.type }
    return groups.map { (t, v) in
      SportSummary(id: t, count: v.count, totalSec: v.reduce(0) { $0 + $1.durationSec },
                   avgStrain: v.reduce(0) { $0 + $1.strain } / Double(max(v.count, 1)))
    }                                                           // STABLE order — Dictionary iteration is non-deterministic
    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.type < $1.type }   // tiebreak by name → no row flicker
  }

  public static func records(_ h: DailyHistory) -> Records {
    Records(
      maxStrain: h.series(\.dayStrain).max(),
      lowestRHR: h.series(\.rhr).min(),
      highestHRV: h.series(\.lnRMSSD).map { exp($0) }.max(),
      bestSleep: h.series(\.sleepScore).max(),
      mostSteps: h.days.compactMap { $0.steps.map(Double.init) }.max())
  }

  /// 7-day vs prior-7-day means for the headline metrics.
  public static func weeklyDeltas(_ h: DailyHistory) -> [WeeklyDelta] {
    func d(_ label: String, _ kp: KeyPath<DailyRecord, Double?>) -> WeeklyDelta? {
      let s = h.series(kp); guard s.count >= 8 else { return nil }
      let now = mean(Array(s.suffix(7)))
      let prev = mean(Array(s.dropLast(7).suffix(7)))
      return WeeklyDelta(label: label, now: now, prev: prev)
    }
    let strain = h.series(\.dayStrain), hrv = h.series(\.lnRMSSD).map { exp($0) }
    var out = [d("Recovery", \.recovery), d("Sleep", \.sleepScore)].compactMap { $0 }
    if strain.count >= 8 {
      out.append(WeeklyDelta(label: "Strain", now: mean(Array(strain.suffix(7))), prev: mean(Array(strain.dropLast(7).suffix(7)))))
    }
    if hrv.count >= 8 {
      out.append(WeeklyDelta(label: "HRV", now: mean(Array(hrv.suffix(7))), prev: mean(Array(hrv.dropLast(7).suffix(7)))))
    }
    return out
  }
}
