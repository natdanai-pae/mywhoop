@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreImage
import SwiftUI

enum GolfTraceReplayPIPComposition {
  private static let pipWidthFraction: CGFloat = 0.30
  private static let pipMaximumHeightFraction: CGFloat = 0.34
  private static let pipTrailingFraction: CGFloat = 0.035
  private static let pipBottomFraction: CGFloat = 0.25

  static func sourceRect(
    for normalizedRect: GolfTraceNormalizedRect,
    in imageExtent: CGRect
  ) -> CGRect {
    CGRect(
      x: imageExtent.minX + CGFloat(normalizedRect.x) * imageExtent.width,
      y: imageExtent.minY
        + (1 - CGFloat(normalizedRect.y + normalizedRect.height)) * imageExtent.height,
      width: CGFloat(normalizedRect.width) * imageExtent.width,
      height: CGFloat(normalizedRect.height) * imageExtent.height
    )
  }

  static func pipFrame(for sourceRect: CGRect, in outputExtent: CGRect) -> CGRect {
    guard sourceRect.width > 0, sourceRect.height > 0 else { return .zero }
    let maximumSize = CGSize(
      width: outputExtent.width * pipWidthFraction,
      height: outputExtent.height * pipMaximumHeightFraction
    )
    let scale = min(
      maximumSize.width / sourceRect.width,
      maximumSize.height / sourceRect.height
    )
    let size = CGSize(
      width: sourceRect.width * scale,
      height: sourceRect.height * scale
    )
    return CGRect(
      x: outputExtent.maxX - outputExtent.width * pipTrailingFraction - size.width,
      y: outputExtent.minY + outputExtent.height * pipBottomFraction,
      width: size.width,
      height: size.height
    ).integral
  }

  static func compose(
    sourceImage: CIImage,
    paneLayout: GolfTraceStagePaneLayout,
    isRapsodoPrimary: Bool
  ) -> CIImage {
    let outputExtent = sourceImage.extent.integral
    guard outputExtent.width > 1, outputExtent.height > 1 else { return sourceImage }

    let mainNormalizedRect =
      isRapsodoPrimary ? paneLayout.rapsodo : paneLayout.swingCamera
    let pipNormalizedRect =
      isRapsodoPrimary ? paneLayout.swingCamera : paneLayout.rapsodo
    let mainSourceRect = sourceRect(for: mainNormalizedRect, in: outputExtent)
      .intersection(outputExtent)
    let pipSourceRect = sourceRect(for: pipNormalizedRect, in: outputExtent)
      .intersection(outputExtent)
    guard mainSourceRect.width > 1, mainSourceRect.height > 1,
      pipSourceRect.width > 1, pipSourceRect.height > 1
    else { return sourceImage }

    let background = CIImage(color: CIColor.black).cropped(to: outputExtent)
    let mainImage = fittedImage(
      sourceImage,
      sourceRect: mainSourceRect,
      destinationRect: outputExtent
    )
    let pipFrame = pipFrame(for: pipSourceRect, in: outputExtent)
    let borderWidth = max(3, min(8, outputExtent.height * 0.004))
    let borderFrame = pipFrame.insetBy(dx: -borderWidth, dy: -borderWidth)
    let border = CIImage(
      color: CIColor(red: 0.18, green: 0.48, blue: 1, alpha: 0.96)
    ).cropped(to: borderFrame)
    let pipImage = fittedImage(
      sourceImage,
      sourceRect: pipSourceRect,
      destinationRect: pipFrame
    )

    return pipImage.composited(
      over: border.composited(over: mainImage.composited(over: background))
    )
    .cropped(to: outputExtent)
  }

  private static func fittedImage(
    _ sourceImage: CIImage,
    sourceRect: CGRect,
    destinationRect: CGRect
  ) -> CIImage {
    let scale = min(
      destinationRect.width / sourceRect.width,
      destinationRect.height / sourceRect.height
    )
    let fittedSize = CGSize(
      width: sourceRect.width * scale,
      height: sourceRect.height * scale
    )
    let destinationOrigin = CGPoint(
      x: destinationRect.midX - fittedSize.width / 2,
      y: destinationRect.midY - fittedSize.height / 2
    )

    return
      sourceImage
      .cropped(to: sourceRect)
      .transformed(
        by: CGAffineTransform(
          translationX: -sourceRect.minX,
          y: -sourceRect.minY
        )
      )
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      .transformed(
        by: CGAffineTransform(
          translationX: destinationOrigin.x,
          y: destinationOrigin.y
        )
      )
      .cropped(to: destinationRect)
  }

  static func makeVideoComposition(
    asset: AVAsset,
    paneLayout: GolfTraceStagePaneLayout,
    isRapsodoPrimary: Bool
  ) async throws -> AVVideoComposition {
    try await withCheckedThrowingContinuation { continuation in
      AVVideoComposition.videoComposition(
        with: asset,
        applyingCIFiltersWithHandler: { request in
          let image = compose(
            sourceImage: request.sourceImage,
            paneLayout: paneLayout,
            isRapsodoPrimary: isRapsodoPrimary
          )
          request.finish(with: image, context: nil)
        },
        completionHandler: { composition, error in
          if let composition {
            continuation.resume(returning: composition)
          } else {
            continuation.resume(
              throwing: error
                ?? CocoaError(
                  .coderInvalidValue,
                  userInfo: [
                    NSLocalizedDescriptionKey:
                      "สร้างภาพ Replay แบบ Picture in Picture ไม่สำเร็จ"
                  ]
                )
            )
          }
        }
      )
    }
  }
}

/// พื้นที่เล่นวิดีโอที่ใช้ `AVPlayerLayer` โดยตรง
///
/// หลีกเลี่ยง SwiftUI `VideoPlayer` ซึ่งเรียก private `_AVKit_SwiftUI.VideoPlayerView`
/// และทำให้ macOS 26.5.2 abort ตอน resolve superclass ของ `AVPlayerView`.
@MainActor
final class SwingReplayPlayerSurface: NSView {
  private let playerLayer = AVPlayerLayer()

  init(player: AVPlayer?) {
    super.init(frame: .zero)
    wantsLayer = true
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = NSColor.black.cgColor
    playerLayer.player = player
    layer = playerLayer
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  var player: AVPlayer? {
    get { playerLayer.player }
    set { playerLayer.player = newValue }
  }
}

struct SwingReplayPlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> SwingReplayPlayerSurface {
    SwingReplayPlayerSurface(player: player)
  }

  func updateNSView(_ nsView: SwingReplayPlayerSurface, context: Context) {
    if nsView.player !== player {
      nsView.player = player
    }
  }

  static func dismantleNSView(_ nsView: SwingReplayPlayerSurface, coordinator: ()) {
    nsView.player = nil
  }
}

/// Replay surface only. Playback state and every transport control live in the
/// shared dashboard timeline so the app never presents a second player UI.
struct SwingReplayView: View {
  let playback: SwingReplayPlaybackController

  var body: some View {
    SwingReplayPlayerView(player: playback.player)
      .background(.black)
      .accessibilityLabel("ภาพย้อนหลังทั้งหน้าจอ GolfTrace")
  }
}

@MainActor
final class SwingReplayPlaybackController: ObservableObject {
  private static let timelinePublishTolerance: TimeInterval = 0.005
  private static let durationPublishTolerance: TimeInterval = 0.001

  let player = AVPlayer()

  @Published private(set) var currentTime: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var isPlaying = false
  @Published private(set) var selectedRate: Float = 0.5
  @Published private(set) var playbackErrorText: String?
  @Published private(set) var videoAspectRatio: CGFloat?
  @Published private(set) var recordedCanvasSize: CGSize?
  @Published private(set) var stagePaneLayout: GolfTraceStagePaneLayout?
  @Published private(set) var isRapsodoPrimary = false
  @Published private(set) var isPIPCompositionReady = false

  private var loadedURL: URL?
  private var loadedStagePaneLayout: GolfTraceStagePaneLayout?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failureObserver: NSObjectProtocol?
  private var statusObserver: NSKeyValueObservation?
  private var durationTask: Task<Void, Never>?
  private var scrubSeekTask: Task<Void, Never>?
  private var pendingScrubTarget: TimeInterval?
  private var isScrubbing = false
  private var resumeAfterScrubbing = false
  private var playbackEndedHandler: (() -> Void)?
  private var playbackFailedHandler: (() -> Void)?
  private var playbackGeneration: UInt = 0
  private var cameraPrimaryComposition: AVVideoComposition?
  private var rapsodoPrimaryComposition: AVVideoComposition?
  private var pendingPlayAfterPIPPreparation = false

  var hasPlayableItem: Bool {
    guard let item = player.currentItem else { return false }
    return item.status != .failed
  }

  var hasReachedEnd: Bool {
    duration > 0 && currentTime >= duration - 0.001
  }

  func load(
    _ url: URL?,
    stagePaneLayout: GolfTraceStagePaneLayout? = nil,
    autoPlay: Bool,
    rate: Float,
    onPlaybackEnded: @escaping () -> Void,
    onPlaybackFailed: @escaping () -> Void
  ) {
    if url == loadedURL, stagePaneLayout == loadedStagePaneLayout {
      playbackEndedHandler = onPlaybackEnded
      playbackFailedHandler = onPlaybackFailed
      if autoPlay, !isPlaying, currentTime <= 0.001 {
        if stagePaneLayout != nil, !isPIPCompositionReady {
          pendingPlayAfterPIPPreparation = true
        } else {
          startPlayback()
        }
      }
      return
    }

    unload()
    guard let url else { return }

    loadedURL = url
    loadedStagePaneLayout = stagePaneLayout
    let nextRate: Float = [0.25, 0.5, 1].contains(rate) ? rate : 0.5
    if selectedRate != nextRate {
      selectedRate = nextRate
    }
    playbackEndedHandler = onPlaybackEnded
    playbackFailedHandler = onPlaybackFailed
    playbackErrorText = nil
    videoAspectRatio = nil
    recordedCanvasSize = nil
    self.stagePaneLayout = nil
    isRapsodoPrimary = false
    isPIPCompositionReady = false
    cameraPrimaryComposition = nil
    rapsodoPrimaryComposition = nil
    pendingPlayAfterPIPPreparation = autoPlay && stagePaneLayout != nil
    let item = AVPlayerItem(url: url)
    player.replaceCurrentItem(with: item)
    installObservers(for: item)
    loadMetadata(of: item, stagePaneLayout: stagePaneLayout)
    if autoPlay, stagePaneLayout == nil {
      startPlayback()
    }
  }

  func unload() {
    playbackGeneration &+= 1
    durationTask?.cancel()
    durationTask = nil
    scrubSeekTask?.cancel()
    scrubSeekTask = nil
    pendingScrubTarget = nil
    isScrubbing = false
    player.pause()
    removeObservers()
    player.replaceCurrentItem(with: nil)
    loadedURL = nil
    loadedStagePaneLayout = nil
    if currentTime != 0 {
      currentTime = 0
    }
    if duration != 0 {
      duration = 0
    }
    setIsPlaying(false)
    resumeAfterScrubbing = false
    playbackEndedHandler = nil
    playbackFailedHandler = nil
    playbackErrorText = nil
    videoAspectRatio = nil
    recordedCanvasSize = nil
    stagePaneLayout = nil
    isRapsodoPrimary = false
    isPIPCompositionReady = false
    cameraPrimaryComposition = nil
    rapsodoPrimaryComposition = nil
    pendingPlayAfterPIPPreparation = false
  }

  func togglePIPPrimary() {
    guard let item = player.currentItem, stagePaneLayout != nil,
      let cameraPrimaryComposition, let rapsodoPrimaryComposition
    else { return }

    isRapsodoPrimary.toggle()
    item.videoComposition =
      isRapsodoPrimary ? rapsodoPrimaryComposition : cameraPrimaryComposition
    // Re-render the paused frame immediately; while playing the next decoded
    // frame naturally picks up the selected composition.
    if player.rate == 0 {
      performSeek(to: currentTime, exact: true)
    }
  }

  func togglePlayback() {
    guard player.currentItem != nil else { return }

    if player.rate != 0 || isPlaying {
      player.pause()
      setIsPlaying(false)
      pendingPlayAfterPIPPreparation = false
      return
    }

    if stagePaneLayout != nil, !isPIPCompositionReady {
      pendingPlayAfterPIPPreparation = true
      return
    }

    if duration > 0, currentTime >= duration - 0.001 {
      seek(to: 0)
    }
    startPlayback()
  }

  func pause() {
    player.pause()
    setIsPlaying(false)
    resumeAfterScrubbing = false
    pendingPlayAfterPIPPreparation = false
  }

  func play() {
    guard player.currentItem != nil else { return }
    if stagePaneLayout != nil, !isPIPCompositionReady {
      pendingPlayAfterPIPPreparation = true
      return
    }
    if duration > 0, currentTime >= duration - 0.001 {
      seek(to: 0)
    }
    startPlayback()
  }

  func setPlaybackRate(_ rate: Float) {
    guard [Float(0.25), Float(0.5), Float(1)].contains(rate) else { return }
    if selectedRate != rate {
      selectedRate = rate
    }
    if player.rate != 0 || isPlaying {
      player.playImmediately(atRate: rate)
      setIsPlaying(true)
    }
  }

  func seek(to seconds: TimeInterval) {
    guard player.currentItem != nil else { return }
    let upperBound = duration > 0 ? duration : max(0, seconds)
    let target = min(max(0, seconds), upperBound)
    setCurrentTime(target, tolerance: 0)
    if isScrubbing {
      pendingScrubTarget = target
      scheduleScrubSeekIfNeeded()
    } else {
      performSeek(to: target, exact: true)
    }
  }

  func setScrubbing(_ nextValue: Bool) {
    if nextValue {
      guard !isScrubbing else { return }
      isScrubbing = true
      resumeAfterScrubbing = player.rate != 0 || isPlaying
      player.pause()
      setIsPlaying(false)
      return
    }

    guard isScrubbing else { return }
    isScrubbing = false
    scrubSeekTask?.cancel()
    scrubSeekTask = nil
    let finalTarget = pendingScrubTarget ?? currentTime
    pendingScrubTarget = nil
    performSeek(to: finalTarget, exact: true)
    if resumeAfterScrubbing {
      resumeAfterScrubbing = false
      player.playImmediately(atRate: selectedRate)
      setIsPlaying(true)
    }
  }

  func step(by frameCount: Int) {
    guard frameCount != 0, let item = player.currentItem else { return }
    let generation = playbackGeneration
    let itemID = ObjectIdentifier(item)
    player.pause()
    setIsPlaying(false)
    resumeAfterScrubbing = false
    item.step(byCount: frameCount)

    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(20))
      guard let self,
        self.playbackGeneration == generation,
        self.player.currentItem.map(ObjectIdentifier.init) == itemID
      else { return }
      self.updateCurrentTime()
    }
  }

  private func installObservers(for item: AVPlayerItem) {
    let generation = playbackGeneration
    let itemID = ObjectIdentifier(item)
    timeObserver = player.addPeriodicTimeObserver(
      // 15 Hz keeps the compact timeline visually fluid while avoiding a
      // whole-dashboard SwiftUI invalidation for every decoded replay frame.
      forInterval: CMTime(value: 1, timescale: 15),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self,
          self.playbackGeneration == generation,
          self.player.currentItem.map(ObjectIdentifier.init) == itemID
        else { return }
        self.updatePlaybackState(at: time)
      }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self,
          self.playbackGeneration == generation,
          self.player.currentItem.map(ObjectIdentifier.init) == itemID
        else { return }
        self.playbackDidFinish()
      }
    }

    failureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      let detail = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
        .localizedDescription
      Task { @MainActor [weak self] in
        guard let self,
          self.playbackGeneration == generation,
          self.player.currentItem.map(ObjectIdentifier.init) == itemID
        else { return }
        self.playbackDidFail(detail: detail)
      }
    }

    statusObserver = item.observe(\.status, options: [.initial, .new]) {
      [weak self] observedItem, _ in
      let didFail = observedItem.status == .failed
      let detail = observedItem.error?.localizedDescription
      guard didFail else { return }
      Task { @MainActor [weak self] in
        guard let self,
          self.playbackGeneration == generation,
          self.player.currentItem.map(ObjectIdentifier.init) == itemID
        else { return }
        self.playbackDidFail(detail: detail)
      }
    }
  }

  private func removeObservers() {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    if let failureObserver {
      NotificationCenter.default.removeObserver(failureObserver)
      self.failureObserver = nil
    }
    statusObserver?.invalidate()
    statusObserver = nil
  }

  private func loadMetadata(
    of item: AVPlayerItem,
    stagePaneLayout: GolfTraceStagePaneLayout?
  ) {
    let generation = playbackGeneration
    let itemID = ObjectIdentifier(item)
    durationTask = Task { @MainActor [weak self] in
      let asset = item.asset
      let loadedDuration = try? await asset.load(.duration)

      var loadedAspectRatio: CGFloat?
      if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
        let videoTrack = videoTracks.first
      {
        do {
          let naturalSize = try await videoTrack.load(.naturalSize)
          let preferredTransform = try await videoTrack.load(.preferredTransform)
          let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
          let width = abs(transformedBounds.width)
          let height = abs(transformedBounds.height)
          if width.isFinite, height.isFinite, width > 0, height > 0 {
            loadedAspectRatio = width / height
          }
        } catch {
          // A valid duration is still useful if the track metadata is absent.
        }
      }

      var loadedDescriptor: GolfTraceStageMovieDescriptor?
      if let metadata = try? await asset.load(.metadata) {
        for item in metadata where item.identifier == .quickTimeMetadataDescription {
          guard let description = try? await item.load(.stringValue),
            let descriptor = GolfTraceStageMovieMetadata.descriptor(from: description)
          else {
            continue
          }
          loadedDescriptor = descriptor
          break
        }
      }

      guard !Task.isCancelled,
        let self,
        self.playbackGeneration == generation,
        self.player.currentItem.map(ObjectIdentifier.init) == itemID
      else { return }
      if let loadedDuration {
        self.setDuration(loadedDuration)
      }
      self.videoAspectRatio = loadedAspectRatio
      self.recordedCanvasSize = loadedDescriptor?.canvasSize
      self.stagePaneLayout = stagePaneLayout

      guard let paneLayout = stagePaneLayout else { return }
      do {
        async let cameraPrimary = GolfTraceReplayPIPComposition.makeVideoComposition(
          asset: asset,
          paneLayout: paneLayout,
          isRapsodoPrimary: false
        )
        async let rapsodoPrimary = GolfTraceReplayPIPComposition.makeVideoComposition(
          asset: asset,
          paneLayout: paneLayout,
          isRapsodoPrimary: true
        )
        let (cameraComposition, rapsodoComposition) = try await (
          cameraPrimary,
          rapsodoPrimary
        )
        guard !Task.isCancelled,
          self.playbackGeneration == generation,
          self.player.currentItem.map(ObjectIdentifier.init) == itemID
        else { return }
        self.cameraPrimaryComposition = cameraComposition
        self.rapsodoPrimaryComposition = rapsodoComposition
        item.videoComposition = cameraComposition
        self.isPIPCompositionReady = true
        if self.pendingPlayAfterPIPPreparation {
          self.pendingPlayAfterPIPPreparation = false
          self.startPlayback()
        } else {
          self.performSeek(to: self.currentTime, exact: true)
        }
      } catch {
        // The stored movie itself remains playable. Fail open to the original
        // whole-window replay instead of turning a composition error into a
        // lost take.
        guard !Task.isCancelled,
          self.playbackGeneration == generation,
          self.player.currentItem.map(ObjectIdentifier.init) == itemID
        else { return }
        self.isPIPCompositionReady = false
        if self.pendingPlayAfterPIPPreparation {
          self.pendingPlayAfterPIPPreparation = false
          self.startPlayback()
        }
      }
    }
  }

  private func updatePlaybackState(at time: CMTime) {
    let seconds = CMTimeGetSeconds(time)
    if seconds.isFinite {
      setCurrentTime(seconds)
    }
    if let item = player.currentItem {
      setDuration(item.duration)
    }
    setIsPlaying(player.rate != 0 && player.timeControlStatus != .paused)
  }

  private func updateCurrentTime() {
    updatePlaybackState(at: player.currentTime())
  }

  private func setDuration(_ time: CMTime) {
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds > 0,
      abs(duration - seconds) > Self.durationPublishTolerance
    else { return }
    duration = seconds
  }

  private func setCurrentTime(
    _ seconds: TimeInterval,
    tolerance: TimeInterval = SwingReplayPlaybackController.timelinePublishTolerance
  ) {
    let nextTime = max(0, seconds)
    guard abs(currentTime - nextTime) > tolerance else { return }
    currentTime = nextTime
  }

  private func setIsPlaying(_ nextValue: Bool) {
    guard isPlaying != nextValue else { return }
    isPlaying = nextValue
  }

  private func scheduleScrubSeekIfNeeded() {
    guard scrubSeekTask == nil else { return }
    scrubSeekTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(40))
      guard !Task.isCancelled, let self else { return }
      self.scrubSeekTask = nil
      guard self.isScrubbing, let target = self.pendingScrubTarget else { return }
      self.pendingScrubTarget = nil
      self.performSeek(to: target, exact: false)
      if self.pendingScrubTarget != nil {
        self.scheduleScrubSeekIfNeeded()
      }
    }
  }

  private func performSeek(to seconds: TimeInterval, exact: Bool) {
    let target = CMTime(seconds: seconds, preferredTimescale: 60_000)
    let tolerance = exact ? CMTime.zero : CMTime(value: 1, timescale: 30)
    player.seek(
      to: target,
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    )
  }

  private func playbackDidFinish() {
    player.pause()
    setIsPlaying(false)
    if duration > 0 {
      setCurrentTime(duration, tolerance: 0)
    }
    playbackEndedHandler?()
  }

  private func playbackDidFail(detail: String?) {
    player.pause()
    setIsPlaying(false)
    playbackErrorText = detail ?? "เปิดไฟล์ภาพย้อนหลังไม่สำเร็จ"
    playbackFailedHandler?()
  }

  private func startPlayback() {
    guard player.currentItem != nil else { return }
    player.playImmediately(atRate: selectedRate)
    setIsPlaying(true)
  }
}
