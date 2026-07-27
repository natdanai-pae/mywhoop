import Combine
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Stores a visual reference of the Mac display without interpreting its pixels.
///
/// The image remains inside GolfTrace's app-support directory. This deliberately
/// does not perform OCR, metric extraction, or network upload.
@MainActor
final class ScreenEvidenceRecorder: ObservableObject {
  @Published private(set) var status = "พร้อมบันทึกภาพอ้างอิงจากจอ Mac"
  @Published private(set) var latestCaptureURL: URL?
  @Published private(set) var isCapturing = false
  @Published private(set) var isArmed = false
  @Published private(set) var captureCount = 0

  private var continuousCaptureTask: Task<Void, Never>?

  deinit {
    continuousCaptureTask?.cancel()
  }

  func capturePrimaryDisplay(afterDelay seconds: UInt64 = 0) {
    guard !isCapturing else { return }
    isCapturing = true
    status =
      seconds == 0
      ? "กำลังบันทึกภาพจากจอ Mac…"
      : "จะบันทึกใน \(seconds) วินาที — สลับไปหน้าจอ Rapsodo ได้เลย"

    Task {
      do {
        if seconds > 0 {
          try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
        let url = try await Self.captureAndStorePrimaryDisplay()
        latestCaptureURL = url
        status = "บันทึกภาพอ้างอิงแล้ว: \(url.lastPathComponent)"
      } catch {
        status = "บันทึกภาพไม่ได้: \(error.localizedDescription)"
      }
      isCapturing = false
    }
  }

  /// Arms a local 1 FPS evidence capture before AirPlay takes over the Mac UI.
  func startContinuousCapture(intervalSeconds: UInt64 = 1) {
    guard continuousCaptureTask == nil else { return }
    isArmed = true
    captureCount = 0
    status = "กำลังเก็บภาพหน้าจอทุก 1 วินาที — เปิด Rapsodo AirPlay ได้เลย"

    continuousCaptureTask = Task { [weak self] in
      guard let self else { return }

      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
        } catch {
          break
        }

        guard !Task.isCancelled else { break }
        do {
          let url = try await Self.captureAndStorePrimaryDisplay()
          latestCaptureURL = url
          captureCount += 1
          status = "กำลังเก็บภาพ Rapsodo ในเครื่อง: \(captureCount) ภาพ"
        } catch {
          status = "หยุดเก็บภาพ: \(error.localizedDescription)"
          break
        }
      }

      let wasArmed = isArmed
      continuousCaptureTask = nil
      isArmed = false
      if wasArmed, !status.hasPrefix("หยุดเก็บภาพ:") {
        status = "หยุดเก็บภาพแล้ว: \(captureCount) ภาพ"
      }
    }
  }

  func stopContinuousCapture() {
    continuousCaptureTask?.cancel()
  }

  private nonisolated static func captureAndStorePrimaryDisplay() async throws -> URL {
    let shareableContent = try await SCShareableContent.current
    guard let display = shareableContent.displays.first else {
      throw ScreenEvidenceError.noDisplay
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.showsCursor = false

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )

    let evidenceDirectory = try evidenceDirectoryURL()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let safeTimestamp = formatter.string(from: .now)
      .replacingOccurrences(of: ":", with: "-")
    let outputURL = evidenceDirectory.appendingPathComponent(
      "screen-evidence-\(safeTimestamp).jpg"
    )

    guard
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw ScreenEvidenceError.destinationUnavailable
    }

    CGImageDestinationAddImage(
      destination, image,
      [
        kCGImageDestinationLossyCompressionQuality: 0.92
      ] as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ScreenEvidenceError.writeFailed
    }
    return outputURL
  }

  private nonisolated static func evidenceDirectoryURL() throws -> URL {
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("GolfTrace", isDirectory: true)
    .appendingPathComponent("ScreenEvidence", isDirectory: true)

    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

private enum ScreenEvidenceError: LocalizedError {
  case noDisplay
  case destinationUnavailable
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .noDisplay:
      "ไม่พบจอที่พร้อมบันทึก"
    case .destinationUnavailable:
      "สร้างไฟล์ภาพอ้างอิงไม่ได้"
    case .writeFailed:
      "เขียนไฟล์ภาพอ้างอิงไม่สำเร็จ"
    }
  }
}
