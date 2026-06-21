import Foundation

/// Multi-account (LOCAL only). One account = one profile + its own dataset + one bound strap.
/// Identity is a stable generated id; the heavy per-account data lives in `whoop_state_<id>.json`
/// (WhoopBLE owns the file I/O). This file is pure + testable — no I/O, no clock.
public struct Account: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public var name: String
  public var strapID: String?       // bound StrapInfo.id (CBPeripheral identifier) — one strap per account
  public let createdAt: Double      // unix ts
  public var lastActive: Double     // unix ts of the last time this account was active
  public init(id: String, name: String, strapID: String? = nil, createdAt: Double, lastActive: Double) {
    self.id = id; self.name = name; self.strapID = strapID
    self.createdAt = createdAt; self.lastActive = lastActive
  }
}

/// The accounts index: known accounts + which one is active. Persisted as `accounts.json` (WhoopBLE).
public struct AccountRegistry: Codable, Equatable, Sendable {
  public var accounts: [Account]
  public var activeID: String?
  public init(accounts: [Account] = [], activeID: String? = nil) {
    self.accounts = accounts; self.activeID = activeID
  }
  /// The active account, or nil if none / dangling pointer.
  public var active: Account? { accounts.first { $0.id == activeID } }
}

/// Pure account-model identity logic (Option 1: every account is owned by a sign-in identity). Holds the
/// data-safety-critical decision for WHICH local account a signing-in identity gets, kept pure (no UserDefaults,
/// no clock) so the rule "a new identity must NEVER adopt/steal another identity's data" is unit-tested.
/// `WhoopBLE.beginUnlock` is a thin wrapper that gathers the inputs (link map + active account) and applies this.
public enum IdentityLink {
  /// What to do when an identity signs in, given the link map and the currently-active account.
  public enum Decision: Equatable, Sendable {
    case loadLinked(localId: String)   // returning identity → load its already-linked account
    case freshAccount                  // active account belongs to a DIFFERENT identity → new identity gets its OWN empty account (no stealing)
    case askAdopt                      // active account is UNLINKED but has data → ask (legit device-only/orphan → cloud upgrade)
    case linkActive                    // active account is empty + unlinked → silently link it to this identity (fresh install)
  }

  /// Reverse of the link map (`identityAcctId → localId`): which identity, if any, already owns this local
  /// account. nil = unlinked (device-only / orphan).
  public static func owner(of localId: String, links: [String: String]) -> String? {
    links.first { $0.value == localId }?.key
  }

  /// The data-safety-critical decision. `linkedLocal` = this identity's own linked account (nil on first sign-in);
  /// `activeOwner` = `owner(of: activeAccountId, links:)` — the identity that already owns the active account.
  public static func decide(identityAcctId: String,
                            linkedLocal: String?,
                            activeAccountId: String,
                            activeOwner: String?,
                            activeHasStoredData: Bool) -> Decision {
    if let localId = linkedLocal { return .loadLinked(localId: localId) }   // returning identity
    if let owner = activeOwner, owner != identityAcctId { return .freshAccount }   // active account is someone else's → never adopt
    if activeHasStoredData { return .askAdopt }   // unlinked device-only/orphan with data → legit upgrade prompt
    return .linkActive                            // empty + unlinked → fresh install, link it
  }
}

/// Pure registry operations. Callers mint ids and pass `now`, so every result is deterministic + testable.
public enum AccountStore {
  /// One-account bootstrap (used by migration): a registry with a single active account.
  public static func bootstrap(id: String, name: String, strapID: String?, now: Double) -> AccountRegistry {
    AccountRegistry(accounts: [Account(id: id, name: name, strapID: strapID, createdAt: now, lastActive: now)],
                    activeID: id)
  }

  /// Add an account (caller mints id/createdAt). Becomes active when `makeActive` (default true) or none is active yet.
  public static func add(_ reg: AccountRegistry, _ acct: Account, makeActive: Bool = true) -> AccountRegistry {
    var out = reg
    out.accounts.removeAll { $0.id == acct.id }   // idempotent on id
    out.accounts.append(acct)
    if makeActive || out.activeID == nil { out.activeID = acct.id }
    return revalidate(out)
  }

  /// Switch the active account and stamp its lastActive. No-op if the id is unknown.
  public static func setActive(_ reg: AccountRegistry, id: String, now: Double) -> AccountRegistry {
    guard reg.accounts.contains(where: { $0.id == id }) else { return reg }
    var out = reg
    out.activeID = id
    if let i = out.accounts.firstIndex(where: { $0.id == id }) { out.accounts[i].lastActive = now }
    return out
  }

  public static func rename(_ reg: AccountRegistry, id: String, name: String) -> AccountRegistry {
    var out = reg
    if let i = out.accounts.firstIndex(where: { $0.id == id }) { out.accounts[i].name = name }
    return out
  }

  /// Bind (or clear, nil) the strap for an account.
  public static func bindStrap(_ reg: AccountRegistry, id: String, strapID: String?) -> AccountRegistry {
    var out = reg
    if let i = out.accounts.firstIndex(where: { $0.id == id }) { out.accounts[i].strapID = strapID }
    return out
  }

  /// Remove an account. If it was the active one, active is reassigned to the most-recently-active remaining
  /// account (or nil when none remain).
  public static func remove(_ reg: AccountRegistry, id: String) -> AccountRegistry {
    var out = reg
    out.accounts.removeAll { $0.id == id }
    return revalidate(out)
  }

  /// Ensure activeID points to an existing account; if not, pick the most-recently-active remaining one (or nil).
  private static func revalidate(_ reg: AccountRegistry) -> AccountRegistry {
    var out = reg
    if let a = out.activeID, out.accounts.contains(where: { $0.id == a }) { return out }
    out.activeID = out.accounts.sorted { $0.lastActive > $1.lastActive }.first?.id
    return out
  }
}
