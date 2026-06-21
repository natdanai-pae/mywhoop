import Testing
@testable import WhoopCore

// seg order [RA, LA, Trunk, RL, LL]

@Test func balanceDetectsArmAndLegAsymmetry() {
  // symmetric limbs → balanced
  let b = BodyComposition.balance([3.0, 3.0, 24.0, 9.0, 9.0])!
  #expect(b.armBalanced && b.legBalanced)
  #expect(b.upperKg == 6.0 && b.lowerKg == 18.0 && b.trunkKg == 24.0)
  // 3.0 vs 2.6 arms = ~14% diff → flagged
  let asym = BodyComposition.balance([3.0, 2.6, 24.0, 9.0, 9.0])!
  #expect(!asym.armBalanced && asym.legBalanced)
  #expect(asym.armDiffPct > 10)
}

@Test func balanceNeedsFiveSegments() {
  #expect(BodyComposition.balance([3, 3, 24, 9]) == nil)
}

@Test func recompositionDetectsMuscleUpFatDown() {
  let prev = BodyScan(ts: 0, weightKg: 80, bodyFatMassKg: 16, smmKg: 33)
  let curr = BodyScan(ts: 1, weightKg: 80, bodyFatMassKg: 14.5, smmKg: 34.5)   // +1.5 muscle, −1.5 fat, scale flat
  let r = BodyComposition.recomposition(curr: curr, prev: prev)!
  #expect(r.status == .recomposing)
  #expect(r.muscleDeltaKg > 0 && r.fatDeltaKg < 0)
  #expect(r.hiddenByScale)                          // weight barely moved but composition shifted
}

@Test func recompositionFallsBackToFatPercentWhenNoFatMass() {
  // only weight + body-fat% given → fat mass derived (80×20% = 16 → 79×18% = 14.22)
  let prev = BodyScan(ts: 0, weightKg: 80, bodyFatPct: 20, leanKg: 64)
  let curr = BodyScan(ts: 1, weightKg: 79, bodyFatPct: 18, leanKg: 64.7)
  let r = BodyComposition.recomposition(curr: curr, prev: prev)!
  #expect(r.status == .recomposing)
}

@Test func recompositionGainingFat() {
  let prev = BodyScan(ts: 0, weightKg: 80, bodyFatMassKg: 16, smmKg: 33)
  let curr = BodyScan(ts: 1, weightKg: 82, bodyFatMassKg: 18, smmKg: 33)
  #expect(BodyComposition.recomposition(curr: curr, prev: prev)!.status == .gainingFat)
}

@Test func recompositionNilWithoutEnoughData() {
  let prev = BodyScan(ts: 0, weightKg: 80)            // no muscle/fat
  let curr = BodyScan(ts: 1, weightKg: 79)
  #expect(BodyComposition.recomposition(curr: curr, prev: prev) == nil)
}

@Test func gaugesClassifyHealthyRanges() {
  #expect(BodyComposition.visceralGauge(85, isArea: true).isHealthy)       // <100 cm²
  #expect(!BodyComposition.visceralGauge(130, isArea: true).isHealthy)
  #expect(BodyComposition.visceralGauge(7, isArea: false).isHealthy)       // level <9
  #expect(BodyComposition.ecwTbwGauge(0.378).band == .inRange)
  #expect(BodyComposition.ecwTbwGauge(0.401).band == .above)               // edema side
  #expect(!BodyComposition.ecwTbwGauge(0.401).isHealthy)
  #expect(BodyComposition.phaseAngleGauge(6.0).isHealthy)                  // higher better, in band
  #expect(BodyComposition.phaseAngleGauge(4.0).band == .below)
  #expect(BodyComposition.scoreGauge(84).isHealthy)
  // metabolic age younger than actual → healthy; older → not
  #expect(BodyComposition.metabolicAgeGauge(23, actualAge: 28).isHealthy)
  #expect(!BodyComposition.metabolicAgeGauge(40, actualAge: 28).isHealthy)
}

@Test func indicesNeedHeight() {
  #expect(BodyComposition.smi(smmKg: 34, heightM: 1.83)! > 9)
  #expect(BodyComposition.ffmi(leanKg: 64, heightM: 1.83)! > 18)
  #expect(BodyComposition.smi(smmKg: 34, heightM: 0) == nil)
}

@Test func bodyFatNormsAreSexAndAgeAware() {
  let m = HealthRef.bodyFatNorms(age: 25, male: true)
  let w = HealthRef.bodyFatNorms(age: 25, male: false)
  #expect(m.lowerBound < w.lowerBound)               // women carry more essential fat
  let older = HealthRef.bodyFatNorms(age: 60, male: true)
  #expect(older.upperBound > m.upperBound)           // band drifts up with age
}

@Test func parseBodyScanReadsSegmentalAndAdvanced() {
  let json = """
  {"weightKg":83,"bodyFatPct":15.2,"smmKg":40.1,"visceralFat":78,"ecwTbw":0.378,"phaseAngle":6.4,
   "segLean":{"ra":3.9,"la":3.8,"tr":31.2,"rl":10.8,"ll":10.7},
   "segFat":{"ra":0.4,"la":0.4,"tr":6.1,"rl":1.3,"ll":1.3}}
  """
  let s = BodyScan.parse(fromJSON: json, ts: 100)!
  #expect(s.weightKg == 83 && s.phaseAngle == 6.4 && s.ecwTbw == 0.378)
  #expect(s.segmentalLeanKg == [3.9, 3.8, 31.2, 10.8, 10.7])
  #expect(s.segmentalFatKg?[0] == 0.4)
  #expect(s.source == "photo")
}

@Test func parseBodyScanSkipsSegmentalWhenLimbsMissing() {
  let s = BodyScan.parse(fromJSON: #"{"weightKg":83,"segLean":{"ra":3.9,"tr":31.2}}"#, ts: 1)!
  #expect(s.segmentalLeanKg == nil)                  // missing la/rl/ll → no array
}

// ---- Phase 5 (full-sheet capture + expanded analytics) ----

@Test func parseReadsWaterAndSegmentalPct() {
  let json = #"{"weightKg":83,"bodyWaterL":51.5,"icwL":30.5,"ecwL":21.0,"ecwTbw":0.378,"segLeanPct":{"ra":102,"la":92,"tr":101,"rl":100,"ll":99}}"#
  let s = BodyScan.parse(fromJSON: json, ts: 1)!
  #expect(s.icwL == 30.5 && s.ecwL == 21.0)
  #expect(s.segmentalLeanPct == [102, 92, 101, 100, 99])
}

@Test func waterDerivedFromRatioWhenNoSplit() {
  // no icwL/ecwL → derive from TBW × ratio
  let s = BodyScan(ts: 0, bodyWaterL: 50, ecwTbw: 0.38)
  #expect(abs(s.ecwDerived! - 19.0) < 0.001)
  #expect(abs(s.icwDerived! - 31.0) < 0.001)
  // direct fields win
  let s2 = BodyScan(ts: 0, bodyWaterL: 50, icwL: 32, ecwL: 18)
  #expect(s2.ecwDerived == 18 && s2.icwDerived == 32)
}

@Test func bodyNormalsScaleWithHeightAndSex() {
  let m = HealthRef.bodyNormals(heightM: 1.83, age: 25, male: true)
  #expect(m.weightKg > 70 && m.weightKg < 80)        // BMI 22 × 1.83²
  #expect(m.smmKg > m.fatMassKg)                      // muscle reference exceeds fat reference
  let w = HealthRef.bodyNormals(heightM: 1.83, age: 25, male: false)
  #expect(w.fatMassKg > m.fatMassKg)                 // women carry more essential fat
}

@Test func muscleFatDetectsDShape() {
  let n = HealthRef.bodyNormals(heightM: 1.83, age: 25, male: true)
  // strong: lots of muscle, low fat → D
  let athletic = BodyScan(ts: 0, weightKg: 83, bodyFatMassKg: 12.5, smmKg: 40.1)
  #expect(BodyComposition.muscleFat(athletic, normals: n)!.shape == .d)
  // high fat, low muscle → C
  let cShape = BodyScan(ts: 0, weightKg: 95, bodyFatMassKg: 30, smmKg: 28)
  #expect(BodyComposition.muscleFat(cShape, normals: n)!.shape == .c)
}

@Test func muscleFatNilWithoutThreeBars() {
  let n = HealthRef.bodyNormals(heightM: 1.83, age: 25, male: true)
  #expect(BodyComposition.muscleFat(BodyScan(ts: 0, weightKg: 83), normals: n) == nil)
}

@Test func radarHasSixAxesAndPenalizesAsymmetry() {
  let s = BodyScan(ts: 0, weightKg: 83, bodyFatPct: 15, smmKg: 40, metabolicAge: 24,
                   segmentalLeanKg: [3.95, 3.55, 31, 10.9, 10.8], ecwTbw: 0.378, phaseAngle: 6.6)
  let r = BodyComposition.radar(s, heightM: 1.83, age: 28, male: true)
  #expect(r.count == 6)
  let sym = r.first { $0.label == "Symmetry" }!.score
  #expect(sym < 90)                                  // ~11% arm imbalance pulls symmetry down
  #expect(r.allSatisfy { $0.score >= 0 && $0.score <= 100 })
}

@Test func radarNeutralWhenNoData() {
  let r = BodyComposition.radar(BodyScan(ts: 0, weightKg: 80), heightM: 1.8, age: 30, male: true)
  #expect(r.first { $0.label == "Fluid" }!.score == 50)   // no ECW/TBW → neutral 50
}
