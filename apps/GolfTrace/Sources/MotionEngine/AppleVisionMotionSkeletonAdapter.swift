import Foundation
import Vision

/// Maps the current Apple Vision pose model into the detector-neutral motion
/// contract. The live pipeline is not routed through this adapter in Milestone
/// 1; it is a compatibility seam for the later runtime migration.
struct AppleVisionMotionSkeletonAdapter: Sendable {
  func skeleton(
    from pose: PoseFrame,
    context: MotionFrameContext
  ) -> MotionSkeletonFrame {
    var joints: [MotionJointID: MotionJointSample] = [:]
    joints.reserveCapacity(pose.joints.count)

    for (visionName, sample) in pose.joints {
      let jointID = Self.jointID(for: visionName)
      joints[jointID] = MotionJointSample(
        position: MotionPoint(
          x: Double(sample.location.x),
          y: Double(sample.location.y)
        ),
        confidence: Double(sample.confidence)
      )
    }

    return MotionSkeletonFrame(context: context, joints: joints)
  }

  static func jointID(
    for visionName: VNHumanBodyPoseObservation.JointName
  ) -> MotionJointID {
    MotionJointID(rawValue: knownJointIDs[visionName] ?? String(describing: visionName))
  }

  private static let knownJointIDs: [VNHumanBodyPoseObservation.JointName: String] = [
    .nose: "nose",
    .leftEye: "left_eye",
    .rightEye: "right_eye",
    .leftEar: "left_ear",
    .rightEar: "right_ear",
    .neck: "neck",
    .leftShoulder: "left_shoulder",
    .rightShoulder: "right_shoulder",
    .leftElbow: "left_elbow",
    .rightElbow: "right_elbow",
    .leftWrist: "left_wrist",
    .rightWrist: "right_wrist",
    .root: "root",
    .leftHip: "left_hip",
    .rightHip: "right_hip",
    .leftKnee: "left_knee",
    .rightKnee: "right_knee",
    .leftAnkle: "left_ankle",
    .rightAnkle: "right_ankle",
  ]
}
