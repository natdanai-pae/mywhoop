import Testing
import Foundation
@testable import WhoopCore

@Test func stressMetricMethodDescribesHRHRVMonitorNotBaevskyFormula() {
  let en = MetricMethods.method("stress", thai: false)!
  #expect(en.source.contains("HRV"))
  #expect(en.source.contains("skin temp"))
  #expect(en.formula.contains("HR above resting baseline"))
  #expect(en.formula.contains("HRV below baseline"))
  #expect(!en.formula.contains("Baevsky"))
  #expect(en.accuracy.contains("raw Baevsky SI is separate"))

  let th = MetricMethods.method("stress", thai: true)!
  #expect(!th.formula.contains("Baevsky"))
  #expect(th.accuracy.contains("Baevsky SI"))
}

@Test func respiratoryMetricMethodDoesNotPromoteK18CandidateResp() {
  let en = MetricMethods.method("resp", thai: false)!
  #expect(en.source.contains("K18 respiratory fields remain candidate-only"))
  #expect(en.formula.contains("RSA"))
  #expect(en.formula.contains("do not promote K18 candidate resp"))
  #expect(en.accuracy.contains("candidate custom fields are excluded"))

  let th = MetricMethods.method("resp", thai: true)!
  #expect(th.source.contains("K18 respiratory fields remain candidate-only"))
  #expect(th.formula.contains("do not promote K18 candidate resp"))
}

@Test func strainMetricMethodMentionsSexSpecificTRIMP() {
  let en = MetricMethods.method("strain", thai: false)!
  #expect(en.formula.contains("sex-specific"))
  #expect(en.formula.contains("male 0.64"))
  #expect(en.formula.contains("female 0.86"))

  let th = MetricMethods.method("strain", thai: true)!
  #expect(th.formula.contains("ตามเพศ"))
  #expect(th.formula.contains("0.86"))
}
