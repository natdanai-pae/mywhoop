import Foundation

/// Strap model detection — distinguishes WHOOP MG (ECG electrodes) from WHOOP 5.0 (no electrodes),
/// so MG-only features (ECG, and later BP) can be gated to the right hardware.
/// PRIMARY signal = the strap serial prefix ("WHOOP 5AM…" = MG, "5AG…" = 5.0), which we already read
/// from the advertised name / DIS 0x2A25. CONFIRMATION = the DIS Hardware Revision (0x2A27): the 5.0
/// reports "WG50_r52". The MG's hardware-revision string is captured on first MG connect (GenieMax reads
/// 0x2A24/0x2A27) and can then strengthen detection here.
public enum WhoopModel: String, Codable, Equatable, Sendable {
  case mg          // WHOOP MG — has the ECG-conductive clasp
  case five0       // WHOOP 5.0 — no ECG electrodes
  case unknown     // not yet identified / non-WHOOP HR strap

  public var label: String {
    switch self {
    case .mg: return "MG"
    case .five0: return "5.0"
    case .unknown: return "—"
    }
  }
  public var isMG: Bool { self == .mg }

  /// Detect from the strap `serial` (primary) and the optional DIS hardware-revision `hwRev` (confirmation).
  /// hwRev "WG50…" authoritatively means 5.0; otherwise the serial prefix decides (5AM → MG, 5AG → 5.0).
  public static func from(serial: String, hwRev: String = "") -> WhoopModel {
    var s = serial.uppercased().trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("WHOOP ") { s = String(s.dropFirst(6)) }       // tolerate the advertised name
    let h = hwRev.uppercased()
    if h.contains("WG50") { return .five0 }       // known 5.0 hardware id — authoritative
    if s.hasPrefix("5AM") { return .mg }
    if s.hasPrefix("5AG") { return .five0 }
    return .unknown
  }
}
