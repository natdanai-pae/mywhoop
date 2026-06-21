import Testing
import Foundation
@testable import WhoopCore

// Section-level sync (the E2EE sync design P5).

private let routes = ["history": "history", "workouts": "activity", "chat": "chat"]
private let snapshot = Data(#"{"history":[1,2,3],"workouts":["run"],"chat":["hi"],"profile":{"name":"S"}}"#.utf8)

// split → merge is lossless (canonical JSON equality regardless of original key order).
@Test func sectionSplitMergeRoundTrips() throws {
  let parts = try SectionSplitter.split(snapshot, routes: routes, fallback: "misc")
  let merged = try SectionSplitter.merge(parts)
  let canonical = try JSONSerialization.data(
    withJSONObject: try JSONSerialization.jsonObject(with: snapshot), options: [.sortedKeys])
  #expect(merged == canonical)
}

// Keys route to their section; unrouted keys fall back.
@Test func sectionSplitRoutesKeys() throws {
  let parts = try SectionSplitter.split(snapshot, routes: routes, fallback: "misc")
  #expect(Set(parts.keys) == ["history", "activity", "chat", "misc"])
  let misc = try JSONSerialization.jsonObject(with: parts["misc"]!) as! [String: Any]
  #expect(misc.keys.contains("profile"))                 // unrouted → fallback
}

// Editing one section changes ONLY that section (the bandwidth win — others can skip upload).
@Test func sectionChangeDetectionIsMinimal() throws {
  let before = try SectionSplitter.split(snapshot, routes: routes, fallback: "misc")
  let edited = Data(#"{"history":[1,2,3],"workouts":["run","swim"],"chat":["hi"],"profile":{"name":"S"}}"#.utf8)
  let after = try SectionSplitter.split(edited, routes: routes, fallback: "misc")
  #expect(SectionSplitter.changedSections(old: before, new: after) == ["activity"])
}

// A removed section is detected as changed.
@Test func sectionRemovalDetected() throws {
  let before = try SectionSplitter.split(snapshot, routes: routes, fallback: "misc")
  var after = before; after.removeValue(forKey: "chat")
  #expect(SectionSplitter.changedSections(old: before, new: after) == ["chat"])
}

@Test func sectionSplitRejectsNonObject() {
  #expect(throws: SectionSplitter.SplitError.notAnObject) {
    try SectionSplitter.split(Data("[1,2,3]".utf8), routes: [:], fallback: "misc")
  }
}

// merge rejects two sections claiming the same top-level key (a corrupt/mixed set).
@Test func sectionMergeRejectsDuplicateKey() {
  let a = Data(#"{"profile":1}"#.utf8), b = Data(#"{"profile":2}"#.utf8)
  #expect(throws: SectionSplitter.SplitError.duplicateKey) {
    try SectionSplitter.merge(["x": a, "y": b])
  }
}

// A manifest names a consistent set; a stale/missing section is detected → puller must NOT merge (torn-read guard).
@Test func sectionManifestDetectsTornRead() throws {
  let parts = try SectionSplitter.split(snapshot, routes: routes, fallback: "misc")
  let man = SectionSplitter.manifest(version: HLC(wall: 100, counter: 0, node: "A"), sections: parts)
  #expect(SectionSplitter.isConsistent(man, sections: parts))            // fully-uploaded set → ok to merge
  var stale = parts; stale["activity"] = Data(#"{"workouts":["OLD"]}"#.utf8)
  #expect(!SectionSplitter.isConsistent(man, sections: stale))           // one section stale → torn read
  var missing = parts; missing.removeValue(forKey: "chat")
  #expect(!SectionSplitter.isConsistent(man, sections: missing))         // a section still in flight → torn read
}

// --- multi-device introspection ---

@Test func enrolledDevicesListsSlotsNotRecovery() throws {
  let env = try E2EEVault.enroll(snapshot: snapshot, deviceId: "iphone", updatedAt: 1,
                                 deviceSecret: "p", recoveryPhrase: "amber river stone")
  let env2 = try E2EEVault.enrollNewDevice(env, recoveryPhrase: "amber river stone", deviceId: "ipad", deviceSecret: "q")
  #expect(E2EEVault.enrolledDevices(env2) == ["ipad", "iphone"])     // sorted, recovery excluded
  #expect(E2EEVault.hasDeviceSlot(env2, deviceId: "ipad"))
  #expect(!E2EEVault.hasDeviceSlot(env2, deviceId: "watch"))
}

// --- conflict-record retention ---

@Test func conflictBackupRetention() {
  let rec = SyncEngine.ConflictRecord(at: 1000, winner: .remote, backupKept: true)
  #expect(rec.winner == .remote)
  #expect(!SyncEngine.shouldPurgeBackup(recordedAt: 1000, now: 1000 + 6 * 86_400))   // within 7 days
  #expect(SyncEngine.shouldPurgeBackup(recordedAt: 1000, now: 1000 + 8 * 86_400))    // past 7 days
  // Codable round-trip (persisted with the backup).
  let back = try! JSONDecoder().decode(SyncEngine.ConflictRecord.self, from: try! JSONEncoder().encode(rec))
  #expect(back == rec)
}
