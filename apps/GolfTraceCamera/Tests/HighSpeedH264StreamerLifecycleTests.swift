import Foundation
import XCTest

@testable import GolfTraceCamera

final class HighSpeedH264StreamerLifecycleTests: XCTestCase {
  func testStopReleasesEncoderSoRestartCreatesFreshSession() throws {
    let streamer = HighSpeedH264Streamer()
    streamer.configure(width: 640, height: 480, framesPerSecond: 30)

    let firstSession = try waitForCompressionSession(in: streamer, toBePresent: true)

    streamer.stop()
    _ = try waitForCompressionSession(in: streamer, toBePresent: false)

    streamer.start()
    let restartedSession = try waitForCompressionSession(in: streamer, toBePresent: true)

    XCTAssertFalse(firstSession === restartedSession)
    streamer.stop()
  }

  private func waitForCompressionSession(
    in streamer: HighSpeedH264Streamer,
    toBePresent expectedPresence: Bool,
    timeout: TimeInterval = 2
  ) throws -> AnyObject? {
    let deadline = Date().addingTimeInterval(timeout)

    repeat {
      let session = compressionSession(in: streamer)
      if (session != nil) == expectedPresence {
        return session
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    } while Date() < deadline

    XCTFail(
      expectedPresence
        ? "Expected the H.264 compression session to be created"
        : "Expected stop() to invalidate and release the H.264 compression session"
    )
    throw TestFailure.timedOut
  }

  private func compressionSession(in streamer: HighSpeedH264Streamer) -> AnyObject? {
    guard
      let storedOptional = Mirror(reflecting: streamer).children.first(where: {
        $0.label == "compressionSession"
      })?.value
    else {
      return nil
    }

    return Mirror(reflecting: storedOptional).children.first?.value as AnyObject?
  }

  private enum TestFailure: Error {
    case timedOut
  }
}
