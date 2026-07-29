import Foundation

enum GolfTraceWireService {
  static let bonjourType = "_golftrace._tcp"
}

/// Small, framed protocol for the direct iPhone-to-Mac high-speed video path.
///
/// Packets travel over one reliable TCP connection. H.264 access units remain in
/// AVCC format (four-byte NAL-unit lengths), which lets VideoToolbox decode them
/// without a container format or a file round-trip.
enum GolfTraceWirePacketKind: UInt8 {
  case hello = 1
  case h264Configuration = 2
  case h264AccessUnit = 3
  case requestKeyFrame = 4
  /// ค่ารอบซ้อม เช่น ชนิดไม้ มุมกล้อง guideline และโปรที่เลือก
  case practiceSettings = 5
  /// องศาที่ Mac ต้องหมุนภาพดิบตามทิศที่ถือ iPhone โดยไม่หมุนพิกเซล 120 FPS
  case videoOrientation = 6
}

/// ทิศของภาพดิบจากเซนเซอร์ที่ส่งเป็นตัวเลขไปพร้อมวิดีโอ
///
/// การส่ง metadata 2 ไบต์ให้ Mac หมุนตอนแสดงผล ประหยัดกว่าการหมุนพิกเซลทุกเฟรม
/// บน iPhone และยังคงเส้นทาง H.264 120 FPS เดิมไว้ครบถ้วน
enum GolfTraceVideoOrientation: UInt16, CaseIterable, Equatable {
  case degrees0 = 0
  case degrees90 = 90
  case degrees180 = 180
  case degrees270 = 270

  var clockwiseDegrees: Double { Double(rawValue) }

  var swapsDimensions: Bool {
    self == .degrees90 || self == .degrees270
  }

  func addingHalfTurn(_ shouldAddHalfTurn: Bool) -> GolfTraceVideoOrientation {
    guard shouldAddHalfTurn else { return self }
    return GolfTraceVideoOrientation(rawValue: (rawValue + 180) % 360) ?? self
  }

  /// RotationCoordinator อาจรายงานค่าระหว่างการขยับเครื่อง จึงล็อกเป็นแกนใกล้สุด
  /// เพื่อไม่ให้ภาพ เส้นท่าทาง และ Vision สั่นตามการเอียงมือเล็กน้อย
  static func nearest(to degrees: Double) -> GolfTraceVideoOrientation {
    guard degrees.isFinite else { return .degrees0 }
    let normalized = degrees.truncatingRemainder(dividingBy: 360) + (degrees < 0 ? 360 : 0)
    let quarterTurns = Int((normalized / 90).rounded()) % 4
    return Self(rawValue: UInt16(quarterTurns * 90)) ?? .degrees0
  }

  func encoded() -> Data {
    var data = Data()
    data.appendBigEndian(rawValue)
    return data
  }

  static func decode(_ data: Data) -> GolfTraceVideoOrientation? {
    guard data.count == 2 else { return nil }
    let value =
      (UInt16(data.byte(atRelativeOffset: 0)) << 8)
      | UInt16(data.byte(atRelativeOffset: 1))
    return Self(rawValue: value)
  }
}

struct GolfTraceWirePacket: Equatable {
  static let version: UInt8 = 1
  static let headerLength = 28
  static let maximumPayloadLength = 8 * 1_024 * 1_024

  /// The ASCII bytes `GTRC` in big-endian order.
  private static let magic: UInt32 = 0x4754_5243

  struct Flags: OptionSet, Equatable {
    let rawValue: UInt16

    static let keyFrame = Flags(rawValue: 1 << 0)
  }

  let kind: GolfTraceWirePacketKind
  let flags: Flags
  let sequence: UInt64
  /// Capture presentation time in microseconds. It is deliberately independent
  /// of either device's wall clock.
  let presentationTimeMicroseconds: Int64
  let payload: Data

  func encoded() -> Data {
    var data = Data()
    data.reserveCapacity(Self.headerLength + payload.count)
    data.appendBigEndian(Self.magic)
    data.append(Self.version)
    data.append(kind.rawValue)
    data.appendBigEndian(flags.rawValue)
    data.appendBigEndian(sequence)
    data.appendBigEndian(UInt64(bitPattern: presentationTimeMicroseconds))
    data.appendBigEndian(UInt32(payload.count))
    data.append(payload)
    return data
  }

  /// Extracts every complete packet that is already available. Invalid leading
  /// bytes are discarded one at a time so a new TCP connection can resynchronize
  /// after a malformed packet without allocating unbounded memory.
  static func consumeAvailablePackets(from buffer: inout Data) -> [GolfTraceWirePacket] {
    var packets: [GolfTraceWirePacket] = []

    while buffer.count >= headerLength {
      guard readUInt32(buffer, at: 0) == magic else {
        buffer.removeFirst()
        continue
      }

      guard buffer.byte(atRelativeOffset: 4) == version,
        let kind = GolfTraceWirePacketKind(rawValue: buffer.byte(atRelativeOffset: 5))
      else {
        buffer.removeFirst(4)
        continue
      }

      let payloadLength = Int(readUInt32(buffer, at: 24))
      guard payloadLength >= 0, payloadLength <= maximumPayloadLength else {
        buffer.removeFirst(4)
        continue
      }

      let packetLength = headerLength + payloadLength
      guard buffer.count >= packetLength else { break }

      let flags = Flags(rawValue: readUInt16(buffer, at: 6))
      let sequence = readUInt64(buffer, at: 8)
      let presentationTime = Int64(bitPattern: readUInt64(buffer, at: 16))
      let payload = buffer.relativeSubdata(in: headerLength..<packetLength)
      packets.append(
        GolfTraceWirePacket(
          kind: kind,
          flags: flags,
          sequence: sequence,
          presentationTimeMicroseconds: presentationTime,
          payload: payload
        )
      )
      buffer.removeFirst(packetLength)
    }

    return packets
  }

  private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(data.byte(atRelativeOffset: offset)) << 8)
      | UInt16(data.byte(atRelativeOffset: offset + 1))
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    (UInt32(data.byte(atRelativeOffset: offset)) << 24)
      | (UInt32(data.byte(atRelativeOffset: offset + 1)) << 16)
      | (UInt32(data.byte(atRelativeOffset: offset + 2)) << 8)
      | UInt32(data.byte(atRelativeOffset: offset + 3))
  }

  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 {
      value = (value << 8) | UInt64(data.byte(atRelativeOffset: offset + index))
    }
    return value
  }
}

/// The H.264 decoder needs the codec parameter sets before it can accept an
/// access unit. This payload appears immediately before an IDR frame and again
/// after reconnecting.
struct GolfTraceH264Configuration: Equatable {
  let sequenceParameterSet: Data
  let pictureParameterSet: Data

  func encoded() -> Data? {
    guard sequenceParameterSet.count <= Int(UInt16.max),
      pictureParameterSet.count <= Int(UInt16.max)
    else {
      return nil
    }

    var data = Data()
    data.reserveCapacity(4 + sequenceParameterSet.count + pictureParameterSet.count)
    data.appendBigEndian(UInt16(sequenceParameterSet.count))
    data.append(sequenceParameterSet)
    data.appendBigEndian(UInt16(pictureParameterSet.count))
    data.append(pictureParameterSet)
    return data
  }

  static func decode(_ data: Data) -> GolfTraceH264Configuration? {
    guard data.count >= 4 else { return nil }
    let spsLength = Int(
      (UInt16(data.byte(atRelativeOffset: 0)) << 8)
        | UInt16(data.byte(atRelativeOffset: 1))
    )
    let ppsLengthOffset = 2 + spsLength
    guard spsLength > 0,
      ppsLengthOffset + 2 <= data.count
    else {
      return nil
    }

    let ppsLength = Int(
      (UInt16(data.byte(atRelativeOffset: ppsLengthOffset)) << 8)
        | UInt16(data.byte(atRelativeOffset: ppsLengthOffset + 1))
    )
    let ppsStart = ppsLengthOffset + 2
    guard ppsLength > 0, ppsStart + ppsLength == data.count else {
      return nil
    }

    return GolfTraceH264Configuration(
      sequenceParameterSet: data.relativeSubdata(in: 2..<ppsLengthOffset),
      pictureParameterSet: data.relativeSubdata(in: ppsStart..<ppsStart + ppsLength)
    )
  }
}

extension Data {
  /// `Data.removeFirst` can leave `startIndex` greater than zero. Network
  /// protocol offsets are relative to the current buffer, not absolute
  /// collection indices, so every read must advance from `startIndex`.
  fileprivate func byte(atRelativeOffset offset: Int) -> UInt8 {
    self[index(startIndex, offsetBy: offset)]
  }

  fileprivate func relativeSubdata(in offsets: Range<Int>) -> Data {
    let lowerBound = index(startIndex, offsetBy: offsets.lowerBound)
    let upperBound = index(startIndex, offsetBy: offsets.upperBound)
    return subdata(in: lowerBound..<upperBound)
  }

  fileprivate mutating func appendBigEndian(_ value: UInt16) {
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8(value & 0xFF))
  }

  fileprivate mutating func appendBigEndian(_ value: UInt32) {
    append(UInt8((value >> 24) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8(value & 0xFF))
  }

  fileprivate mutating func appendBigEndian(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
  }
}
