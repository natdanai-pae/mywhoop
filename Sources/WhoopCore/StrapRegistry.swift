import Foundation

/// Multi-strap support — a small registry of WHOOP straps this phone has seen, so the user can pick WHICH one to
/// connect when more than one is in range. Identity = the iOS `CBPeripheral.identifier` (stable per phone); the
/// `serial` (from the advertised name "WHOOP 5AG0296841") is the human label. Pure + testable; WhoopBLE owns the
/// CoreBluetooth side and persists the list.
public struct StrapInfo: Codable, Identifiable, Equatable, Sendable {
  public var id: String          // CBPeripheral.identifier.uuidString (stable on this phone)
  public var serial: String      // e.g. "5AG0296841"
  public var name: String        // e.g. "WHOOP 5AG0296841"
  public var rssi: Int           // last seen signal (dBm; 0 = unknown)
  public var lastSeen: Double     // unix ts of the last advertisement
  public init(id: String, serial: String, name: String, rssi: Int, lastSeen: Double) {
    self.id = id; self.serial = serial; self.name = name; self.rssi = rssi; self.lastSeen = lastSeen
  }
  /// Model inferred from the serial prefix (5AM → MG, 5AG → 5.0). Stored serial only — no Codable change.
  public var model: WhoopModel { WhoopModel.from(serial: serial.isEmpty ? name : serial) }
}

public enum StrapRegistry {
  /// Upsert a freshly-seen strap (match by `id`) and return the list sorted most-recently-seen first. A re-seen
  /// strap updates its rssi/lastSeen/serial in place rather than duplicating.
  public static func upsert(_ list: [StrapInfo], _ s: StrapInfo) -> [StrapInfo] {
    var out = list.filter { $0.id != s.id }
    out.append(s)
    return out.sorted { $0.lastSeen > $1.lastSeen }
  }

  /// Which strap should we connect to? The preferred one if it's known; else the most-recently-seen (the default
  /// single-strap behaviour). Returns nil when the list is empty.
  public static func target(_ list: [StrapInfo], preferred: String?) -> StrapInfo? {
    if let p = preferred, let hit = list.first(where: { $0.id == p }) { return hit }
    return list.first
  }
}
