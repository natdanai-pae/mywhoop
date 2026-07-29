@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CameraStoryboardArtifactExporterError: LocalizedError {
  case invalidSwingTiming
  case captureOrientationChanged
  case cannotCreateWorkspace(String)

  var errorDescription: String? {
    switch self {
    case .invalidSwingTiming:
      return "ช่วงเวลาวงสวิงสำหรับสร้าง Storyboard ไม่สมบูรณ์"
    case .captureOrientationChanged:
      return "มุมหมุนของกล้องเปลี่ยนก่อนสร้าง Storyboard"
    case .cannotCreateWorkspace(let detail):
      return "เตรียมพื้นที่ชั่วคราวสำหรับ Storyboard ไม่สำเร็จ: \(detail)"
    }
  }
}

/// ไฟล์ชั่วคราวหนึ่งภาพพร้อมหลักฐานที่ต้องบันทึกลง record เดียวกัน
struct CameraStoryboardKeyframeArtifact: Equatable, Sendable {
  let slot: SwingStoryboardPhaseSlot
  let requestedSourceTimestampMs: Int
  let extractedSourceTimestampMs: Int?
  let state: SwingStoryboardKeyframeExtractionState
  let temporaryJPEGURL: URL?
  let contentSHA256: String?
  let pixelWidth: Int?
  let pixelHeight: Int?
  let byteCount: Int?
  let limitation: String?
}

/// ผลจาก segment ที่ถูก snapshot แล้ว จึงไม่ขึ้นกับอายุแปดวินาทีของ live buffer อีกต่อไป
struct CameraStoryboardArtifactExportResult: Equatable, Sendable {
  let sourceID: String
  let captureOrientation: SwingStoryboardCaptureOrientation
  let segmentStartTimestampSeconds: TimeInterval
  let swingStartOffsetMs: Int
  let rotationDegrees: Double
  let keyframes: [CameraStoryboardKeyframeArtifact]
  let temporaryDirectoryURL: URL

  func removeTemporaryFiles(fileManager: FileManager = .default) {
    try? fileManager.removeItem(at: temporaryDirectoryURL)
  }
}

/// Source ต้อง snapshot compressed frames ก่อนคืนจากคิวของตัวเอง แล้วค่อยทำ MOV/JPEG
/// บนคิวเบื้องหลัง การแยก protocol นี้ทำให้ History ไม่ต้องรู้จัก H264ReplayBuffer
/// และช่วยให้ tests ยืนยันได้ว่า MainActor ไม่ต้องรับงาน video ใด ๆ
protocol CameraStoryboardArtifactExporting: AnyObject {
  func exportStoryboardArtifacts(
    swingStart: CMTime,
    swingEnd: CMTime,
    phaseMarkers: [SwingStoryboardPhaseMarker],
    preRoll: TimeInterval,
    captureOrientation: SwingStoryboardCaptureOrientation,
    completion: @escaping @Sendable (Result<CameraStoryboardArtifactExportResult, Error>) -> Void
  )
}

extension HighSpeedVideoReceiver: CameraStoryboardArtifactExporting {}

/// เปลี่ยน compressed camera-only segment เป็น JPEG ตาม phase ที่มีหลักฐานทุกจุด
/// โดย reuse `SwingReplayWriter` เพื่อคง transform เดียวกับ replay สำรองเดิม
enum CameraStoryboardArtifactExporter {
  private static let processingQueue = DispatchQueue(
    label: "com.bda.golftrace.storyboard-artifact-export",
    qos: .utility
  )

  static func export(
    segment: H264ReplaySegment,
    swingStart: CMTime,
    phaseMarkers: [SwingStoryboardPhaseMarker],
    rotationDegrees: Double,
    completion: @escaping @Sendable (Result<CameraStoryboardArtifactExportResult, Error>) -> Void
  ) {
    processingQueue.async {
      guard swingStart.isValid, segment.startTimestamp.isValid else {
        completion(.failure(CameraStoryboardArtifactExporterError.invalidSwingTiming))
        return
      }

      let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("GolfTrace-Storyboard-\(UUID().uuidString.lowercased())")
      do {
        try FileManager.default.createDirectory(
          at: workspace,
          withIntermediateDirectories: true
        )
      } catch {
        completion(
          .failure(
            CameraStoryboardArtifactExporterError.cannotCreateWorkspace(
              error.localizedDescription
            )
          )
        )
        return
      }

      let movieURL = workspace.appendingPathComponent("camera-segment.mov")
      SwingReplayWriter.write(
        segment,
        to: movieURL,
        rotationDegrees: rotationDegrees
      ) { writerResult in
        processingQueue.async {
          switch writerResult {
          case .failure(let error):
            try? FileManager.default.removeItem(at: workspace)
            completion(.failure(error))
          case .success(let writtenMovieURL):
            let result = makeResult(
              movieURL: writtenMovieURL,
              workspace: workspace,
              segment: segment,
              swingStart: swingStart,
              phaseMarkers: phaseMarkers,
              rotationDegrees: rotationDegrees
            )
            // JPEGs remain only until SwingRecordStore commits them. The MOV is
            // never persisted because the app already owns a separate replay.
            try? FileManager.default.removeItem(at: writtenMovieURL)
            completion(.success(result))
          }
        }
      }
    }
  }

  /// Pure clock mapping used by extraction and focused tests. The MOV timeline
  /// starts at the segment's keyframe, not at the detector's swing start.
  static func assetTimestamp(
    sourceTimestampMs: Int,
    swingStart: CMTime,
    segmentStart: CMTime
  ) -> CMTime? {
    guard swingStart.isValid, segmentStart.isValid, sourceTimestampMs >= 0 else {
      return nil
    }
    let offset = CMTimeGetSeconds(swingStart - segmentStart)
    guard offset.isFinite else { return nil }
    return CMTime(
      seconds: offset + (Double(sourceTimestampMs) / 1_000),
      preferredTimescale: 1_000_000
    )
  }

  private static func makeResult(
    movieURL: URL,
    workspace: URL,
    segment: H264ReplaySegment,
    swingStart: CMTime,
    phaseMarkers: [SwingStoryboardPhaseMarker],
    rotationDegrees: Double
  ) -> CameraStoryboardArtifactExportResult {
    let asset = AVURLAsset(url: movieURL)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let tolerance = frameTolerance(for: segment.frames)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    let segmentDuration =
      (segment.endTimestamp - segment.startTimestamp) + tolerance
    let swingOffsetSeconds = CMTimeGetSeconds(swingStart - segment.startTimestamp)
    let keyframes = phaseMarkers.map { marker in
      extract(
        marker: marker,
        generator: generator,
        segmentDuration: segmentDuration,
        swingOffsetSeconds: swingOffsetSeconds,
        swingStart: swingStart,
        segmentStart: segment.startTimestamp,
        workspace: workspace
      )
    }

    return CameraStoryboardArtifactExportResult(
      sourceID: SwingStoryboardCaptureSnapshot.primaryIPhoneSourceID,
      captureOrientation: captureOrientation(for: rotationDegrees),
      segmentStartTimestampSeconds: CMTimeGetSeconds(segment.startTimestamp),
      swingStartOffsetMs: Int((swingOffsetSeconds * 1_000).rounded()),
      rotationDegrees: rotationDegrees,
      keyframes: keyframes,
      temporaryDirectoryURL: workspace
    )
  }

  private static func captureOrientation(
    for rotationDegrees: Double
  ) -> SwingStoryboardCaptureOrientation {
    let normalized = (rotationDegrees.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)
    if abs(normalized) < 0.1 { return .degrees0 }
    if abs(normalized - 90) < 0.1 { return .degrees90 }
    if abs(normalized - 180) < 0.1 { return .degrees180 }
    if abs(normalized - 270) < 0.1 { return .degrees270 }
    return .unknown
  }

  private static func extract(
    marker: SwingStoryboardPhaseMarker,
    generator: AVAssetImageGenerator,
    segmentDuration: CMTime,
    swingOffsetSeconds: TimeInterval,
    swingStart: CMTime,
    segmentStart: CMTime,
    workspace: URL
  ) -> CameraStoryboardKeyframeArtifact {
    guard
      let requestedTime = assetTimestamp(
        sourceTimestampMs: marker.sourceTimestampMs,
        swingStart: swingStart,
        segmentStart: segmentStart
      )
    else {
      return failedArtifact(
        marker: marker,
        state: .failed,
        limitation: "คำนวณเวลาระหว่างวงสวิงกับ camera segment ไม่สำเร็จ"
      )
    }

    guard CMTimeCompare(requestedTime, .zero) >= 0,
      CMTimeCompare(requestedTime, segmentDuration) < 0
    else {
      return failedArtifact(
        marker: marker,
        state: .unavailable,
        limitation: "เฟรม phase อยู่นอกช่วง camera buffer ที่ snapshot ได้"
      )
    }

    var actualTime = CMTime.invalid
    do {
      let image = try generator.copyCGImage(at: requestedTime, actualTime: &actualTime)
      let filename = "phase-\(marker.slot.rawValue)-\(UUID().uuidString.lowercased()).jpg"
      let jpegURL = workspace.appendingPathComponent(filename)
      try writeJPEG(image, to: jpegURL)
      let data = try Data(contentsOf: jpegURL, options: [.mappedIfSafe])
      let actualAssetSeconds = CMTimeGetSeconds(actualTime)
      let extractedSourceTimestampMs: Int? =
        actualAssetSeconds.isFinite && swingOffsetSeconds.isFinite
        ? max(0, Int(((actualAssetSeconds - swingOffsetSeconds) * 1_000).rounded()))
        : nil

      return CameraStoryboardKeyframeArtifact(
        slot: marker.slot,
        requestedSourceTimestampMs: marker.sourceTimestampMs,
        extractedSourceTimestampMs: extractedSourceTimestampMs,
        state: .available,
        temporaryJPEGURL: jpegURL,
        contentSHA256: sha256Hex(data),
        pixelWidth: image.width,
        pixelHeight: image.height,
        byteCount: data.count,
        limitation: marker.limitation
      )
    } catch {
      return failedArtifact(
        marker: marker,
        state: .failed,
        limitation: "แยกภาพ phase ไม่สำเร็จ: \(error.localizedDescription)"
      )
    }
  }

  private static func failedArtifact(
    marker: SwingStoryboardPhaseMarker,
    state: SwingStoryboardKeyframeExtractionState,
    limitation: String
  ) -> CameraStoryboardKeyframeArtifact {
    CameraStoryboardKeyframeArtifact(
      slot: marker.slot,
      requestedSourceTimestampMs: marker.sourceTimestampMs,
      extractedSourceTimestampMs: nil,
      state: state,
      temporaryJPEGURL: nil,
      contentSHA256: nil,
      pixelWidth: nil,
      pixelHeight: nil,
      byteCount: nil,
      limitation: limitation
    )
  }

  private static func writeJPEG(_ image: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    let properties =
      [
        kCGImageDestinationLossyCompressionQuality: 0.88
      ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func frameTolerance(for frames: [H264ReplayFrame]) -> CMTime {
    let positiveIntervals = zip(frames, frames.dropFirst()).compactMap {
      first, second -> Double? in
      let seconds = CMTimeGetSeconds(second.timestamp - first.timestamp)
      return seconds.isFinite && seconds > 0 ? seconds : nil
    }.sorted()
    guard !positiveIntervals.isEmpty else {
      return CMTime(value: 1, timescale: 60)
    }
    return CMTime(
      seconds: positiveIntervals[positiveIntervals.count / 2],
      preferredTimescale: 1_000_000
    )
  }
}
