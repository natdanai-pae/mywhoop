import Foundation

/// L3 — composite scores. Formulas/weights per METRICS-INDICATORS-SPEC.md + METRICS-TUNING-LOCK.md.
public enum Scores {
  /// Standard normal CDF (via erf).
  public static func phi(_ s: Double) -> Double { 0.5 * (1 + erf(s / (2.0).squareRoot())) }

  /// Recovery 0-100 = 100·Φ(composite z). Weights: 0.55 zHRV −0.20 zRHR −0.10 zRR +0.15 zSleep.
  public static func recovery(zHRV: Double, zRHR: Double, zRR: Double, zSleep: Double,
                              weights: [Double] = [0.55, 0.20, 0.10, 0.15]) -> Double {
    let w = weights.count >= 4 ? weights : [0.55, 0.20, 0.10, 0.15]
    return 100 * phi(w[0] * zHRV - w[1] * zRHR - w[2] * zRR + w[3] * zSleep)
  }

  /// Day Strain 0-21 (Banister): 21·(1−e^(−TRIMP/τ)).
  public static func strain(trimp: Double, tau: Double) -> Double { 21 * (1 - exp(-trimp / tau)) }

  /// P2 — recommended Strain TARGET from this morning's recovery (WHOOP Strain-Coach idea: recovered → more
  /// capacity). Maps recovery 0-100 → ~8-18 on the 0-21 scale.
  public static func strainTarget(recovery: Double) -> Double { min(20, max(6, 8 + recovery / 100 * 10)) }

  /// P2 — dynamic sleep need (hours): age baseline + today's-strain bump + a fraction of accrued debt
  /// (WHOOP: baseline + today's strain + sleep debt + naps). Higher strain → more sleep needed.
  public static func sleepNeedH(base: Double, dayStrain: Double, debtH: Double) -> Double {
    base + (dayStrain / 21) * 0.75 + min(debtH * 0.3, 1.5)
  }
  /// Solve τ from one known (WHOOP strain, TRIMP) anchor.
  public static func calibrateTau(whoopStrain: Double, trimp: Double) -> Double {
    -trimp / log(1 - whoopStrain / 21)
  }

  public struct Load: Equatable { public let ctl: Double; public let atl: Double; public let tsb: Double }
  /// Performance Management model (Banister/TrainingPeaks): CTL τ=42 (fitness), ATL τ=7 (fatigue), TSB=CTL−ATL.
  public static func performanceModel(dailyLoads: [Double], ctlTau: Double = 42, atlTau: Double = 7) -> [Load] {
    let kc = exp(-1 / ctlTau), ka = exp(-1 / atlTau)
    var ctl = 0.0, atl = 0.0; var out = [Load]()
    for L in dailyLoads {
      ctl = ctl * kc + L * (1 - kc); atl = atl * ka + L * (1 - ka)
      out.append(Load(ctl: ctl, atl: atl, tsb: ctl - atl))
    }
    return out
  }

  /// ACWR — SOFT TREND ONLY (contested: Lolli 2019 / Impellizzeri 2020-21). Never a thresholded injury alert.
  public static func acwr(acute: Double, chronic: Double) -> Double? { chronic == 0 ? nil : acute / chronic }

  /// Readiness 0-100 — the headline composite (broader than Recovery): recovery + sleep + TSB balance,
  /// minus an illness penalty. Transparent tunable weights 0.5/0.3/0.2.
  public static func readiness(recovery: Double, sleepScore: Double, tsbNorm: Double,
                               illnessPenalty: Double = 0) -> Double {
    min(100, max(0, 0.5 * recovery + 0.3 * sleepScore + 0.2 * tsbNorm - illnessPenalty))
  }
}
