import Foundation
import XCTest

@testable import GolfTrace

final class VideoHalfTurnPreferenceTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "VideoHalfTurnPreferenceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = ""
    super.tearDown()
  }

  func testMissingOrInvalidPreferenceFallsBackToNormal() {
    let preference = VideoHalfTurnPreference(defaults: defaults)

    XCTAssertEqual(preference.load(for: .directIPhone), .normal)

    defaults.set("unsupported", forKey: VideoHalfTurnPreference.storageKey)
    XCTAssertEqual(preference.load(for: .directIPhone), .normal)
  }

  func testPreferenceRoundTripsRotatedHalfTurn() {
    let preference = VideoHalfTurnPreference(defaults: defaults)

    preference.save(.rotated180, for: .directIPhone)

    XCTAssertEqual(preference.load(for: .directIPhone), .rotated180)
    XCTAssertEqual(preference.load(for: .appleFallback), .normal)
  }

  func testLegacyPreferenceMigratesOnlyToDirectIPhoneSource() {
    defaults.set(VideoHalfTurn.rotated180.rawValue, forKey: VideoHalfTurnPreference.storageKey)
    let preference = VideoHalfTurnPreference(defaults: defaults)

    XCTAssertEqual(preference.load(for: .directIPhone), .rotated180)
    XCTAssertEqual(preference.load(for: .appleFallback), .normal)
  }

  func testDirectAndFallbackCorrectionsAreIndependent() {
    let preference = VideoHalfTurnPreference(defaults: defaults)

    preference.save(.rotated180, for: .appleFallback)

    XCTAssertEqual(preference.load(for: .directIPhone), .normal)
    XCTAssertEqual(preference.load(for: .appleFallback), .rotated180)
  }

  func testManualHalfTurnComposesWithEveryWireOrientationExactlyOnce() {
    let expected: [GolfTraceVideoOrientation: GolfTraceVideoOrientation] = [
      .degrees0: .degrees180,
      .degrees90: .degrees270,
      .degrees180: .degrees0,
      .degrees270: .degrees90,
    ]

    for orientation in GolfTraceVideoOrientation.allCases {
      XCTAssertEqual(
        orientation.addingHalfTurn(VideoHalfTurn.rotated180.isEnabled),
        expected[orientation]
      )
    }
  }

  func testCaptureContextDropsDirectQuarterTurnWhenTransitioningToFallback() {
    let transitions: [(GolfTraceVideoOrientation, GolfTraceVideoOrientation)] = [
      (.degrees90, .degrees270),
      (.degrees270, .degrees90),
    ]

    for (receivedOrientation, expectedDirectOrientation) in transitions {
      let direct = CameraCaptureSourceContextResolver.resolve(
        usesDirectIPhoneInput: true,
        receivedDirectOrientation: receivedOrientation,
        directHalfTurn: .rotated180,
        fallbackHalfTurn: .normal,
        activeFallbackSourceID: "continuity-camera-17"
      )
      XCTAssertEqual(direct.sourceID, SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID)
      XCTAssertEqual(direct.orientation, expectedDirectOrientation)

      let fallback = CameraCaptureSourceContextResolver.resolve(
        usesDirectIPhoneInput: false,
        receivedDirectOrientation: receivedOrientation,
        directHalfTurn: .rotated180,
        fallbackHalfTurn: .normal,
        activeFallbackSourceID: "continuity-camera-17"
      )
      XCTAssertEqual(fallback.sourceID, "continuity-camera-17")
      XCTAssertEqual(fallback.orientation, .degrees0)
    }
  }

  func testFallbackCaptureContextUsesOnlyItsOwnHalfTurnAndStableFallbackIdentity() {
    for receivedOrientation in [
      GolfTraceVideoOrientation.degrees90,
      GolfTraceVideoOrientation.degrees270,
    ] {
      let fallback = CameraCaptureSourceContextResolver.resolve(
        usesDirectIPhoneInput: false,
        receivedDirectOrientation: receivedOrientation,
        directHalfTurn: .normal,
        fallbackHalfTurn: .rotated180,
        activeFallbackSourceID: nil
      )

      XCTAssertEqual(fallback.sourceID, CameraCaptureSourceContextResolver.fallbackSourceID)
      XCTAssertEqual(fallback.orientation, .degrees180)
    }
  }

  @MainActor
  func testCameraModelRestoresAndPersistsHalfTurnWithoutStartingReceiver() {
    let preference = VideoHalfTurnPreference(defaults: defaults)
    preference.save(.rotated180, for: .directIPhone)

    let camera = CameraCaptureModel(
      videoHalfTurnPreference: preference,
      automaticallyStartsHighSpeedInput: false
    )

    XCTAssertEqual(camera.videoHalfTurn, .rotated180)
    XCTAssertEqual(camera.videoOrientation, .degrees180)
    XCTAssertEqual(
      camera.currentLiveSwingCaptureContext.sourceID,
      CameraCaptureSourceContextResolver.fallbackSourceID
    )
    XCTAssertEqual(camera.currentLiveSwingCaptureContext.orientation, .degrees0)

    camera.toggleVideoHalfTurn()

    XCTAssertEqual(camera.videoHalfTurn, .normal)
    XCTAssertEqual(preference.load(for: .directIPhone), .normal)
    XCTAssertEqual(camera.currentLiveSwingCaptureContext.orientation, .degrees0)
  }

  @MainActor
  func testCameraModelDoesNotLeakInactiveDirectCorrectionIntoFallbackContext() {
    let preference = VideoHalfTurnPreference(defaults: defaults)
    preference.save(.normal, for: .directIPhone)
    preference.save(.rotated180, for: .appleFallback)

    let camera = CameraCaptureModel(
      videoHalfTurnPreference: preference,
      automaticallyStartsHighSpeedInput: false
    )

    XCTAssertEqual(camera.videoHalfTurn, .normal)
    XCTAssertEqual(
      camera.currentLiveSwingCaptureContext.sourceID,
      CameraCaptureSourceContextResolver.fallbackSourceID
    )
    XCTAssertEqual(camera.currentLiveSwingCaptureContext.orientation, .degrees180)
  }
}

final class LiveVideoStagePresentationTests: XCTestCase {
  func testAdvertisingExplainsHowGolfTraceCameraConnectsAutomatically() throws {
    let presentation = try XCTUnwrap(
      LiveVideoStagePresentationResolver.resolve(
        receiverState: .advertising,
        decodedFrames: 0
      ))

    XCTAssertEqual(presentation.title, "กำลังค้นหา GolfTrace Camera")
    XCTAssertTrue(presentation.detail.contains("เปิดแอป GolfTrace Camera"))
    XCTAssertEqual(presentation.systemImage, "iphone.radiowaves.left.and.right")
    XCTAssertEqual(presentation.tint, .orange)
    XCTAssertFalse(presentation.allowsReconnectAction)
  }

  func testConnectedWithoutFrameShowsPreparingState() throws {
    let presentation = try XCTUnwrap(
      LiveVideoStagePresentationResolver.resolve(
        receiverState: .connected,
        decodedFrames: 0
      ))

    XCTAssertEqual(presentation.title, "เชื่อมต่อ GolfTrace Camera แล้ว")
    XCTAssertTrue(presentation.detail.contains("กำลังเตรียมภาพ"))
    XCTAssertEqual(presentation.systemImage, "camera.aperture")
    XCTAssertEqual(presentation.tint, .blue)
    XCTAssertFalse(presentation.allowsReconnectAction)
  }

  func testConnectedWithDecodedFrameDoesNotCoverLivePreview() {
    XCTAssertNil(
      LiveVideoStagePresentationResolver.resolve(
        receiverState: .connected,
        decodedFrames: 1
      ))
  }

  func testStalledExplainsAutomaticRecoveryWithoutManualAction() throws {
    let presentation = try XCTUnwrap(
      LiveVideoStagePresentationResolver.resolve(
        receiverState: .stalled,
        decodedFrames: 12
      ))

    XCTAssertEqual(presentation.title, "ภาพจาก GolfTrace Camera หยุดชั่วคราว")
    XCTAssertTrue(presentation.detail.contains("กำลังเชื่อมต่อใหม่อัตโนมัติ"))
    XCTAssertEqual(presentation.systemImage, "arrow.triangle.2.circlepath")
    XCTAssertEqual(presentation.tint, .orange)
    XCTAssertFalse(presentation.allowsReconnectAction)
  }

  func testFailureIncludesReasonAndOffersOneExplicitReconnect() throws {
    let presentation = try XCTUnwrap(
      LiveVideoStagePresentationResolver.resolve(
        receiverState: .failed("ช่องรับภาพถูกใช้งานอยู่"),
        decodedFrames: 0
      ))

    XCTAssertEqual(presentation.title, "เชื่อมต่อ GolfTrace Camera ไม่สำเร็จ")
    XCTAssertTrue(presentation.detail.contains("ช่องรับภาพถูกใช้งานอยู่"))
    XCTAssertTrue(presentation.detail.contains("เปิด GolfTrace Camera แล้วลองใหม่"))
    XCTAssertEqual(presentation.systemImage, "wifi.exclamationmark")
    XCTAssertEqual(presentation.tint, .red)
    XCTAssertTrue(presentation.allowsReconnectAction)
    XCTAssertEqual(presentation.actionTitle, "เชื่อมต่อใหม่")
  }

  func testStoppedOffersExplicitReconnectAndNoAutomaticClaim() throws {
    let presentation = try XCTUnwrap(
      LiveVideoStagePresentationResolver.resolve(
        receiverState: .stopped,
        decodedFrames: 0
      ))

    XCTAssertEqual(presentation.title, "กล้อง iPhone ยังไม่ได้เชื่อมต่อ")
    XCTAssertTrue(presentation.detail.contains("เปิดแอป GolfTrace Camera"))
    XCTAssertEqual(presentation.systemImage, "camera.fill")
    XCTAssertEqual(presentation.tint, .muted)
    XCTAssertTrue(presentation.allowsReconnectAction)
    XCTAssertEqual(presentation.actionTitle, "เชื่อมต่อใหม่")
  }
}

final class LiveSwingOverlayContextResolverTests: XCTestCase {
  func testKeepsCompletedOverlayOnlyForSameSourceViewAndOrientation() {
    let context = makeContext(sourceID: "iphone.high-speed", orientation: .degrees180)

    XCTAssertTrue(
      LiveSwingOverlayContextResolver.canReuseCompletedSwing(
        last: context,
        current: context,
        displayedOrientation: .degrees180
      ))
  }

  func testRejectsCompletedOverlayAfterSourceSwitch() {
    let last = makeContext(sourceID: "iphone.high-speed", orientation: .degrees180)
    let current = makeContext(sourceID: "mac.camera.fallback", orientation: .degrees180)

    XCTAssertFalse(
      LiveSwingOverlayContextResolver.canReuseCompletedSwing(
        last: last,
        current: current,
        displayedOrientation: .degrees180
      ))
  }

  func testRejectsCompletedOverlayAfterOrientationChange() {
    let last = makeContext(sourceID: "iphone.high-speed", orientation: .degrees180)
    let current = makeContext(sourceID: "iphone.high-speed", orientation: .degrees0)

    XCTAssertFalse(
      LiveSwingOverlayContextResolver.canReuseCompletedSwing(
        last: last,
        current: current,
        displayedOrientation: .degrees0
      ))
  }

  func testRejectsContextThatDoesNotMatchDisplayedOrientation() {
    let context = makeContext(sourceID: "iphone.high-speed", orientation: .degrees180)

    XCTAssertFalse(
      LiveSwingOverlayContextResolver.canReuseCompletedSwing(
        last: context,
        current: context,
        displayedOrientation: .degrees0
      ))
  }

  private func makeContext(
    sourceID: String,
    orientation: SwingStoryboardCaptureOrientation
  ) -> LiveSwingCaptureContext {
    LiveSwingCaptureContext(
      captureFPS: 120,
      poseAnalysisFPS: 30,
      cameraView: GolfCameraView.downTheLine.rawValue,
      sourceID: sourceID,
      orientation: orientation,
      encodedPixelWidth: 1_920,
      encodedPixelHeight: 1_080
    )
  }
}
