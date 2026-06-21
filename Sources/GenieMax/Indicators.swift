import Foundation

/// L2 — statistical transforms with parameters LOCKED in METRICS-TUNING-LOCK.md.
/// All operate on a personalized rolling baseline (mean/sd) per the SPC-on-biometrics caveat.
public enum Indicators {

  public static func zscore(_ x: Double, mean: Double, sd: Double) -> Double {
    sd == 0 ? 0 : (x - mean) / sd
  }

  /// Streaming EWMA; seed = first value. α: slow 0.0645(~30) / fast 0.25(~7) per the lock.
  public static func ewma(_ x: [Double], alpha: Double) -> [Double] {
    guard let first = x.first else { return [] }
    var e = first; var out = [first]
    for v in x.dropFirst() { e = alpha * v + (1 - alpha) * e; out.append(e) }
    return out
  }

  public struct ControlChart: Equatable {
    public let ewma: [Double]; public let upper: [Double]; public let lower: [Double]; public let violations: [Int]
  }
  /// EWMA control chart (NIST/SEMATECH §6.3.2.4): λ=0.2, L=3 default. Limits widen with t then plateau.
  public static func ewmaControlChart(_ x: [Double], mean: Double, sd: Double,
                                      lambda: Double = 0.2, L: Double = 3) -> ControlChart {
    var e = mean
    var ew = [Double](), up = [Double](), lo = [Double](), viol = [Int]()
    for (t, v) in x.enumerated() {
      e = lambda * v + (1 - lambda) * e; ew.append(e)
      let f = sd * L * (lambda / (2 - lambda) * (1 - pow(1 - lambda, Double(2 * (t + 1))))).squareRoot()
      up.append(mean + f); lo.append(mean - f)
      if e > mean + f || e < mean - f { viol.append(t) }
    }
    return ControlChart(ewma: ew, upper: up, lower: lo, violations: viol)
  }

  /// Two-sided standardized CUSUM (NIST §6.3.2.3): k=0.5 slack, h=5 decision interval; reset on alarm.
  /// Returns the indices where an alarm fired. Run on a DAILY series (RHR/temp), not intraday HR.
  public static func cusumAlarms(_ x: [Double], mean: Double, sd: Double,
                                 k: Double = 0.5, h: Double = 5) -> [Int] {
    var sp = 0.0, sm = 0.0; var alarms = [Int]()
    for (i, v) in x.enumerated() {
      let z = sd == 0 ? 0 : (v - mean) / sd
      sp = max(0, sp + z - k); sm = min(0, sm + z + k)
      if sp > h || sm < -h { alarms.append(i); sp = 0; sm = 0 }
    }
    return alarms
  }

  public static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
  public static func popStd(_ x: [Double]) -> Double {
    let m = mean(x); return x.isEmpty ? 0 : (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count)).squareRoot()
  }
  /// Coefficient of variation (population) — HRV-CV is a published readiness marker (Plews).
  public static func cv(_ x: [Double]) -> Double { let m = mean(x); return m == 0 ? 0 : popStd(x) / m }

  /// Pearson correlation r between two equal-length series (0 if degenerate). For "do you push on recovered days?".
  public static func pearson(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count); guard n >= 2 else { return 0 }
    let ma = mean(Array(a.prefix(n))), mb = mean(Array(b.prefix(n)))
    var num = 0.0, da = 0.0, db = 0.0
    for i in 0..<n { let x = a[i] - ma, y = b[i] - mb; num += x * y; da += x * x; db += y * y }
    let den = (da * db).squareRoot()
    return den > 0 ? num / den : 0
  }

  /// Time-in-range fractions. Ascending `edges` define edges.count+1 bins; returns fraction per bin.
  public static func tir(_ x: [Double], edges: [Double]) -> [Double] {
    var counts = [Int](repeating: 0, count: edges.count + 1)
    for v in x {
      var b = edges.count
      for (i, e) in edges.enumerated() where v < e { b = i; break }
      counts[b] += 1
    }
    let n = Double(max(x.count, 1))
    return counts.map { Double($0) / n }
  }
}
