import Foundation

/// Cited population reference norms, by age & sex — the "compared against what" for personalized analysis.
/// Sources: HRV RMSSD age decline (Welltory/Cora norms), ACSM/Cooper VO₂max categories, AHA RHR 60–100
/// (women ~+4 bpm), National Sleep Foundation duration by age, FAO/WHO PAL.
public enum HealthRef {
  /// Typical resting RMSSD (ms) for an age — population declines ~linearly (≈46@22 → ≈24@60); women a touch higher.
  public static func hrvTypical(age: Double, male: Bool) -> Double {
    max(15, (male ? 58 : 61) - 0.55 * age)
  }
  /// Athletic RHR cut-off (bpm): below = athletic; women run ~4 bpm higher.
  public static func rhrAthleticCut(male: Bool) -> Double { male ? 60 : 64 }

  /// National Sleep Foundation need (h): adults 18–64 → 7–9 (mid 8); 65+ → 7–8 (mid 7.5); teens 8–10.
  public static func sleepNeed(age: Double) -> Double { age >= 65 ? 7.5 : (age < 18 ? 9 : 8) }

  /// Healthy sleep-stage proportions for an adult (AASM / Ohayon 2004 meta-norms), as %.
  /// Deep (N3) is %-of-TST and falls markedly with age (~18%@25 → ~12%@60); REM/Light are %-of-TST; Wake is a
  /// MAX %-of-time-in-bed (WASO). REM 20–25%, Light(N1+N2) 50–60% are roughly age-stable in healthy adults.
  public struct StageNorms: Equatable {
    public let deep: ClosedRange<Double>, rem: ClosedRange<Double>, light: ClosedRange<Double>, wakeMax: Double
  }
  public static func sleepStageNorms(age: Double) -> StageNorms {
    let deepMid = max(8.0, 18 - 0.18 * max(0, age - 25))      // ~18%@25 → ~11.7%@60
    return StageNorms(deep: (deepMid - 5)...(deepMid + 5), rem: 20...25, light: 50...60, wakeMax: 10)
  }

  /// Healthy body-fat % band by sex & age (ACE/ACSM "fitness"→"acceptable" zone, drifting up slightly with age).
  /// Men ≈ 11–22% (20s) creeping to ≈ 13–25% (60s); women ≈ 19–30% → ≈ 22–33%. Used for the Body-fat trend band.
  public static func bodyFatNorms(age: Double, male: Bool) -> ClosedRange<Double> {
    let drift = max(0, age - 25) * 0.08                       // ~+0.08%/yr past 25
    return male ? (11 + drift)...(22 + drift) : (19 + drift)...(30 + drift)
  }

  /// Reference (100%-normal) weight / skeletal-muscle / fat mass for a person's height+sex — drives the
  /// InBody-style Muscle-Fat Analysis (each bar = value ÷ this normal). Normal weight = BMI 22; normal fat mass =
  /// mid body-fat-norm × normal weight; normal SMM ≈ 0.54 × the resulting lean mass (SMM is roughly half of FFM).
  public struct BodyNormals: Equatable { public let weightKg, smmKg, fatMassKg: Double }
  public static func bodyNormals(heightM: Double, age: Double, male: Bool) -> BodyNormals {
    let h = heightM > 0 ? heightM : 1.7
    let nWeight = 22.0 * h * h
    let fatMid = (bodyFatNorms(age: age, male: male).lowerBound + bodyFatNorms(age: age, male: male).upperBound) / 2
    let nFat = nWeight * fatMid / 100
    let nSMM = (nWeight - nFat) * 0.54
    return BodyNormals(weightKg: nWeight, smmKg: nSMM, fatMassKg: nFat)
  }

  /// ACSM/Cooper "good"-band lower bound of VO₂max (ml/kg/min) by sex & age decade.
  public static func vo2Good(age: Double, male: Bool) -> Double {
    let dec = min(max(Int(age / 10), 2), 6)                          // clamp to 20s…60s
    let men: [Int: Double] = [2: 38, 3: 34, 4: 31, 5: 28, 6: 25]
    let women: [Int: Double] = [2: 33, 3: 30, 4: 27, 5: 24, 6: 21]
    return (male ? men : women)[dec] ?? (male ? 31 : 27)
  }
  /// VO₂max category relative to the age/sex "good" band.
  public static func vo2Label(_ v: Double, age: Double, male: Bool) -> String {
    let g = vo2Good(age: age, male: male)
    if v < 0.80 * g { return "Poor" }
    if v < g { return "Fair" }
    if v < 1.15 * g { return "Good" }
    if v < 1.30 * g { return "Excellent" }
    return "Superior"
  }

  public static func bmiCategory(_ bmi: Double) -> String {
    if bmi < 18.5 { return "Underweight" }
    if bmi < 25 { return "Healthy" }
    if bmi < 30 { return "Overweight" }
    return "Obese"
  }
}
