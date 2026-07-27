import SwiftUI
import Vision

/// A lightweight visual reference rendered in the same aspect-fitted geometry
/// as the camera, pose and hand trace. These marks are coaching guides only;
/// they are not presented as measured club-head or launch-monitor data.
struct GolfGuidelineOverlay: View {
  let guideline: GolfGuideline
  let cameraView: GolfCameraView
  let pose: PoseFrame?
  let personalBaseline: [SwingMotionPoint]?
  let sourceDimensions: CGSize

  var body: some View {
    GeometryReader { proxy in
      Canvas { context, size in
        guard guideline != .none,
          sourceDimensions.width > 0,
          sourceDimensions.height > 0,
          size.width > 0,
          size.height > 0
        else {
          return
        }

        let videoRect = aspectFitRect(source: sourceDimensions, in: size)
        let guideStyle = StrokeStyle(
          lineWidth: 2,
          lineCap: .round,
          lineJoin: .round,
          dash: [9, 7]
        )

        switch guideline {
        case .personalBaseline:
          drawPersonalBaseline(in: videoRect, context: &context, style: guideStyle)
        case .posture:
          drawPostureGuide(in: videoRect, context: &context, style: guideStyle)
        case .swingPlane:
          drawSwingPlane(in: videoRect, context: &context, style: guideStyle)
        case .rotation:
          drawRotationGuide(in: videoRect, context: &context, style: guideStyle)
        case .tempo:
          drawTempoGuide(in: videoRect, context: &context, style: guideStyle)
        case .none:
          break
        }

        let label = Text("เส้นช่วยดู · \(guideline.displayName)")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundColor(.green)
        context.draw(
          label,
          at: CGPoint(x: videoRect.maxX - 12, y: videoRect.minY + 12),
          anchor: .topTrailing
        )
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func drawPersonalBaseline(
    in rect: CGRect,
    context: inout GraphicsContext,
    style: StrokeStyle
  ) {
    guard let personalBaseline, personalBaseline.count > 1 else {
      var center = Path()
      center.move(to: point(x: 0.5, y: 0.18, in: rect))
      center.addLine(to: point(x: 0.5, y: 0.82, in: rect))
      context.stroke(center, with: .color(.green.opacity(0.48)), style: style)
      return
    }

    var path = Path()
    for (index, sample) in personalBaseline.enumerated() {
      let display = displayPoint(for: sample.normalizedLocation, in: rect)
      if index == 0 { path.move(to: display) } else { path.addLine(to: display) }
    }
    context.stroke(path, with: .color(.green.opacity(0.72)), style: style)
  }

  private func drawPostureGuide(
    in rect: CGRect,
    context: inout GraphicsContext,
    style: StrokeStyle
  ) {
    let centerX = normalizedBodyCenterX ?? 0.5
    var path = Path()
    path.move(to: point(x: centerX, y: 0.12, in: rect))
    path.addLine(to: point(x: centerX, y: 0.9, in: rect))
    path.move(to: point(x: centerX - 0.22, y: 0.48, in: rect))
    path.addLine(to: point(x: centerX + 0.22, y: 0.48, in: rect))
    context.stroke(path, with: .color(.green.opacity(0.72)), style: style)
  }

  private func drawSwingPlane(
    in rect: CGRect,
    context: inout GraphicsContext,
    style: StrokeStyle
  ) {
    let leansRight = cameraView == .downTheLine
    let lowerX: CGFloat = leansRight ? 0.28 : 0.72
    let upperX: CGFloat = leansRight ? 0.76 : 0.24
    var corridor = Path()
    corridor.move(to: point(x: lowerX - 0.06, y: 0.12, in: rect))
    corridor.addLine(to: point(x: upperX - 0.06, y: 0.88, in: rect))
    corridor.move(to: point(x: lowerX + 0.06, y: 0.12, in: rect))
    corridor.addLine(to: point(x: upperX + 0.06, y: 0.88, in: rect))
    context.stroke(corridor, with: .color(.green.opacity(0.76)), style: style)
  }

  private func drawRotationGuide(
    in rect: CGRect,
    context: inout GraphicsContext,
    style: StrokeStyle
  ) {
    var axes = Path()
    if let shoulders = jointLine(.leftShoulder, .rightShoulder, in: rect) {
      axes.move(to: shoulders.0)
      axes.addLine(to: shoulders.1)
    } else {
      axes.move(to: point(x: 0.28, y: 0.66, in: rect))
      axes.addLine(to: point(x: 0.72, y: 0.66, in: rect))
    }
    if let hips = jointLine(.leftHip, .rightHip, in: rect) {
      axes.move(to: hips.0)
      axes.addLine(to: hips.1)
    } else {
      axes.move(to: point(x: 0.32, y: 0.48, in: rect))
      axes.addLine(to: point(x: 0.68, y: 0.48, in: rect))
    }
    context.stroke(axes, with: .color(.green.opacity(0.78)), style: style)
  }

  private func drawTempoGuide(
    in rect: CGRect,
    context: inout GraphicsContext,
    style: StrokeStyle
  ) {
    let y: CGFloat = 0.12
    var path = Path()
    path.move(to: point(x: 0.22, y: y, in: rect))
    path.addLine(to: point(x: 0.78, y: y, in: rect))
    for index in 0...4 {
      let x = 0.22 + CGFloat(index) * 0.14
      path.move(to: point(x: x, y: y - 0.025, in: rect))
      path.addLine(to: point(x: x, y: y + 0.025, in: rect))
    }
    context.stroke(path, with: .color(.green.opacity(0.72)), style: style)
    context.draw(
      Text("3 : 1").font(.system(size: 13, weight: .bold, design: .rounded)),
      at: point(x: 0.5, y: y + 0.055, in: rect),
      anchor: .bottom
    )
  }

  private var normalizedBodyCenterX: CGFloat? {
    guard let pose else { return nil }
    let candidates = [
      pose.joints[.leftShoulder]?.location.x,
      pose.joints[.rightShoulder]?.location.x,
      pose.joints[.leftHip]?.location.x,
      pose.joints[.rightHip]?.location.x,
    ].compactMap { $0 }
    guard !candidates.isEmpty else { return nil }
    return candidates.reduce(0, +) / CGFloat(candidates.count)
  }

  private func jointLine(
    _ first: VNHumanBodyPoseObservation.JointName,
    _ second: VNHumanBodyPoseObservation.JointName,
    in rect: CGRect
  ) -> (CGPoint, CGPoint)? {
    guard let firstPoint = pose?.joints[first]?.location,
      let secondPoint = pose?.joints[second]?.location
    else {
      return nil
    }
    return (
      displayPoint(for: firstPoint, in: rect),
      displayPoint(for: secondPoint, in: rect)
    )
  }

  private func aspectFitRect(source: CGSize, in container: CGSize) -> CGRect {
    let scale = min(container.width / source.width, container.height / source.height)
    let fitted = CGSize(width: source.width * scale, height: source.height * scale)
    return CGRect(
      x: (container.width - fitted.width) / 2,
      y: (container.height - fitted.height) / 2,
      width: fitted.width,
      height: fitted.height
    )
  }

  private func displayPoint(for normalizedPoint: CGPoint, in rect: CGRect) -> CGPoint {
    point(x: normalizedPoint.x, y: normalizedPoint.y, in: rect)
  }

  private func point(x: CGFloat, y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(
      x: rect.minX + x * rect.width,
      y: rect.maxY - y * rect.height
    )
  }
}
