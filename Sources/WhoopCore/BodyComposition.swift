import Foundation

/// Pure body-composition analytics over `BodyScan`s — segmental balance, recomposition direction, and
/// healthy-range classification for the InBody-style health metrics. No UI, no I/O → fully unit-tested.
/// Research-grounded: InBody visceral <100 cm² / level <10; ECW/TBW healthy 0.360–0.390; recomposition =
/// muscle ↑ while fat ↓ (the change the scale hides).
public enum BodyComposition {

  /// Segment indices into `BodyScan.segmentalLeanKg` / `segmentalFatKg` — InBody's top-to-bottom sheet order.
  public enum Seg: Int, CaseIterable {
    case rightArm = 0, leftArm, trunk, rightLeg, leftLeg
    public var label: String {
      switch self { case .rightArm: return "Right arm"; case .leftArm: return "Left arm"
      case .trunk: return "Trunk"; case .rightLeg: return "Right leg"; case .leftLeg: return "Left leg" }
    }
    public var short: String {
      switch self { case .rightArm: return "R arm"; case .leftArm: return "L arm"
      case .trunk: return "Trunk"; case .rightLeg: return "R leg"; case .leftLeg: return "L leg" }
    }
  }

  /// Where a value sits relative to a healthy band.
  public enum Band: String { case below, inRange, above }

  /// Left/right + upper/lower symmetry of segmental lean mass. An imbalance >10% flags asymmetric development.
  public struct Balance: Equatable {
    public let upperKg: Double     // arms (RA + LA)
    public let lowerKg: Double     // legs (RL + LL)
    public let trunkKg: Double
    public let armDiffPct: Double  // |RA − LA| / mean × 100
    public let legDiffPct: Double  // |RL − LL| / mean × 100
    public var armBalanced: Bool { armDiffPct <= 10 }
    public var legBalanced: Bool { legDiffPct <= 10 }
    /// Limb (arms+legs) share of total segmental lean — a high trunk share with low limbs can mean under-developed limbs.
    public var limbToTrunk: Double { trunkKg > 0 ? (upperKg + lowerKg) / trunkKg : 0 }
  }

  public static func balance(_ seg: [Double]) -> Balance? {
    guard seg.count == 5 else { return nil }
    let ra = seg[Seg.rightArm.rawValue], la = seg[Seg.leftArm.rawValue], tr = seg[Seg.trunk.rawValue]
    let rl = seg[Seg.rightLeg.rawValue], ll = seg[Seg.leftLeg.rawValue]
    func diffPct(_ a: Double, _ b: Double) -> Double { let m = (a + b) / 2; return m > 0 ? abs(a - b) / m * 100 : 0 }
    return Balance(upperKg: ra + la, lowerKg: rl + ll, trunkKg: tr,
                   armDiffPct: diffPct(ra, la), legDiffPct: diffPct(rl, ll))
  }

  // MARK: - Recomposition (muscle vs fat direction between two scans)

  public enum Recomp: String {
    case recomposing      // muscle ↑ AND fat ↓ — the ideal
    case buildingMuscle   // muscle ↑, fat ~flat/↑slightly
    case losingFat        // fat ↓, muscle ~held
    case losingBoth       // fat ↓ but muscle ↓ too (under-eating / muscle loss)
    case gainingFat       // fat ↑, muscle not up
    case losingMuscle     // muscle ↓ without fat ↓
    case stable
  }

  public struct RecompResult: Equatable {
    public let fatDeltaKg: Double      // + gained fat, − lost fat
    public let muscleDeltaKg: Double   // + gained muscle, − lost
    public let weightDeltaKg: Double
    public let status: Recomp
    /// True when the scale moved little but composition changed meaningfully (the "scale hides progress" case).
    public var hiddenByScale: Bool { abs(weightDeltaKg) < 0.8 && (abs(fatDeltaKg) >= 0.3 || abs(muscleDeltaKg) >= 0.3) }
  }

  /// Compare two scans. Muscle = SMM if present else lean; fat = fat mass if present else weight×fat%.
  public static func recomposition(curr: BodyScan, prev: BodyScan) -> RecompResult? {
    func muscle(_ s: BodyScan) -> Double? { s.smmKg ?? s.leanKg }
    func fat(_ s: BodyScan) -> Double? { s.bodyFatMassKg ?? (s.bodyFatPct.flatMap { p in s.weightKg.map { $0 * p / 100 } }) }
    guard let m0 = muscle(prev), let m1 = muscle(curr), let f0 = fat(prev), let f1 = fat(curr) else { return nil }
    let dM = m1 - m0, dF = f1 - f0
    let w0 = prev.weightKg ?? (m0 + f0), w1 = curr.weightKg ?? (m1 + f1)
    let mUp = dM > 0.2, mDown = dM < -0.2, fUp = dF > 0.2, fDown = dF < -0.2
    let status: Recomp = {
      if mUp && fDown { return .recomposing }
      if mDown && fDown { return .losingBoth }
      if mUp { return .buildingMuscle }
      if fDown { return .losingFat }
      if fUp { return .gainingFat }
      if mDown { return .losingMuscle }
      return .stable
    }()
    return RecompResult(fatDeltaKg: dF, muscleDeltaKg: dM, weightDeltaKg: w1 - w0, status: status)
  }

  // MARK: - Healthy-range classification (for the bullet gauges)

  /// A value + the healthy band + axis extent that drives a bullet gauge. `lowerIsBetter` orients the verdict arrow.
  public struct Gauge: Equatable {
    public let value: Double
    public let axisMin: Double, axisMax: Double
    public let goodLo: Double, goodHi: Double
    public let lowerIsBetter: Bool
    /// True for one-sided metrics (visceral, phase angle, score…) where out-of-band on the "good" side is still fine.
    /// False for band-is-best metrics (ECW/TBW) where BOTH tails are unhealthy.
    public let directional: Bool
    public init(value: Double, axisMin: Double, axisMax: Double, goodLo: Double, goodHi: Double,
                lowerIsBetter: Bool, directional: Bool = true) {
      self.value = value; self.axisMin = axisMin; self.axisMax = axisMax
      self.goodLo = goodLo; self.goodHi = goodHi; self.lowerIsBetter = lowerIsBetter; self.directional = directional
    }
    public var band: Band { value < goodLo ? .below : (value > goodHi ? .above : .inRange) }
    /// inRange is always good; otherwise good only if directional AND the out-of-range side is the "better" one.
    public var isHealthy: Bool {
      switch band {
      case .inRange: return true
      case .below: return directional && lowerIsBetter
      case .above: return directional && !lowerIsBetter
      }
    }
  }

  /// Visceral fat. InBody recommends Area <100 cm² (`isArea`) or Level <10. Treat the whole healthy zone as the band.
  public static func visceralGauge(_ v: Double, isArea: Bool) -> Gauge {
    let hi = isArea ? 100.0 : 9.0
    return Gauge(value: v, axisMin: 0, axisMax: isArea ? 200 : 20, goodLo: 0, goodHi: hi, lowerIsBetter: true)
  }
  /// ECW/TBW — fluid balance. Healthy 0.360–0.390; >0.390 = edema/inflammation, <0.360 typical of high muscle.
  public static func ecwTbwGauge(_ r: Double) -> Gauge {
    Gauge(value: r, axisMin: 0.34, axisMax: 0.42, goodLo: 0.360, goodHi: 0.390, lowerIsBetter: false, directional: false)
  }
  /// Phase angle (°) — cellular integrity; higher is better. Healthy adult band ≈ 5–7° (sex/age vary).
  public static func phaseAngleGauge(_ p: Double) -> Gauge {
    Gauge(value: p, axisMin: 3, axisMax: 9, goodLo: 5.0, goodHi: 7.5, lowerIsBetter: false)
  }
  /// InBody score 0–100 — ≥80 generally indicates a well-balanced body. Higher better.
  public static func scoreGauge(_ s: Double) -> Gauge {
    Gauge(value: s, axisMin: 40, axisMax: 100, goodLo: 80, goodHi: 100, lowerIsBetter: false)
  }
  /// Metabolic age vs chronological age — younger (≤ actual) is better.
  public static func metabolicAgeGauge(_ metaAge: Double, actualAge: Double) -> Gauge {
    Gauge(value: metaAge, axisMin: max(15, actualAge - 20), axisMax: actualAge + 20,
          goodLo: 0, goodHi: actualAge, lowerIsBetter: true)
  }

  // MARK: - Muscle-Fat Analysis (InBody C / I / D shape)

  public enum BodyShape: String { case c, i, d }   // C=fat-dominant, I=balanced, D=muscle-dominant (athletic)

  /// Each bar = value ÷ its 100%-normal, as a %. Connecting Weight→SMM→Fat endpoints gives the C/I/D shape.
  public struct MuscleFat: Equatable {
    public let weightPct: Double, smmPct: Double, fatPct: Double   // each vs its normal (100 = normal)
    public let shape: BodyShape
    public var shapeLabel: String {
      switch shape { case .d: return "D-shape · strong / athletic"
      case .c: return "C-shape · build muscle, lower fat"; case .i: return "I-shape · balanced" }
    }
  }
  /// Needs weight + SMM(or lean) + fat mass(or fat%). nil if it can't form all three bars.
  public static func muscleFat(_ s: BodyScan, normals: HealthRef.BodyNormals) -> MuscleFat? {
    let smm = s.smmKg ?? s.leanKg.map { $0 * 0.54 }
    let fat = s.bodyFatMassKg ?? (s.bodyFatPct.flatMap { p in s.weightKg.map { $0 * p / 100 } })
    guard let w = s.weightKg, let smm = smm, let fat = fat, normals.weightKg > 0, normals.smmKg > 0, normals.fatMassKg > 0 else { return nil }
    let wp = w / normals.weightKg * 100, sp = smm / normals.smmKg * 100, fp = fat / normals.fatMassKg * 100
    let shape: BodyShape = (sp >= wp + 5 && sp >= fp + 5) ? .d : ((fp >= wp + 5 && fp >= sp + 5) ? .c : .i)
    return MuscleFat(weightPct: wp, smmPct: sp, fatPct: fp, shape: shape)
  }

  // MARK: - Body profile radar (6 axes, each 0–100)

  public struct RadarAxis: Equatable { public let label: String; public let score: Double }   // score 0…100

  /// A 6-axis "how balanced is my body" profile: Muscle, Leanness, Fluid balance, Cellular health, Metabolic age,
  /// Symmetry. Each is a 0–100 score vs healthy references; axes with no data score a neutral 50.
  public static func radar(_ s: BodyScan, heightM: Double, age: Double, male: Bool) -> [RadarAxis] {
    func clamp(_ v: Double) -> Double { min(100, max(0, v)) }
    let normals = HealthRef.bodyNormals(heightM: heightM, age: age, male: male)
    // Muscle — SMM vs normal (100% normal → 70, +50% → 100)
    let smm = s.smmKg ?? s.leanKg.map { $0 * 0.54 }
    let muscle = smm.map { clamp(($0 / normals.smmKg - 0.6) / 0.6 * 100) } ?? 50
    // Leanness — body fat % vs the healthy band (in-band high, above-band drops)
    let bf = s.bodyFatPct
    let fn = HealthRef.bodyFatNorms(age: age, male: male)
    let lean = bf.map { v -> Double in v <= fn.upperBound ? clamp(95 - (v - fn.lowerBound) * 2) : clamp(70 - (v - fn.upperBound) * 4) } ?? 50
    // Fluid — ECW/TBW closeness to 0.380 (0.380→100, ±0.02→~0)
    let fluid = s.ecwTbw.map { clamp(100 - abs($0 - 0.380) / 0.02 * 60) } ?? 50
    // Cellular — phase angle (5°→70, 7.5°→100, 4°→40)
    let cell = s.phaseAngle.map { clamp(($0 - 3.5) / 4.0 * 100) } ?? 50
    // Metabolic age — younger than actual scores higher
    let meta = s.metabolicAge.map { clamp(75 + (age - $0) * 3) } ?? 50
    // Symmetry — 100 − worst limb imbalance %
    let sym = (s.segmentalLeanKg.flatMap(balance)).map { clamp(100 - max($0.armDiffPct, $0.legDiffPct) * 1.5) } ?? 50
    return [RadarAxis(label: "Muscle", score: muscle), RadarAxis(label: "Lean", score: lean),
            RadarAxis(label: "Fluid", score: fluid), RadarAxis(label: "Cellular", score: cell),
            RadarAxis(label: "Meta-age", score: meta), RadarAxis(label: "Symmetry", score: sym)]
  }

  // MARK: - Indices (need height)

  /// Skeletal Muscle Index = SMM / height² (kg/m²). Low SMI ↔ sarcopenia risk.
  public static func smi(smmKg: Double, heightM: Double) -> Double? { heightM > 0 ? smmKg / (heightM * heightM) : nil }
  /// Fat-Free Mass Index = lean / height² (kg/m²).
  public static func ffmi(leanKg: Double, heightM: Double) -> Double? { heightM > 0 ? leanKg / (heightM * heightM) : nil }
}
