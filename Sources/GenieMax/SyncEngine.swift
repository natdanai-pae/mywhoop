import Foundation

/// The pure decision core of cloud sync (the E2EE sync design P4). Given the local version, the server's version, and
/// the last version both sides agreed on, it decides ONE action: push, pull, in-sync, or conflict. All versions are
/// HLCs; "newer" = the HLC total order. No I/O, no clock, no crypto — fully deterministic + testable. The WhoopUI
/// sync client does the network + encrypt/decrypt around this; this just answers "what should happen?".
///
/// v1 is WHOLE-BLOB Last-Write-Wins: on a true concurrent edit the higher-HLC snapshot wins as a whole (the loser is
/// kept as a backup blob — see P5). Section-level merge (only changed parts, field-level high-water) is P5.
public enum SyncEngine {

  public enum Winner: String, Codable, Equatable, Sendable { case local, remote }

  public enum Action: Equatable, Sendable {
    case inSync                       // both sides identical → nothing to do
    case push                         // we have unsynced local edits, server unchanged → upload
    case pull                         // server moved ahead, no local edits → adopt server
    case conflict(winner: Winner)     // BOTH changed since last sync → LWW picks the higher HLC
  }

  /// What we know going into a sync round.
  public struct State: Equatable, Sendable {
    public var local: HLC?            // our current version (nil = we have no data yet)
    public var remote: HLC?           // server's current version (nil = server is empty)
    public var lastSynced: HLC?       // the version both sides last agreed on (nil = never synced)
    public init(local: HLC?, remote: HLC?, lastSynced: HLC? = nil) {
      self.local = local; self.remote = remote; self.lastSynced = lastSynced
    }
  }

  /// Has the local side changed relative to the last agreed version? (No baseline ⇒ any local data is "unsynced".)
  static func dirty(_ v: HLC?, since baseline: HLC?) -> Bool {
    guard let v = v else { return false }            // nothing locally/remotely ⇒ not dirty
    guard let b = baseline else { return true }      // never synced ⇒ treat existing data as unsynced
    return v > b
  }

  public static func decide(_ s: State) -> Action {
    switch (s.local, s.remote) {
    case (nil, nil): return .inSync                  // nothing anywhere
    case (.some, nil): return .push                  // we have data, server empty → upload
    case (nil, .some): return .pull                  // server has data, we have none → download
    case let (l?, r?):
      if l == r { return .inSync }                   // identical version → done
      let localDirty = dirty(l, since: s.lastSynced)
      let remoteDirty = dirty(r, since: s.lastSynced)
      if !localDirty { return .pull }                // we didn't touch it, server differs → take server
      if !remoteDirty { return .push }               // server didn't touch it, we differ → push ours
      return .conflict(winner: l > r ? .local : .remote)   // both moved → LWW by HLC
    }
  }

  /// A record of a resolved concurrent-edit conflict (P5). The LWW loser's snapshot is kept as a backup blob for a
  /// retention window so a user can recover data the auto-merge dropped; `shouldPurgeBackup` decides when to delete.
  public struct ConflictRecord: Codable, Equatable, Sendable {
    public let at: Double                // when resolved (unix seconds)
    public let winner: Winner
    public let backupKept: Bool          // was the loser snapshot retained?
    public init(at: Double, winner: Winner, backupKept: Bool) {
      self.at = at; self.winner = winner; self.backupKept = backupKept
    }
  }

  /// Whether a kept loser-backup is past its retention window and can be deleted.
  public static func shouldPurgeBackup(recordedAt: Double, now: Double, retentionDays: Double = 7) -> Bool {
    now - recordedAt >= retentionDays * 86_400
  }

  /// The agreed version after an action succeeds (the new `lastSynced`, and the version now live on both sides).
  /// Used by the client to advance its watermark so the next round is correct.
  public static func resolvedVersion(_ s: State, _ action: Action) -> HLC? {
    switch action {
    case .inSync:               return s.local ?? s.remote
    case .push:                 return s.local
    case .pull:                 return s.remote
    case .conflict(.local):     return s.local
    case .conflict(.remote):    return s.remote
    }
  }
}
