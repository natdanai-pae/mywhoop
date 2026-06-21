import Foundation

/// L1 — HR-derived physiology: HRmax, Karvonen HRR zones, Uth VO₂max.
/// Params locked in METRICS-TUNING-LOCK.md (Tanaka 2001; Uth 2004).
public enum Physiology {
  /// Tanaka 2001 (JACC 37:153) — cold-start estimate; SD ±10bpm → prefer a MEASURED peak.
  public static func tanakaHRmax(age: Double) -> Double { 208 - 0.7 * age }

  /// Heart-rate reserve fraction (Karvonen).
  public static func karvonenHRR(hr: Double, hrMax: Double, hrRest: Double) -> Double {
    (hr - hrRest) / (hrMax - hrRest)
  }

  /// 5-zone index (0=Z1 recovery … 4=Z5 max) by %HRR bands at 0.5/0.6/0.7/0.8/0.9.
  /// Banister TRIMP increment for one interval. Male: 0.64*e^(1.92*HRR), female: 0.86*e^(1.67*HRR).
  public static func banisterTRIMP(dtMin: Double, hrr: Double, male: Bool) -> Double {
    let x = max(0, min(1, hrr))
    let factor = male ? 0.64 * exp(1.92 * x) : 0.86 * exp(1.67 * x)
    return max(0, dtMin) * x * factor
  }

  public static func karvonenZone(hr: Double, hrMax: Double, hrRest: Double) -> Int {
    let r = karvonenHRR(hr: hr, hrMax: hrMax, hrRest: hrRest)
    if r < 0.5 { return 0 }
    if r >= 1.0 { return 4 }
    return Int((r - 0.5) / 0.1) + 1
  }

  /// Uth 2004 — VO₂max ≈ 15.3 · HRmax / HRrest. Accuracy hinges on a correct measured HRmax + RHR.
  public static func uthVO2max(hrMax: Double, hrRest: Double) -> Double { 15.3 * hrMax / hrRest }

  /// Keytel 2005 (J Sports Sci 23:289) — energy expenditure from HR, kcal/min. Sex-specific coefficients.
  public static func kcalPerMin(hr: Double, weightKg: Double, age: Double, male: Bool = true) -> Double {
    let v = male ? (-55.0969 + 0.6309 * hr + 0.1988 * weightKg + 0.2017 * age)
                 : (-20.4022 + 0.4472 * hr - 0.1263 * weightKg + 0.0740 * age)
    return max(0, v / 4.184)                       // kJ/min → kcal/min
  }

  /// Mifflin-St Jeor 1990 (Am J Clin Nutr 51:241) — basal metabolic rate, kcal/day.
  public static func mifflinBMR(weightKg: Double, heightCm: Double, age: Double, male: Bool) -> Double {
    10 * weightKg + 6.25 * heightCm - 5 * age + (male ? 5 : -161)
  }
  /// C3 — Katch-McArdle: BMR from LEAN body mass (kcal/day). More accurate than Mifflin for lean/athletic bodies
  /// because it removes the metabolically-quiet fat mass. `bodyFatPct` in percent (e.g. 18 = 18%).
  public static func katchMcArdleBMR(weightKg: Double, bodyFatPct: Double) -> Double {
    let lbm = weightKg * (1 - bodyFatPct / 100)
    return 370 + 21.6 * lbm
  }
  /// C2 — EPOC ("afterburn") kcal from a session, Firstbeat-style: extra energy burned recovering AFTER exercise,
  /// scaling with intensity. Approximated as a fraction of the session's active kcal that rises with strain
  /// (~5% easy → ~15% all-out on the 0-21 Banister scale). Deliberately conservative (EPOC is small + uncertain).
  public static func epocKcal(strain: Double, activeKcal: Double) -> Double {
    let frac = min(0.15, max(0.03, 0.03 + strain / 21 * 0.12))
    return max(0, activeKcal * frac)
  }

  /// METs added per g of mean |accel|−1g (wrist). UNCALIBRATED placeholder — tune vs WHOOP day-kcal.
  static let accelMETGain = 20.0

  /// Q6 — branched HR+accel energy expenditure, kcal/min (Brage 2004-style branch).
  /// Adds a Mifflin resting floor so sedentary minutes still accrue (Keytel alone clamps to ~0 at rest →
  /// undercounts daily total), then blends an accel path (trusted at low HR, where HR is noisy) with the
  /// Keytel HR path (trusted at high HR) by HR-reserve. `accelG` = mean |accel|−1g over the interval;
  /// pass nil when no IMU (live-only tier) → HR path + resting floor.
  public static func branchedKcalPerMin(hr: Double, accelG: Double?, weightKg: Double, heightCm: Double,
                                        age: Double, male: Bool, hrMax: Double, hrRest: Double) -> Double {
    let rmr = mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, male: male) / 1440  // kcal/min, ≈1 MET
    let hrEE = max(rmr, kcalPerMin(hr: hr, weightKg: weightKg, age: age, male: male))           // HR (Keytel) path
    let accEE: Double
    if let a = accelG {
      let mets = min(10, max(0, accelMETGain * a))                                              // extra METs from motion
      accEE = rmr * (1 + mets)
    } else { accEE = hrEE }                                                                     // no IMU → HR path
    let hrr = max(0, min(1, (hr - hrRest) / (hrMax - hrRest)))
    let w = max(0, min(1, (hrr - 0.30) / (0.50 - 0.30)))                                        // 0→all accel, 1→all HR
    return w * hrEE + (1 - w) * accEE
  }

  /// D1 — Compendium of Physical Activities (Ainsworth/ACSM) typical MET by our activity types. `kcal = MET·kg·h`.
  public static func metForActivity(_ type: String) -> Double {
    switch type {
    case "Run": return 9.0
    case "Bike": return 7.0
    case "Walk": return 3.5
    case "Strength": return 5.0
    case "HIIT": return 8.0
    case "Cardio": return 7.0
    case "Yoga": return 2.5
    case "Swim": return 8.0
    default: return 6.0                                   // Other / Auto
    }
  }
  /// MET-based energy (kcal) for a session: MET × 3.5 × kg ÷ 200 × minutes (ACSM).
  public static func metKcal(type: String, weightKg: Double, minutes: Double) -> Double {
    metForActivity(type) * 3.5 * weightKg / 200 * max(0, minutes)
  }
  /// Activity types where HR is an UNRELIABLE energy proxy (static/intermittent work) → always use type-MET.
  public static let hrUnreliableTypes: Set<String> = ["Strength", "Yoga"]
  /// G1/D2 — type-aware HR-gate reconciliation. Strength/Yoga: HR doesn't track the work (static lifts, isometrics)
  /// → use the activity-type MET. Cardio: HR-based energy is trustworthy only when genuinely elevated
  /// (avg HRR ≥ 0.30, steady-state); otherwise fall back to MET. Returns (kcal, method "HR"|"MET").
  public static func reconcileSessionKcal(hrKcal: Double, type: String, weightKg: Double, minutes: Double,
                                          avgHRR: Double) -> (kcal: Double, method: String) {
    if hrUnreliableTypes.contains(type) { return (metKcal(type: type, weightKg: weightKg, minutes: minutes), "MET") }
    if avgHRR >= 0.30 { return (hrKcal, "HR") }
    return (metKcal(type: type, weightKg: weightKg, minutes: minutes), "MET")
  }
  /// D3 — calories from step count (ACSM walking): stride_m = height·0.414 → distance → ~0.74 kcal/kg/km
  /// (gross, level ground; ≈ 3.5 MET at ~5 km/h).
  public static func stepsKcal(steps: Int, weightKg: Double, heightCm: Double) -> Double {
    let strideM = heightCm / 100 * 0.414
    let km = Double(max(0, steps)) * strideM / 1000
    return km * weightKg * 0.74
  }

  /// C4 — daily energy balance for weight management. `expended` = best total-burn estimate (typically TDEE).
  /// balance = intake − expended: negative = deficit (loss), positive = surplus (gain). Safe loss ≈ 0.5-1 lb/wk;
  /// flagged aggressive past ~1% body-weight/wk or a >1000 kcal/day deficit (muscle-loss risk).
  public struct EnergyBalance: Equatable {
    public let expended: Double, intake: Double, weightKg: Double
    public init(expended: Double, intake: Double, weightKg: Double) {
      self.expended = expended; self.intake = intake; self.weightKg = weightKg
    }
    public var balance: Double { intake - expended }
    public var kgPerWeek: Double { balance * 7 / 7700 }        // 7700 kcal ≈ 1 kg
    public var lbPerWeek: Double { balance * 7 / 3500 }        // 3500 kcal ≈ 1 lb
    /// "deficit_aggressive" | "deficit_healthy" | "maintenance" | "surplus"
    public var status: String {
      let safeKgPerWk = weightKg * 0.01                         // ~1%/wk ceiling
      if balance <= -250 { return (-kgPerWeek > safeKgPerWk || balance < -1000) ? "deficit_aggressive" : "deficit_healthy" }
      if balance >= 250 { return "surplus" }
      return "maintenance"
    }
  }

  /// Tier 3 (Firstbeat-style) — estimated recovery time in HOURS from strain + current recovery. Capped at 72h.
  public static func recoveryHours(strain: Double, recovery: Double) -> Double {
    let factor = 1.3 - recovery / 100 * 0.8                    // poor recovery (0)→1.3, great (100)→0.5
    return min(72, (max(0, strain) * 2.2 * factor)).rounded()
  }
  /// Training Effect label from strain (0-21 Banister scale), Firstbeat-style bands.
  public static func trainingEffect(strain: Double) -> String {
    strain >= 18 ? "Overreaching" : (strain >= 14 ? "Highly improving"
      : (strain >= 10 ? "Improving" : (strain >= 5 ? "Maintaining" : "Minor")))
  }
  /// WHOOP strain band label for a 0-21 value.
  public static func strainBand(_ s: Double) -> String {
    s >= 18 ? "All-out" : (s >= 14 ? "High" : (s >= 10 ? "Moderate" : "Light"))
  }
  /// Aerobic Training Effect 0-5 (Garmin/EPOC-style) — accumulated low-to-mid zone time drives endurance gains.
  /// `zoneMin` = minutes in Z1…Z5.
  public static func trainingEffectAerobic(zoneMin: [Double]) -> Double {
    guard zoneMin.count >= 5 else { return 0 }
    let load = zoneMin[1] + 2 * zoneMin[2] + 3 * zoneMin[3] + zoneMin[4]   // Z2..Z5 weighted toward mid
    return min(5, load / 30)
  }
  /// Anaerobic Training Effect 0-5 — high-intensity (Z4-Z5) time drives anaerobic/glycolytic gains.
  public static func trainingEffectAnaerobic(zoneMin: [Double]) -> Double {
    guard zoneMin.count >= 5 else { return 0 }
    let load = zoneMin[3] + 3 * zoneMin[4]
    return min(5, load / 8)
  }
  /// Tier 3 (Kubios-style) — autonomic balance from Poincaré SD1 (parasympathetic) vs SD2 (sympathetic-leaning).
  /// Higher SD1/SD2 = more parasympathetic (rest/recovery) dominance. Returns (ratio, label).
  public static func autonomicBalance(sd1: Double, sd2: Double) -> (ratio: Double, label: String) {
    guard sd2 > 0 else { return (0, "—") }
    let r = sd1 / sd2
    return (r, r >= 0.5 ? "Parasympathetic (recovery)" : (r >= 0.3 ? "Balanced" : "Sympathetic (stress)"))
  }
  /// Fitness age — the "cardio fitness age" idea (Garmin Fitness Age / Apple Cardio Fitness / Oura cardiovascular
  /// age): the age at which your VO₂max would be age-typical, then nudged by resting HR and body fat. A higher-than-
  /// expected VO₂max ⇒ a younger fitness age. Reference curve = the HealthRef good-band anchors (men 38→25, women
  /// 33→21 over 20→60), i.e. ref(age)=base − slope·(age−20); invert to solve for the age.
  /// `bodyFatPct` and `smi` (skeletal-muscle index = SMM ÷ height², kg/m²) are best taken MEASURED from an InBody
  /// scan — far more accurate than a profile estimate. VO₂max stays the primary driver (the fitness-age definition);
  /// body fat and muscle are secondary composition modifiers.
  public static func fitnessAge(vo2max: Double, rhr: Double?, bodyFatPct: Double?, smi: Double? = nil,
                                age: Double, male: Bool) -> Double {
    fitnessAgeBreakdown(vo2max: vo2max, rhr: rhr, bodyFatPct: bodyFatPct, smi: smi,
                        measured: false, age: age, male: male).fitnessAge
  }

  /// One input's contribution to the fitness age. `deltaYears` > 0 adds years (older); < 0 subtracts (younger),
  /// relative to the VO₂max-only baseline. `measured` = the value came from a real InBody scan, not an estimate.
  public struct FitnessAgeTerm: Equatable, Sendable {
    public let key: String           // "rhr" | "fat" | "muscle"
    public let inputValue: Double
    public let deltaYears: Double
    public let measured: Bool
    public init(key: String, inputValue: Double, deltaYears: Double, measured: Bool) {
      self.key = key; self.inputValue = inputValue; self.deltaYears = deltaYears; self.measured = measured
    }
  }
  /// Full decomposition of the fitness age, so the detail page can SHOW the math and advise on the biggest lever.
  public struct FitnessAgeBreakdown: Equatable, Sendable {
    public let fitnessAge: Double      // final, clamped
    public let chronoAge: Double
    public let vo2: Double
    public let vo2BaselineAge: Double  // the cardio-only age, before the composition modifiers
    public let terms: [FitnessAgeTerm]
    public init(fitnessAge: Double, chronoAge: Double, vo2: Double, vo2BaselineAge: Double, terms: [FitnessAgeTerm]) {
      self.fitnessAge = fitnessAge; self.chronoAge = chronoAge; self.vo2 = vo2
      self.vo2BaselineAge = vo2BaselineAge; self.terms = terms
    }
  }
  public static func fitnessAgeBreakdown(vo2max: Double, rhr: Double?, bodyFatPct: Double?, smi: Double? = nil,
                                         measured: Bool = false, age: Double, male: Bool) -> FitnessAgeBreakdown {
    let base = male ? 38.0 : 33.0
    let slope = male ? 0.325 : 0.30
    let vo2BaselineAge = 20 + (base - vo2max) / slope
    var fa = vo2BaselineAge
    var terms: [FitnessAgeTerm] = []
    if let r = rhr {
      let d = (r - 60) * 0.08; fa += d                                  // lower resting HR → a little younger
      terms.append(FitnessAgeTerm(key: "rhr", inputValue: r, deltaYears: d, measured: true))
    }
    if let bf = bodyFatPct {
      let d = (bf - (male ? 18.0 : 25.0)) * 0.15; fa += d               // leaner than healthy → a little younger
      terms.append(FitnessAgeTerm(key: "fat", inputValue: bf, deltaYears: d, measured: measured))
    }
    if let smi = smi {
      let ref = male ? 8.5 : 6.5                                        // healthy young-adult SMI (kg/m²)
      let d = (ref - smi) * 1.5; fa += d                                // more muscle-for-height → a little younger
      terms.append(FitnessAgeTerm(key: "muscle", inputValue: smi, deltaYears: d, measured: measured))
    }
    return FitnessAgeBreakdown(fitnessAge: min(85, max(18, fa)), chronoAge: age, vo2: vo2max,
                               vo2BaselineAge: vo2BaselineAge, terms: terms)
  }
}
