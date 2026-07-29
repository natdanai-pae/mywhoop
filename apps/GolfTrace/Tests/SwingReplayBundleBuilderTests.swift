import CoreMedia
import CoreVideo
import XCTest

@testable import GolfTrace

final class SwingReplayBundleBuilderTests: XCTestCase {
  func testBuildsSynchronizedPairFromOverlappingFileClockAnchors() {
    let export = SwingReplayBundleBuilder.make(
      camera: cameraResult(),
      rapsodo: rapsodoResult()
    )

    XCTAssertEqual(export.bundle.status, .synchronizedPair)
    XCTAssertTrue(export.bundle.isSynchronizedPair)
    XCTAssertEqual(export.bundle.camera.sourceKind, "direct_iphone_h264")
    XCTAssertEqual(export.bundle.rapsodo?.sourceKind, "rapsodo_usb_screen")
    XCTAssertEqual(export.bundle.camera.orientation, .degrees90)
    XCTAssertEqual(export.bundle.rapsodo?.nominalFPS ?? 0, 30, accuracy: 0.001)
    XCTAssertNotNil(export.rapsodoURL)
  }

  func testCameraMasterSurvivesMissingRapsodo() {
    let export = SwingReplayBundleBuilder.make(camera: cameraResult(), rapsodo: nil)

    XCTAssertEqual(export.bundle.status, .cameraSaved)
    XCTAssertFalse(export.bundle.isSynchronizedPair)
    XCTAssertNil(export.bundle.rapsodo)
    XCTAssertNil(export.bundle.synchronization)
    XCTAssertNil(export.rapsodoURL)
  }

  private func cameraResult() -> CameraMasterReplayExportResult {
    CameraMasterReplayExportResult(
      url: URL(fileURLWithPath: "/tmp/camera.mov"),
      sourcePTSOrigin: CMTime(seconds: 100, preferredTimescale: 1_000_000),
      durationSeconds: 1,
      fileClockAnchors: anchors(hostStart: 20),
      format: CameraMasterReplayFormat(
        codec: "h264",
        encodedPixelWidth: 1_920,
        encodedPixelHeight: 1_080,
        nominalFrameRate: 120,
        rotationDegrees: 90
      ),
      counters: CameraMasterReplayCounters(
        selectedFrames: 120,
        selectedBytes: 1_000_000,
        receiverReceivedFrames: 120,
        receiverDecodedFrames: 120,
        decoderDrops: 0,
        renderDrops: 0
      )
    )
  }

  private func rapsodoResult() -> RapsodoReplayExportResult {
    RapsodoReplayExportResult(
      url: URL(fileURLWithPath: "/tmp/rapsodo.mov"),
      sourceKind: .usb(deviceID: "K"),
      generationID: 7,
      format: RapsodoReplayVideoFormat(
        width: 1_920,
        height: 1_080,
        pixelFormat: kCVPixelFormatType_32BGRA
      ),
      duration: 1,
      anchors: anchors(hostStart: 20.1),
      counters: rapsodoCounters()
    )
  }

  private func rapsodoCounters() -> RapsodoReplayFrameCounters {
    var counters = RapsodoReplayFrameCounters()
    counters.received = 60
    counters.appended = 30
    return counters
  }

  private func anchors(hostStart: Double) -> [SwingReplayClockAnchor] {
    (0..<20).map { index in
      let media = Double(index) * 0.05
      return SwingReplayClockAnchor(
        mediaTimeSeconds: media,
        monotonicTimeSeconds: hostStart + media
      )
    }
  }
}
