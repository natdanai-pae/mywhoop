import Foundation
import XCTest

@testable import GolfTrace

final class GolfTraceWireProtocolTests: XCTestCase {
  func testConsumesMultiplePacketsFromOneTCPBuffer() {
    let first = makePacket(sequence: 1, payload: Data([0x10, 0x11]))
    let second = makePacket(sequence: 2, payload: Data([0x20, 0x21, 0x22]))
    var buffer = first.encoded()
    buffer.append(second.encoded())

    let packets = GolfTraceWirePacket.consumeAvailablePackets(from: &buffer)

    XCTAssertEqual(packets, [first, second])
    XCTAssertTrue(buffer.isEmpty)
  }

  func testKeepsPartialPacketUntilRemainingBytesArrive() {
    let packet = makePacket(sequence: 7, payload: Data(repeating: 0xAB, count: 64))
    let encoded = packet.encoded()
    var buffer = Data(encoded.prefix(19))

    XCTAssertTrue(GolfTraceWirePacket.consumeAvailablePackets(from: &buffer).isEmpty)
    buffer.append(Data(encoded.dropFirst(19)))

    XCTAssertEqual(GolfTraceWirePacket.consumeAvailablePackets(from: &buffer), [packet])
    XCTAssertTrue(buffer.isEmpty)
  }

  func testPacketAccumulatorParsesFragmentedAndCombinedReadsInOrder() {
    let first = makePacket(sequence: 31, payload: Data(repeating: 0x31, count: 17))
    let second = makePacket(sequence: 32, payload: Data(repeating: 0x32, count: 33))
    var encoded = first.encoded()
    encoded.append(second.encoded())

    var accumulator = GolfTracePacketAccumulator()
    var packets: [GolfTraceWirePacket] = []
    let fragmentSizes = [1, 7, 19, 2, 41, 3, 128]
    var offset = 0
    for size in fragmentSizes where offset < encoded.count {
      let end = min(encoded.count, offset + size)
      packets.append(contentsOf: accumulator.append(Data(encoded[offset..<end])))
      offset = end
    }
    if offset < encoded.count {
      packets.append(contentsOf: accumulator.append(Data(encoded[offset...])))
    }

    XCTAssertEqual(packets, [first, second])
    XCTAssertEqual(accumulator.bufferedByteCount, 0)
  }

  func testPacketAccumulatorKeepsIncompleteTailAfterCompletePacket() {
    let first = makePacket(sequence: 41, payload: Data([0x41]))
    let second = makePacket(sequence: 42, payload: Data(repeating: 0x42, count: 80))
    let secondBytes = second.encoded()
    var firstRead = first.encoded()
    firstRead.append(Data(secondBytes.prefix(23)))

    var accumulator = GolfTracePacketAccumulator()
    XCTAssertEqual(accumulator.append(firstRead), [first])
    XCTAssertEqual(accumulator.bufferedByteCount, 23)
    XCTAssertEqual(accumulator.append(Data(secondBytes.dropFirst(23))), [second])
    XCTAssertEqual(accumulator.bufferedByteCount, 0)
  }

  func testResynchronizesAfterGarbagePrefixWithoutUsingAbsoluteDataIndices() {
    let packet = makePacket(sequence: 9, payload: Data([0x42]))
    var buffer = Data([0x00, 0x01, 0x02, 0x03, 0x04])
    buffer.append(packet.encoded())

    let packets = GolfTraceWirePacket.consumeAvailablePackets(from: &buffer)

    XCTAssertEqual(packets, [packet])
    XCTAssertTrue(buffer.isEmpty)
  }

  func testPracticeSettingsRoundTripKeepsClubViewGuideCoachAndAudioDevice() throws {
    let settings = GolfPracticeSettings(
      club: .driver,
      cameraView: .faceOn,
      guideline: .rotation,
      coach: .dataCoach,
      audioDevice: .mac
    )

    let data = try XCTUnwrap(settings.encoded())

    XCTAssertEqual(GolfPracticeSettings.decode(data), settings)
  }

  func testPracticeSettingsPacketSharesTCPBufferWithVideoPacket() throws {
    let settings = GolfPracticeSettings.default
    let settingsPacket = GolfTraceWirePacket(
      kind: .practiceSettings,
      flags: [],
      sequence: 10,
      presentationTimeMicroseconds: 0,
      payload: try XCTUnwrap(settings.encoded())
    )
    let videoPacket = makePacket(sequence: 11, payload: Data([0x01, 0x02]))
    var buffer = settingsPacket.encoded()
    buffer.append(videoPacket.encoded())

    let packets = GolfTraceWirePacket.consumeAvailablePackets(from: &buffer)

    XCTAssertEqual(packets, [settingsPacket, videoPacket])
    XCTAssertEqual(GolfPracticeSettings.decode(packets[0].payload), settings)
    XCTAssertTrue(buffer.isEmpty)
  }

  func testPracticeSettingsRejectsSchemaFromUnsupportedFutureVersion() throws {
    let settings = GolfPracticeSettings(
      schemaVersion: GolfPracticeSettings.currentSchemaVersion + 1,
      club: .iron7,
      cameraView: .downTheLine,
      guideline: .personalBaseline,
      coach: .personalBlend,
      audioDevice: .mac
    )

    XCTAssertNil(GolfPracticeSettings.decode(try XCTUnwrap(settings.encoded())))
  }

  func testVideoOrientationRoundTripsAsTwoNumericBytes() throws {
    for orientation in GolfTraceVideoOrientation.allCases {
      let encoded = orientation.encoded()
      XCTAssertEqual(encoded.count, 2)
      XCTAssertEqual(GolfTraceVideoOrientation.decode(encoded), orientation)
    }
  }

  func testVideoOrientationUsesStableNearestQuarterTurn() {
    XCTAssertEqual(GolfTraceVideoOrientation.nearest(to: 2), .degrees0)
    XCTAssertEqual(GolfTraceVideoOrientation.nearest(to: 88), .degrees90)
    XCTAssertEqual(GolfTraceVideoOrientation.nearest(to: 181), .degrees180)
    XCTAssertEqual(GolfTraceVideoOrientation.nearest(to: -91), .degrees270)
    XCTAssertTrue(GolfTraceVideoOrientation.degrees90.swapsDimensions)
    XCTAssertFalse(GolfTraceVideoOrientation.degrees180.swapsDimensions)
  }

  func testDecodedFrameContextKeepsGenerationAndOrientationTogether() throws {
    for generation in [UInt64(0), 1, 42, 65_535] {
      for orientation in GolfTraceVideoOrientation.allCases {
        let submitted = GolfTraceDecodedFrameContext(
          generation: generation,
          videoOrientation: orientation
        )
        let decoded = try XCTUnwrap(
          GolfTraceDecodedFrameContext(opaquePointer: submitted.opaquePointer)
        )

        XCTAssertEqual(decoded, submitted)
      }
    }
  }

  func testLatestPreviewSlotCoalescesToNewestPendingFrame() {
    let slot = GolfTraceLatestValueSlot(1)

    XCTAssertTrue(slot.offer(2))
    XCTAssertTrue(slot.offer(3))
    XCTAssertEqual(slot.takeLatest(), 3)
    XCTAssertFalse(slot.hasPendingValue)

    XCTAssertFalse(slot.offer(4))
    XCTAssertEqual(slot.takeLatest(), 4)
    slot.cancel()
    XCTAssertFalse(slot.offer(5))
    XCTAssertNil(slot.takeLatest())
  }

  func testVideoOrientationPacketSharesTCPBufferWithVideoPacket() {
    let orientationPacket = GolfTraceWirePacket(
      kind: .videoOrientation,
      flags: [],
      sequence: 20,
      presentationTimeMicroseconds: 0,
      payload: GolfTraceVideoOrientation.degrees90.encoded()
    )
    let videoPacket = makePacket(sequence: 21, payload: Data([0xAA]))
    var buffer = orientationPacket.encoded()
    buffer.append(videoPacket.encoded())

    let packets = GolfTraceWirePacket.consumeAvailablePackets(from: &buffer)

    XCTAssertEqual(packets, [orientationPacket, videoPacket])
    XCTAssertEqual(
      GolfTraceVideoOrientation.decode(packets[0].payload),
      .degrees90
    )
    XCTAssertTrue(buffer.isEmpty)
  }

  private func makePacket(sequence: UInt64, payload: Data) -> GolfTraceWirePacket {
    GolfTraceWirePacket(
      kind: .h264AccessUnit,
      flags: [],
      sequence: sequence,
      presentationTimeMicroseconds: Int64(sequence * 1_000),
      payload: payload
    )
  }
}
