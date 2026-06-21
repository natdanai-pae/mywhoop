import Testing
import Foundation
@testable import WhoopCore

// Pure account-model identity logic (Option 1). The data-safety-critical rule under test:
// a NEW identity must NEVER adopt/steal an account that already belongs to a DIFFERENT identity.

// MARK: - owner() reverse lookup

@Test func ownerFindsLinkedIdentity() {
  let links = ["idA": "acct1", "idB": "acct2"]
  #expect(IdentityLink.owner(of: "acct1", links: links) == "idA")
  #expect(IdentityLink.owner(of: "acct2", links: links) == "idB")
}

@Test func ownerNilForUnlinkedAccount() {
  let links = ["idA": "acct1"]
  #expect(IdentityLink.owner(of: "orphan", links: links) == nil)
  #expect(IdentityLink.owner(of: "acct1", links: [:]) == nil)
}

// MARK: - decide()

@Test func decideReturningIdentityLoadsLinkedAccount() {
  // idA signs in again; it already owns acct1 → load it (active account is irrelevant).
  let d = IdentityLink.decide(identityAcctId: "idA",
                              linkedLocal: "acct1",
                              activeAccountId: "acctOther",
                              activeOwner: "idB",
                              activeHasStoredData: true)
  #expect(d == .loadLinked(localId: "acct1"))
}

@Test func decideNewIdentityNeverStealsAnotherIdentitysAccount() {
  // ⭐ The critical fix: idB signs in for the first time while the active account (acct1) belongs to idA
  // and HAS data. Must get its OWN fresh account — NOT an adopt prompt over idA's data.
  let d = IdentityLink.decide(identityAcctId: "idB",
                              linkedLocal: nil,
                              activeAccountId: "acct1",
                              activeOwner: "idA",
                              activeHasStoredData: true)
  #expect(d == .freshAccount)
}

@Test func decideUnlinkedDataAsksToAdopt() {
  // Device-only / orphan account with data, no owning identity → legit upgrade: ask to adopt.
  let d = IdentityLink.decide(identityAcctId: "idA",
                              linkedLocal: nil,
                              activeAccountId: "acct1",
                              activeOwner: nil,
                              activeHasStoredData: true)
  #expect(d == .askAdopt)
}

@Test func decideEmptyUnlinkedLinksActive() {
  // Fresh install: empty, unlinked active account → just link it to the signing-in identity.
  let d = IdentityLink.decide(identityAcctId: "idA",
                              linkedLocal: nil,
                              activeAccountId: "acct1",
                              activeOwner: nil,
                              activeHasStoredData: false)
  #expect(d == .linkActive)
}

@Test func decideOwnUnlinkedAccountFallsThrough() {
  // Defensive: activeOwner == self (shouldn't normally happen since linkedLocal would catch it) must NOT
  // be treated as "someone else's" → falls through to the data/empty branches, never .freshAccount.
  let withData = IdentityLink.decide(identityAcctId: "idA",
                                     linkedLocal: nil,
                                     activeAccountId: "acct1",
                                     activeOwner: "idA",
                                     activeHasStoredData: true)
  #expect(withData == .askAdopt)
  let empty = IdentityLink.decide(identityAcctId: "idA",
                                  linkedLocal: nil,
                                  activeAccountId: "acct1",
                                  activeOwner: "idA",
                                  activeHasStoredData: false)
  #expect(empty == .linkActive)
}

// MARK: - End-to-end scenario (the PLAN's verification): A signs in → sign out → B signs in → B fresh, A untouched.

@Test func scenarioSignInABThenBackToA() {
  // After A's first sign-in, A is linked to acct1; acct1 is active and has data.
  var links = ["idA": "acct1"]
  // Sign out keeps the registry active account = acct1 (data on disk), only the identity changes on next sign-in.
  // B signs in: B has no link; acct1 is owned by idA and has data → fresh account for B.
  let bDecision = IdentityLink.decide(identityAcctId: "idB",
                                      linkedLocal: links["idB"],          // nil — B has never signed in
                                      activeAccountId: "acct1",
                                      activeOwner: IdentityLink.owner(of: "acct1", links: links),
                                      activeHasStoredData: true)
  #expect(bDecision == .freshAccount)
  // The runtime would mint acct2 + link idB→acct2; acct1 (A's data) is untouched.
  links["idB"] = "acct2"
  // A signs back in: A's link still resolves → load acct1 (A's data returns).
  let aDecision = IdentityLink.decide(identityAcctId: "idA",
                                      linkedLocal: links["idA"],
                                      activeAccountId: "acct2",                 // B's account is currently active
                                      activeOwner: IdentityLink.owner(of: "acct2", links: links),
                                      activeHasStoredData: true)
  #expect(aDecision == .loadLinked(localId: "acct1"))
}
