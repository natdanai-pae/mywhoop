import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// โหลด PNG ที่ Xcode คัดลอกเป็นไฟล์ใน app bundle โดยตรง
/// ไม่พึ่ง Asset Catalog จึงใช้ภาพจาก ImageGen ชุดเดียวกันได้ทั้ง Mac และ iPhone
@MainActor
enum GolfTraceBundledPNG {
#if os(macOS)
  private static let cache = NSCache<NSString, NSImage>()
#else
  private static let cache = NSCache<NSString, UIImage>()
#endif

  static func image(named name: String) -> Image? {
#if os(macOS)
    if let cached = cache.object(forKey: name as NSString) {
      return Image(nsImage: cached)
    }
#else
    if let cached = cache.object(forKey: name as NSString) {
      return Image(uiImage: cached)
    }
#endif

    guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
      return nil
    }
#if os(macOS)
    guard let image = NSImage(contentsOf: url) else { return nil }
    cache.setObject(image, forKey: name as NSString)
    return Image(nsImage: image)
#else
    guard let image = UIImage(contentsOfFile: url.path) else { return nil }
    cache.setObject(image, forKey: name as NSString)
    return Image(uiImage: image)
#endif
  }
}

/// ชุดไอคอนที่ ImageGen ออกแบบให้ GolfTrace โดยใช้จุดสีน้ำเงินเป็นลายเซ็นการติดตาม
enum GolfTraceGeneratedIcon: String, Sendable {
  case club = "GolfTraceIconClub"
  case cameraAngle = "GolfTraceIconCameraAngle"
  case guideline = "GolfTraceIconGuideline"
  case aiPro = "GolfTraceIconAIPro"
}

struct GolfTraceGeneratedIconView: View {
  let icon: GolfTraceGeneratedIcon
  var size: CGFloat = 28

  var body: some View {
    Group {
      if let image = GolfTraceBundledPNG.image(named: icon.rawValue) {
        image
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "circle.dotted.circle.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.blue)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
