import Foundation

/// Stable identity for one physical or virtual camera.
///
/// The value is intentionally open-ended so future camera types do not require
/// changing a closed enum or the persistence schema.
struct MotionCameraSourceID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String
}

/// A camera placement understood by the analysis engine.
///
/// Only the two currently supported golf views have convenience constants.
/// Additional values can be introduced by a future provider without changing
/// this type.
struct MotionCameraViewpoint: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let faceOn = MotionCameraViewpoint(rawValue: "face_on")
  static let downTheLine = MotionCameraViewpoint(rawValue: "down_the_line")
  static let unknown = MotionCameraViewpoint(rawValue: "unknown")
}

/// The canonical phase vocabulary shared by motion, history, and coaching.
///
/// Declaration order is the chronological order. A phase is evidence-backed:
/// the presence of a case here never means the detector has observed it.
enum GolfSwingPhase: String, CaseIterable, Codable, Hashable, Sendable {
  case address
  case takeaway
  case p2
  case p3
  case top
  case transition
  case p6
  case impact
  case release
  case finish

  var chronologicalIndex: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }
}

struct MotionCoordinateSpaceID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let normalizedImage2D = MotionCoordinateSpaceID(rawValue: "normalized_image_2d")
  static let bodyLocal3D = MotionCoordinateSpaceID(rawValue: "body_local_3d")
  static let calibratedWorld3D = MotionCoordinateSpaceID(rawValue: "calibrated_world_3d")
}

struct MotionJointID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String
}

struct MotionPoint: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  /// `nil` means the source is two-dimensional.
  let z: Double?

  init(x: Double, y: Double, z: Double? = nil) {
    self.x = x
    self.y = y
    self.z = z
  }
}

struct MotionJointSample: Codable, Equatable, Sendable {
  let position: MotionPoint
  let confidence: Double
}

/// Provenance attached to every analyzed frame.
///
/// Source-local timestamps are not assumed to share a clock with another
/// camera. Multi-camera fusion requires an explicit clock calibration later.
struct MotionFrameContext: Codable, Equatable, Sendable {
  let sourceID: MotionCameraSourceID
  let streamSessionID: UUID
  let viewpoint: MotionCameraViewpoint
  let sourceTimeSeconds: Double
  let coordinateSpace: MotionCoordinateSpaceID
  let rotationDegrees: Int
  let isMirrored: Bool
}

/// Detector-neutral skeleton representation.
///
/// Apple Vision names stay inside an adapter; the motion engine consumes stable
/// joint identifiers and normalized values instead.
struct MotionSkeletonFrame: Codable, Equatable, Sendable {
  let context: MotionFrameContext
  let joints: [MotionJointID: MotionJointSample]
}

struct MotionMetricID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let shoulderTurn = MotionMetricID(rawValue: "shoulder_turn")
  static let chestTurn = MotionMetricID(rawValue: "chest_turn")
  static let pelvisTurn = MotionMetricID(rawValue: "pelvis_turn")
  static let xFactor = MotionMetricID(rawValue: "x_factor")
  static let headMovement = MotionMetricID(rawValue: "head_movement")
  static let sideBend = MotionMetricID(rawValue: "side_bend")
  static let hipDepth = MotionMetricID(rawValue: "hip_depth")
  static let sway = MotionMetricID(rawValue: "sway")
  static let earlyExtension = MotionMetricID(rawValue: "early_extension")
}

struct MotionMetricUnitID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let degrees = MotionMetricUnitID(rawValue: "degrees")
  static let ratio = MotionMetricUnitID(rawValue: "ratio")
  static let normalizedBodyLength = MotionMetricUnitID(rawValue: "normalized_body_length")
}

enum MotionValueProvenance: String, Codable, Equatable, Sendable {
  case measured2D = "measured_2d"
  case derived2D = "derived_2d"
  case measured3D = "measured_3d"
  case derived3D = "derived_3d"
  case aiInferred = "ai_inferred"
}

enum MotionMetricComparisonScope: String, Codable, Equatable, Sendable {
  /// Safe only against captures from the same camera placement.
  case sameViewOnly = "same_view_only"
  /// Safe across sources only after spatial and clock calibration.
  case calibratedMultiCamera = "calibrated_multi_camera"
}

enum MotionMetricAvailability: String, Codable, Equatable, Sendable {
  case available
  case limited
  case unavailable
}

struct MotionTimeRange: Codable, Equatable, Sendable {
  let startSeconds: Double
  let endSeconds: Double
}

struct MotionMetricReading: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let metricID: MotionMetricID
  let value: Double?
  let unit: MotionMetricUnitID
  let phase: GolfSwingPhase?
  let sourceID: MotionCameraSourceID
  let viewpoint: MotionCameraViewpoint
  let timeRange: MotionTimeRange
  let provenance: MotionValueProvenance
  let comparisonScope: MotionMetricComparisonScope
  let availability: MotionMetricAvailability
  let confidence: Double
  let unavailableReason: String?
  let limitations: [String]

  init(
    id: UUID = UUID(),
    metricID: MotionMetricID,
    value: Double?,
    unit: MotionMetricUnitID,
    phase: GolfSwingPhase?,
    sourceID: MotionCameraSourceID,
    viewpoint: MotionCameraViewpoint,
    timeRange: MotionTimeRange,
    provenance: MotionValueProvenance,
    comparisonScope: MotionMetricComparisonScope = .sameViewOnly,
    availability: MotionMetricAvailability = .available,
    confidence: Double,
    unavailableReason: String? = nil,
    limitations: [String] = []
  ) {
    self.id = id
    self.metricID = metricID
    self.value = value
    self.unit = unit
    self.phase = phase
    self.sourceID = sourceID
    self.viewpoint = viewpoint
    self.timeRange = timeRange
    self.provenance = provenance
    self.comparisonScope = comparisonScope
    self.availability = availability
    self.confidence = confidence
    self.unavailableReason = unavailableReason
    self.limitations = limitations
  }
}

struct SwingPhaseObservation: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let phase: GolfSwingPhase
  let sourceID: MotionCameraSourceID
  let viewpoint: MotionCameraViewpoint
  let sourceTimeSeconds: Double
  let confidence: Double
  let provenance: MotionValueProvenance
  let limitations: [String]

  init(
    id: UUID = UUID(),
    phase: GolfSwingPhase,
    sourceID: MotionCameraSourceID,
    viewpoint: MotionCameraViewpoint,
    sourceTimeSeconds: Double,
    confidence: Double,
    provenance: MotionValueProvenance,
    limitations: [String] = []
  ) {
    self.id = id
    self.phase = phase
    self.sourceID = sourceID
    self.viewpoint = viewpoint
    self.sourceTimeSeconds = sourceTimeSeconds
    self.confidence = confidence
    self.provenance = provenance
    self.limitations = limitations
  }
}

struct MotionAnalysisInput: Sendable {
  let swingID: UUID
  let skeletonFrames: [MotionSkeletonFrame]
}

struct MotionAnalysisResult: Codable, Equatable, Sendable {
  static let schemaVersion = 1

  let schemaVersion: Int
  let swingID: UUID
  let skeletonFrames: [MotionSkeletonFrame]
  let phaseObservations: [SwingPhaseObservation]
  let metrics: [MotionMetricReading]
  let limitations: [String]

  init(
    schemaVersion: Int = Self.schemaVersion,
    swingID: UUID,
    skeletonFrames: [MotionSkeletonFrame],
    phaseObservations: [SwingPhaseObservation],
    metrics: [MotionMetricReading],
    limitations: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.swingID = swingID
    self.skeletonFrames = skeletonFrames
    self.phaseObservations = phaseObservations
    self.metrics = metrics
    self.limitations = limitations
  }

  func metrics(for phase: GolfSwingPhase) -> [MotionMetricReading] {
    metrics.filter { $0.phase == phase }
  }

  func metric(_ metricID: MotionMetricID, at phase: GolfSwingPhase) -> MotionMetricReading? {
    metrics.first { $0.metricID == metricID && $0.phase == phase }
  }
}

/// Boundary between a platform image source and a pose implementation.
///
/// `FrameInput` may be a sample buffer, pixel buffer, fixture, or remote frame.
/// The returned skeleton is independent from that transport.
protocol PoseDetecting: Sendable {
  associatedtype FrameInput: Sendable

  func detectPose(
    in frame: FrameInput,
    context: MotionFrameContext
  ) async throws -> MotionSkeletonFrame?
}

protocol SwingPhaseDetecting: Sendable {
  func detectPhases(in input: MotionAnalysisInput) throws -> [SwingPhaseObservation]
}

protocol MotionMetricCalculating: Sendable {
  var supportedMetricIDs: Set<MotionMetricID> { get }

  func calculateMetrics(
    in input: MotionAnalysisInput,
    phases: [SwingPhaseObservation]
  ) throws -> [MotionMetricReading]
}

struct MotionCoachEvidence: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let phase: GolfSwingPhase?
  let value: Double?
  let unit: String?
  let source: String
  let confidence: Double
  let limitations: [String]
}

struct MotionCoachRequest: Codable, Equatable, Sendable {
  let swingID: UUID
  let playerQuestion: String
  let evidence: [MotionCoachEvidence]
}

/// Structured coaching chain. Each field remains independently reviewable and
/// can cite the evidence used to produce it.
struct MotionCoachFeedback: Codable, Equatable, Sendable {
  let observation: String
  let possibleCause: String?
  let expectedBallFlight: String?
  let suggestedDrill: String
  let nextPracticeGoal: String
  let phase: GolfSwingPhase?
  let confidence: Double
  let evidenceIDs: [String]
  let limitations: [String]
}

protocol MotionCoachServing: Sendable {
  func feedback(for request: MotionCoachRequest) async throws -> MotionCoachFeedback
}
