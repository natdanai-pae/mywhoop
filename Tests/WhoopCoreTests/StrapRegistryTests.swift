import Testing
import Foundation
@testable import WhoopCore

@Test func strapRegistryUpsertDedupesAndSorts() {
  var list: [StrapInfo] = []
  list = StrapRegistry.upsert(list, StrapInfo(id: "A", serial: "5AG0296841", name: "WHOOP 5AG0296841", rssi: -50, lastSeen: 100))
  list = StrapRegistry.upsert(list, StrapInfo(id: "B", serial: "5AG0123456", name: "WHOOP 5AG0123456", rssi: -70, lastSeen: 200))
  #expect(list.count == 2)
  #expect(list.first?.id == "B")                       // most-recently-seen first
  // re-seeing A updates in place (no dup) + re-sorts to front
  list = StrapRegistry.upsert(list, StrapInfo(id: "A", serial: "5AG0296841", name: "WHOOP 5AG0296841", rssi: -45, lastSeen: 300))
  #expect(list.count == 2)
  #expect(list.first?.id == "A" && list.first?.rssi == -45)
}

@Test func strapRegistryTargetPrefersSelection() {
  let list = [
    StrapInfo(id: "A", serial: "aaa", name: "WHOOP aaa", rssi: -45, lastSeen: 300),
    StrapInfo(id: "B", serial: "bbb", name: "WHOOP bbb", rssi: -70, lastSeen: 200),
  ]
  #expect(StrapRegistry.target(list, preferred: nil)?.id == "A")        // no preference → most recent
  #expect(StrapRegistry.target(list, preferred: "B")?.id == "B")        // preference honored
  #expect(StrapRegistry.target(list, preferred: "Z")?.id == "A")        // stale preference → falls back to most recent
  #expect(StrapRegistry.target([], preferred: "A") == nil)
}
