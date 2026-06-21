import Foundation

/// L1 — PPG-derived HRV (A1). Port of gateway computePpgHRV: 0.5s baseline highpass → light smooth →
/// peak detect (thr 0.15·RMS, 0.3s refractory) → ★parabolic sub-sample peak time → PPI →
/// Malik vs-median outlier reject → RMSSD. HRV is motion-gated (PPG-PRV reliable only at rest/sleep).
public struct PPGHRVResult: Equatable {
  public let ppgHR: Int?       // pulse rate (cross-check vs HR)
  public let rmssd: Double?    // ms — nil unless clean & low-motion
  public let quality: Int?     // % of PPIs retained
}

public enum PPGHRV {
  public static let fs = 25.0

  static func movavgAt(_ a: [Double], _ i: Int, _ half: Int) -> Double {
    let lo = max(0, i - half), hi = min(a.count, i + half + 1)
    var s = 0.0; for k in lo..<hi { s += a[k] }; return s / Double(hi - lo)
  }
  static func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); let n = s.count
    return n % 2 != 0 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
  }

  public static func compute(_ ppg: [Double], accelRms: Double?) -> PPGHRVResult {
    let none = PPGHRVResult(ppgHR: nil, rmssd: nil, quality: nil)
    let N = ppg.count
    if Double(N) < fs * 12 { return none }                       // need ≥12 s
    let half = Int(fs * 0.5)
    let ac = (0..<N).map { ppg[$0] - movavgAt(ppg, $0, half) }
    let s = (0..<N).map { movavgAt(ac, $0, 1) }
    let rms = (s.map { $0 * $0 }.reduce(0, +) / Double(N)).squareRoot()
    let thr = 0.15 * rms
    let refr = Int((fs * 0.30).rounded())
    var pk = [Double](); var last = -1e9
    var i = 1
    while i < N - 1 {
      if s[i] > thr && s[i] >= s[i - 1] && s[i] > s[i + 1] && Double(i) - last >= Double(refr) {
        let y0 = s[i - 1], y1 = s[i], y2 = s[i + 1]; let den = y0 - 2 * y1 + y2
        let d = den != 0 ? 0.5 * (y0 - y2) / den : 0                // ★parabolic sub-sample peak time
        pk.append((Double(i) + d) / fs * 1000); last = Double(i)
      }
      i += 1
    }
    if pk.count < 8 { return none }
    var ppi = [Double]()
    for j in 1..<pk.count { let d = pk[j] - pk[j - 1]; if d > 300 && d < 1800 { ppi.append(d) } }
    if ppi.count < 6 { return none }
    let m = median(ppi)
    let clean = ppi.filter { abs($0 - m) <= 0.2 * m }              // Malik vs-median
    let ppgHR = Int((60000 / m).rounded())
    var rmssd: Double? = nil; var q: Int? = nil
    if Double(clean.count) >= max(8, Double(ppi.count) * 0.6) && (accelRms == nil || accelRms! < 0.03) {
      var dd = [Double](); for j in 1..<clean.count { dd.append(clean[j] - clean[j - 1]) }
      rmssd = ((dd.map { $0 * $0 }.reduce(0, +) / Double(dd.count)).squareRoot() * 10).rounded() / 10
      q = Int((Double(clean.count) / Double(ppi.count) * 100).rounded())
    }
    return PPGHRVResult(ppgHR: ppgHR, rmssd: rmssd, quality: q)
  }
}
