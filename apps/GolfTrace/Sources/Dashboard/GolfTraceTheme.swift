import SwiftUI

enum GolfTraceTheme {
  static let canvas = Color(red: 0.025, green: 0.043, blue: 0.066)
  static let panel = Color(red: 0.050, green: 0.075, blue: 0.105)
  static let raisedPanel = Color(red: 0.070, green: 0.098, blue: 0.132)
  static let border = Color.white.opacity(0.14)
  static let subtleBorder = Color.white.opacity(0.08)
  static let blue = Color(red: 0.25, green: 0.53, blue: 1.0)
  static let mutedText = Color.white.opacity(0.60)
}

extension View {
  func golfTracePanel(cornerRadius: CGFloat = 14) -> some View {
    background(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(GolfTraceTheme.panel)
        .overlay(
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(GolfTraceTheme.border, lineWidth: 1)
        )
    )
  }
}
