import CoreMedia
import Foundation
import ImageIO
import Vision

struct PoseJoint: Identifiable, Equatable {
  let id: String
  let location: CGPoint
  let confidence: Float
}

struct PoseFrame: Equatable {
  let joints: [VNHumanBodyPoseObservation.JointName: PoseJoint]
  let timestamp: CMTime
  /// Orientation that was applied to this exact sample buffer before Vision
  /// produced the normalized joint coordinates. Keeping it on the frame avoids
  /// pairing a pose with a newer device orientation while the iPhone is turning.
  let videoOrientation: GolfTraceVideoOrientation

  init(
    joints: [VNHumanBodyPoseObservation.JointName: PoseJoint],
    timestamp: CMTime,
    videoOrientation: GolfTraceVideoOrientation = .degrees0
  ) {
    self.joints = joints
    self.timestamp = timestamp
    self.videoOrientation = videoOrientation
  }

  var confidenceText: String {
    guard !joints.isEmpty else { return "กำลังตรวจหาร่างกาย" }
    let average = joints.values.map(\.confidence).reduce(0, +) / Float(joints.count)
    return "ความมั่นใจของท่าทาง \(Int((average * 100).rounded()))%"
  }
}

/// Performance counters for the latest-frame Vision scheduler. `inputFramesSkipped`
/// means a newer camera frame arrived while Vision was still processing; that is
/// intentional for live analysis because stale frames are less useful than the
/// newest available swing position.
struct PoseMetrics: Equatable {
  var processedFrames = 0
  var inputFramesSkipped = 0
  var analysisFPS = 0.0
  var latestInferenceMilliseconds = 0.0

  var fpsText: String {
    analysisFPS > 0 ? String(format: "วิเคราะห์ %.1f FPS", analysisFPS) : "กำลังวัดความเร็ววิเคราะห์"
  }

  var timingText: String {
    latestInferenceMilliseconds > 0
      ? String(format: "ล่าสุด %.1f มิลลิวินาที", latestInferenceMilliseconds)
      : "กำลังรอภาพเพื่อวิเคราะห์"
  }
}

final class PoseDetector: @unchecked Sendable {
  var onPose: ((PoseFrame?, UInt64) -> Void)?
  var onMetrics: ((PoseMetrics, UInt64) -> Void)?

  private let queue = DispatchQueue(label: "com.bda.golftrace.pose", qos: .userInitiated)
  /// Vision requests are reusable. This instance is touched only on `queue`,
  /// avoiding one request allocation for every analyzed camera frame.
  private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
  private let stateLock = NSLock()
  private var isProcessing = false
  private var generation: UInt64 = 0
  private var inputFramesSkipped = 0
  private var processedFrames = 0
  private var completionTimes: [TimeInterval] = []
  private var lastMetricsLoggedAt: TimeInterval = 0
  private var lastMetricsPublishedAt: TimeInterval = 0
  private var defaultVideoOrientation = GolfTraceVideoOrientation.degrees0
  private var appliesManualHalfTurn = false

  func setImageOrientation(_ orientation: CGImagePropertyOrientation) {
    stateLock.lock()
    defaultVideoOrientation = orientation.videoOrientation
    stateLock.unlock()
  }

  func setVideoHalfTurn(_ isEnabled: Bool) {
    stateLock.lock()
    appliesManualHalfTurn = isEnabled
    stateLock.unlock()
  }

  func reset() {
    stateLock.lock()
    generation &+= 1
    let resetGeneration = generation
    isProcessing = false
    inputFramesSkipped = 0
    stateLock.unlock()

    queue.async { [weak self] in
      guard let self else { return }
      guard self.isCurrentGeneration(resetGeneration) else { return }
      self.processedFrames = 0
      self.completionTimes.removeAll(keepingCapacity: true)
      self.lastMetricsLoggedAt = 0
      self.lastMetricsPublishedAt = 0
      self.publishMetrics(
        latestInferenceMilliseconds: 0,
        generation: resetGeneration,
        force: true
      )
    }
  }

  func analyze(
    _ sampleBuffer: CMSampleBuffer,
    videoOrientation: GolfTraceVideoOrientation? = nil
  ) {
    stateLock.lock()
    guard !isProcessing else {
      inputFramesSkipped += 1
      stateLock.unlock()
      return
    }
    isProcessing = true
    let requestGeneration = generation
    let resolvedVideoOrientation = (videoOrientation ?? defaultVideoOrientation)
      .addingHalfTurn(appliesManualHalfTurn)
    stateLock.unlock()

    let transfer = PoseSampleBufferTransfer(sampleBuffer)
    let timestamp = CMSampleBufferGetPresentationTimeStamp(transfer.sampleBuffer)
    queue.async { [weak self] in
      guard let self else { return }
      let startedAt = ProcessInfo.processInfo.systemUptime
      defer {
        if self.isCurrentGeneration(requestGeneration) {
          self.recordProcessed(
            inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            generation: requestGeneration
          )
          self.finishProcessing(generation: requestGeneration)
        }
      }

      let handler = VNImageRequestHandler(
        cmSampleBuffer: transfer.sampleBuffer,
        orientation: resolvedVideoOrientation.visionOrientation
      )

      do {
        try handler.perform([self.bodyPoseRequest])
        guard self.isCurrentGeneration(requestGeneration) else { return }
        guard let observation = self.bodyPoseRequest.results?.first else {
          self.publish(nil, generation: requestGeneration)
          return
        }

        let recognized = try observation.recognizedPoints(.all)
        var joints: [VNHumanBodyPoseObservation.JointName: PoseJoint] = [:]
        joints.reserveCapacity(recognized.count)
        for (name, point) in recognized where point.confidence >= 0.25 {
          joints[name] = PoseJoint(
            id: String(describing: name),
            location: point.location,
            confidence: point.confidence
          )
        }
        self.publish(
          PoseFrame(
            joints: joints,
            timestamp: timestamp,
            videoOrientation: resolvedVideoOrientation
          ),
          generation: requestGeneration
        )
      } catch {
        if self.isCurrentGeneration(requestGeneration) {
          self.publish(nil, generation: requestGeneration)
        }
      }
    }
  }

  private func finishProcessing(generation expectedGeneration: UInt64) {
    stateLock.lock()
    if generation == expectedGeneration {
      isProcessing = false
    }
    stateLock.unlock()
  }

  func isGenerationCurrent(_ expectedGeneration: UInt64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return generation == expectedGeneration
  }

  private func isCurrentGeneration(_ expectedGeneration: UInt64) -> Bool {
    isGenerationCurrent(expectedGeneration)
  }

  private func recordProcessed(inferenceMilliseconds: Double, generation: UInt64) {
    processedFrames += 1

    let now = ProcessInfo.processInfo.systemUptime
    completionTimes.append(now)
    while let oldest = completionTimes.first, now - oldest > 2 {
      completionTimes.removeFirst()
    }
    publishMetrics(
      latestInferenceMilliseconds: inferenceMilliseconds,
      generation: generation
    )
  }

  private func publishMetrics(
    latestInferenceMilliseconds: Double,
    generation: UInt64,
    force: Bool = false
  ) {
    let analysisFPS: Double
    if let first = completionTimes.first,
      let last = completionTimes.last,
      completionTimes.count > 1
    {
      let elapsed = last - first
      analysisFPS = elapsed > 0 ? Double(completionTimes.count - 1) / elapsed : 0
    } else {
      analysisFPS = 0
    }

    let now = ProcessInfo.processInfo.systemUptime
    if analysisFPS > 0,
      lastMetricsLoggedAt == 0 || now - lastMetricsLoggedAt >= 2
    {
      lastMetricsLoggedAt = now
      print(
        "[GolfTrace] วิเคราะห์ท่าทาง \(String(format: "%.1f", analysisFPS)) FPS · "
          + "ล่าสุด \(String(format: "%.1f", latestInferenceMilliseconds)) มิลลิวินาที"
      )
    }

    stateLock.lock()
    let skipped = inputFramesSkipped
    stateLock.unlock()

    guard force || lastMetricsPublishedAt == 0 || now - lastMetricsPublishedAt >= 0.1 else {
      return
    }
    lastMetricsPublishedAt = now
    onMetrics?(
      PoseMetrics(
        processedFrames: processedFrames,
        inputFramesSkipped: skipped,
        analysisFPS: analysisFPS,
        latestInferenceMilliseconds: latestInferenceMilliseconds
      ),
      generation
    )
  }

  private func publish(_ pose: PoseFrame?, generation: UInt64) {
    onPose?(pose, generation)
  }
}

extension GolfTraceVideoOrientation {
  fileprivate var visionOrientation: CGImagePropertyOrientation {
    switch self {
    case .degrees0: return .up
    case .degrees90: return .right
    case .degrees180: return .down
    case .degrees270: return .left
    }
  }
}

extension CGImagePropertyOrientation {
  fileprivate var videoOrientation: GolfTraceVideoOrientation {
    switch self {
    case .up, .upMirrored: return .degrees0
    case .right, .rightMirrored: return .degrees90
    case .down, .downMirrored: return .degrees180
    case .left, .leftMirrored: return .degrees270
    }
  }
}

/// Keeps the CoreMedia buffer retained while it crosses from the capture or
/// decoder callback into the serial Vision queue.
private final class PoseSampleBufferTransfer: @unchecked Sendable {
  let sampleBuffer: CMSampleBuffer

  init(_ sampleBuffer: CMSampleBuffer) {
    self.sampleBuffer = sampleBuffer
  }
}
