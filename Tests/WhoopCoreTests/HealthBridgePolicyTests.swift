import Testing
@testable import WhoopCore

@Test func healthExportPolicyBlocksCandidateHeartRateSources() {
  #expect(HealthExportPolicy.canWriteHeartRate(source: "standard_hr"))
  #expect(!HealthExportPolicy.canWriteHeartRate(source: "k2_candidate_hr"))
  #expect(!HealthExportPolicy.canWriteHeartRate(source: "k18_candidate_hr"))
  #expect(!HealthExportPolicy.canWriteHeartRate(source: nil))
}

@Test func healthExportPolicyAllowsOnlyValidatedNightlySources() {
  #expect(HealthExportPolicy.canWriteHRV(source: "rr"))
  #expect(!HealthExportPolicy.canWriteHRV(source: "ppg"))
  #expect(!HealthExportPolicy.canWriteHRV(source: "mixed_rr_ppg"))
  #expect(HealthExportPolicy.canWriteRestingHR(source: "standard_hr"))
  #expect(!HealthExportPolicy.canWriteRestingHR(source: "mixed_candidate"))
  #expect(!HealthExportPolicy.canWriteRespiratoryRate(source: nil))
  #expect(!HealthExportPolicy.canWriteBodyTemperature(source: "skin_temp"))
}

@Test func healthExportPolicyBlocksEstimatedVO2maxByDefault() {
  #expect(!HealthExportPolicy.canWriteEstimatedVO2max)
}

@Test func healthExportPolicyOnlyExportsSDNNWhenCurrentSourceIsRR() {
  #expect(HealthExportPolicy.healthKitSDNNSource(liveHRVSource: "rr", hasSDNN: true) == "rr")
  #expect(HealthExportPolicy.healthKitSDNNSource(liveHRVSource: "ppg", hasSDNN: true) == nil)
  #expect(HealthExportPolicy.healthKitSDNNSource(liveHRVSource: "mixed_rr_ppg", hasSDNN: true) == nil)
  #expect(HealthExportPolicy.healthKitSDNNSource(liveHRVSource: nil, hasSDNN: true) == nil)
  #expect(HealthExportPolicy.healthKitSDNNSource(liveHRVSource: "rr", hasSDNN: false) == nil)
}
