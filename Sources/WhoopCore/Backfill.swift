import Foundation

/// I8 — turn the strap's flash backlog (historical k18/type47 rows drained on reconnect) into coarse
/// per-day records, so CTL/ATL/TSB + RHR/temp trends have history without waiting one day at a time.
/// k18 history carries hr/temp/resp but NOT RR or motion → no HRV/sleep-stage/recovery here (those stay
/// nil and are filled by the live nightly pipeline). Pure + testable; the BLE drain lives in WhoopBLE.
public enum Backfill {
  public struct HistRow: Equatable {
    public let ts: Double; public let hr: Double?; public let temp: Double?; public let resp: Double?
    public let hrSource: String?
    public init(ts: Double, hr: Double?, temp: Double?, resp: Double?, hrSource: String? = nil) {
      self.ts = ts; self.hr = hr; self.temp = temp; self.resp = resp; self.hrSource = hrSource
    }
  }

  static func dayKey(_ ts: Double, _ tz: TimeZone) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
    f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date(timeIntervalSince1970: ts))
  }

  /// Build per-minute SleepSamples from the drained flash history (k18 = HR/temp/resp, NO motion) for the
  /// most recent ~16h. Since flash lacks motion, use **HR-above-the-sleeping-floor as a pseudo-activity**
  /// proxy so the motion-based Cole-Kripke pipeline can still detect the sleep block (low HR = still = asleep).
  public static func sleepSamples(_ rows: [HistRow], hoursBack: Double = 16,
                                  includeCandidateResp: Bool = false) -> [SleepSample] {
    let valid = rows.filter { $0.hr != nil }.sorted { $0.ts < $1.ts }
    guard let maxTs = valid.last?.ts else { return [] }
    let recent = valid.filter { $0.ts >= maxTs - hoursBack * 3600 }
    guard recent.count >= 120 else { return [] }
    let hrs = recent.compactMap { $0.hr }.sorted()
    let floor = hrs.prefix(max(1, hrs.count / 20)).reduce(0, +) / Double(max(1, hrs.count / 20))   // ~5th-pct sleeping HR
    var out = [SleepSample](); var bk: Int? = nil
    var bhr = [Double](), bt = [Double](), br = [Double](), hrSources = [String]()
    func flush(_ k: Int) {
      let hr = bhr.isEmpty ? nil : bhr.reduce(0, +) / Double(bhr.count)
      let mot = hr.map { max(0, $0 - floor) } ?? 0                  // HR above the floor ⇒ awake/active proxy
      let resp = (includeCandidateResp && !br.isEmpty) ? br.reduce(0, +) / Double(br.count) : nil
      out.append(SleepSample(ts: Double(k) * 60, hr: hr, hrv: nil, motion: mot,
        resp: resp, temp: bt.isEmpty ? nil : bt.reduce(0, +) / Double(bt.count),
        hrSource: hrSources.first))
    }
    for r in recent {
      let k = Int(r.ts / 60)
      if bk == nil { bk = k }
      if k != bk! { flush(bk!); bk = k; bhr = []; bt = []; br = []; hrSources = [] }
      if let h = r.hr { bhr.append(h); if let s = r.hrSource { hrSources.append(s) } }
      if let t = r.temp { bt.append(t) }; if let rr = r.resp { br.append(rr) }
    }
    if let k = bk { flush(k) }
    return out
  }

  public static func aggregate(_ rows: [HistRow], hrMax: Double, hrRest: Double, tau: Double,
                               tz: TimeZone = .current,
                               male: Bool = true,
                               includeCandidateResp: Bool = false) -> [DailyRecord] {
    var out = [DailyRecord]()
    for (date, drows) in Dictionary(grouping: rows, by: { dayKey($0.ts, tz) }) {
      let sorted = drows.sorted { $0.ts < $1.ts }
      // day strain from HR-TRIMP (Banister, male)
      var trimp = 0.0, lastTs: Double? = nil, hrs = [Double]()
      for r in sorted {
        guard let hr = r.hr else { continue }
        if let lt = lastTs {
          let dt = min(max(r.ts - lt, 0), 300) / 60.0
          let hrr = max(0, min(1, (hr - hrRest) / (hrMax - hrRest)))
          trimp += Physiology.banisterTRIMP(dtMin: dt, hrr: hrr, male: male)
        }
        lastTs = r.ts; hrs.append(hr)
      }
      // RHR proxy = min of 5-sample moving-avg HR (the sleeping trough)
      var rhr: Double? = nil
      if hrs.count >= 5 {
        var lo = Double.infinity
        for i in 0...(hrs.count - 5) { lo = min(lo, hrs[i..<(i + 5)].reduce(0, +) / 5) }
        rhr = lo
      }
      let temps = drows.compactMap { $0.temp }.sorted()
      let resps = drows.compactMap { $0.resp }
      let resp = (includeCandidateResp && !resps.isEmpty) ? resps.reduce(0, +) / Double(resps.count) : nil
      let rhrSource = sorted.first { $0.hr != nil }?.hrSource
      out.append(DailyRecord(date: date, dayStrain: Scores.strain(trimp: trimp, tau: tau),
        rhr: rhr, rhrSource: rhrSource, sdnn: nil, resp: resp,
        skinTemp: temps.isEmpty ? nil : temps[temps.count / 2]))
    }
    return out.sorted { $0.date < $1.date }
  }
}
