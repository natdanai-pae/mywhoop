import Testing
@testable import WhoopCore

@Test func hapticFrameByteExact() {
  // openwhoop verified Gen5 haptic RunHapticPatternMaverick=19 (matches our validate_haptic.mjs)
  let got = WhoopFrame.hex(WhoopFrame.build(seq: 0x02, cmd: 19,
    data: [0x01,0x2f,0x98,0,0,0,0,0,0,0,0,0x01,0x00]))
  #expect(got == "aa0114000001e1e1230213012f9800000000000000000100a090e5ad")
}
@Test func getDataRangeByteExact() {
  let got = WhoopFrame.hex(WhoopFrame.build(seq: 0x01, cmd: 34, data: []))
  #expect(got == "aa0108000001e67123012200dbf3b335")
}
@Test func hexRoundTrip() {
  let b: [UInt8] = [0xaa, 0x01, 0x00, 0xff, 0x10]
  #expect(WhoopFrame.bytes(WhoopFrame.hex(b)) == b)
}
