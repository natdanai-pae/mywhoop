import Testing
import Foundation
@testable import WhoopCore

@Test func healthRefNormsByAgeSex() {
  // HRV declines with age
  #expect(HealthRef.hrvTypical(age: 25, male: true) > HealthRef.hrvTypical(age: 60, male: true))
  // sleep need by age band
  #expect(HealthRef.sleepNeed(age: 30) == 8)
  #expect(HealthRef.sleepNeed(age: 70) == 7.5)
  // VO2max "good" band drops with age and is higher for men
  #expect(HealthRef.vo2Good(age: 25, male: true) > HealthRef.vo2Good(age: 60, male: true))
  #expect(HealthRef.vo2Good(age: 25, male: true) > HealthRef.vo2Good(age: 25, male: false))
  #expect(HealthRef.vo2Label(55, age: 25, male: true) == "Superior")
  #expect(HealthRef.vo2Label(20, age: 25, male: true) == "Poor")
  #expect(HealthRef.bmiCategory(22) == "Healthy")
}

@Test func sleepStageNormsAreSaneAndAgeAdjusted() {
  // P3: deep% band declines with age; REM/Light bands are physiological; Tata (25/M) deep≈19% lands in range.
  let young = HealthRef.sleepStageNorms(age: 25)
  let old = HealthRef.sleepStageNorms(age: 60)
  #expect(young.deep.lowerBound > old.deep.lowerBound)            // deep sleep declines with age
  #expect(young.deep.contains(19))                               // 19% deep is "in range" for a 25-y-old
  #expect(young.rem == 20...25 && young.light == 50...60)        // AASM adult proportions
  #expect(young.wakeMax > 0 && young.wakeMax <= 15)
  #expect(old.deep.lowerBound >= 3)                             // floor — never an absurd range
}

@Test func profileBMRtdeeAndPAL() {
  let p = Profile(age: 25, male: true, weightKg: 83, heightCm: 183, activity: 2)
  #expect(abs(p.bmr - 1853.75) < 0.5)            // Mifflin
  #expect(abs(p.pal - 1.55) < 0.001)             // moderately active
  #expect(p.tdee > p.bmr)
  #expect(abs(p.bmi - 24.78) < 0.1)
}

@Test func analysisIsPersonalizedAndStatusful() {
  let p = Profile(age: 25, male: true, weightKg: 83, heightCm: 183, activity: 2)
  // recovery bands
  #expect(Analysis.summary("recovery", value: 80, profile: p).status == .good)
  #expect(Analysis.summary("recovery", value: 20, profile: p).status == .watch)
  // HRV below baseline → watch + an action
  let lowHRV = Analysis.summary("hrv", value: 40, profile: p, baselineMean: 60, baselineSD: 8)
  #expect(lowHRV.status == .watch && !lowHRV.action.isEmpty)
  // VO2max verdict references the age/sex norm
  #expect(Analysis.summary("vo2", value: 55, profile: p).headline.contains("Superior"))
  // nil value → info / not-enough-data
  #expect(Analysis.summary("hrv", value: nil, profile: p).status == .info)
  // kcal mentions personalized maintenance
  #expect(Analysis.summary("kcal", value: 1500, profile: p).detail.contains("TDEE"))
}

@Test func confidenceAndReliabilityNotes() {
  let p = Profile()
  // calories + sleep stages are the weakest → "estimate" + a caveat note
  let kcal = Analysis.summary("kcal", value: 1500, profile: p)
  #expect(kcal.confidence == .estimate && kcal.note.contains("±25%"))
  #expect(Analysis.summary("sleep", value: 80, profile: p).confidence == .estimate)
  // HR is high-confidence; nil value → low (coverage gate)
  #expect(Analysis.summary("hr", value: 60, profile: p).confidence == .high)
  #expect(Analysis.summary("hrv", value: nil, profile: p).confidence == .low)
  // HRV: low without a baseline, medium with one
  #expect(Analysis.summary("hrv", value: 50, profile: p).confidence == .low)
  #expect(Analysis.summary("hrv", value: 50, profile: p, baselineMean: 55, baselineSD: 8).confidence == .medium)
  // single-signal watch carries a "confirm with trend" note
  let watch = Analysis.summary("rhr", value: 80, profile: p, baselineMean: 55, baselineSD: 5)
  #expect(watch.status == .watch && watch.note.contains("trend"))
}
