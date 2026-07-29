import Foundation

/// Exact source provenance required for a completion-scoped skeleton slice.
///
/// A slice never combines frames across stream generations, physical sources,
/// viewpoints, coordinate spaces, orientations, or mirroring conventions.
struct MotionSkeletonSessionProvenance: Equatable, Sendable {
  let streamSessionID: UUID
  let sourceID: MotionCameraSourceID
  let viewpoint: MotionCameraViewpoint
  let coordinateSpace: MotionCoordinateSpaceID
  let rotationDegrees: Int
  let isMirrored: Bool
}

/// Immutable neutral skeleton evidence for one completed swing.
///
/// The first and last frame have timestamps exactly equal to `timeRange`.
/// Every frame between those inclusive boundaries is retained in source order.
struct MotionSkeletonSessionSlice: Equatable, Sendable {
  let timeRange: MotionTimeRange
  let provenance: MotionSkeletonSessionProvenance
  let frames: [MotionSkeletonFrame]
}

/// A typed explanation for why completion-scoped skeleton evidence is absent.
///
/// The slicer abstains instead of clamping a boundary, interpolating a frame,
/// repairing invalid joint data, or silently mixing provenance.
enum MotionSkeletonSessionUnavailability: Equatable, Sendable {
  case invalidTimeRange
  case noFrames
  case invalidFrameTime(frameIndex: Int)
  case unorderedFrameTime(frameIndex: Int)
  case missingStartBoundary
  case missingEndBoundary
  case noJointEvidence
  case streamSessionMismatch(frameIndex: Int)
  case sourceMismatch(frameIndex: Int)
  case viewpointMismatch(frameIndex: Int)
  case coordinateSpaceMismatch(frameIndex: Int)
  case orientationMismatch(frameIndex: Int)
  case mirroringMismatch(frameIndex: Int)
  case invalidJointCoordinates(frameIndex: Int, jointID: MotionJointID)
  case invalidJointConfidence(frameIndex: Int, jointID: MotionJointID)
}

enum MotionSkeletonSessionEvidence: Equatable, Sendable {
  case available(MotionSkeletonSessionSlice)
  case unavailable(MotionSkeletonSessionUnavailability)
}

/// Pure selector for extracting neutral skeleton evidence from a completed
/// swing's exact source-time boundaries.
enum MotionSkeletonSessionSlicer {
  static func slice(
    frames: [MotionSkeletonFrame],
    timeRange: MotionTimeRange,
    provenance: MotionSkeletonSessionProvenance
  ) -> MotionSkeletonSessionEvidence {
    guard
      timeRange.startSeconds.isFinite,
      timeRange.endSeconds.isFinite,
      timeRange.startSeconds >= 0,
      timeRange.endSeconds >= timeRange.startSeconds
    else {
      return .unavailable(.invalidTimeRange)
    }

    guard !frames.isEmpty else {
      return .unavailable(.noFrames)
    }

    var previousTime: Double?
    var hasStartBoundary = false
    var hasEndBoundary = false

    for (frameIndex, frame) in frames.enumerated() {
      let sourceTime = frame.context.sourceTimeSeconds
      guard sourceTime.isFinite, sourceTime >= 0 else {
        return .unavailable(.invalidFrameTime(frameIndex: frameIndex))
      }
      if let previousTime, sourceTime < previousTime {
        return .unavailable(.unorderedFrameTime(frameIndex: frameIndex))
      }

      hasStartBoundary = hasStartBoundary || sourceTime == timeRange.startSeconds
      hasEndBoundary = hasEndBoundary || sourceTime == timeRange.endSeconds
      previousTime = sourceTime
    }

    let selectedFrames = frames.enumerated().filter { _, frame in
      let sourceTime = frame.context.sourceTimeSeconds
      return sourceTime >= timeRange.startSeconds && sourceTime <= timeRange.endSeconds
    }

    for (frameIndex, frame) in selectedFrames {
      let context = frame.context
      guard context.streamSessionID == provenance.streamSessionID else {
        return .unavailable(.streamSessionMismatch(frameIndex: frameIndex))
      }
      guard context.sourceID == provenance.sourceID else {
        return .unavailable(.sourceMismatch(frameIndex: frameIndex))
      }
      guard context.viewpoint == provenance.viewpoint else {
        return .unavailable(.viewpointMismatch(frameIndex: frameIndex))
      }
      guard context.coordinateSpace == provenance.coordinateSpace else {
        return .unavailable(.coordinateSpaceMismatch(frameIndex: frameIndex))
      }
      guard context.rotationDegrees == provenance.rotationDegrees else {
        return .unavailable(.orientationMismatch(frameIndex: frameIndex))
      }
      guard context.isMirrored == provenance.isMirrored else {
        return .unavailable(.mirroringMismatch(frameIndex: frameIndex))
      }

      for jointID in frame.joints.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        guard let joint = frame.joints[jointID] else { continue }
        guard
          joint.position.x.isFinite,
          joint.position.y.isFinite,
          joint.position.z.map(\.isFinite) ?? true
        else {
          return .unavailable(
            .invalidJointCoordinates(frameIndex: frameIndex, jointID: jointID)
          )
        }
        if context.coordinateSpace == .normalizedImage2D {
          guard
            (0...1).contains(joint.position.x),
            (0...1).contains(joint.position.y),
            joint.position.z == nil
          else {
            return .unavailable(
              .invalidJointCoordinates(frameIndex: frameIndex, jointID: jointID)
            )
          }
        }
        guard joint.confidence.isFinite, (0...1).contains(joint.confidence) else {
          return .unavailable(
            .invalidJointConfidence(frameIndex: frameIndex, jointID: jointID)
          )
        }
      }
    }

    guard hasStartBoundary else {
      return .unavailable(.missingStartBoundary)
    }
    guard hasEndBoundary else {
      return .unavailable(.missingEndBoundary)
    }
    guard selectedFrames.contains(where: { !$0.element.joints.isEmpty }) else {
      return .unavailable(.noJointEvidence)
    }

    return .available(
      MotionSkeletonSessionSlice(
        timeRange: timeRange,
        provenance: provenance,
        frames: selectedFrames.map(\.element)
      )
    )
  }
}
