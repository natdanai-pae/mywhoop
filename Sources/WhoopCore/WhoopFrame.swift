import Foundation

/// WHOOP 5.0 V5 frame builder — ported byte-exact from a reference implementation buildFrame().
/// aa01<len LE>0001<crc16-modbus(hdr)><payload [35,seq,cmd,data] pad4><crc32/ISO-HDLC>
public enum WhoopFrame {
  public static func crc16modbus(_ d: [UInt8]) -> UInt16 {
    var c: UInt16 = 0xFFFF
    for b in d { c ^= UInt16(b); for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 } }
    return c & 0xFFFF
  }
  static let crc32Table: [UInt32] = {
    var t = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 { var c = UInt32(n); for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; t[n] = c }
    return t
  }()
  public static func crc32(_ d: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in d { c = crc32Table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
  }
  public static func build(seq: UInt8, cmd: UInt8, data: [UInt8]) -> [UInt8] {
    var p: [UInt8] = [35, seq, cmd] + data
    while p.count % 4 != 0 { p.append(0) }
    let cr = crc32(p)
    var pf = p
    pf.append(UInt8(cr & 0xFF)); pf.append(UInt8((cr >> 8) & 0xFF))
    pf.append(UInt8((cr >> 16) & 0xFF)); pf.append(UInt8((cr >> 24) & 0xFF))
    let dl = pf.count
    var h: [UInt8] = [0xAA, 0x01, UInt8(dl & 0xFF), UInt8((dl >> 8) & 0xFF), 0x00, 0x01]
    let hc = crc16modbus(h); h.append(UInt8(hc & 0xFF)); h.append(UInt8((hc >> 8) & 0xFF))
    return h + pf
  }
  public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
  /// hex string → bytes (for fixtures/tests)
  public static func bytes(_ hex: String) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(hex.count / 2)
    var idx = hex.startIndex
    while idx < hex.endIndex {
      let next = hex.index(idx, offsetBy: 2)
      out.append(UInt8(hex[idx..<next], radix: 16) ?? 0); idx = next
    }
    return out
  }
}
