import Foundation

/// L5/L6 — daily rollup history. One record per day feeds the historical indicators
/// (CTL/ATL/TSB, ACWR, daily CUSUM/EWMA-control-chart, Alerts) that need a series, not a single value.

/// One day's summary. Optionals are nil when the signal wasn't captured that day.
public struct DailyRecord: Codable, Equatable {
  public var date: String          // "yyyy-MM-dd" (local)
  public var dayStrain: Double
  public var rhr: Double?
  public var lnRMSSD: Double?      // ln(RMSSD) — HRV baseline domain (matches RecoveryEngine)
  public var rhrSource: String?
  public var hrvSource: String?
  public var hrvQuality: Int?
  public var sdnn: Double?
  public var resp: Double?
  public var skinTemp: Double?
  public var sleepScore: Double?
  public var recovery: Double?
  public var readiness: Double?
  public var deep: Int?, rem: Int?, light: Int?, wake: Int?
  public var steps: Int?
  public var kcal: Double?
  public var activeKcal: Double?                    // durable active-energy high-water mark (Move ring; survives relaunch)
  public var zoneMinutes: [Double]?                 // durable time-in-zone high-water mark (5 zones)
  public var onsetMin: Double?, wakeMin: Double?   // sleep onset / wake time as minute-of-day (for SRI) — may be user-edited
  public var autoOnsetMin: Double?, autoWakeMin: Double?   // sensor-detected onset/wake (kept so a manual edit can be compared/reverted)
  public var weight: Double?                        // kg (manual / scale)
  public var hypnogram: [Int]?                      // last night's stage track (0=Deep 1=Light 2=REM 3=Wake)
  public var hypnoHR: [Double]?                     // P2: sleeping HR aligned 1:1 with `hypnogram` (overlay). nil for old records.
  public var hypnoStartMin: Double?                 // Phase A: clock minute-of-day of hypnogram[0] (time-axis anchor)
  public var hypnoEpochMin: Double?                 // Phase A: minutes each hypnogram point spans (index → clock)
  public var tstRefinedH: Double?                   // pass-2 HR-refined total sleep time (vs actigraphy, for comparison)
  public var effRefined: Int?                       // pass-2 HR-refined efficiency %
  public var spo2Trend: [Double]?                   // overnight relative-SpO₂ index trend (downsampled ≤120)
  public var recoveryIndexH: Double?                // Oura-style: hours from sleep onset to HR stabilization
  public var recoveryIndexScore: Int?              // 0-100 (earlier stabilization = higher)
  public init(date: String, dayStrain: Double = 0, rhr: Double? = nil, lnRMSSD: Double? = nil,
              rhrSource: String? = nil, hrvSource: String? = nil, hrvQuality: Int? = nil,
              sdnn: Double? = nil, resp: Double? = nil, skinTemp: Double? = nil, sleepScore: Double? = nil,
              recovery: Double? = nil, readiness: Double? = nil, deep: Int? = nil, rem: Int? = nil,
              light: Int? = nil, wake: Int? = nil, steps: Int? = nil, kcal: Double? = nil,
              activeKcal: Double? = nil, zoneMinutes: [Double]? = nil,
              onsetMin: Double? = nil, wakeMin: Double? = nil, weight: Double? = nil, hypnogram: [Int]? = nil,
              hypnoHR: [Double]? = nil, hypnoStartMin: Double? = nil, hypnoEpochMin: Double? = nil,
              tstRefinedH: Double? = nil, effRefined: Int? = nil, spo2Trend: [Double]? = nil,
              recoveryIndexH: Double? = nil, recoveryIndexScore: Int? = nil) {
    self.date = date; self.dayStrain = dayStrain; self.rhr = rhr; self.lnRMSSD = lnRMSSD
    self.rhrSource = rhrSource; self.hrvSource = hrvSource; self.hrvQuality = hrvQuality
    self.sdnn = sdnn; self.resp = resp; self.skinTemp = skinTemp; self.sleepScore = sleepScore
    self.recovery = recovery; self.readiness = readiness
    self.deep = deep; self.rem = rem; self.light = light; self.wake = wake
    self.steps = steps; self.kcal = kcal; self.activeKcal = activeKcal; self.zoneMinutes = zoneMinutes
    self.onsetMin = onsetMin; self.wakeMin = wakeMin; self.weight = weight; self.hypnogram = hypnogram
    self.hypnoHR = hypnoHR; self.hypnoStartMin = hypnoStartMin; self.hypnoEpochMin = hypnoEpochMin
    self.autoOnsetMin = onsetMin; self.autoWakeMin = wakeMin   // at creation, detected == displayed (manual edit diverges later)
    self.tstRefinedH = tstRefinedH; self.effRefined = effRefined; self.spo2Trend = spo2Trend
    self.recoveryIndexH = recoveryIndexH; self.recoveryIndexScore = recoveryIndexScore
  }
}

/// Ordered (ascending date), deduped-by-date daily history with a rolling cap.
public struct DailyHistory: Codable, Equatable {
  public private(set) var days: [DailyRecord]
  public var cap: Int
  public init(cap: Int = 400) { days = []; self.cap = cap }

  /// Upsert by date (replace same-date), keep sorted ascending, enforce cap (drop oldest).
  public mutating func upsert(_ r: DailyRecord) {
    if let i = days.firstIndex(where: { $0.date == r.date }) { days[i] = r } else { days.append(r) }
    days.sort { $0.date < $1.date }
    if days.count > cap { days.removeFirst(days.count - cap) }
  }

  /// Numeric series (chronological), skipping nils — for the indicators.
  public func series(_ kp: KeyPath<DailyRecord, Double?>) -> [Double] { days.compactMap { $0[keyPath: kp] } }
  public func series(_ kp: KeyPath<DailyRecord, Double>) -> [Double] { days.map { $0[keyPath: kp] } }

  public var last: DailyRecord? { days.last }
}
