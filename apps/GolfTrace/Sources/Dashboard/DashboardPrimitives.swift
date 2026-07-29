import SwiftUI

struct HeaderWaveform: View {
  let isActive: Bool
  var tint: Color = GolfTraceTheme.blue
  private let heights: [CGFloat] = [8, 16, 11, 21, 13, 18, 9, 14, 7, 11]

  var body: some View {
    HStack(spacing: 2.5) {
      ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
        Capsule()
          .fill(
            isActive
              ? (index < 6 ? tint : Color.white.opacity(0.72))
              : (index < 6 ? tint : Color.white.opacity(0.16))
          )
          .frame(width: 2.5, height: height)
      }
    }
  }
}

struct TimelineScrubber: View {
  let isReady: Bool
  @Binding var progress: Double
  let onEditingChanged: (Bool) -> Void
  @State private var isScrubbing = false

  init(
    isReady: Bool,
    progress: Binding<Double> = .constant(0),
    onEditingChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.isReady = isReady
    _progress = progress
    self.onEditingChanged = onEditingChanged
  }

  var body: some View {
    GeometryReader { geometry in
      let thumbSize: CGFloat = 16
      let travel = max(0, geometry.size.width - thumbSize)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.white.opacity(0.18))
          .frame(height: 3)

        HStack(spacing: 0) {
          ForEach(0..<22, id: \.self) { index in
            Rectangle()
              .fill(Color.white.opacity(index == 0 ? 0.55 : 0.35))
              .frame(width: 1, height: index.isMultiple(of: 5) ? 9 : 6)

            if index < 21 {
              Spacer(minLength: 0)
            }
          }
        }
        .padding(.horizontal, 4)

        Circle()
          .fill(isReady ? GolfTraceTheme.blue : Color(red: 0.27, green: 0.53, blue: 1.0))
          .frame(width: thumbSize, height: thumbSize)
          .offset(x: travel * CGFloat(min(1, max(0, progress))))
          .shadow(color: GolfTraceTheme.blue.opacity(0.6), radius: 5)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard isReady, travel > 0 else { return }
            if !isScrubbing {
              isScrubbing = true
              onEditingChanged(true)
            }
            progress = min(1, max(0, Double((value.location.x - thumbSize / 2) / travel)))
          }
          .onEnded { _ in
            guard isScrubbing else { return }
            isScrubbing = false
            onEditingChanged(false)
          }
      )
    }
    .frame(height: 18)
    .accessibilityLabel("ตำแหน่งภาพย้อนหลัง")
    .accessibilityValue("\(Int(min(1, max(0, progress)) * 100)) เปอร์เซ็นต์")
  }
}
