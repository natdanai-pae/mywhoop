import Testing
import Foundation
@testable import GenieMax

// SyncEngine decision core (the E2EE sync design P4).

private func hlc(_ wall: Int64, _ c: Int = 0, _ node: String = "A") -> HLC { HLC(wall: wall, counter: c, node: node) }

@Test func syncEmptyEverywhereIsInSync() {
  #expect(SyncEngine.decide(.init(local: nil, remote: nil)) == .inSync)
}

@Test func syncPushesWhenServerEmpty() {
  #expect(SyncEngine.decide(.init(local: hlc(10), remote: nil)) == .push)
}

@Test func syncPullsWhenLocalEmpty() {
  #expect(SyncEngine.decide(.init(local: nil, remote: hlc(10))) == .pull)
}

@Test func syncInSyncWhenEqual() {
  #expect(SyncEngine.decide(.init(local: hlc(10), remote: hlc(10), lastSynced: hlc(10))) == .inSync)
}

// Server advanced, we didn't touch it → pull.
@Test func syncPullsWhenOnlyRemoteChanged() {
  let s = SyncEngine.State(local: hlc(10), remote: hlc(20), lastSynced: hlc(10))
  #expect(SyncEngine.decide(s) == .pull)
}

// We edited, server didn't → push.
@Test func syncPushesWhenOnlyLocalChanged() {
  let s = SyncEngine.State(local: hlc(20), remote: hlc(10), lastSynced: hlc(10))
  #expect(SyncEngine.decide(s) == .push)
}

// BOTH edited since last sync → conflict, LWW picks the higher HLC (remote here).
@Test func syncConflictRemoteWinsByHLC() {
  let s = SyncEngine.State(local: hlc(15), remote: hlc(25), lastSynced: hlc(10))
  #expect(SyncEngine.decide(s) == .conflict(winner: .remote))
}

@Test func syncConflictLocalWinsByHLC() {
  let s = SyncEngine.State(local: hlc(30), remote: hlc(25), lastSynced: hlc(10))
  #expect(SyncEngine.decide(s) == .conflict(winner: .local))
}

// Never-synced with data on both sides differing = a conflict (both treated as unsynced).
@Test func syncNeverSyncedBothHaveDataIsConflict() {
  let s = SyncEngine.State(local: hlc(30), remote: hlc(25), lastSynced: nil)
  #expect(SyncEngine.decide(s) == .conflict(winner: .local))
}

// The resolved version (new watermark) matches the action's winner.
@Test func syncResolvedVersionTracksWinner() {
  let s = SyncEngine.State(local: hlc(30), remote: hlc(25), lastSynced: hlc(10))
  #expect(SyncEngine.resolvedVersion(s, .conflict(winner: .local)) == hlc(30))
  #expect(SyncEngine.resolvedVersion(s, .pull) == hlc(25))
  #expect(SyncEngine.resolvedVersion(s, .push) == hlc(30))
}

// A full round-trip: device A pushes; device B (behind) pulls and converges.
@Test func syncTwoDeviceConverges() {
  // A edits to v20 (was synced at v10), server still v10 → A pushes.
  let a = SyncEngine.State(local: hlc(20, 0, "A"), remote: hlc(10), lastSynced: hlc(10))
  #expect(SyncEngine.decide(a) == .push)
  let serverNow = SyncEngine.resolvedVersion(a, .push)        // server now v20
  // B was synced at v10, hasn't edited, sees server v20 → pulls.
  let b = SyncEngine.State(local: hlc(10), remote: serverNow, lastSynced: hlc(10))
  #expect(SyncEngine.decide(b) == .pull)
  #expect(SyncEngine.resolvedVersion(b, .pull) == hlc(20, 0, "A"))
}
