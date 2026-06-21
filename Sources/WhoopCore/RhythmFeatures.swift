import Foundation

/// Track-1 RR-interval AF-discrimination features (licence-free, pure math). These are the standard
/// short-RR atrial-fibrillation descriptors from the literature (Lake & Moorman CoSEn; Shannon entropy of
/// RR; turning-point ratio). They distinguish *disorder* (AF-like, unpredictable) from ordered variability
/// (sinus arrhythmia / a slow drift), which raw CV cannot. Used to harden T1b and — calibrated on labelled
/// data (PhysioNet CinC-2017 / MIT-BIH AFDB) — as the L1 classifier for the future MG ECG strip.
public enum RhythmFeatures {

  /// Sample entropy SampEn(m, r): the negative log conditional probability that two sub-series similar for
  /// m points stay similar at m+1. Lower = more regular/predictable; higher = more random (AF-like).
  public static func sampEn(_ x: [Double], m: Int = 2, r: Double) -> Double {
    let N = x.count
    guard N > m + 1, r > 0 else { return 0 }
    func matches(_ mm: Int) -> Int {
      let count = N - mm + 1
      guard count > 1 else { return 0 }
      var hits = 0
      for i in 0..<(count - 1) {
        for j in (i + 1)..<count {
          var ok = true
          for k in 0..<mm where abs(x[i + k] - x[j + k]) > r { ok = false; break }
          if ok { hits += 1 }
        }
      }
      return hits
    }
    let B = matches(m), A = matches(m + 1)
    if B == 0 { return 0 }
    if A == 0 { return log(Double(B)) + 1 }          // no longer-template matches → very irregular; bounded
    return -log(Double(A) / Double(B))
  }

  /// Coefficient of Sample Entropy (Lake & Moorman 2011) — density-corrected SampEn tuned for very short RR
  /// records, the standard AF feature. = SampEn(m=1, r) + ln(2r) − ln(mean). Higher = more irregular.
  public static func coSEn(_ rr: [Double]) -> Double {
    guard rr.count >= 12 else { return 0 }
    let mean = rr.reduce(0, +) / Double(rr.count)
    guard mean > 0 else { return 0 }
    let r = max(0.20 * popStd(rr), 1)                 // tolerance ~0.2·SD (floor 1 ms)
    let se = sampEn(rr, m: 1, r: r)
    return se + log(2 * r) - log(mean)
  }

  /// Shannon entropy of the RR distribution, normalised to [0,1] (÷ ln(bins)). AF spreads RR widely → high.
  /// NOTE: distribution-based, so it is order-blind (a drift and a shuffle score alike) — pair with CoSEn/TPR.
  public static func shannonEntropy(_ rr: [Double], bins: Int = 16) -> Double {
    guard rr.count >= 4, let lo = rr.min(), let hi = rr.max(), hi > lo else { return 0 }
    var hist = [Int](repeating: 0, count: bins)
    let span = hi - lo
    for v in rr {
      var b = Int((v - lo) / span * Double(bins))
      if b >= bins { b = bins - 1 }
      if b < 0 { b = 0 }
      hist[b] += 1
    }
    let n = Double(rr.count)
    var h = 0.0
    for c in hist where c > 0 { let p = Double(c) / n; h -= p * log(p) }
    return h / log(Double(bins))
  }

  /// Turning-point ratio: fraction of interior points that are a local max or min. ~0 for a monotonic drift,
  /// ~1 for strict alternation, ~0.67 for random. A "disorder/roughness" proxy.
  public static func turningPointRatio(_ x: [Double]) -> Double {
    guard x.count >= 3 else { return 0 }
    var t = 0
    for i in 1..<(x.count - 1) {
      if (x[i] > x[i - 1] && x[i] > x[i + 1]) || (x[i] < x[i - 1] && x[i] < x[i + 1]) { t += 1 }
    }
    return Double(t) / Double(x.count - 2)
  }

  static func popStd(_ x: [Double]) -> Double {
    guard !x.isEmpty else { return 0 }
    let m = x.reduce(0, +) / Double(x.count)
    return (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count)).squareRoot()
  }
}
