import Foundation

/// One body-composition scan (e.g. an InBody result sheet parsed from a photo). All metrics optional — different
/// devices report different subsets. Stored as a time series so the Body screen can trend muscle/fat/etc. over scans.
public struct BodyScan: Codable, Equatable, Identifiable {
  public var ts: Double                  // scan time (unix). id derives from it.
  public var weightKg: Double?
  public var bmi: Double?
  public var bodyFatPct: Double?         // PBF
  public var bodyFatMassKg: Double?      // BFM
  public var leanKg: Double?             // fat-free / lean body mass (FFM)
  public var smmKg: Double?              // skeletal muscle mass (SMM)
  public var bmr: Double?                // basal metabolic rate (kcal/day) — measured
  public var visceralFat: Double?        // visceral fat area (cm²) or level
  public var bodyWaterL: Double?         // total body water
  public var proteinKg: Double?
  public var mineralsKg: Double?
  public var inbodyScore: Double?        // 0-100 (or "fitness score")
  public var metabolicAge: Double?       // body/metabolic age (years), if reported
  // --- Phase 1 (2026-06-12): advanced InBody fields the photo OCR can read but Apple Health has no HKType for ---
  public var segmentalLeanKg: [Double]?  // lean mass per segment, order [RA, LA, Trunk, RL, LL] (BodyComposition.Seg)
  public var segmentalFatKg: [Double]?   // fat mass per segment, same order (some sheets report it)
  public var ecwTbw: Double?             // ECW/TBW ratio (~0.380; >0.390 = edema/inflammation)
  public var phaseAngle: Double?         // whole-body phase angle (°) at 50 kHz — cellular integrity
  public var vatSat: Double?             // visceral/subcutaneous fat ratio (metabolic risk), if reported
  public var source: String?             // "photo" (OCR) | "health" (Apple Health import). nil → photo (legacy).
  // --- Phase 5 (2026-06-12): full-sheet capture for the expanded viz ---
  public var icwL: Double?               // intracellular water (L)
  public var ecwL: Double?               // extracellular water (L)
  public var segmentalLeanPct: [Double]? // lean "% of ideal" per segment [RA,LA,Trunk,RL,LL] (InBody's key number)
  public var segmentalFatPct: [Double]?  // fat "% of ideal" per segment, same order
  public var photoJPEG: String?          // base64 of the uploaded InBody sheet — kept for the progress overlay
  public var id: String { String(Int(ts)) }
  public init(ts: Double, weightKg: Double? = nil, bmi: Double? = nil, bodyFatPct: Double? = nil,
              bodyFatMassKg: Double? = nil, leanKg: Double? = nil, smmKg: Double? = nil, bmr: Double? = nil,
              visceralFat: Double? = nil, bodyWaterL: Double? = nil, proteinKg: Double? = nil,
              mineralsKg: Double? = nil, inbodyScore: Double? = nil, metabolicAge: Double? = nil,
              segmentalLeanKg: [Double]? = nil, segmentalFatKg: [Double]? = nil, ecwTbw: Double? = nil,
              phaseAngle: Double? = nil, vatSat: Double? = nil, source: String? = nil,
              icwL: Double? = nil, ecwL: Double? = nil, segmentalLeanPct: [Double]? = nil,
              segmentalFatPct: [Double]? = nil, photoJPEG: String? = nil) {
    self.ts = ts; self.weightKg = weightKg; self.bmi = bmi; self.bodyFatPct = bodyFatPct
    self.bodyFatMassKg = bodyFatMassKg; self.leanKg = leanKg; self.smmKg = smmKg; self.bmr = bmr
    self.visceralFat = visceralFat; self.bodyWaterL = bodyWaterL; self.proteinKg = proteinKg
    self.mineralsKg = mineralsKg; self.inbodyScore = inbodyScore; self.metabolicAge = metabolicAge
    self.segmentalLeanKg = segmentalLeanKg; self.segmentalFatKg = segmentalFatKg; self.ecwTbw = ecwTbw
    self.phaseAngle = phaseAngle; self.vatSat = vatSat; self.source = source
    self.icwL = icwL; self.ecwL = ecwL; self.segmentalLeanPct = segmentalLeanPct
    self.segmentalFatPct = segmentalFatPct; self.photoJPEG = photoJPEG
  }
  /// Intracellular water — direct field, else derived from TBW − ECW (ECW from the ratio).
  public var icwDerived: Double? { icwL ?? (bodyWaterL.flatMap { tbw in ecwDerived.map { tbw - $0 } }) }
  /// Extracellular water — direct field, else TBW × ECW/TBW ratio.
  public var ecwDerived: Double? { ecwL ?? (bodyWaterL.flatMap { tbw in ecwTbw.map { tbw * $0 } }) }

  /// Parse a body-composition scan out of a model's JSON reply (tolerant of stray text around the object).
  /// Pure (no UI) so it's unit-tested; `LLMCoach.estimateBodyScan` calls it after the vision request.
  /// Segmental sub-objects {ra,la,tr,rl,ll} → [RA, LA, Trunk, RL, LL]; built only when ≥ the 4 limbs are present.
  public static func parse(fromJSON text: String, ts: Double, source: String = "photo") -> BodyScan? {
    guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
          let j = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any] else { return nil }
    func d(_ k: String) -> Double? { (j[k] as? Double) ?? (j[k] as? Int).map(Double.init) ?? (j[k] as? String).flatMap { Double($0) } }
    func seg(_ key: String) -> [Double]? {
      guard let o = j[key] as? [String: Any] else { return nil }
      func v(_ k: String) -> Double? { (o[k] as? Double) ?? (o[k] as? Int).map(Double.init) ?? (o[k] as? String).flatMap { Double($0) } }
      guard let ra = v("ra"), let la = v("la"), let rl = v("rl"), let ll = v("ll") else { return nil }
      return [ra, la, v("tr") ?? 0, rl, ll]
    }
    let scan = BodyScan(ts: ts, weightKg: d("weightKg"), bmi: d("bmi"), bodyFatPct: d("bodyFatPct"),
      bodyFatMassKg: d("bodyFatMassKg"), leanKg: d("leanKg"), smmKg: d("smmKg"), bmr: d("bmr"),
      visceralFat: d("visceralFat"), bodyWaterL: d("bodyWaterL"), proteinKg: d("proteinKg"),
      mineralsKg: d("mineralsKg"), inbodyScore: d("inbodyScore"), metabolicAge: d("metabolicAge"),
      segmentalLeanKg: seg("segLean"), segmentalFatKg: seg("segFat"), ecwTbw: d("ecwTbw"),
      phaseAngle: d("phaseAngle"), vatSat: d("vatSat"), source: source,
      icwL: d("icwL"), ecwL: d("ecwL"), segmentalLeanPct: seg("segLeanPct"), segmentalFatPct: seg("segFatPct"))
    return (scan.weightKg != nil || scan.bodyFatPct != nil) ? scan : nil   // need at least one core value
  }
}
