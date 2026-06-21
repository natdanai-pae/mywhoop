import Testing
import Foundation
@testable import WhoopCore

// Hybrid Logical Clock — the sync version (the E2EE sync design P4/P5).

// Local ticks are STRICTLY increasing even when the physical clock is frozen (counter carries the order).
@Test func hlcTickMonotonicWhenClockFrozen() {
  var h = HLC.origin(node: "A")
  var prev = h
  for _ in 0..<5 { h = h.tick(physicalMillis: 1000); #expect(h > prev); prev = h }
  #expect(h.wall == 1000 && h.counter == 4)
}

// When physical time advances past `wall`, the counter resets to 0.
@Test func hlcTickResetsCounterWhenTimeAdvances() {
  let h = HLC(wall: 1000, counter: 3, node: "A").tick(physicalMillis: 2000)
  #expect(h.wall == 2000 && h.counter == 0)
}

// receive() merges a remote stamp and is strictly greater than BOTH inputs (causality), even with clock skew.
@Test func hlcReceiveIsAfterBothInputs() {
  let local = HLC(wall: 1000, counter: 2, node: "A")
  let remote = HLC(wall: 1500, counter: 9, node: "B")
  let merged = local.receive(remote, physicalMillis: 800)   // our physical clock is BEHIND remote
  #expect(merged > local)
  #expect(merged > remote)
  #expect(merged.node == "A")                                // keeps our node
  #expect(merged.wall == 1500 && merged.counter == 10)       // adopts remote wall, counter = remote+1
}

// Total order: ties on (wall,counter) break by node so two devices never compare equal.
@Test func hlcTotalOrderTieBreaksByNode() {
  let a = HLC(wall: 5, counter: 1, node: "A")
  let b = HLC(wall: 5, counter: 1, node: "B")
  #expect(a < b)
  #expect(!(a == b))
  #expect(HLC(wall: 5, counter: 0, node: "Z") < HLC(wall: 5, counter: 1, node: "A"))
  #expect(HLC(wall: 4, counter: 9, node: "Z") < HLC(wall: 5, counter: 0, node: "A"))
}

// The packed string sorts identically to the Comparable order (so the server can order by string).
@Test func hlcPackedSortsLikeComparable() {
  let clocks = [HLC(wall: 12, counter: 0, node: "B"),
                HLC(wall: 2, counter: 5, node: "A"),
                HLC(wall: 12, counter: 0, node: "A"),
                HLC(wall: 2, counter: 9, node: "A")]
  let byValue = clocks.sorted()
  let byString = clocks.sorted { $0.packed < $1.packed }
  #expect(byValue == byString)
}

// parse(packed) round-trips, including a node id that itself contains ':'.
@Test func hlcPackedRoundTrips() {
  let h = HLC(wall: 1718000000000, counter: 7, node: "dev:ice-42")
  #expect(HLC.parse(h.packed) == h)
  #expect(HLC.parse("not-an-hlc") == nil)
}

// Codable wire form = the single packed string (cross-platform stable for the Android client).
@Test func hlcCodableIsPackedString() throws {
  let h = HLC(wall: 99, counter: 1, node: "A")
  let data = try JSONEncoder().encode(h)
  #expect(String(data: data, encoding: .utf8) == "\"\(h.packed)\"")
  #expect(try JSONDecoder().decode(HLC.self, from: data) == h)
}
