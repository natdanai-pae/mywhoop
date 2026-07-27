import Foundation

/// Adapts arbitrary TCP reads to the shared incremental wire parser.
///
/// The parser addresses bytes relative to `Data.startIndex`, so a complete TCP
/// read can be appended and parsed in one pass. Rebase at most once afterwards
/// to keep a long-lived slice from retaining already-consumed storage.
struct GolfTracePacketAccumulator {
  private var buffer = Data()

  var bufferedByteCount: Int {
    buffer.count
  }

  mutating func append(_ content: Data) -> [GolfTraceWirePacket] {
    guard !content.isEmpty else { return [] }
    buffer.append(content)
    let packets = GolfTraceWirePacket.consumeAvailablePackets(from: &buffer)
    if buffer.startIndex != 0 {
      buffer = Data(buffer)
    }
    return packets
  }

  mutating func reset() {
    buffer = Data()
  }

}
