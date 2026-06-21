import Foundation

/// L4 cross-metric synthesizer — reads SEVERAL daily signals together instead of one chart in isolation.
/// Mirrors the multi-signal logic clinical wearables use (Apple Vitals "≥2 metrics out of range", WHOOP's
/// illness/strain flag): elevated RHR + skin temp + respiration alongside suppressed HRV = a coordinated
/// stress/illness pattern that no single metric reveals. All rule-based — no AI.
public enum HealthContext {
  public struct Reading: Equatable, Sendable {
    public let status: Int        // 0 aligned · 1 watch · 2 alert
    public let headline: String
    public let detail: String
    public init(status: Int, headline: String, detail: String) {
      self.status = status; self.headline = headline; self.detail = detail
    }
  }

  /// Compares the latest day to a baseline of prior days (z-score) across RHR / HRV / respiration / skin temp.
  /// Returns nil when there isn't enough history to judge (needs ≥7 prior points on a core signal).
  public static func read(_ days: [DailyRecord], thai: Bool) -> Reading? {
    func t(_ en: String, _ th: String) -> String { thai ? th : en }
    // z-score of the latest value vs the mean/SD of all prior days for one field
    func z(_ kp: KeyPath<DailyRecord, Double?>) -> Double? {
      let prior = days.dropLast().compactMap { $0[keyPath: kp] }
      guard prior.count >= 7, let last = days.last?[keyPath: kp] else { return nil }
      let m = prior.reduce(0, +) / Double(prior.count)
      let sd = (prior.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(prior.count)).squareRoot()
      guard sd > 0 else { return nil }
      return (last - m) / sd
    }
    let zRHR = z(\.rhr), zHRV = z(\.lnRMSSD), zResp = z(\.resp), zTemp = z(\.skinTemp)
    guard zRHR != nil || zHRV != nil else { return nil }     // need at least one core signal with a baseline

    // Plews overreaching: suppressed HRV (below SWC) AND a rising 7-day HRV coefficient-of-variation
    // (day-to-day HRV becoming more erratic precedes non-functional overreaching).
    var overreaching = false
    let rmssd = days.compactMap { $0.lnRMSSD.map { exp($0) } }
    if rmssd.count >= 14, let zh = zHRV, zh < -0.5 {
      func cv(_ a: [Double]) -> Double {
        let m = a.reduce(0, +) / Double(a.count)
        let sd = (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
        return m > 0 ? sd / m : 0
      }
      let last7 = Array(rmssd.suffix(7)), prior7 = Array(rmssd.suffix(14).prefix(7))
      if cv(last7) > cv(prior7) * 1.15 { overreaching = true }
    }

    var off: [String] = []
    if let z = zRHR, z > 1 { off.append(t("RHR up", "RHR สูง")) }
    if let z = zTemp, z > 1 { off.append(t("skin temp up", "อุณหภูมิผิวสูง")) }
    if let z = zResp, z > 1 { off.append(t("respiration up", "การหายใจเร็วขึ้น")) }
    if let z = zHRV, z < -1 { off.append(t("HRV down", "HRV ต่ำ")) }
    let joined = off.joined(separator: ", ")

    if off.count >= 2 {
      return Reading(status: 2, headline: t("Possible illness or heavy strain", "อาจกำลังป่วยหรือมีภาระหนัก"),
        detail: t("\(off.count) signals are off your baseline (\(joined)). Prioritize rest, hydration and sleep, and watch for symptoms.",
                  "มี \(off.count) สัญญาณผิดจาก baseline (\(joined)) — เน้นพัก ดื่มน้ำ และนอน พร้อมสังเกตอาการ"))
    }
    if overreaching {
      return Reading(status: 2, headline: t("Possible overreaching", "อาจฝึกหนักเกิน (overreaching)"),
        detail: t("HRV is low AND increasingly erratic (rising 7-day variability) — a pattern that precedes non-functional overreaching. Insert easy/recovery days.",
                  "HRV ต่ำ และแกว่งมากขึ้น (ความผันผวน 7 วันสูงขึ้น) — รูปแบบก่อนภาวะฝึกหนักเกิน ควรแทรกวันเบา/ฟื้นตัว"))
    }
    if off.count == 1 {
      return Reading(status: 1, headline: t("One signal off baseline", "มี 1 สัญญาณผิดจาก baseline"),
        detail: t("\(off[0]) vs your baseline — keep an eye on it; a single signal alone is often just noise.",
                  "\(off[0]) เทียบ baseline — จับตาดูไว้; สัญญาณเดียวมักเป็นแค่ความผันผวน"))
    }
    return Reading(status: 0, headline: t("Signals look aligned", "สัญญาณสอดคล้องกันดี"),
      detail: t("HRV, resting HR and temperature are all near your healthy baseline.",
                "HRV, หัวใจขณะพัก และอุณหภูมิ อยู่ใกล้ baseline ปกติทั้งหมด"))
  }
}
