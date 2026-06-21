import Testing
import Foundation
@testable import WhoopCore

@Test func accountBootstrapMakesOneActive() {
  let r = AccountStore.bootstrap(id: "a", name: "Tata", strapID: "s1", now: 100)
  #expect(r.accounts.count == 1)
  #expect(r.activeID == "a")
  #expect(r.active?.name == "Tata")
  #expect(r.active?.strapID == "s1")
  #expect(r.active?.createdAt == 100.0)
}

@Test func accountAddBecomesActiveOrNot() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.add(r, Account(id: "b", name: "B", createdAt: 2, lastActive: 2))   // default makeActive
  #expect(r.activeID == "b")
  r = AccountStore.add(r, Account(id: "c", name: "C", createdAt: 3, lastActive: 3), makeActive: false)
  #expect(r.activeID == "b")          // unchanged
  #expect(r.accounts.count == 3)
}

@Test func accountSetActiveStampsLastActive() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.add(r, Account(id: "b", name: "B", createdAt: 2, lastActive: 2), makeActive: false)
  r = AccountStore.setActive(r, id: "b", now: 50)
  #expect(r.activeID == "b")
  #expect((r.accounts.first { $0.id == "b" }?.lastActive) == 50.0)
  let r2 = AccountStore.setActive(r, id: "zzz", now: 99)   // unknown id = no-op
  #expect(r2.activeID == "b")
}

@Test func accountRenameAndBindStrap() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.rename(r, id: "a", name: "Tata")
  #expect(r.active?.name == "Tata")
  r = AccountStore.bindStrap(r, id: "a", strapID: "5AG0296841")
  #expect(r.active?.strapID == "5AG0296841")
  r = AccountStore.bindStrap(r, id: "a", strapID: nil)
  #expect(r.active?.strapID == nil)
}

@Test func accountRemoveNonActiveKeepsActive() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.add(r, Account(id: "b", name: "B", createdAt: 2, lastActive: 2), makeActive: false)
  r = AccountStore.remove(r, id: "b")
  #expect(r.activeID == "a")
  #expect(r.accounts.count == 1)
}

@Test func accountRemoveActiveReassignsToMostRecent() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.add(r, Account(id: "b", name: "B", createdAt: 2, lastActive: 20), makeActive: false)
  r = AccountStore.add(r, Account(id: "c", name: "C", createdAt: 3, lastActive: 30), makeActive: true)  // active = c
  r = AccountStore.remove(r, id: "c")     // remove the active one
  #expect(r.activeID == "b")              // b lastActive 20 > a's 1
  #expect(r.accounts.count == 2)
}

@Test func accountRemoveLastClearsActive() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.remove(r, id: "a")
  #expect(r.accounts.isEmpty)
  #expect(r.activeID == nil)
  #expect(r.active == nil)
}

@Test func accountRegistryCodableRoundTrip() throws {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: "s", now: 1)
  r = AccountStore.add(r, Account(id: "b", name: "B", createdAt: 2, lastActive: 2))
  let back = try JSONDecoder().decode(AccountRegistry.self, from: JSONEncoder().encode(r))
  #expect(back == r)
}

@Test func accountAddIsIdempotentOnID() {
  var r = AccountStore.bootstrap(id: "a", name: "A", strapID: nil, now: 1)
  r = AccountStore.add(r, Account(id: "a", name: "A-updated", createdAt: 1, lastActive: 5))  // same id
  #expect(r.accounts.count == 1)
  #expect(r.active?.name == "A-updated")
}
