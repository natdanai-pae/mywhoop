import Testing
@testable import WhoopCore

// Strap model detection (MG vs 5.0) from serial prefix + DIS hardware revision.

@Test func serial5AMisMG() {
  #expect(WhoopModel.from(serial: "5AM0331473") == .mg)
  #expect(WhoopModel.from(serial: "WHOOP 5AM0331473") == .mg)   // tolerates the advertised name
  #expect(WhoopModel.from(serial: "5AM0331473").isMG)
}

@Test func serial5AGis5point0() {
  #expect(WhoopModel.from(serial: "5AG0296841") == .five0)
  #expect(!WhoopModel.from(serial: "5AG0296841").isMG)
}

@Test func hwRevWG50ConfirmsFive0EvenOverSerial() {
  // hardware revision is authoritative: a WG50 strap is 5.0 even if the serial were ambiguous
  #expect(WhoopModel.from(serial: "", hwRev: "WG50_r52") == .five0)
  #expect(WhoopModel.from(serial: "5AG0296841", hwRev: "WG50_r52") == .five0)
}

@Test func unknownSerialIsUnknown() {
  #expect(WhoopModel.from(serial: "") == .unknown)
  #expect(WhoopModel.from(serial: "POLARH10") == .unknown)
}

@Test func labels() {
  #expect(WhoopModel.mg.label == "MG")
  #expect(WhoopModel.five0.label == "5.0")
  #expect(WhoopModel.unknown.label == "—")
}
