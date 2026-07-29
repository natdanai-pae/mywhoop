import Foundation

struct SwingReplayBundleExport: Sendable {
  let bundle: SwingReplayBundle
  let cameraURL: URL
  let rapsodoURL: URL?
}

/// Converts exporter-owned temporary files into one truthful persistence
/// request. The store assigns managed filenames, hashes and byte counts after
/// copying, so this builder never treats temporary paths as durable identity.
enum SwingReplayBundleBuilder {
  static func make(
    camera: CameraMasterReplayExportResult,
    rapsodo: RapsodoReplayExportResult?,
    maximumSyncUncertaintyMilliseconds: Double = 100
  ) -> SwingReplayBundleExport {
    let cameraDuration = max(0, camera.durationSeconds)
    let cameraAsset = SwingReplayAsset(
      role: .swingCamera,
      sourceKind: "direct_iphone_h264",
      durationMilliseconds: milliseconds(cameraDuration),
      encodedPixelWidth: camera.format.encodedPixelWidth,
      encodedPixelHeight: camera.format.encodedPixelHeight,
      nominalFPS: camera.format.nominalFrameRate,
      orientation: captureOrientation(rotationDegrees: camera.format.rotationDegrees),
      mediaRangeSeconds: mediaRange(duration: cameraDuration)
    )

    let rapsodoAsset: SwingReplayAsset?
    let synchronization: SwingReplaySynchronization?
    if let rapsodo {
      let rapsodoDuration = max(0, rapsodo.duration)
      let measuredFPS =
        rapsodoDuration > 0
        ? Double(rapsodo.counters.appended) / rapsodoDuration : nil
      rapsodoAsset = SwingReplayAsset(
        role: .rapsodoScreen,
        sourceKind: sourceKind(rapsodo.sourceKind),
        durationMilliseconds: milliseconds(rapsodoDuration),
        encodedPixelWidth: rapsodo.format.width,
        encodedPixelHeight: rapsodo.format.height,
        nominalFPS: measuredFPS.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
        orientation: .degrees0,
        mediaRangeSeconds: mediaRange(duration: rapsodoDuration)
      )
      synchronization = SwingReplayClockMapper.makeSynchronization(
        cameraAnchors: camera.fileClockAnchors,
        rapsodoAnchors: rapsodo.anchors,
        maximumUncertaintyMilliseconds: maximumSyncUncertaintyMilliseconds
      )
    } else {
      rapsodoAsset = nil
      synchronization = nil
    }

    return SwingReplayBundleExport(
      bundle: SwingReplayBundle(
        camera: cameraAsset,
        rapsodo: rapsodoAsset,
        synchronization: synchronization
      ),
      cameraURL: camera.url,
      rapsodoURL: rapsodo?.url
    )
  }

  private static func sourceKind(_ kind: RapsodoReplaySourceKind) -> String {
    switch kind {
    case .appleMirroring:
      return "apple_iphone_mirroring"
    case .usb:
      return "rapsodo_usb_screen"
    }
  }

  private static func milliseconds(_ duration: TimeInterval) -> Int? {
    guard duration.isFinite, duration > 0 else { return nil }
    return Int((duration * 1_000).rounded())
  }

  private static func mediaRange(duration: TimeInterval) -> ClosedRange<Double>? {
    guard duration.isFinite, duration > 0 else { return nil }
    return 0...duration
  }

  private static func captureOrientation(
    rotationDegrees: Double
  ) -> SwingStoryboardCaptureOrientation {
    guard rotationDegrees.isFinite else { return .unknown }
    let normalized = (rotationDegrees.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)
    if abs(normalized) < 0.1 { return .degrees0 }
    if abs(normalized - 90) < 0.1 { return .degrees90 }
    if abs(normalized - 180) < 0.1 { return .degrees180 }
    if abs(normalized - 270) < 0.1 { return .degrees270 }
    return .unknown
  }
}
