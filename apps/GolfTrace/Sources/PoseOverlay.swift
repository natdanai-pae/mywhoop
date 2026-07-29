import SwiftUI
import Vision

struct PoseOverlay: View {
  let pose: PoseFrame?
  let sourceDimensions: CGSize

  private let bones:
    [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
      (.neck, .leftShoulder), (.neck, .rightShoulder),
      (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
      (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
      (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
      (.leftHip, .rightHip), (.leftHip, .leftKnee),
      (.leftKnee, .leftAnkle), (.rightHip, .rightKnee),
      (.rightKnee, .rightAnkle),
    ]

  var body: some View {
    GeometryReader { proxy in
      Canvas { context, size in
        guard let pose, !pose.joints.isEmpty, sourceDimensions.width > 0,
          sourceDimensions.height > 0
        else {
          return
        }

        let videoRect = aspectFitRect(source: sourceDimensions, in: size)
        var path = Path()

        for (from, to) in bones {
          guard let start = pose.joints[from], let end = pose.joints[to] else { continue }
          path.move(to: point(for: start, in: videoRect))
          path.addLine(to: point(for: end, in: videoRect))
        }

        context.stroke(path, with: .color(.mint.opacity(0.95)), lineWidth: 3)

        for joint in pose.joints.values {
          let center = point(for: joint, in: videoRect)
          let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
          context.fill(dot, with: .color(.white))
          context.stroke(dot, with: .color(.mint), lineWidth: 2)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .allowsHitTesting(false)
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

  private func point(for joint: PoseJoint, in videoRect: CGRect) -> CGPoint {
    CGPoint(
      x: videoRect.minX + joint.location.x * videoRect.width,
      y: videoRect.maxY - joint.location.y * videoRect.height
    )
  }
}
