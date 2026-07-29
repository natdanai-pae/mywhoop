# Motion Engine Architecture

Status: proposed architecture, with the Milestone 1 additive domain contracts and the first
Milestone 2 shadow-runtime slice implemented.

This document designs GolfTrace's motion-analysis boundary. It does not claim that the
listed three-dimensional metrics or full live ten-phase detection are implemented today.
The canonical ten-phase vocabulary is implemented, but the authoritative runtime still
produces partial legacy phase evidence. Accepted poses are also translated into bounded,
detector-neutral shadow skeleton frames. At completion, a pure slicer produces one
provenance-checked internal evidence result, but no UI, persistence, metric, phase, or
coaching path consumes it yet. The contracts let later work add validated phase detection,
Face-On, Down-The-Line, and synchronized multi-camera analysis without moving UI concerns
into the analysis code.

## 1. Current implementation

The working capture and analysis path is:

```text
GolfTraceCamera on iPhone
  -> H.264 over the GolfTrace TCP wire protocol
  -> HighSpeedVideoReceiver on Mac
  -> VideoToolbox decode
  -> PoseDetector using Apple Vision
  -> LiveSwingPipeline
  -> SwingMotionAnalyzer / SwingSessionDetector / SwingMetricsAnalyzer
  -> SwingEvidencePacket
  -> replay, local history, and AI Coach request context
```

The implementation is deliberately local-first:

- [`apps/GolfTraceCamera/Sources/Camera/CameraService.swift`](../apps/GolfTraceCamera/Sources/Camera/CameraService.swift)
  captures the iPhone camera.
- [`apps/GolfTraceCamera/Sources/Transport/HighSpeedH264Streamer.swift`](../apps/GolfTraceCamera/Sources/Transport/HighSpeedH264Streamer.swift)
  encodes and sends H.264.
- [`apps/Shared/GolfTraceWireProtocol.swift`](../apps/Shared/GolfTraceWireProtocol.swift)
  defines the current single-stream framed protocol.
- [`apps/GolfTrace/Sources/HighSpeedTransport/HighSpeedVideoReceiver.swift`](../apps/GolfTrace/Sources/HighSpeedTransport/HighSpeedVideoReceiver.swift)
  receives and decodes the stream.
- [`apps/GolfTrace/Sources/PoseDetector.swift`](../apps/GolfTrace/Sources/PoseDetector.swift)
  schedules Apple Vision body-pose requests and drops stale input while an inference is
  already running.
- [`apps/GolfTrace/Sources/LiveSwingPipeline.swift`](../apps/GolfTrace/Sources/LiveSwingPipeline.swift)
  moves pose, motion, session, and metric work away from the main actor and publishes
  bounded UI snapshots.
- [`apps/GolfTrace/Sources/SwingMotionAnalyzer.swift`](../apps/GolfTrace/Sources/SwingMotionAnalyzer.swift)
  tracks the midpoint of the wrists. It explicitly does not claim to track the club head.
- [`apps/GolfTrace/Sources/SwingSessionDetector.swift`](../apps/GolfTrace/Sources/SwingSessionDetector.swift)
  detects one motion session using hand stillness and speed.
- [`apps/GolfTrace/Sources/SwingMetricsAnalyzer.swift`](../apps/GolfTrace/Sources/SwingMetricsAnalyzer.swift)
  produces current two-dimensional, body-normalized measurements and evidence.
- [`apps/GolfTrace/Sources/Analysis/SwingEvidencePacket.swift`](../apps/GolfTrace/Sources/Analysis/SwingEvidencePacket.swift)
  records metric, phase, confidence, provenance, availability, and limitation data for the
  AI boundary.

The current pipeline is a useful vertical slice, but its domain model is coupled to Apple
frameworks:

- `PoseFrame` exposes `VNHumanBodyPoseObservation.JointName` and `CMTime`.
- `SwingMetricsAnalyzer` consumes the concrete `PoseFrame`.
- current phase marker IDs are strings, and only Address, estimated Top, estimated Impact,
  and sometimes Finish are emitted.
- the eight storyboard slots in
  [`apps/GolfTrace/Sources/Records/SwingRecordArtifacts.swift`](../apps/GolfTrace/Sources/Records/SwingRecordArtifacts.swift)
  are presentation slots, not a canonical motion-phase model.
- the current camera setting supports Face-On and Down-The-Line, but the transport and live
  pipeline have one primary high-speed source.

These are extension constraints, not reasons to replace the working pipeline.

## 2. Architectural principles

1. **Evidence before interpretation.** A detector may return unavailable or partial data.
   It must not manufacture a phase or metric to fill a UI slot.
2. **Vendor-neutral domain.** Motion types must not import Vision, SwiftUI, AppKit,
   AVFoundation, or any launch-monitor provider.
3. **Camera-independent computation.** Every frame carries its source and viewpoint.
   Algorithms declare which viewpoints and calibration levels they require.
4. **Explicit dimensionality.** A projected 2D proxy must never be named or presented as a
   true 3D body rotation.
5. **Phase-addressable results.** Metrics may describe a point phase, a phase-to-phase
   interval, or an entire swing.
6. **Reproducible results.** Detector, model, calibration, and algorithm versions are part
   of provenance.
7. **One-way dependencies.** Capture adapters feed the domain; metrics and coaching consume
   the domain. The domain never reaches into UI, persistence, or hardware.
8. **Incremental migration.** Existing replay, record schema, wire protocol, and UI continue
   to work until an explicit migration milestone replaces an adapter.

## 3. Target module boundaries

The following is the intended destination structure. Milestone 1 creates only the minimal
domain contracts selected by the roadmap; empty folders and speculative implementations
should not be added.

```text
apps/GolfTrace/Sources/
  MotionEngine/
    Domain/
      MotionCameraSource.swift
      MotionTime.swift
      SkeletonModels.swift
      SwingPhase.swift
      MotionMetricModels.swift
      MotionEvidence.swift
    Pose/
      PoseDetectorProtocol.swift
      VisionPoseDetectorAdapter.swift
      PoseSequenceNormalizer.swift
    Skeleton/
      SkeletonTopology.swift
      SkeletonSmoother.swift
      SkeletonFusion.swift
    Phase/
      SwingPhaseDetectorProtocol.swift
      PhaseEvidenceValidator.swift
    Metrics/
      MotionMetricCalculator.swift
      ShoulderTurnCalculator.swift
      ChestTurnCalculator.swift
      PelvisTurnCalculator.swift
      XFactorCalculator.swift
      HeadMovementCalculator.swift
      SideBendCalculator.swift
      HipDepthCalculator.swift
      SwayCalculator.swift
      EarlyExtensionCalculator.swift
    Coaching/
      CoachingObservationBuilder.swift
      CoachingEvidenceModels.swift
    Pipeline/
      MotionAnalysisPipeline.swift
      MultiCameraSynchronizer.swift
      MotionAnalysisResult.swift
```

Responsibilities:

| Layer | Owns | Must not own |
|---|---|---|
| Domain | stable identifiers, coordinates, time, skeleton, phase, metrics, provenance | Apple Vision types, views, files, network calls |
| Pose | detector adapters and raw joint confidence | swing judgment, launch data, UI strings |
| Skeleton | topology, normalization, smoothing, optional multi-view fusion | coaching advice |
| Phase | evidence-backed phase candidates and sequence validation | storyboard layout |
| Metrics | deterministic calculations from skeletons, phases, and calibration | UI thresholds or player-quality labels |
| Coaching | structured observations derived from available evidence | pose inference or provider credentials |
| Pipeline | orchestration, cancellation, back-pressure, source synchronization | dashboard state |

The existing source files remain in place while adapters are introduced. Moving large files
is not part of Milestone 1.

## 4. Core data model

The examples below describe the long-term semantics. Milestone 1 uses the compact contracts
in
[`apps/GolfTrace/Sources/MotionEngine/MotionAnalysisContracts.swift`](../apps/GolfTrace/Sources/MotionEngine/MotionAnalysisContracts.swift);
the exact implemented type map appears in section 13.

### 4.1 Camera source and viewpoint

```swift
struct MotionCameraSourceID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String
}

enum MotionCameraViewpoint: Codable, Hashable, Sendable {
  case faceOn
  case downTheLine
  case custom(String)
}

struct MotionCameraSource: Codable, Equatable, Sendable {
  let id: MotionCameraSourceID
  let viewpoint: MotionCameraViewpoint
  let nominalFrameRate: Double?
  let imageSize: MotionImageSize?
  let calibration: MotionCameraCalibration?
}
```

Source identity and viewpoint are separate. Two Face-On cameras still have different source
IDs. A source may change orientation or calibration over time, so a frame also records the
configuration revision used to interpret it.

The existing `GolfCameraView` in
[`apps/Shared/GolfPracticeSettings.swift`](../apps/Shared/GolfPracticeSettings.swift) is a
user-selected practice setting. An adapter may map it to `MotionCameraViewpoint`, but the
motion engine should not use a display setting as proof of camera calibration.

### 4.2 Time

Wall-clock time, media presentation time, and a swing-relative offset are different clocks:

```swift
struct MotionTimestamp: Codable, Equatable, Comparable, Sendable {
  let sourceTimeNanoseconds: Int64
  let clockID: String
}

struct SwingRelativeTime: Codable, Equatable, Sendable {
  let millisecondsFromSwingStart: Int
}
```

Each source retains its native monotonic timestamp. A synchronization result maps source
time into a session clock and reports uncertainty. Algorithms must not compare timestamps
from two sources until that mapping exists.

### 4.3 Skeleton

```swift
struct MotionJointID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String
}

enum MotionCoordinateSpace: Codable, Equatable, Sendable {
  case imageNormalized2D
  case cameraMeters3D
  case worldMeters3D
  case bodyNormalized3D
}

struct MotionJointSample: Codable, Equatable, Sendable {
  let id: MotionJointID
  let position: MotionVector
  let confidence: Double
  let visibility: MotionJointVisibility
}

struct MotionSkeletonFrame: Codable, Equatable, Sendable {
  let sourceID: MotionCameraSourceID
  let timestamp: MotionTimestamp
  let coordinateSpace: MotionCoordinateSpace
  let joints: [MotionJointSample]
  let detectorProvenance: MotionAlgorithmProvenance
  let limitations: [MotionLimitation]
}
```

The neutral joint vocabulary contains stable anatomical `MotionJointID` constants, not
Vision identifiers. The Apple Vision adapter uses an explicit revisioned mapping table and
omits unknown or unsupported joints. Mapping changes require a new mapping version and
focused compatibility tests. Absence is different from a coordinate of zero.

Confidence describes detector evidence, not whether a golfer's movement is good. Consumers
may require different confidence floors, and the floor used must be recorded in the metric
provenance.

### 4.4 Calibration and dimensionality

```swift
enum MotionDimensionality: String, Codable, Sendable {
  case projected2D
  case estimatedDepth
  case reconstructed3D
}

enum MotionCalibrationLevel: String, Codable, Sendable {
  case none
  case bodyNormalized
  case singleCameraGeometric
  case synchronizedMultiCamera
}
```

Every metric declares both. `reconstructed3D` requires calibrated multi-view geometry or
another validated depth source; it cannot be inferred merely because a pose API returns a
third coordinate.

## 5. Pose detection interface

Pose detection converts a camera frame into observations. It does not determine swing phases
or coaching.

```swift
protocol PoseDetecting: Sendable {
  var descriptor: PoseDetectorDescriptor { get }

  func detectPose(
    in frame: MotionVideoFrame
  ) async throws -> PoseDetectionResult
}

struct PoseDetectionResult: Sendable {
  let sourceID: MotionCameraSourceID
  let timestamp: MotionTimestamp
  let skeletons: [MotionSkeletonFrame]
  let processingDuration: Duration
  let droppedInputCount: Int
}
```

Required behavior:

- retain the frame's source, orientation, timestamp, and detector version;
- support cancellation and latest-frame back-pressure for live work;
- return no skeleton when evidence is insufficient;
- never substitute the previous pose without marking it as interpolated;
- allow offline analysis to use every frame even if live analysis drops stale frames;
- keep detector-specific keys inside its adapter.

`PoseDetector` already implements a useful latest-frame scheduler. The first adapter should
wrap or translate its output, not duplicate the Vision request or change its scheduling.

The Milestone 1 Apple Vision adapter accepts a `PoseFrame` plus source-only
identity/session/viewpoint context. Timestamp and orientation come exclusively from the
exact frame, and Vision output is identified as normalized image-space 2D. Invalid,
non-finite, or negative media time fails conversion; the adapter does not substitute a
default timestamp or accept caller-supplied coordinate/orientation metadata.

## 6. Skeleton processing

Skeleton processing is a sequence of explicit, testable transforms:

```text
detector observation
  -> joint-vocabulary mapping
  -> orientation transform
  -> confidence filtering
  -> temporal smoothing
  -> optional gap interpolation
  -> body normalization
  -> optional calibrated multi-view fusion
```

Each transform appends provenance. Interpolation must record the original neighboring
frames, duration of the gap, and confidence penalty. Long gaps remain unavailable.

Multi-camera fusion consumes synchronized observations and calibration. It produces a new
derived source identity rather than overwriting either camera's skeleton. This preserves the
ability to audit Face-On and Down-The-Line evidence independently.

## 7. Canonical swing phases

The domain order is:

```swift
enum GolfSwingPhase: String, CaseIterable, Codable, Sendable {
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
}
```

This enum is implemented and its exact order is tested. It is a vocabulary, not evidence
that every phase was observed. The current live pipeline still emits only Address, estimated
Top, estimated Impact, and sometimes Finish through its legacy path. Full live ten-phase
detection, confidence calibration, and validation remain later algorithm work.

Definitions must be versioned in the detector documentation. At minimum, a definition states
the anatomical or club evidence used, camera requirements, and ambiguity policy. For
example, Impact cannot be considered measured if the implementation only observes the
hands returning near their address height.

The current domain observation contract can carry evidence from a future detector:

```swift
struct SwingPhaseObservation: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let phase: GolfSwingPhase
  let sourceID: MotionCameraSourceID
  let viewpoint: MotionCameraViewpoint
  let sourceTimeSeconds: Double
  let confidence: Double
  let provenance: MotionValueProvenance
  let limitations: [String]
}
```

A future sequence validator must check ordering and incompatible duplicates without
inventing missing phases. A result containing Address, Top, and Finish is valid partial
evidence. The UI may render placeholders, but placeholders never become observations.

The current eight-slot storyboard remains a separate presentation model. During migration,
an explicit adapter may map available canonical phases to storyboard slots. It must preserve
the original phase and provenance; for example, `P3` must not silently become a generic
`backswing` measurement.

## 8. Motion metric interface

The implemented calculator boundary is:

```swift
protocol MotionMetricCalculating: Sendable {
  var supportedMetricIDs: Set<MotionMetricID> { get }

  func calculateMetrics(
    in input: MotionAnalysisInput,
    phases: [SwingPhaseObservation]
  ) throws -> [MotionMetricReading]
}
```

The implemented compact result is evidence-bearing and phase-addressable:

```swift
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
}
```

The compact Milestone 1 `MotionMetricReading` rejects incoherent states both in its throwing
initializer and custom `Decodable` path:

- any present value, both time-range endpoints, and confidence must be finite;
- confidence must be in `0...1`;
- the time range must be nonnegative and ordered from start to end;
- `.available` and `.limited` require a value and forbid `unavailableReason`;
- `.unavailable` requires a `nil` value and a nonempty reason bounded to 512 UTF-8 bytes.

There is no crash-path coercion or silent clamping. Structurally decodable persisted inputs
that violate these invariants fail with `DecodingError.dataCorrupted`; missing fields and
type mismatches retain their native decoding errors. Thresholds used for coaching or
comparison belong to a versioned coaching/profile layer, not the calculator.

### 8.1 Planned metrics and evidence requirements

| Metric | Meaning | Useful single-camera evidence | Requirement for a true 3D value |
|---|---|---|---|
| Shoulder Turn | axial orientation of the shoulder line relative to Address | projected shoulder-line or shoulder-span proxy, with the viewpoint in the metric name | calibrated 3D shoulder joints in a stable body/world frame |
| Chest Turn | axial orientation of the thorax | torso/shoulder projection proxy; not interchangeable with Shoulder Turn | validated thorax orientation from 3D landmarks |
| Pelvis Turn | axial orientation of the pelvis relative to Address | projected hip-line or hip-span proxy | calibrated 3D pelvis joints |
| X Factor | shoulder/chest turn minus pelvis turn at the same phase | only a clearly named projected difference when both proxies share one frame and method | shoulder/chest and pelvis rotations in the same 3D frame and timestamp |
| Head Movement | displacement from Address | Face-On is useful for lateral/vertical image-plane movement; scale by a stable body measure | calibrated 3D head center for lateral, vertical, and depth components |
| Side Bend | lateral flexion of the trunk | view-dependent projected torso angle, explicitly named 2D | trunk orientation in a player-relative 3D coordinate frame |
| Hip Depth | pelvis displacement relative to the Address hip-depth reference | Down-The-Line projected depth-line proxy when setup and framing are stable | calibrated pelvis depth in camera/world coordinates |
| Sway | lateral pelvis or torso displacement from Address | Face-On body-normalized lateral displacement | calibrated 3D displacement along the player/target axis |
| Early Extension | pelvis moving toward the ball line during downswing | Down-The-Line projected pelvis-to-reference-line change | calibrated pelvis motion toward the ball/stance reference plane |

No single-camera 2D value may drop the `projected2D` dimensionality or its viewpoint-specific
limitation. The initial product can still provide useful coaching from those proxies, but it
must describe what was observed rather than claim an unmeasured anatomical angle.

### 8.2 Phase access

The aggregate analysis result exposes both query styles:

```swift
result.metrics(matching: .pelvisTurn, at: .impact)
result.metric(
  .pelvisTurn,
  at: .impact,
  from: faceOnSourceID,
  viewpoint: .faceOn
)
result.metrics(for: .p6)
```

The all-match query returns every matching reading across sources. Singular lookup requires
an explicit source and viewpoint and therefore never silently selects the first camera.
These are read-only domain queries; they do not calculate on demand in a SwiftUI view.

## 9. Multi-camera pipeline

The engine treats cameras as a collection, not `camera1` and `camera2` fields:

```text
CaptureSource[ID]
  -> TimestampMapper[ID]
  -> PoseDetecting[ID]
  -> SkeletonSequence[ID]
                    \
                     -> Synchronizer -> optional SkeletonFusion
                    /
  -> Phase detectors (single-view and/or fused)
  -> Metric calculators selected by declared requirements
  -> MotionAnalysisResult
```

The source registry supports one Face-On stream, one Down-The-Line stream, two views of the
same kind, or future camera types. Analysis continues with one available camera. Losing one
source changes capabilities and confidence; it does not invalidate unrelated measurements.

Synchronization reports offset, drift, and uncertainty. A phase or cross-camera metric is
unavailable when uncertainty exceeds that algorithm's declared tolerance.

Adding a second live camera later requires transport/session work beyond this engine. The
existing wire protocol has one stream on one connection and should not be changed as a side
effect of adding domain types.

## 10. AI Coach boundary

The motion engine does not generate free-form advice. It emits structured coaching evidence:

```swift
struct CoachingObservation: Codable, Equatable, Sendable {
  let observationID: UUID
  let phase: GolfSwingPhase?
  let supportingMetricIDs: [MotionMetricReadingID]
  let statement: String
  let confidence: Double
  let limitations: [MotionLimitation]
}

struct CoachingHypothesis: Codable, Equatable, Sendable {
  let observationID: UUID
  let possibleCause: String
  let expectedBallFlight: String?
  let suggestedDrill: String
  let nextPracticeGoal: String
  let confidence: Double
}
```

The intended chain is:

```text
Observation
  -> Possible Cause
  -> Expected Ball Flight
  -> Suggested Drill
  -> Next Practice Goal
```

Rules:

- an observation must cite motion metric or launch-monitor evidence;
- a possible cause is a hypothesis, not a measurement;
- expected ball flight is omitted when launch or model evidence is insufficient;
- one recommendation may use multiple metrics, but every metric retains provenance;
- advice should prefer one actionable change and a measurable next practice goal;
- model output never overwrites measured data.

The existing
[`apps/GolfTrace/Sources/AICoach/AIGolfCoachModels.swift`](../apps/GolfTrace/Sources/AICoach/AIGolfCoachModels.swift)
already separates evidence, request context, advice, confidence, and limitations. Future
adapters should extend that boundary instead of putting prompt strings into metric
calculators. The evidence and safety requirements in
[`apps/GolfTrace/AI-SPEC.md`](../apps/GolfTrace/AI-SPEC.md) remain authoritative.

## 11. Persistence and aggregate boundaries

The long-term swing aggregate can reference:

- original and derived video assets by camera source;
- neutral skeleton sequences;
- joint-angle and motion-metric results;
- canonical phase observations;
- launch-monitor measurements;
- coach observations and hypotheses;
- practice notes, equipment, and environment;
- algorithm, model, calibration, and consent provenance.

Large frame sequences and videos should be stored as versioned artifacts with hashes, not
embedded repeatedly in the record JSON. The record stores descriptors and integrity links.
Schema migrations must be forward-readable and preserve unknown metric/provider IDs.

Milestone 1 does **not** change `SwingRecord.currentSchemaVersion`, the on-disk layout managed
by [`apps/GolfTrace/Sources/Records/SwingRecordStore.swift`](../apps/GolfTrace/Sources/Records/SwingRecordStore.swift),
or existing replay artifacts.

## 12. Extension points

### New pose model

Implement `PoseDetecting`, map its joint vocabulary to neutral IDs, declare coordinate space
and version, then run the shared conformance tests. No metric or UI rewrite is required.

### New camera

Register another `MotionCameraSourceID`, a timestamp mapper, viewpoint, and calibration.
Single-view calculators become available immediately; fusion calculators wait for valid
synchronization and calibration.

### New phase algorithm

Implement the phase-detector protocol, emit candidates plus unavailable reasons, and assign
a versioned descriptor. Existing metrics select the phase result through declared
capabilities.

### New metric

Implement one calculator, define required joints/views/phases/calibration, publish a stable
metric ID and unit, and add fixture-based tests. The dashboard discovers presentable metrics
from result metadata in a later UI milestone.

### New coaching model

Consume structured observations and launch evidence. It cannot import or invoke the pose
detector directly.

## 13. Milestone 1 boundary

Milestone 1 is a foundation, not the feature set above.

Included:

- additive, Foundation-friendly identifiers and domain contracts in
  `apps/GolfTrace/Sources/MotionEngine/MotionAnalysisContracts.swift` for canonical swing
  phase, camera source/viewpoint, neutral skeletons, metric readings, availability,
  confidence, and provenance;
- protocol boundaries for pose detection, phase detection, and metric calculation where
  required by the roadmap;
- adapters that translate current types without changing the current live path;
- focused unit tests in
  `apps/GolfTrace/Tests/MotionAnalysisContractsTests.swift` for ordering, Codable round
  trips, no fabricated phase observations, multiple source identity, coherent metric
  construction and decode rejection, finite boundary states, invalid pose time, versioned
  joint mapping and unknown omission, source-aware metric queries, and explicit unavailable
  results.

The implemented Milestone 1 vocabulary is:

| Concern | Contract |
|---|---|
| camera identity and placement | `MotionCameraSourceID`, `MotionCameraViewpoint` |
| per-frame source provenance | `MotionFrameSourceContext` for caller-supplied identity, viewpoint, and mirroring; `MotionFrameContext` combines those with frame-derived source-local time, coordinate space, and rotation |
| neutral pose | stable `MotionJointID` constants, `MotionPoint`, `MotionJointSample`, `MotionSkeletonFrame` |
| canonical phases | `GolfSwingPhase`, `SwingPhaseObservation`, `SwingPhaseDetecting` |
| metric catalog and results | `MotionMetricID`, `MotionMetricUnitID`, `MotionMetricReading`, `MotionMetricCalculating` |
| truth and comparison boundary | `MotionValueProvenance`, `MotionMetricAvailability`, `MotionMetricComparisonScope`, `MotionMetricReadingValidationError`, bounded `unavailableReason`, and limitations |
| pose boundary | `PoseDetecting` with an associated platform frame input, plus `AppleVisionMotionSkeletonAdapter` as the current translation seam |
| Apple Vision adaptation | `AppleVisionMotionJointMappingVersion`, `AppleVisionMotionSkeletonAdapter`, and invalid-time rejection |
| aggregate | `MotionAnalysisInput`, `MotionAnalysisResult`, all-match queries, and source-plus-viewpoint-qualified singular metric lookup |
| coaching boundary | `MotionCoachEvidence`, `MotionCoachRequest`, `MotionCoachFeedback`, `MotionCoachServing` |

`AppleVisionMotionSkeletonAdapter` derives timestamp and orientation from the existing
`PoseFrame`, declares its Vision coordinates as normalized image-space 2D, and translates
only joints present in its explicit versioned map. M1 intentionally does not route
`LiveSwingPipeline` through that adapter yet; runtime migration remains a later step, which
is how M1 avoids changing capture or analysis behavior.

Excluded:

- replacing Apple Vision or `LiveSwingPipeline`;
- implementing or integrating full live ten-phase detection;
- implementing all nine requested motion metrics;
- claiming 3D motion from a single camera;
- adding a second wire stream or changing `GolfTraceWireProtocol`;
- changing storyboard behavior, dashboard layout, or AI prompts;
- migrating `SwingRecord` or existing files;
- changing capture, replay, persistence, or launch-monitor behavior.

Definition of Done:

1. Existing Mac and iPhone behavior is unchanged.
2. Domain contracts compile without SwiftUI/AppKit/Vision dependencies.
3. The canonical phase order is tested exactly as Address, Takeaway, P2, P3, Top,
   Transition, P6, Impact, Release, Finish without fabricating observations.
4. Camera source identity and viewpoint are independent fields; the current focused fixtures
   distinguish two source identities across different viewpoints.
5. Metrics support all-match lookup and source-plus-viewpoint-qualified singular lookup, so
   singular access cannot silently select the first source.
6. `MotionMetricReading` construction and decoding reject non-finite, out-of-range,
   contradictory, or overlong unavailable-reason states while retaining valid boundary
   values.
7. Current `PoseFrame` output converts deterministically through the versioned Apple Vision
   joint map, with invalid timestamps rejected.
8. The focused contract tests pass; real-device and full phase/metric validation remain
   separate acceptance work.

## 14. Milestone 2 shadow runtime slice

The first Milestone 2 slice is deliberately non-authoritative:

- every accepted `PoseFrame` is additionally translated by
  `AppleVisionMotionSkeletonAdapter` on the existing serial analysis queue;
- neutral frames are retained in a six-second ring with a 720-frame absolute ceiling;
- reset generations and mid-stream source/viewpoint/mirroring changes create a new stream
  identity and clear prior neutral frames;
- invalid, negative, or regressing source timestamps are rejected before mutating the ring;
- immutable snapshots are available for future analyzers, while latest-frame access reads
  the ring tail without copying the whole window;
- when a legacy swing completes, `MotionSkeletonSessionSlicer` selects the exact inclusive
  session time range once, validates frozen stream/source/viewpoint/coordinate-space/
  orientation/mirroring provenance and joint evidence, and returns a typed abstention rather
  than interpolating or relabelling incomplete evidence;
- the completion retains that immutable shadow result, so reconnect re-delivery never reads
  a reset or newer ring;
- legacy session detection, metrics, evidence, UI, persistence, replay, and coaching remain
  authoritative and unchanged.

This slice is not permission to poll full snapshots from SwiftUI or to publish neutral
metrics. Completion is the only downstream cadence introduced here. Before any analyzer
becomes authoritative, profile the adapter, ring, and slicer on real iPhone streams and
validate results against labeled Face-On and Down-The-Line fixtures.

## 15. Validation strategy after Milestone 1

Later algorithm milestones require more than unit tests:

- deterministic fixture clips for Face-On and Down-The-Line;
- frame-level human annotations with inter-rater agreement;
- occlusion, lighting, clothing, handedness, and camera-height strata;
- phase precision/recall and timestamp error, not only a whole-swing pass/fail;
- per-metric error against a calibrated reference system;
- confidence calibration and abstention tests;
- real-device performance at target capture rates;
- regression checks that UI snapshots never trigger analysis work.

Automated tests are not evidence that a real swing, camera placement, or three-dimensional
metric is accurate. Product claims must follow the dimensionality and validation level that
the recorded provenance supports.
