import Foundation

/// L3/L4 — derives the historical composites + the active alert set from a `DailyHistory`.
/// Pure (no state); WhoopBLE calls `compute` after each rollup and publishes the result.

public struct DailyMetrics: Equatable {
  public let ctl: Double?            // chronic training load (fitness, τ=42)
  public let atl: Double?            // acute training load (fatigue, τ=7)
  public let tsb: Double?            // training stress balance (form) = CTL−ATL
  public let acwr: Double?           // acute:chronic workload ratio (soft trend)
  public let tsbNorm: Double         // TSB mapped to 0-100 (neutral 50) for readiness/alerts
  public let sleepDebtH: Double      // cumulative need−TST over last 7 nights
  public let sri: Double?            // Sleep Regularity Index 0-100 (nil until ≥3 nights of onset/wake)
  public let resilience: Double?     // Oura-style 14-day stress↔recovery balance 0-100 (nil until ≥5 days)
  public let resilienceLevel: String? // Exceptional/Strong/Solid/Adequate/Limited
  public let alerts: [Alert]
}

public enum DailyMetricsEngine {
  static func mean(_ a: ArraySlice<Double>) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

  public static func compute(_ h: DailyHistory, state: PersistedState) -> DailyMetrics {
    let strain = h.series(\.dayStrain)
    let debt = sleepDebt(h), sriV = sri(h)
    let res = resilience(h)
    guard !strain.isEmpty else {
      return DailyMetrics(ctl: nil, atl: nil, tsb: nil, acwr: nil, tsbNorm: 50,
                          sleepDebtH: debt, sri: sriV, resilience: res?.0, resilienceLevel: res?.1, alerts: [])
    }
    // CTL/ATL/TSB — EWMA over the whole strain series (Banister/TrainingPeaks).
    let load = Scores.performanceModel(dailyLoads: strain).last!
    // ACWR — acute(7d)/chronic(28d) means. Soft trend only (contested), never a thresholded alert.
    let acute = mean(strain.suffix(7)), chronic = mean(strain.suffix(28))
    let acwr = Scores.acwr(acute: acute, chronic: chronic)
    // TSB → 0-100 logistic (≈±25 saturates), neutral 50.
    let tsbNorm = 100 / (1 + exp(-load.tsb / 10))

    let alerts = evaluateAlerts(h, state: state, tsb: load.tsb, acwr: acwr, debt: debt, sri: sriV)
    return DailyMetrics(ctl: load.ctl, atl: load.atl, tsb: load.tsb, acwr: acwr, tsbNorm: tsbNorm,
                        sleepDebtH: debt, sri: sriV, resilience: res?.0, resilienceLevel: res?.1, alerts: alerts)
  }

  /// Resilience — Oura-style 14-day balance of stress and recovery. High, CONSISTENT recovery (low CV) = robust.
  /// Needs ≥5 days with a recovery score in the last 14. Returns (score 0-100, level).
  static func resilience(_ h: DailyHistory) -> (Double, String)? {
    let recent = h.days.suffix(14)
    let rec = recent.compactMap { $0.recovery }
    guard rec.count >= 5 else { return nil }
    let slp = recent.compactMap { $0.sleepScore }
    let meanRec = rec.reduce(0, +) / Double(rec.count)
    let meanSlp = slp.isEmpty ? meanRec : slp.reduce(0, +) / Double(slp.count)
    let sd = (rec.map { ($0 - meanRec) * ($0 - meanRec) }.reduce(0, +) / Double(rec.count)).squareRoot()
    let cv = meanRec > 0 ? sd / meanRec : 0
    let score = max(0, min(100, 0.6 * meanRec + 0.4 * meanSlp - cv * 30))   // consistency penalty
    let level = score >= 80 ? "Exceptional" : score >= 65 ? "Strong" : score >= 50 ? "Solid" : (score >= 35 ? "Adequate" : "Limited")
    return (score, level)
  }

  /// Cumulative sleep debt (need 8h − TST) over the last 7 nights.
  static func sleepDebt(_ h: DailyHistory) -> Double {
    h.days.suffix(7).reduce(0.0) { acc, d in
      let tst = Double((d.deep ?? 0) + (d.rem ?? 0) + (d.light ?? 0)) / 60.0
      return acc + max(0, 8.0 - tst)
    }
  }

  /// Sleep Regularity Index 0-100 from onset/wake-time consistency (last 7 nights). Noon-shifted to handle midnight wrap.
  static func sri(_ h: DailyHistory) -> Double? {
    let recent = h.days.suffix(7)
    func shift(_ m: Double) -> Double { (m + 720).truncatingRemainder(dividingBy: 1440) }
    let on = recent.compactMap { $0.onsetMin.map(shift) }, wk = recent.compactMap { $0.wakeMin.map(shift) }
    guard on.count >= 3, wk.count >= 3 else { return nil }
    let sd = (Indicators.popStd(on) + Indicators.popStd(wk)) / 2          // minutes
    return max(0, min(100, 100 * (1 - sd / 120)))                        // 120-min SD → 0
  }

  /// Standardized CUSUM (k,h locked): did it trip on the high (S+) / low (S−) side AT the last sample.
  /// reset-on-alarm per the lock. Used for "is today alarming" signals (rising RHR/temp, falling HRV).
  static func cusumState(_ x: [Double], mean: Double, sd: Double, k: Double, h: Double) -> (hi: Bool, lo: Bool) {
    guard sd > 0, !x.isEmpty else { return (false, false) }
    var sp = 0.0, sm = 0.0, hi = false, lo = false
    for (i, v) in x.enumerated() {
      let z = (v - mean) / sd
      sp = max(0, sp + z - k); sm = min(0, sm + z + k)
      let isLast = i == x.count - 1
      if sp > h { if isLast { hi = true }; sp = 0; sm = 0 }
      else if sm < -h { if isLast { lo = true }; sp = 0; sm = 0 }
    }
    return (hi, lo)
  }

  /// D3/U4 — turn the daily series + baselines into the active alert set.
  static func evaluateAlerts(_ h: DailyHistory, state: PersistedState, tsb: Double, acwr: Double?,
                             debt: Double, sri: Double?) -> [Alert] {
    guard let last = h.last else { return [] }
    let k = state.params.cusumK, hh = state.params.cusumH
    let rhrHi  = cusumState(h.series(\.rhr),     mean: state.rhrBaseline.mean,  sd: state.rhrBaseline.sd,  k: k, h: hh).hi
    let tempHi = cusumState(h.series(\.skinTemp), mean: state.tempBaseline.mean, sd: state.tempBaseline.sd, k: k, h: hh).hi
    let hrvLo  = cusumState(h.series(\.lnRMSSD),  mean: state.hrvBaseline.mean,  sd: state.hrvBaseline.sd,  k: k, h: hh).lo
    let respHigh = (last.resp.flatMap { state.respBaseline.z($0) } ?? 0) > 1.0
    let dqOK = last.rhr != nil && last.lnRMSSD != nil
    // chronic under-recovery: ≥3 of the last 5 days = high strain (>12) on low recovery (<50)
    let under = h.days.suffix(5).filter { $0.dayStrain > 12 && ($0.recovery ?? 100) < 50 }.count >= 3
    let sig = AlertSignals(rhrCusumHigh: rhrHi, tempCusumHigh: tempHi, respHigh: respHigh, hrvCusumLow: hrvLo,
      tsb: tsb, acwr: acwr, recovery: last.recovery ?? 50, sleepDebtHours: debt,
      sriDropping: (sri ?? 100) < 70, dataQualityOK: dqOK, chronicUnderRecovery: under)
    return Alerts.evaluate(sig)
  }
}
