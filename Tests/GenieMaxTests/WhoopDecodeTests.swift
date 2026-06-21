import Testing
import Foundation
@testable import GenieMax

/// C1 — decode parity vs golden vectors exported from the validated JS pipeline
/// (a reference exporter over a real btsnoop capture).
private func golden() throws -> [String: Any] {
  let url = Bundle.module.url(forResource: "decode_golden", withExtension: "json", subdirectory: "Fixtures")!
  let data = try Data(contentsOf: url)
  return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}
private func frame(_ name: String) throws -> ([UInt8], [String: Any]) {
  let frames = try golden()["frames"] as! [String: Any]
  let f = frames[name] as! [String: Any]
  return (WhoopFrame.bytes(f["hex"] as! String), f)
}
private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@Test func decodeK2RealtimeHR() throws {
  let (bytes, exp) = try frame("k2")
  #expect(WhoopDecode.decode(bytes) == .realtimeHR(hr: exp["hr8"] as! Int))
}

@Test func decodeShortK2DoesNotReadPastFrame() {
  var bytes = [UInt8](repeating: 0, count: 12)
  bytes[0] = 0xaa; bytes[1] = 0x01; bytes[8] = 40
  #expect(WhoopDecode.decode(bytes) == nil)
}

@Test func decodeK18() throws {
  let (bytes, exp) = try frame("k18")
  guard case let .k18(tempC, hr, resp, ts) = WhoopDecode.decode(bytes) else { Issue.record("not k18"); return }
  #expect(approx(tempC, exp["temp_c"] as! Double))
  #expect(hr == exp["hr14"] as! Int)
  #expect(resp == exp["resp35"] as! Int)
  #expect(ts == UInt32(exp["ts7"] as! Int))
}

@Test func decodeK21IMU() throws {
  let (bytes, exp) = try frame("k21")
  guard case let .imu(nc, ax0, ay0, az0, gyroCount, gx0) = WhoopDecode.decode(bytes) else { Issue.record("not imu"); return }
  #expect(nc == exp["nc"] as! Int)
  #expect(approx(ax0, exp["ax0"] as! Double, 1e-9))
  #expect(approx(ay0, exp["ay0"] as! Double, 1e-9))
  #expect(approx(az0, exp["az0"] as! Double, 1e-9))
  #expect(gyroCount == exp["gyroCount"] as! Int)
  #expect(gx0 == exp["gx0"] as! Int)
}

@Test func decodeK20Optical() throws {
  let (bytes, exp) = try frame("k20")
  guard case .optical(let s) = WhoopDecode.decode(bytes) else { Issue.record("not optical"); return }
  #expect(s.count == 25)
  #expect(s.first == UInt32(exp["opt0"] as! Int))     // first sample = gateway opt0
}

@Test func decodeType36DataRange() throws {
  let (bytes, exp) = try frame("type36")
  #expect(WhoopDecode.decode(bytes) == .dataRange(head: UInt32(exp["head"] as! Int),
                                                  watermark: UInt32(exp["watermark"] as! Int)))
}

@Test func accumReassemblesSingleFrame() throws {
  // feeding a complete frame in two chunks must yield exactly one reassembled frame
  let (bytes, _) = try frame("k2")
  let acc = Accum()
  var out = acc.feed(Array(bytes[0..<5]))
  #expect(out.isEmpty)               // partial → nothing yet
  out = acc.feed(Array(bytes[5...]))
  #expect(out.count == 1)
  #expect(out.first == bytes)
}

@Test func accumSkipsMalformedAAHeaderAndOversizeLength() throws {
  let (bytes, _) = try frame("k2")
  let acc = Accum()
  let noise: [UInt8] = [
    0xaa, 0x02, 0x04, 0x00, 0, 0, 0, 0,     // wrong version byte
    0xaa, 0x01, 0xff, 0xff, 0, 0, 0, 0      // impossible local frame size
  ]
  let out = acc.feed(noise + bytes)
  #expect(out.count == 1)
  #expect(out.first == bytes)
}
