import Foundation

/// Hybrid Logical Clock (Kulkarni et al. 2014) — the per-account sync VERSION used by the E2EE backend
/// (`the E2EE sync design` P4/P5). It blends physical wall-clock time with a logical counter so that:
///   • versions track real time well enough for humans / Last-Write-Wins, AND
///   • two devices that write in the same millisecond still get a strict, causally-correct order.
///
/// The physical clock is passed IN (`physicalMillis`) so this type is pure + deterministic + unit-testable —
/// it never reads `Date()` itself. Total order is `(wall, counter, node)` lexicographically; `node` (the device id)
/// is only a final tie-break so the order is total even across devices.
public struct HLC: Comparable, Codable, Equatable, Sendable {
  public let wall: Int64      // logical wall time in ms (max physical time observed so far, never goes backwards)
  public let counter: Int     // disambiguates events that share the same `wall`
  public let node: String     // device id — tie-break only (keeps the order total)

  public init(wall: Int64, counter: Int, node: String) {
    self.wall = wall; self.counter = counter; self.node = node
  }

  /// A fresh clock for a device at the epoch.
  public static func origin(node: String) -> HLC { HLC(wall: 0, counter: 0, node: node) }

  /// Stamp a LOCAL event (a change we are about to write). Advances using the physical clock; if physical time
  /// hasn't moved past `wall`, only the counter bumps — so repeated local writes are strictly increasing.
  public func tick(physicalMillis pt: Int64) -> HLC {
    let lNew = max(wall, pt)
    let cNew = (lNew == wall) ? counter + 1 : 0
    return HLC(wall: lNew, counter: cNew, node: node)
  }

  /// Merge a REMOTE timestamp we just received (e.g. the server's current version) into ours. The result is
  /// strictly greater than both inputs, preserving causality regardless of clock skew between devices.
  public func receive(_ remote: HLC, physicalMillis pt: Int64) -> HLC {
    let lNew = max(wall, remote.wall, pt)
    let cNew: Int
    if lNew == wall && lNew == remote.wall { cNew = max(counter, remote.counter) + 1 }
    else if lNew == wall                   { cNew = counter + 1 }
    else if lNew == remote.wall            { cNew = remote.counter + 1 }
    else                                   { cNew = 0 }
    return HLC(wall: lNew, counter: cNew, node: node)
  }

  public static func < (a: HLC, b: HLC) -> Bool {
    if a.wall != b.wall { return a.wall < b.wall }
    if a.counter != b.counter { return a.counter < b.counter }
    return a.node < b.node
  }

  /// Canonical, lexicographically-sortable string for the `version` field on the wire / in the D1 metadata row.
  /// Zero-padded so string order == numeric `(wall, counter)` order; `node` appended verbatim (may contain ':').
  public var packed: String {
    func pad(_ s: String, _ n: Int) -> String { String(repeating: "0", count: max(0, n - s.count)) + s }
    return pad(String(wall), 15) + ":" + pad(String(counter), 6) + ":" + node
  }

  /// Parse a `packed` string back to an HLC. `node` may itself contain ':' (only the first two ':' are separators).
  public static func parse(_ s: String) -> HLC? {
    let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, let w = Int64(parts[0]), let c = Int(parts[1]) else { return nil }
    return HLC(wall: w, counter: c, node: String(parts[2]))
  }

  // Wire form = the single `packed` string (compact + stable across platforms incl. the Android client).
  public init(from decoder: Decoder) throws {
    let s = try decoder.singleValueContainer().decode(String.self)
    guard let h = HLC.parse(s) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad HLC: \(s)"))
    }
    self = h
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer(); try c.encode(packed)
  }
}
