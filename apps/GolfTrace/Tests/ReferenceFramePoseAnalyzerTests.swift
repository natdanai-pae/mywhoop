import AppKit
import XCTest

@testable import GolfTrace

final class ReferenceFramePoseAnalyzerTests: XCTestCase {
  func testRejectsInvalidImageData() async {
    let analyzer = ReferenceFramePoseAnalyzer()

    do {
      _ = try await analyzer.analyze(
        frameData: Data("not-an-image".utf8),
        mimeType: "image/jpeg",
        timestampSeconds: 2,
        relativeImagePath: "video/frame.jpg",
        linkedClaimIDs: ["claim-1"],
        sha256: String(repeating: "a", count: 64)
      )
      XCTFail("ควรปฏิเสธข้อมูลที่ไม่ใช่ภาพ")
    } catch {
      XCTAssertEqual(error as? ReferenceFramePoseError, .invalidImage)
    }
  }

  func testBlankImageReturnsAuditableNoBodyObservation() async throws {
    let analyzer = ReferenceFramePoseAnalyzer()
    let imageData = try XCTUnwrap(Self.blankPNG(width: 96, height: 64))

    let result = try await analyzer.analyze(
      frameData: imageData,
      mimeType: "image/png",
      timestampSeconds: 12.5,
      relativeImagePath: "video/frame.png",
      linkedClaimIDs: ["claim-1"],
      sha256: String(repeating: "b", count: 64)
    )

    XCTAssertEqual(result.pixelWidth, 96)
    XCTAssertEqual(result.pixelHeight, 64)
    XCTAssertEqual(result.timestampSeconds, 12.5)
    XCTAssertEqual(result.linkedClaimIDs, ["claim-1"])
    XCTAssertTrue(result.qualityFlags.contains("ไม่พบร่างกาย"))
    XCTAssertFalse(result.hasUsableBodyPose)
    XCTAssertEqual(result.recognizedText, [])
  }

  func testRejectsImageWithUnsafePixelDimensionsBeforeVisionDecode() async throws {
    let analyzer = ReferenceFramePoseAnalyzer()
    let imageData = try XCTUnwrap(Self.blankPNG(width: 4_097, height: 1))

    do {
      _ = try await analyzer.analyze(
        frameData: imageData,
        mimeType: "image/png",
        timestampSeconds: 1,
        relativeImagePath: "video/wide.png",
        linkedClaimIDs: [],
        sha256: String(repeating: "c", count: 64)
      )
      XCTFail("ควรปฏิเสธภาพที่มีมิติพิกเซลเกินขอบเขต")
    } catch {
      XCTAssertEqual(error as? ReferenceFramePoseError, .imageDimensionsTooLarge)
    }
  }

  private static func blankPNG(width: Int, height: Int) -> Data? {
    guard
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])
  }
}
