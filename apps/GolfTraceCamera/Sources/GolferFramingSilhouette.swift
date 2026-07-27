import SwiftUI

/// โครงร่างเส้นประสำหรับช่วยจัดตำแหน่งผู้เล่น โดยไม่มีภาพบุคคลจริงบังภาพกล้อง
struct GolferFramingSilhouette: View {
  let cameraView: GolfCameraView

  private var assetName: String {
    switch cameraView {
    case .faceOn:
      "GolferGuideFaceOn"
    case .downTheLine:
      "GolferGuideDownTheLine"
    }
  }

  var body: some View {
    Group {
      if let image = GolfTraceBundledPNG.image(named: assetName) {
        image
          .resizable()
          .scaledToFill()
          .clipped()
          .opacity(0.78)
          .shadow(color: .black.opacity(0.82), radius: 2)
      } else {
        Image(systemName: "figure.golf")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.white.opacity(0.58))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
