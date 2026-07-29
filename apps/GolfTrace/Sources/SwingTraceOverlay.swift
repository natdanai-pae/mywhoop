import SwiftUI

/// Draws the local wrist-derived hand-center trail over an aspect-fitted camera image.
///
/// The trace is cyan for its retained history and orange for its newest segment and point.
/// It intentionally labels itself as a wrist/hand-center diagnostic rather than club tracking.
struct SwingTraceOverlay: View {
  let motion: SwingMotionFrame?
  /// เมื่อมีค่า ให้ตรึงเส้นทางของวงที่จบแล้วแทนประวัติสดที่เลื่อนไปเรื่อย ๆ
  let retainedPoints: [SwingMotionPoint]?
  let sourceDimensions: CGSize

  var body: some View {
    GeometryReader { proxy in
      Canvas { context, size in
        guard sourceDimensions.width > 0,
          sourceDimensions.height > 0,
          size.width > 0,
          size.height > 0
        else {
          return
        }

        let points = retainedPoints ?? motion?.pointHistory ?? []
        let videoRect = aspectFitRect(source: sourceDimensions, in: size)
        drawTrace(points, in: videoRect, context: &context)

        if retainedPoints == nil, let handCenter = motion?.handCenter {
          drawCurrentHandCenter(handCenter, in: videoRect, context: &context)
        }

        if retainedPoints != nil {
          drawEndpoints(points, in: videoRect, context: &context)
        }

        if motion?.handCenter != nil || !points.isEmpty {
          drawLabel(
            retainedPoints == nil
              ? (motion?.traceLabel ?? "กึ่งกลางมือ · ยังไม่ใช่หัวไม้")
              : "วงล่าสุด · เส้นทางกึ่งกลางมือ · ยังไม่ใช่หัวไม้",
            in: videoRect,
            context: &context
          )
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(motion?.diagnosticText ?? "ยังไม่มีเส้นทางกึ่งกลางมือ")
  }

  private func drawTrace(
    _ points: [SwingMotionPoint],
    in videoRect: CGRect,
    context: inout GraphicsContext
  ) {
    guard let first = points.first else { return }

    let displayPoints = points.map { displayPoint(for: $0.normalizedLocation, in: videoRect) }
    let historyPath = curvedPath(through: displayPoints)
    context.stroke(historyPath, with: .color(.cyan.opacity(0.78)), lineWidth: 2.5)

    // Accentuate only the latest part of the path, leaving older history cyan.
    let newestCount = min(8, displayPoints.count)
    if newestCount >= 2 {
      let newestPath = curvedPath(through: Array(displayPoints.suffix(newestCount)))
      context.stroke(newestPath, with: .color(.orange), lineWidth: 4)
    } else {
      let dot = dotPath(at: displayPoint(for: first.normalizedLocation, in: videoRect), radius: 3)
      context.fill(dot, with: .color(.cyan))
    }
  }

  /// Joins filtered samples with quadratic curves instead of exposing every small
  /// direction change as a sharp corner.
  private func curvedPath(through points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)

    guard points.count > 2 else {
      if let last = points.last, last != first {
        path.addLine(to: last)
      }
      return path
    }

    for index in 1..<(points.count - 1) {
      let control = points[index]
      let next = points[index + 1]
      let midpoint = CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2)
      path.addQuadCurve(to: midpoint, control: control)
    }

    if let last = points.last {
      path.addQuadCurve(to: last, control: points[points.count - 2])
    }
    return path
  }

  private func drawCurrentHandCenter(
    _ normalizedPoint: CGPoint,
    in videoRect: CGRect,
    context: inout GraphicsContext
  ) {
    let center = displayPoint(for: normalizedPoint, in: videoRect)
    let halo = dotPath(at: center, radius: 8)
    let dot = dotPath(at: center, radius: 4)
    context.fill(halo, with: .color(.cyan.opacity(0.42)))
    context.fill(dot, with: .color(.orange))
    context.stroke(dot, with: .color(.white.opacity(0.9)), lineWidth: 1.25)
  }

  private func drawEndpoints(
    _ points: [SwingMotionPoint],
    in videoRect: CGRect,
    context: inout GraphicsContext
  ) {
    guard let first = points.first, let last = points.last else { return }

    let start = displayPoint(for: first.normalizedLocation, in: videoRect)
    let end = displayPoint(for: last.normalizedLocation, in: videoRect)
    let startDot = dotPath(at: start, radius: 6)
    let endDot = dotPath(at: end, radius: 7)
    context.fill(startDot, with: .color(.green))
    context.stroke(startDot, with: .color(.white), lineWidth: 1.5)
    context.fill(endDot, with: .color(.orange))
    context.stroke(endDot, with: .color(.white), lineWidth: 1.5)
  }

  private func drawLabel(
    _ label: String,
    in videoRect: CGRect,
    context: inout GraphicsContext
  ) {
    let text = Text(label)
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundColor(.orange)
    context.draw(
      text,
      at: CGPoint(x: videoRect.minX + 10, y: videoRect.minY + 10),
      anchor: .topLeading
    )
  }

  private func aspectFitRect(source: CGSize, in container: CGSize) -> CGRect {
    let scale = min(container.width / source.width, container.height / source.height)
    let size = CGSize(width: source.width * scale, height: source.height * scale)
    return CGRect(
      x: (container.width - size.width) / 2,
      y: (container.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }

  private func displayPoint(for normalizedPoint: CGPoint, in videoRect: CGRect) -> CGPoint {
    CGPoint(
      x: videoRect.minX + normalizedPoint.x * videoRect.width,
      y: videoRect.maxY - normalizedPoint.y * videoRect.height
    )
  }

  private func dotPath(at center: CGPoint, radius: CGFloat) -> Path {
    Path(
      ellipseIn: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
    )
  }
}
