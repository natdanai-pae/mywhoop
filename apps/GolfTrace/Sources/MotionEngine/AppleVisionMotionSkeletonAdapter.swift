import CoreMedia
import Foundation
import Vision

enum AppleVisionMotionJointMappingVersion: Int, Codable, Equatable, Sendable {
  case vision2DRevision1 = 1
}

enum AppleVisionMotionSkeletonAdapterError: Error, Equatable {
  case invalidTimestamp
}

/// Maps the current Apple Vision pose model into the detector-neutral motion
/// contract. The live pipeline is not routed through this adapter in Milestone
/// 1; it is a compatibility seam for the later runtime migration.
struct AppleVisionMotionSkeletonAdapter: Sendable {
  let jointMappingVersion: AppleVisionMotionJointMappingVersion

  init(jointMappingVersion: AppleVisionMotionJointMappingVersion = .vision2DRevision1) {
    self.jointMappingVersion = jointMappingVersion
  }

  func skeleton(
    from pose: PoseFrame,
    sourceContext: MotionFrameSourceContext
  ) throws -> MotionSkeletonFrame {
    let sourceTimeSeconds = CMTimeGetSeconds(pose.timestamp)
    guard pose.timestamp.isValid, sourceTimeSeconds.isFinite, sourceTimeSeconds >= 0 else {
      throw AppleVisionMotionSkeletonAdapterError.invalidTimestamp
    }

    var joints: [MotionJointID: MotionJointSample] = [:]
    joints.reserveCapacity(pose.joints.count)

    for (visionName, sample) in pose.joints {
      guard let jointID = Self.jointID(for: visionName, version: jointMappingVersion) else {
        continue
      }
      joints[jointID] = MotionJointSample(
        position: MotionPoint(
          x: Double(sample.location.x),
          y: Double(sample.location.y)
        ),
        confidence: Double(sample.confidence)
      )
    }

    return MotionSkeletonFrame(
      context: MotionFrameContext(
        sourceID: sourceContext.sourceID,
        streamSessionID: sourceContext.streamSessionID,
        viewpoint: sourceContext.viewpoint,
        sourceTimeSeconds: sourceTimeSeconds,
        coordinateSpace: .normalizedImage2D,
        rotationDegrees: Int(pose.videoOrientation.rawValue),
        isMirrored: sourceContext.isMirrored
      ),
      joints: joints
    )
  }

  static func jointID(
    for visionName: VNHumanBodyPoseObservation.JointName,
    version: AppleVisionMotionJointMappingVersion
  ) -> MotionJointID? {
    switch version {
    case .vision2DRevision1:
      revision1JointIDs[visionName]
    }
  }

  private static let revision1JointIDs: [VNHumanBodyPoseObservation.JointName: MotionJointID] = [
    .nose: .nose,
    .leftEye: .leftEye,
    .rightEye: .rightEye,
    .leftEar: .leftEar,
    .rightEar: .rightEar,
    .neck: .neck,
    .leftShoulder: .leftShoulder,
    .rightShoulder: .rightShoulder,
    .leftElbow: .leftElbow,
    .rightElbow: .rightElbow,
    .leftWrist: .leftWrist,
    .rightWrist: .rightWrist,
    .root: .root,
    .leftHip: .leftHip,
    .rightHip: .rightHip,
    .leftKnee: .leftKnee,
    .rightKnee: .rightKnee,
    .leftAnkle: .leftAnkle,
    .rightAnkle: .rightAnkle,
  ]
}
