import XCTest

@testable import GolfTrace

final class SwingHistoryReviewLayoutTests: XCTestCase {
  func testReviewCanvasStaysCompactEnoughToKeepStoryboardInFocus() {
    XCTAssertEqual(
      SwingHistoryReviewLayout.canvasHeight(availableHeight: 552),
      520,
      accuracy: 0.001
    )
    XCTAssertEqual(
      SwingHistoryReviewLayout.canvasHeight(availableHeight: 1_200),
      720,
      accuracy: 0.001
    )
  }

  func testEightStoryboardPhasesFitAtMinimumWindowWidth() {
    let availableWidth: CGFloat = 622
    let phaseWidth = SwingHistoryReviewLayout.phaseWidth(availableWidth: availableWidth)
    let occupiedWidth = phaseWidth * 8 + SwingHistoryReviewLayout.phaseSpacing * 7 + 26

    XCTAssertLessThanOrEqual(occupiedWidth, availableWidth + 0.001)
    XCTAssertGreaterThanOrEqual(phaseWidth, 56)
  }

  func testPIPWidthIsBoundedAcrossWindowSizes() {
    XCTAssertEqual(
      SwingHistoryReviewLayout.pipWidth(availableWidth: 680),
      210,
      accuracy: 0.001
    )
    XCTAssertEqual(
      SwingHistoryReviewLayout.pipWidth(availableWidth: 1_600),
      330,
      accuracy: 0.001
    )
  }

  func testIndependentPairUsesCameraMainAndRapsodoPIP() throws {
    let bundle = makeReplayBundleURLs(includeSynchronizedRapsodo: true)
    let selection = try XCTUnwrap(
      SwingHistoryReviewLayout.mediaSelection(
        legacyReplayURL: URL(fileURLWithPath: "/tmp/legacy-stage.mov"),
        stagePaneLayout: legacyPaneLayout(),
        replayBundle: bundle,
        isRapsodoPrimary: false
      )
    )

    XCTAssertEqual(selection.main.url, bundle.cameraURL)
    XCTAssertEqual(selection.main.role, .swingCamera)
    XCTAssertNil(selection.main.normalizedCrop)
    XCTAssertEqual(selection.pip?.url, bundle.rapsodoURL)
    XCTAssertEqual(selection.pip?.role, .rapsodoScreen)
    XCTAssertNil(selection.pip?.normalizedCrop)
    XCTAssertEqual(selection.main.requestedTimeSeconds ?? -1, 0.525, accuracy: 0.000_001)
    XCTAssertEqual(selection.pip?.requestedTimeSeconds ?? -1, 0.475, accuracy: 0.000_001)
    XCTAssertEqual(selection.bundleStatus, .synchronizedPair)
    XCTAssertEqual(selection.cameraNominalFPS ?? 0, 119.88, accuracy: 0.001)
  }

  func testIndependentPairCanSwapRapsodoToMain() throws {
    let bundle = makeReplayBundleURLs(includeSynchronizedRapsodo: true)
    let selection = try XCTUnwrap(
      SwingHistoryReviewLayout.mediaSelection(
        legacyReplayURL: nil,
        stagePaneLayout: nil,
        replayBundle: bundle,
        isRapsodoPrimary: true
      )
    )

    XCTAssertEqual(selection.main.url, bundle.rapsodoURL)
    XCTAssertEqual(selection.main.role, .rapsodoScreen)
    XCTAssertEqual(selection.main.requestedTimeSeconds ?? -1, 0.475, accuracy: 0.000_001)
    XCTAssertEqual(selection.pip?.url, bundle.cameraURL)
    XCTAssertEqual(selection.pip?.role, .swingCamera)
    XCTAssertEqual(selection.pip?.requestedTimeSeconds ?? -1, 0.525, accuracy: 0.000_001)
  }

  func testIndependentPairWithoutUsableCalibrationDoesNotInventPIP() throws {
    let valid = makeReplayBundleURLs(includeSynchronizedRapsodo: true)
    var damagedBundle = valid.bundle
    damagedBundle.synchronization?.cameraClock.sampleCount = 1
    let damaged = SwingReplayBundleURLs(
      bundle: damagedBundle,
      cameraURL: valid.cameraURL,
      rapsodoURL: valid.rapsodoURL
    )

    let selection = try XCTUnwrap(
      SwingHistoryReviewLayout.mediaSelection(
        legacyReplayURL: nil,
        stagePaneLayout: nil,
        replayBundle: damaged,
        isRapsodoPrimary: true
      )
    )

    XCTAssertEqual(selection.main.url, valid.cameraURL)
    XCTAssertEqual(selection.main.role, .swingCamera)
    XCTAssertNil(selection.main.requestedTimeSeconds)
    XCTAssertNil(selection.pip)
    XCTAssertEqual(selection.bundleStatus, .cameraSaved)
  }

  func testCameraOnlyBundleWinsOverLegacyStageWithoutInventingPIP() throws {
    let bundle = makeReplayBundleURLs(includeSynchronizedRapsodo: false)
    let selection = try XCTUnwrap(
      SwingHistoryReviewLayout.mediaSelection(
        legacyReplayURL: URL(fileURLWithPath: "/tmp/legacy-stage.mov"),
        stagePaneLayout: legacyPaneLayout(),
        replayBundle: bundle,
        isRapsodoPrimary: true
      )
    )

    XCTAssertEqual(selection.main.url, bundle.cameraURL)
    XCTAssertEqual(selection.main.role, .swingCamera)
    XCTAssertNil(selection.main.normalizedCrop)
    XCTAssertNil(selection.main.requestedTimeSeconds)
    XCTAssertNil(selection.pip)
    XCTAssertEqual(selection.bundleStatus, .cameraSaved)
  }

  func testLegacyStageKeepsTruthfulPaneCropsAndSwap() throws {
    let legacyURL = URL(fileURLWithPath: "/tmp/legacy-stage.mov")
    let layout = legacyPaneLayout()
    let cameraPrimary = try XCTUnwrap(
      SwingHistoryReviewLayout.mediaSelection(
        legacyReplayURL: legacyURL,
        stagePaneLayout: layout,
        replayBundle: nil,
        isRapsodoPrimary: false
      )
    )
    let rapsodoPrimary = try XCTUnwrap(
      SwingHistoryReviewLayout.mediaSelection(
        legacyReplayURL: legacyURL,
        stagePaneLayout: layout,
        replayBundle: nil,
        isRapsodoPrimary: true
      )
    )

    XCTAssertEqual(cameraPrimary.main.normalizedCrop, layout.swingCamera)
    XCTAssertEqual(cameraPrimary.pip?.normalizedCrop, layout.rapsodo)
    XCTAssertNil(cameraPrimary.main.requestedTimeSeconds)
    XCTAssertNil(cameraPrimary.pip?.requestedTimeSeconds)
    XCTAssertEqual(rapsodoPrimary.main.normalizedCrop, layout.rapsodo)
    XCTAssertEqual(rapsodoPrimary.pip?.normalizedCrop, layout.swingCamera)
    XCTAssertNil(cameraPrimary.bundleStatus)
  }

  func testCameraFPSBadgeUsesMetadataWithoutGuessing() {
    XCTAssertEqual(SwingHistoryReviewLayout.cameraFPSBadgeText(119.88), "Camera 120 fps")
    XCTAssertEqual(SwingHistoryReviewLayout.cameraFPSBadgeText(29.5), "Camera 29.5 fps")
    XCTAssertEqual(SwingHistoryReviewLayout.cameraFPSBadgeText(nil), "Camera")
    XCTAssertEqual(SwingHistoryReviewLayout.cameraFPSBadgeText(.nan), "Camera")
  }

  private func legacyPaneLayout() -> GolfTraceStagePaneLayout {
    GolfTraceStagePaneLayout(
      rapsodo: GolfTraceNormalizedRect(x: 0, y: 0, width: 0.62, height: 1),
      swingCamera: GolfTraceNormalizedRect(x: 0.64, y: 0, width: 0.36, height: 1)
    )
  }

  private func makeReplayBundleURLs(
    includeSynchronizedRapsodo: Bool
  ) -> SwingReplayBundleURLs {
    let cameraURL = URL(fileURLWithPath: "/tmp/camera-master.mov")
    let rapsodoURL = URL(fileURLWithPath: "/tmp/rapsodo-screen.mov")
    let camera = SwingReplayAsset(
      role: .swingCamera,
      filename: cameraURL.lastPathComponent,
      sourceKind: "direct_iphone_h264",
      nominalFPS: 119.88,
      orientation: .degrees90,
      mediaRangeSeconds: 0...1
    )
    guard includeSynchronizedRapsodo else {
      return SwingReplayBundleURLs(
        bundle: SwingReplayBundle(camera: camera),
        cameraURL: cameraURL,
        rapsodoURL: nil
      )
    }

    let cameraClock = SwingReplayAssetClockCalibration(
      scaleToMonotonicClock: 1,
      monotonicClockOffsetSeconds: 100,
      uncertaintyMilliseconds: 4,
      sampleCount: 8,
      mediaRangeSeconds: 0...1
    )
    let rapsodoClock = SwingReplayAssetClockCalibration(
      scaleToMonotonicClock: 1,
      monotonicClockOffsetSeconds: 100.05,
      uncertaintyMilliseconds: 5,
      sampleCount: 8,
      mediaRangeSeconds: 0...1
    )
    let bundle = SwingReplayBundle(
      camera: camera,
      rapsodo: SwingReplayAsset(
        role: .rapsodoScreen,
        filename: rapsodoURL.lastPathComponent,
        sourceKind: "rapsodo_usb_screen",
        nominalFPS: 30,
        orientation: .degrees0,
        mediaRangeSeconds: 0...1
      ),
      synchronization: SwingReplaySynchronization(
        cameraClock: cameraClock,
        rapsodoClock: rapsodoClock,
        timelineMonotonicRangeSeconds: 100.05...101,
        uncertaintyMilliseconds: 7
      )
    )
    return SwingReplayBundleURLs(
      bundle: bundle,
      cameraURL: cameraURL,
      rapsodoURL: rapsodoURL
    )
  }
}
