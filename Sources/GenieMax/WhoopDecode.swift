import Foundation

/// L0 decode — frame reassembly (Accum) + per-frame decode (WhoopDecode).
/// Ported byte-exact from a reference implementation / a reference validator.
/// Payload = frame[8...]; pl[0]=type(pt), pl[1]=k-domain(k). All multi-byte little-endian.

// MARK: - little-endian payload readers (operate on the full frame; off is into the PAYLOAD)
@inline(__always) func u8(_ f: [UInt8], _ off: Int) -> Int { Int(f[8 + off]) }
@inline(__always) func u16le(_ f: [UInt8], _ off: Int) -> Int {
  let o = 8 + off; return Int(f[o]) | (Int(f[o + 1]) << 8)
}
@inline(__always) func i16le(_ f: [UInt8], _ off: Int) -> Int {
  let v = u16le(f, off); return v >= 0x8000 ? v - 0x10000 : v
}
@inline(__always) func u32le(_ f: [UInt8], _ off: Int) -> UInt32 {
  let o = 8 + off
  return UInt32(f[o]) | (UInt32(f[o + 1]) << 8) | (UInt32(f[o + 2]) << 16) | (UInt32(f[o + 3]) << 24)
}

/// Typed decode of one V5 frame.
public enum WhoopRecord: Equatable {
  case realtimeHR(hr: Int)                                              // k2  (pt40)
  case k18(tempC: Double, hr: Int, resp: Int, ts: UInt32)               // pt47 k18 (1Hz history record)
  case imu(nc: Int, ax0: Double, ay0: Double, az0: Double, gyroCount: Int, gx0: Int)  // pt43 k21
  case optical(samples: [UInt32])                                      // k20 (len 2132): 25 PPG samples @25Hz
  case dataRange(head: UInt32, watermark: UInt32)                       // type36 (get_data_range response)
  case other(pt: Int, k: Int, len: Int)
}

public enum WhoopDecode {
  public static let accScale = 4096.0

  /// Pure per-frame decode (deterministic field extraction; no state).
  public static func decode(_ f: [UInt8]) -> WhoopRecord? {
    guard f.count >= 9 else { return nil }
    let len = f.count - 8           // payload length
    let pt = u8(f, 0), k = u8(f, 1)
    if pt == 40 {                                                       // k2 realtime HR
      guard len >= 9 else { return nil }
      return .realtimeHR(hr: u8(f, 8))
    }
    if pt == 47 && k == 18 && len >= 67 {                               // k18
      let temp = Double(i16le(f, 65)) / 100.0
      return .k18(tempC: temp, hr: u8(f, 14), resp: u8(f, 35), ts: u32le(f, 7))
    }
    if pt == 43 && k == 21 && len >= 620 {                              // k21 IMU
      var nc = u16le(f, 14); if nc > 100 { nc = 100 }
      var gc = 0, gx = 0
      if len >= 1236 { gc = u16le(f, 622); if gc > 100 { gc = 100 }; gx = i16le(f, 632) }
      return .imu(nc: nc,
                  ax0: Double(i16le(f, 20)) / accScale,
                  ay0: Double(i16le(f, 220)) / accScale,
                  az0: Double(i16le(f, 420)) / accScale,
                  gyroCount: gc, gx0: gx)
    }
    if (pt == 43 || pt == 47) && k == 20 && len == 2132 {               // k20 optical
      // 25 PPG samples, uint32 LE, payload offset 239, stride 4 (gateway PERF_OFF=239, PERF_N=25).
      return .optical(samples: (0..<25).map { u32le(f, 239 + 4 * $0) })
    }
    if pt == 36 && len >= 22 {                                          // type36 data-range response
      return .dataRange(head: u32le(f, 14), watermark: u32le(f, 18))
    }
    return .other(pt: pt, k: k, len: len)
  }

  /// Peak |accel|−1g across ALL samples batched in one k21 IMU frame (~100 tri-axial samples @ high rate, payload
  /// offsets ax 20.., ay 220.., az 420.., 2-byte LE). The realtime stream only sends one frame ~1.5 Hz, but each
  /// frame carries the full high-rate window — so this recovers the true transient peak (e.g. a tap) the single-
  /// sample `.imu` decode misses. Returns 0 for non-IMU / short frames.
  public static func imuPeakMag(_ f: [UInt8]) -> Double { imuBatch(f).peak }

  /// Peak AND mean |accel|−1g over a k21 batch. A discrete TAP is a sharp transient — high `peak`, low `mean`
  /// (most of the ~100-sample window is calm) — so `peak − mean` is large; a shake/clench has a high mean too,
  /// so `peak − mean` stays small. That difference is what tells a real tap from generic vibration.
  public static func imuBatch(_ f: [UInt8]) -> (peak: Double, mean: Double) {
    let len = f.count - 8
    guard f.count >= 9, u8(f, 0) == 43, u8(f, 1) == 21, len >= 620 else { return (0, 0) }
    var nc = u16le(f, 14); if nc > 100 { nc = 100 }; if nc < 1 { return (0, 0) }
    var peak = 0.0, sum = 0.0
    for i in 0..<nc {
      let ax = Double(i16le(f, 20 + 2 * i)) / accScale
      let ay = Double(i16le(f, 220 + 2 * i)) / accScale
      let az = Double(i16le(f, 420 + 2 * i)) / accScale
      let m = abs((ax * ax + ay * ay + az * az).squareRoot() - 1)
      if m > peak { peak = m }; sum += m
    }
    return (peak, sum / Double(nc))
  }
}

/// Frame reassembler — feed raw BLE notification chunks, get back complete aa-frames.
/// Port of the JS Accum: scan for 0xAA, declared length = bytes[2..3] LE, total = declared+8.
public final class Accum {
  private static let maxFrameLen = 8192
  private var buf: [UInt8] = []
  public init() {}
  public func feed(_ chunk: [UInt8]) -> [[UInt8]] {
    buf.append(contentsOf: chunk)
    var out: [[UInt8]] = []
    while true {
      guard let i = buf.firstIndex(of: 0xAA) else { buf.removeAll(); break }
      if i > 0 { buf.removeFirst(i) }
      if buf.count < 8 { break }
      if buf[1] != 0x01 { buf.removeFirst(); continue }
      let declared = Int(buf[2]) | (Int(buf[3]) << 8)
      let flen = declared + 8
      if flen > Self.maxFrameLen { buf.removeFirst(); continue }
      if buf.count < flen { break }
      out.append(Array(buf[0..<flen]))
      buf.removeFirst(flen)
    }
    return out
  }
}
