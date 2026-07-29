@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum SwingReplayWriterError: LocalizedError {
  case missingFrames
  case invalidConfiguration(OSStatus)
  case cannotCreateWriterInput
  case cannotStartWriting(String)
  case cannotCreateSample(OSStatus)
  case appendFailed(String)
  case writerTimedOut
  case finishFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingFrames:
      return "ข้อมูลภาพย้อนหลังไม่ครบ"
    case .invalidConfiguration(let status):
      return "อ่านรูปแบบวิดีโอ H.264 ไม่สำเร็จ (รหัส \(status))"
    case .cannotCreateWriterInput:
      return "เตรียมช่องบันทึกวิดีโอไม่สำเร็จ"
    case .cannotStartWriting(let message):
      return "เริ่มสร้างคลิปย้อนหลังไม่สำเร็จ: \(message)"
    case .cannotCreateSample(let status):
      return "เตรียมภาพสำหรับคลิปย้อนหลังไม่สำเร็จ (รหัส \(status))"
    case .appendFailed(let message):
      return "เขียนภาพย้อนหลังไม่สำเร็จ: \(message)"
    case .writerTimedOut:
      return "สร้างคลิปย้อนหลังใช้เวลานานเกินไป"
    case .finishFailed(let message):
      return "ปิดไฟล์ภาพย้อนหลังไม่สำเร็จ: \(message)"
    }
  }
}

/// Metadata that preserves how the rebased MOV timeline relates to the
/// original iPhone presentation clock. The file always begins at zero, while
/// `sourcePTSOrigin` identifies which source instant became file time zero.
struct SwingReplayWriteResult: Equatable, @unchecked Sendable {
  let url: URL
  let sourcePTSOrigin: CMTime
  let sourcePTSEnd: CMTime
  let durationSeconds: TimeInterval
}

/// Writes the selected compressed frames directly into a local MOV container.
/// H.264 is not encoded again, so creating the replay is fast and keeps image quality.
enum SwingReplayWriter {
  /// AVAssetWriter invokes its completion handler on an internal queue but is not
  /// annotated as Sendable. Keep that single, documented boundary in this box so
  /// the callback itself only captures a Sendable value.
  private final class FinishContext: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let outputURL: URL
    private let result: SwingReplayWriteResult
    private let completion: @Sendable (Result<SwingReplayWriteResult, Error>) -> Void
    private var hasCompleted = false

    init(
      writer: AVAssetWriter,
      outputURL: URL,
      result: SwingReplayWriteResult,
      completion: @escaping @Sendable (Result<SwingReplayWriteResult, Error>) -> Void
    ) {
      self.writer = writer
      self.outputURL = outputURL
      self.result = result
      self.completion = completion
    }

    func completeFromWriter() {
      guard claimCompletion() else { return }
      if writer.status == .completed {
        completion(.success(result))
      } else {
        try? FileManager.default.removeItem(at: outputURL)
        completion(
          .failure(
            SwingReplayWriterError.finishFailed(
              writer.error?.localizedDescription ?? "ไม่ทราบสาเหตุ"
            )
          )
        )
      }
    }

    func timeOut() {
      guard claimCompletion() else { return }
      if writer.status == .unknown || writer.status == .writing {
        writer.cancelWriting()
      }
      try? FileManager.default.removeItem(at: outputURL)
      completion(.failure(SwingReplayWriterError.writerTimedOut))
    }

    private func claimCompletion() -> Bool {
      lock.withLock {
        guard !hasCompleted else { return false }
        hasCompleted = true
        return true
      }
    }
  }

  static func write(
    _ segment: H264ReplaySegment,
    to outputURL: URL,
    rotationDegrees: Double = 0,
    completion: @escaping @Sendable (Result<URL, Error>) -> Void
  ) {
    writeWithMetadata(
      segment,
      to: outputURL,
      rotationDegrees: rotationDegrees
    ) { result in
      completion(result.map(\.url))
    }
  }

  /// Writes the same zero-based MOV as `write`, and also returns the source
  /// clock interval that was rebased into the file. Callers can use this to
  /// translate live-analysis anchors without inspecting the finished asset.
  static func writeWithMetadata(
    _ segment: H264ReplaySegment,
    to outputURL: URL,
    rotationDegrees: Double = 0,
    completion: @escaping @Sendable (Result<SwingReplayWriteResult, Error>) -> Void
  ) {
    do {
      guard segment.frames.count >= 2 else {
        throw SwingReplayWriterError.missingFrames
      }

      try? FileManager.default.removeItem(at: outputURL)
      let formatDescription = try makeFormatDescription(from: segment.configuration)
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: formatDescription
      )
      input.expectsMediaDataInRealTime = false
      input.transform = displayTransform(
        for: formatDescription,
        rotationDegrees: rotationDegrees
      )
      guard writer.canAdd(input) else {
        throw SwingReplayWriterError.cannotCreateWriterInput
      }
      writer.add(input)

      guard writer.startWriting() else {
        throw SwingReplayWriterError.cannotStartWriting(
          writer.error?.localizedDescription ?? "ไม่ทราบสาเหตุ"
        )
      }
      writer.startSession(atSourceTime: .zero)

      let nominalDuration = nominalFrameDuration(for: segment.frames)
      let firstTimestamp = segment.frames[0].timestamp
      let sourcePTSEnd = segment.frames[segment.frames.count - 1].timestamp + nominalDuration
      let durationSeconds = max(0, CMTimeGetSeconds(sourcePTSEnd - firstTimestamp))
      let writeResult = SwingReplayWriteResult(
        url: outputURL,
        sourcePTSOrigin: firstTimestamp,
        sourcePTSEnd: sourcePTSEnd,
        durationSeconds: durationSeconds
      )
      let deadline = Date().addingTimeInterval(12)

      for index in segment.frames.indices {
        while !input.isReadyForMoreMediaData, writer.status == .writing {
          guard Date() < deadline else {
            writer.cancelWriting()
            throw SwingReplayWriterError.writerTimedOut
          }
          Thread.sleep(forTimeInterval: 0.001)
        }

        let frame = segment.frames[index]
        let duration: CMTime
        if index + 1 < segment.frames.count {
          let measured = segment.frames[index + 1].timestamp - frame.timestamp
          duration = CMTimeCompare(measured, .zero) > 0 ? measured : nominalDuration
        } else {
          duration = nominalDuration
        }

        let sample = try makeSampleBuffer(
          frame: frame,
          relativeTimestamp: frame.timestamp - firstTimestamp,
          duration: duration,
          formatDescription: formatDescription
        )
        guard input.append(sample) else {
          throw SwingReplayWriterError.appendFailed(
            writer.error?.localizedDescription ?? "ระบบไม่รับภาพ"
          )
        }
      }

      input.markAsFinished()
      let finishContext = FinishContext(
        writer: writer,
        outputURL: outputURL,
        result: writeResult,
        completion: completion
      )
      writer.finishWriting {
        finishContext.completeFromWriter()
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
        finishContext.timeOut()
      }
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      completion(.failure(error))
    }
  }

  private static func makeFormatDescription(
    from configuration: GolfTraceH264Configuration
  ) throws -> CMVideoFormatDescription {
    var formatDescription: CMFormatDescription?
    let status = configuration.sequenceParameterSet.withUnsafeBytes { spsBuffer in
      configuration.pictureParameterSet.withUnsafeBytes { ppsBuffer in
        guard let sps = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
          let pps = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else {
          return OSStatus(paramErr)
        }
        var parameterSets = [sps, pps]
        var sizes = [
          configuration.sequenceParameterSet.count,
          configuration.pictureParameterSet.count,
        ]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault,
          parameterSetCount: parameterSets.count,
          parameterSetPointers: &parameterSets,
          parameterSetSizes: &sizes,
          nalUnitHeaderLength: 4,
          formatDescriptionOut: &formatDescription
        )
      }
    }
    guard status == noErr, let formatDescription else {
      throw SwingReplayWriterError.invalidConfiguration(status)
    }
    return formatDescription
  }

  private static func displayTransform(
    for formatDescription: CMVideoFormatDescription,
    rotationDegrees: Double
  ) -> CGAffineTransform {
    let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(
      formatDescription,
      usePixelAspectRatio: true,
      useCleanAperture: true
    )
    let normalized = (rotationDegrees.truncatingRemainder(dividingBy: 360) + 360)
      .truncatingRemainder(dividingBy: 360)

    if abs(normalized - 90) < 0.1 {
      return CGAffineTransform(
        a: 0, b: 1,
        c: -1, d: 0,
        tx: dimensions.height, ty: 0
      )
    }
    if abs(normalized - 180) < 0.1 {
      return CGAffineTransform(
        a: -1, b: 0,
        c: 0, d: -1,
        tx: dimensions.width, ty: dimensions.height
      )
    }
    if abs(normalized - 270) < 0.1 {
      return CGAffineTransform(
        a: 0, b: -1,
        c: 1, d: 0,
        tx: 0, ty: dimensions.width
      )
    }
    return .identity
  }

  private static func makeSampleBuffer(
    frame: H264ReplayFrame,
    relativeTimestamp: CMTime,
    duration: CMTime,
    formatDescription: CMVideoFormatDescription
  ) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    let createStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: frame.payload.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: frame.payload.count,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard createStatus == noErr, let blockBuffer else {
      throw SwingReplayWriterError.cannotCreateSample(createStatus)
    }

    let copyStatus = frame.payload.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return OSStatus(paramErr) }
      return CMBlockBufferReplaceDataBytes(
        with: baseAddress,
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: frame.payload.count
      )
    }
    guard copyStatus == noErr else {
      throw SwingReplayWriterError.cannotCreateSample(copyStatus)
    }

    var timing = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: relativeTimestamp,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = frame.payload.count
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw SwingReplayWriterError.cannotCreateSample(sampleStatus)
    }

    if !frame.isKeyFrame,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: true
      ), CFArrayGetCount(attachments) > 0
    {
      let firstAttachment = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        firstAttachment,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sampleBuffer
  }

  private static func nominalFrameDuration(for frames: [H264ReplayFrame]) -> CMTime {
    let positiveDurations = zip(frames, frames.dropFirst()).compactMap { first, second -> Double? in
      let seconds = CMTimeGetSeconds(second.timestamp - first.timestamp)
      return seconds.isFinite && seconds > 0 ? seconds : nil
    }.sorted()
    guard !positiveDurations.isEmpty else {
      return CMTime(value: 1, timescale: 120)
    }
    return CMTime(
      seconds: positiveDurations[positiveDurations.count / 2],
      preferredTimescale: 1_000_000
    )
  }
}
