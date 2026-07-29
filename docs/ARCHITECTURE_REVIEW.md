# GolfTrace Architecture Review

## Scope and review method

This review covers the GolfTrace product only:

- `apps/GolfTrace/` — the macOS analysis, replay, history, launch-monitor, and coaching application.
- `apps/GolfTraceCamera/` — the iPhone high-speed capture application.
- `apps/Shared/` — the local wire protocol, practice settings, and shared presentation assets.
- `tools/IPhoneMirror/` — an optional way to expose iPhone Mirroring pixels to the Mac. It is not a motion-data or launch-monitor API.

The repository also contains the GenieMax application, `ios-app/`, the root Swift package in
`Sources/`, and a Cloudflare Worker in `backend/`. Those systems are separate products today.
In particular, the Worker in `backend/src/index.ts` stores encrypted GenieMax blobs; GolfTrace
does not call it and should not inherit its schema or authentication assumptions by accident.

The findings below come from the checked-in source and tests. They do not claim that every
hardware path has passed current real-device acceptance testing. The project tracks those
remaining checks in `apps/GolfTrace/HARDWARE-UAT.md` and `apps/GolfTrace/MVP-STATUS.md`.

## Overall architecture

GolfTrace is currently a local-first, Apple-platform system with two cooperating executables:

```text
iPhone rear camera
  -> AVFoundation capture
  -> VideoToolbox H.264 encode
  -> Bonjour discovery + framed TCP stream
  -> Mac VideoToolbox decode
  -> Apple Vision 2D pose
  -> ordered motion/session/metric pipeline
  -> replay, storyboard, local swing history, and AI evidence

MLM2PRO
  -> CoreBluetooth
  -> device authorization/session codec
  -> structured launch measurement
  -> time-window match to a completed swing
  -> the same local swing record

Rapsodo iPhone screen
  -> macOS/iPhone Mirroring pixels
  -> optional visual source and replay asset
  -> no OCR and no claim that pixels are structured launch data
```

The Mac application is the composition root. `apps/GolfTrace/Sources/GolfTraceApp.swift`
constructs history, replay, stage recording, Rapsodo recording, launch-monitor, AI, settings,
and knowledge controllers, connects launch events to history, and injects those objects into
`ContentView`.

The architecture already separates many expensive operations from the main actor:

- `LiveSwingPipeline` owns ordered motion, session, and metric analysis on a serial queue and
  limits the UI projection to at most 30 updates per second.
- `PoseDetector` reuses a Vision request and intentionally analyzes the newest available frame
  instead of allowing stale frames to accumulate.
- Replay file operations and offline frame reading use actors or background queues.
- Record persistence uses atomic package-style writes and retention limits.

The main architectural limitation is not a missing framework. It is that several good
components are joined through concrete, UI-observable types rather than stable domain
contracts. That makes adding cameras, pose engines, launch-monitor providers, and richer
practice history harder than it needs to be.

## Folder structure

### Current structure

| Path | Current responsibility |
| --- | --- |
| `apps/GolfTrace/Sources/GolfTraceApp.swift` | macOS composition root and application lifecycle |
| `apps/GolfTrace/Sources/ContentView.swift` | main workspace, source layout, capture coordination, replay and sheets |
| `apps/GolfTrace/Sources/Dashboard/` | SwiftUI dashboard components, sheets, settings, theme, and stage views |
| `apps/GolfTrace/Sources/HighSpeedTransport/` | H.264 packet accumulation, receive, decode, and preview |
| `apps/GolfTrace/Sources/Analysis/` | evidence packets, storyboard export, offline frames, and replay-clock mapping |
| `apps/GolfTrace/Sources/Records/` | swing schema, artifacts, history controller, local store, and retention |
| `apps/GolfTrace/Sources/Replay/` | buffers, writers, recorders, synchronized replay bundle, playback, and export |
| `apps/GolfTrace/Sources/LaunchMonitor/` | MLM2PRO BLE integration, authorization, parsing, matching, and credentials |
| `apps/GolfTrace/Sources/AICoach/` | AI request models, controller, settings, OpenRouter client, and Whisper client |
| `apps/GolfTrace/Sources/Knowledge/` | reference-video ingestion, Apple Vision/OCR, MCP, and optional GX10 VLM |
| `apps/GolfTrace/Sources/Capture/` and `Audio/` | hands-free capture, voice commands, countdown, and swing cues |
| `apps/GolfTraceCamera/Sources/Camera/` | iPhone AVFoundation capture and supported high-speed profiles |
| `apps/GolfTraceCamera/Sources/Transport/` | VideoToolbox H.264 encoder and Bonjour/TCP sender |
| `apps/GolfTraceCamera/Sources/Orientation/` | physical device and scene orientation handling |
| `apps/Shared/GolfTraceWireProtocol.swift` | framed transport v1 and orientation/configuration packets |
| `apps/Shared/GolfPracticeSettings.swift` | club, camera view, guideline, coach, and audio preferences |

Both applications use XcodeGen. Their source-of-truth project files are
`apps/GolfTrace/project.yml` and `apps/GolfTraceCamera/project.yml`; generated `.xcodeproj`
files are not architecture inputs.

### Recommended target structure

The current folders should be evolved incrementally, not replaced:

```text
apps/GolfTrace/Sources/
├── App/
│   ├── Composition/
│   └── Workspace/
├── Capture/
│   ├── Sources/
│   ├── Synchronization/
│   └── Recording/
├── MotionEngine/
│   ├── Domain/
│   ├── Pose/
│   ├── Skeleton/
│   ├── Phases/
│   ├── Metrics/
│   └── Adapters/AppleVision/
├── LaunchMonitor/
│   ├── Domain/
│   ├── Providers/MLM2PRO/
│   ├── Matching/
│   └── Credentials/
├── Coaching/
│   ├── Domain/
│   ├── Evidence/
│   ├── Planning/
│   └── Providers/
├── Practice/
│   ├── Domain/
│   ├── Persistence/
│   ├── History/
│   └── Comparison/
└── Presentation/
    ├── Dashboard/
    ├── Replay/
    └── Settings/
```

This is a responsibility map, not a request for a bulk file move. New work should enter through
these seams, and existing code should migrate only when a feature touches it.

## Frontend architecture

The frontend is native SwiftUI on macOS. `GolfTraceApp` creates one hidden-title-bar window and
injects long-lived controllers into `ContentView`. The current dashboard is optimized for the
two-source workflow: a high-speed swing camera beside Rapsodo/iPhone Mirroring, a shared
timeline, replay, history, hands-free controls, settings, and AI Golf Pro.

The UI has useful extracted components in `Sources/Dashboard/`, including
`VideoStageViews.swift`, `AdaptivePhaseStrip.swift`, and `SettingsPanels.swift`. Theme tokens
are centralized in `GolfTraceTheme.swift`, which is the right base for a clean tablet-oriented
design language.

However, `ContentView.swift` is still the de facto workspace coordinator. It owns camera,
voice, capture, screen evidence, Rapsodo/iPhone Mirroring, replay, launch-monitor, AI, history,
zoom/pan, source sizing, and sheet state. It also observes the concrete
`LaunchMonitorController`. `DashboardSheets.swift` similarly carries substantial history and
review behavior. These files are extension risks because a provider or workflow change can
invalidate a large SwiftUI tree.

Recommended direction:

1. Keep high-frequency camera state in its existing narrow observable projection
   (`CameraLiveState`), not in the root dashboard.
2. Introduce small feature view models for Live Practice, Review, Coach, and History.
3. Expose domain snapshots and commands to the views; do not expose Vision, CoreBluetooth,
   provider-specific authorization, or file-store types.
4. Treat split-screen as a layout policy over source identifiers, rather than hard-coding a
   Rapsodo pane and a camera pane.
5. Reuse one design system across macOS and a future iPad client, while allowing platform-
   specific capture and window adapters.

## Backend architecture

GolfTrace has no first-party backend today. Capture, pose analysis, session detection, replay,
history, launch matching, and most evidence generation run on the Mac. This is a strength for
latency and privacy, but it means the future "one login, one dashboard" product has no account,
sync, roster, subscription, or multi-device data service yet.

The root `backend/` directory must not be described as the GolfTrace backend. Its routes and D1
schema serve a separate encrypted health-data product.

When a GolfTrace backend becomes necessary, it should begin as a narrow synchronization and
identity boundary:

- stable user/player/practice/swing identifiers;
- encrypted metadata and asset manifests;
- resumable media upload with explicit retention;
- schema-version and provenance preservation;
- account deletion/export;
- conflict-aware sync for offline practice;
- server authorization separate from launch-provider authorization.

Raw high-frame-rate video should remain local by default. Cloud upload should be opt-in and
policy-driven. AI inference should not require a cloud round trip for live capture correctness.

## AI pipeline

The current AI path is evidence-first:

1. `SwingMetricsAnalyzer` creates bounded 2D measurements and explicit unavailable/limited
   results instead of fabricating values.
2. `SwingEvidencePacket` in `Sources/Analysis/SwingEvidencePacket.swift` records timeline
   samples, metrics, phase markers, provenance, confidence, limitations, and requested audit
   frames.
3. `GolfCoachRequestContext` in `Sources/AICoach/AIGolfCoachModels.swift` combines swing
   evidence, optional structured launch data, selected practice settings, and cited knowledge.
4. `AIGolfProController` calls configured AI services and falls back to local advice when the
   external path is unavailable.
5. Reference knowledge can pass through YouTube MCP, Apple Vision/OCR, and an optional GX10 VLM
   adapter before reaching the coaching prompt.

`apps/GolfTrace/AI-SPEC.md` defines important provenance, rights, failure, evaluation, and
guardrail requirements. The next architecture should preserve that contract.

Current gaps:

- AI launch evidence is named specifically for Rapsodo rather than a provider-neutral source.
- Advice has focus, evidence, drill, confidence, and limitations, but does not yet model the
  complete chain: observation, possible cause, expected ball flight, drill, and next goal.
- Advice and practice goals are not durable, phase-addressable history entities.
- The AI layer still assembles parts of its model from current presentation/settings types.

The AI coach should consume a versioned `SwingAnalysisSnapshot`, never raw view state. It should
produce a structured coaching plan whose claims cite metric IDs, phase IDs, source IDs, and
confidence. Speech and chat text should be renderings of that plan, not the source of record.

## Video pipeline

### Direct iPhone path

`apps/GolfTraceCamera/Sources/Camera/CameraService.swift` configures the rear camera and
negotiates available high-speed profiles. `HighSpeedH264Streamer` uses VideoToolbox, bounds
encode/network work, discovers the Mac with Bonjour, and sends AVCC H.264 over TCP.
`apps/Shared/GolfTraceWireProtocol.swift` defines packet framing, H.264 configuration, practice
settings, and per-stream orientation.

On macOS, `HighSpeedVideoReceiver` listens for the service, parses packets, decodes H.264, and
publishes sample buffers. `CameraCaptureModel` also supports an AVFoundation/Continuity Camera
fallback. It forwards frames to `PoseDetector` and `LiveSwingPipeline`.

The protocol is currently one logical primary high-speed stream. `LiveSwingCaptureContext` has
a source ID and camera-view string, which is a useful seed, but there is no source registry,
cross-camera clock model, or multi-stream analysis session.

### Replay and visual companion path

Replay is intentionally split by evidence role:

- camera H.264 buffering/writing for analysis-quality material;
- `GolfTraceStageReplayRecorder` for what the user saw in the full workspace;
- `RapsodoSourceReplayRecorder` for independent companion pixels;
- `SwingReplayBundle` plus per-asset clock calibration for synchronized playback when evidence
  quality permits it.

The Rapsodo screen is a visual companion. `IPhoneMirroringCaptureModel.swift`,
`RapsodoScreenMirrorModel.swift`, and `tools/IPhoneMirror/` do not expose structured metrics.
Structured launch values enter separately through a launch-monitor provider.

### Multi-camera extension

Additional cameras should be modeled as independent `VideoSource` instances with:

- stable source ID and role;
- viewpoint (`faceOn`, `downTheLine`, or future calibrated/custom view);
- intrinsic dimensions, orientation, frame rate, and clock metadata;
- independent health and quality state;
- a synchronization transform into the swing-session clock.

Pose detection should run per source. Fusion, if introduced, must be a separate optional stage
that consumes synchronized source observations. No motion metric should assume that a launch
monitor or a second camera exists.

Transport security is a known gap: the direct stream is trusted-LAN TCP without TLS or peer
authentication. Device pairing, authenticated transport, and replay protection should be
added before use on untrusted networks.

## State management

GolfTrace currently uses a pragmatic mix:

- `ObservableObject` and `@Published` for UI-facing controllers;
- `@StateObject`, `@ObservedObject`, and `@State` in SwiftUI;
- serial dispatch queues for capture, transport, pose, and ordered analysis;
- actors for selected file/network operations;
- Combine publishers for launch-monitor and controller events.

This works, and the split between `CameraCaptureModel` and high-frequency `CameraLiveState`
shows the correct performance instinct. The weakness is ownership at the application boundary:
`ContentView` knows too many concrete controllers and coordinates too many workflows.

Recommended state model:

- immutable, `Sendable` domain snapshots;
- explicit commands for capture, review, coach, and provider actions;
- one session coordinator that owns the current swing lifecycle;
- per-feature observable projections;
- typed domain events for completed swing, launch measurement, replay readiness, and coaching
  completion;
- no UI observation of provider-specific connection states.

This does not require adopting a third-party architecture framework. It requires moving
coordination behind interfaces as features are touched.

## Database and persistence

There is no database in the current GolfTrace runtime. `SwingRecordStore` persists each swing
as an application-support package under `GolfTrace/Swings/<record-id>/` with `record.json`,
replay assets, bundle manifests, and storyboard images. Writes are atomic, damaged records can
be quarantined, and retention defaults to 20 swings or 4 GiB. Pending unmatched launch shots
also have durable local storage.

`SwingRecord` schema version 4 currently includes:

- a session summary;
- normalized hand-trace points;
- replay filename and/or replay bundle;
- optional launch match;
- optional storyboard/artifact metadata;
- extensible metadata values.

This is a sound local package format but not yet the long-term aggregate requested by the
product vision. Skeleton samples, joint angles, phase-indexed metrics, coaching plans, notes,
equipment, environment, player identity, and practice-session identity need explicit versioned
models. Putting all of them into the generic metadata dictionary would create hidden schema
debt.

Recommended persistence evolution:

1. Keep the asset package and atomic file semantics.
2. Introduce a `SwingRepository` interface before choosing SQLite or a cloud database.
3. Add explicit versioned manifests for analysis, launch, coaching, and practice context.
4. Preserve provenance and model version on every derived result.
5. Add deterministic migrations and round-trip fixtures before changing stored records.
6. Add indexes only when history queries exceed what the package catalog can serve.

A future database should index summaries and relationships; immutable media and evidence
artifacts should remain content-addressed files/object storage.

## API flow

GolfTrace currently has four distinct integration boundaries:

| Boundary | Flow | Contract |
| --- | --- | --- |
| iPhone camera to Mac | local Bonjour/TCP | `apps/Shared/GolfTraceWireProtocol.swift` |
| MLM2PRO to Mac | CoreBluetooth GATT plus authorized session messages | `Sources/LaunchMonitor/MLM2PRO*` |
| AI provider | HTTPS request/response | `Sources/AICoach/DSV4GolfCoachClient.swift` and OpenRouter settings/models |
| Knowledge services | local MCP and optional GX10 HTTP endpoints | `Sources/Knowledge/` and `GX10WhisperClient.swift` |

The primary completed-swing flow is:

```text
camera frame
  -> pose frame
  -> motion/session/metrics
  -> completed SwingEvidencePacket
  -> SwingRecord + replay/artifacts
  -> nearest eligible launch measurement
  -> optional GolfCoachRequestContext
  -> structured advice
```

There is no public GolfTrace REST or GraphQL API, no account API, and no launch-provider
registry. The first stable APIs should be in-process domain protocols. A network API should be
introduced only when login/sync requires one.

## Current strengths

- High-speed capture, encoding, transport, decode, and analysis are bounded to protect live
  latency.
- Motion analysis is already independent of launch-monitor availability at runtime.
- Evidence carries source, confidence, availability, and limitations.
- The product distinguishes structured MLM2PRO data from visual Rapsodo pixels.
- Replay supports independent assets and explicit clock uncertainty rather than pretending
  unsynchronized media is exact.
- Local persistence is atomic, recoverable, retention-aware, and extensively tested.
- The code has meaningful protocol seams for parsers, HTTP transport, replay export, and
  storyboard export.
- Credentials are stored in Keychain rather than source or `.env`.
- Storyboard code refuses to invent unsupported phases or images.
- Existing tests cover transport parsing, motion/session/metrics, replay, record storage,
  launch parsing/matching, AI models, and knowledge adapters.

## Technical debt

### High priority

- `ContentView` and several dashboard files combine presentation and workflow orchestration.
- The UI observes the concrete MLM2PRO `LaunchMonitorController`.
- Launch connection state, events, AI evidence, and persisted shots contain provider-specific
  names or assumptions.
- Legacy live metrics still depend directly on Vision joint identifiers and Apple media
  time. Accepted poses now also pass through the neutral adapter into a bounded shadow
  skeleton window. A pure completion-scoped slicer validates exact time boundaries and
  frozen provenance once per completed swing, but no UI, persistence, phase detector,
  metric calculator, or coach path consumes that shadow evidence yet.
- The additive domain contracts define the canonical ten-phase vocabulary, but the live path
  still emits partial string-based phase evidence and the eight-slot storyboard remains a
  presentation model. Full live ten-phase detection is neither integrated nor validated.
- Only one primary high-speed camera stream is modeled.
- GolfTrace macOS tests and GolfTraceCamera iOS build/tests now run in the dedicated
  `.github/workflows/golftrace-ci.yml`; physical iPhone, camera, Bluetooth, and MLM2PRO UAT
  remain outside CI.

### Medium priority

- Large source files increase review and regression risk.
- Current metrics are projected 2D proxies, but future metric names could be misread as true 3D
  rotation without a capability/claim taxonomy.
- Launch matching uses a wall-clock nearest window rather than a unified event clock.
- Local packages do not yet express player, practice session, coach plan, equipment, or
  environment as first-class entities.
- The direct camera transport lacks authentication and encryption.
- Optional AI/knowledge clients have no shared provider health, budget, or retry abstraction.

### Product-validation debt

- Current build paths still require real-device UAT for sustained capture/reconnect and
  provider authorization.
- Full ten-phase detection is not validated.
- Club shaft/head and confirmed ball impact are not measured by the current pose engine.
- Shoulder/chest/pelvis turn and X-factor cannot be presented as calibrated 3D quantities from
  one uncalibrated 2D view.

## Suggested architecture improvements

1. **Adopt the canonical contracts added in Milestone 1.** Keep their framework-neutral
   identity guarantees as runtime paths migrate.
2. **Route current implementations through the tested adapters.** Preserve Apple Vision, the
   current live pipeline, and MLM2PRO behavior while moving composition to the new
   boundaries.
3. **Move orchestration out of views.** Introduce a practice-session coordinator and narrow
   feature view models without a broad UI rewrite.
4. **Version the swing aggregate.** Add explicit analysis, launch, coaching, practice,
   equipment, and environment manifests with migrations.
5. **Create a camera-source registry and clock domain.** Support multiple independent sources,
   then add optional synchronization and fusion.
6. **Make phase and metric capabilities explicit.** A metric declares required view,
   dimensionality, minimum joints, calibration needs, confidence, and limitation.
7. **Make launch monitoring provider-neutral end to end.** UI consumes a façade; provider
   adapters own discovery, credentials, parsing, and provider errors.
8. **Structure coaching output.** Persist observation, possible cause, expected ball flight,
   drill, and next goal, all linked to evidence and phase.
9. **Add GolfTrace CI lanes.** Generate both Xcode projects, build macOS and iOS Simulator
   targets, run tests, and lint changed Swift files.
10. **Preserve local-first operation.** Add account/sync later behind repository protocols and
    explicit privacy controls.

## Natural placement of future modules

| Future module | Natural location | Input | Output | Boundary rule |
| --- | --- | --- | --- | --- |
| Motion Analysis | `Sources/MotionEngine/Metrics/` | normalized skeleton sequence, view, phases | versioned metric readings by phase | no SwiftUI, provider, or persistence imports |
| Skeleton Detection | `Sources/MotionEngine/Pose/` and `Adapters/AppleVision/` | frames from one camera source | vendor-neutral skeleton frames | Vision names stop at the adapter |
| Swing Phase Detection | `Sources/MotionEngine/Phases/` | synchronized skeleton/motion features | canonical phase events with confidence | missing phases remain missing |
| AI Coach | evolve `Sources/AICoach/` toward `Sources/Coaching/` | swing snapshot, launch snapshot, practice goal, cited knowledge | structured coaching plan | no raw view state; every claim cites evidence |
| Launch Monitor Abstraction | `Sources/LaunchMonitor/Domain/` and `Providers/` | provider events | provider-neutral status/capabilities/measurements | UI never imports a provider implementation |
| Practice History | evolve `Sources/Records/` toward `Sources/Practice/` | sessions, swings, assets, notes, goals | history, trends, comparisons | repository interface owns storage choice |

## Milestone 1 boundary

The implemented Milestone 1 contract slice is deliberately additive:

- introduce canonical, framework-neutral motion domain contracts;
- define the ten ordered swing phases: Address, Takeaway, P2, P3, Top, Transition, P6,
  Impact, Release, and Finish;
- identify camera source and viewpoint independently so Face-On and Down-the-Line records do
  not collide and future cameras remain representable;
- define reusable skeleton, metric, phase-detector, pose-detector, and metric-calculator
  contracts;
- derive neutral Apple Vision frame time, orientation, and normalized coordinate context from
  each `PoseFrame`, reject invalid media time, and map only explicitly supported joints
  through a versioned table of stable neutral constants;
- expose all-match metric queries plus source-plus-viewpoint-qualified singular lookup so a
  multi-camera result never silently chooses its first matching source;
- reject incoherent `MotionMetricReading` construction and decoding, including non-finite
  values/time/confidence, invalid confidence or time ranges, and contradictory
  availability/value/reason combinations; bound required unavailable reasons;
- introduce provider-neutral launch-monitor identity, typed capability-unavailability reason,
  status detail/recovery, failure, associated-value trust action, measurements, and provider
  interface;
- envelope provider events with a process-local `eventStreamID` and monotonically increasing
  sequence, plus a cursor that rejects zero-sequence, wrong-stream, duplicate, and
  out-of-order envelopes;
- represent durable launch-measurement deduplication identity as a structured value rather
  than delimiter-concatenated text;
- add compatibility adapters or mappings for the current Apple Vision/MLM2PRO types;
- test ordering without fabricated observations, serialization, source separation, metric
  invariant/decode rejection, invalid pose time, versioned joint mapping/omission,
  source-aware metric lookup, typed/redacted provider mapping, event sequencing/stale
  rejection, and deduplication field-boundary collisions.

Milestone 1 does **not** switch the UI or composition root to the new provider façade:
`GolfTraceApp`, dashboard, and settings still use the concrete `LaunchMonitorController`.
It also does not implement the full live ten-phase detector, change the stored `SwingRecord`
schema, change the camera wire protocol, move files in bulk, add another provider, add
login/cloud services, or alter capture/replay behavior. Those are later, separately
reviewable milestones.
