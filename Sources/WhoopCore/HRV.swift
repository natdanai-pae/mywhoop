import Foundation

/// L1 — time-domain + Poincaré HRV, all computed from ONE shared RR/PPI set.
/// Fixes the stored-data bug (prototype): SD1 and RMSSD must come from the same beat window,
/// so SD1 ≡ RMSSD/√2 holds (gap = mean-diff term only, <1% on real data) instead of being 18% apart.
public struct HRVMetrics: Equatable {
  public let rmssd: Double   // ms — short-term parasympathetic
  public let sdnn: Double    // ms — overall variability (population SD of RR)
  public let sd1: Double     // ms — Poincaré short-axis = √0.5·SDSD
  public let sd2: Double     // ms — Poincaré long-axis
}

public enum HRV {
  /// RR in milliseconds. Returns nil if fewer than 3 intervals.
  /// Poincaré per the gateway reference (so C7 parity holds): SD1 ≡ RMSSD/√2 EXACTLY,
  /// SD2 = √(2·SDNN² − SD1²). One shared RR set → SD1/RMSSD identity is exact (was 18% off in stored data).
  public static func metrics(_ rr: [Double]) -> HRVMetrics? {
    guard rr.count >= 3 else { return nil }
    let diff = zip(rr.dropFirst(), rr).map { $0 - $1 }           // RR[i+1]-RR[i]
    let rmssd = (diff.map { $0 * $0 }.reduce(0, +) / Double(diff.count)).squareRoot()
    let sdnn = popStd(rr)
    let sd1 = rmssd / (2.0).squareRoot()
    let sd2 = max(0, 2 * sdnn * sdnn - sd1 * sd1).squareRoot()
    return HRVMetrics(rmssd: rmssd, sdnn: sdnn, sd1: sd1, sd2: sd2)
  }

  /// Baevsky Stress Index (ported byte-exact from gateway baevskySI): 50ms-binned mode.
  /// SI = AMo / (2·VR·Mo), rounded. nil if <20 intervals or degenerate.
  public static func baevskySI(_ rr: [Double]) -> Int? {
    guard rr.count >= 20 else { return nil }
    var hist = [Double: Int](); var mode = 0.0; var modeCount = 0
    for x in rr {
      let b = (x / 50).rounded() * 50
      let c = (hist[b] ?? 0) + 1; hist[b] = c
      if c > modeCount { modeCount = c; mode = b }
    }
    let Mo = mode / 1000
    let AMo = 100 * Double(modeCount) / Double(rr.count)
    let VR = ((rr.max() ?? 0) - (rr.min() ?? 0)) / 1000
    guard Mo > 0, VR > 0 else { return nil }
    return Int((AMo / (2 * VR * Mo)).rounded())
  }
  static func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }
  static func popStd(_ x: [Double]) -> Double {
    let m = mean(x)
    return (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count)).squareRoot()
  }
}
