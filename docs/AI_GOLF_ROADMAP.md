# AI Golf Coach Roadmap

## Vision

GolfTrace should become one integrated AI Golf Coach product:

- one identity;
- one dashboard;
- one practice history;
- one evidence model shared by video, motion, launch data, and coaching;
- one workflow from capture to the next practice goal.

The goal is not to reproduce another company's interface or proprietary model. GolfTrace's
advantage should come from joining four domains that are often separated:

```text
Motion + Launch Monitor + AI Coach + Practice Management
```

Numbers are useful only when they improve the next swing. The product loop is therefore:

```text
capture
  -> trustworthy observation
  -> possible cause
  -> expected ball flight
  -> one suggested drill
  -> one next practice goal
  -> measured follow-up
```

The long-term product may use multiple devices as capture nodes, but a golfer should experience
one product, one login, and one dashboard rather than managing unrelated applications.

## Current status

The current GolfTrace implementation already provides a credible local-first base:

- iPhone rear-camera capture with high-speed profiles;
- hardware H.264 encode, Bonjour/TCP transport, and Mac decode;
- Continuity Camera fallback;
- Apple Vision 2D skeleton overlay;
- ordered hand-motion, swing-session, and bounded 2D metric analysis;
- hands-free commands, countdown/tempo components, and spoken feedback;
- full-stage and camera replay infrastructure, synchronized companion PIP when calibration
  quality permits it, and adaptive storyboard artifacts;
- local practice history with retention and recovery;
- MLM2PRO BLE parsing, authorized session flow, and time-window matching;
- evidence-first AI requests, local fallback advice, cited knowledge, and optional external AI;
- explicit provenance and limitations.

Important current limits:

- the Mac app and iPhone camera are two cooperating executables and there is no login;
- only one primary high-speed camera stream is active;
- motion output is uncalibrated 2D, not a full 3D biomechanics engine;
- the canonical ten-phase vocabulary now exists in additive domain contracts, but the live
  pipeline still emits only partial legacy phase evidence and full validated ten-phase
  detection is not implemented;
- launch-monitor UI/state is tied to MLM2PRO;
- Rapsodo Mirroring is pixels for visual review, not structured metric extraction;
- history is local package storage, not cross-device practice management;
- real-device acceptance remains required for current hardware/service paths.

## Architecture principles

### 1. Evidence before opinion

Every metric and coaching claim carries source, phase, camera view, confidence, model version,
and limitation. Missing evidence remains missing. The product must not infer launch values from
screen pixels or label an estimated wrist event as confirmed impact.

### 2. Domain contracts before providers

UI, history, and coaching consume GolfTrace domain models. Apple Vision, CoreBluetooth,
OpenRouter, MLM2PRO, Garmin, TrackMan, Foresight, Uneekor, and future SDKs remain adapters.

### 3. Motion is independent

The motion engine accepts camera frames/skeletons and works without a launch monitor. Launch
data enriches a swing after capture; it never gates pose analysis.

### 4. Multi-view by design

Every video, skeleton, phase, and metric is associated with a camera source and viewpoint.
Face-On and Down-the-Line are first-class. Additional synchronized or unsynchronized cameras
must not require changing metric interfaces.

### 5. Local-first, cloud-optional

Live capture, replay, and baseline coaching continue if the network or AI provider is offline.
Login/sync is added behind repositories, with explicit media upload and retention choices.

### 6. One aggregate, immutable evidence

One swing aggregate links video, skeleton, angles, metrics, launch measurements, coaching,
notes, equipment, and environment. Derived analysis can be recomputed, but its original
versioned evidence is never silently overwritten.

### 7. Small modules and reversible migration

New work enters behind contracts. Existing runtime paths migrate feature by feature. There is
no whole-app rewrite and no bulk folder move merely to match an ideal diagram.

### 8. Tablet-first presentation

The UI exposes progressive detail: live practice first, evidence on demand, and comparison when
requested. Source panels use adaptive split-screen layouts and shared controls instead of
provider-specific dashboards.

### 9. Measured performance

Live capture has explicit frame, latency, memory, and thermal budgets. Expensive segmentation,
reports, and comparison run after the swing unless a validated live use case requires them.

### 10. Authorized integrations only

Launch providers require an official SDK/API, documented interoperability path, or explicit
partner authorization. Credentials remain outside source and logs.

## Long-term data model

The target model is relational at the domain level even if the first implementation remains
file-backed:

```text
Player
└── PracticeSession
    ├── PracticeGoal
    ├── EquipmentContext
    ├── EnvironmentContext
    └── Swing
        ├── VideoAsset[]
        ├── SkeletonSequence[]
        ├── JointAngleSeries[]
        ├── PhaseEvent[]
        ├── MotionMetric[]
        ├── LaunchMeasurement[]
        ├── CoachPlan[]
        ├── PracticeNote[]
        └── ComparisonReference[]
```

Every child includes an ID, schema version, producer/model version, timestamps in a common
swing clock, provenance, confidence, and quality flags. Media assets also include source ID,
viewpoint, orientation, dimensions, frame rate, hash, and retention policy.

The existing package record in `apps/GolfTrace/Sources/Records/SwingRecord.swift` remains the
starting point. Future milestones add explicit manifests and migrations rather than hiding the
model inside generic metadata.

## Planned modules

### Capture and video

- camera-source registry;
- Face-On and Down-the-Line source roles;
- per-source orientation, health, and clock calibration;
- additional camera adapters;
- synchronized replay and evidence alignment;
- authenticated local transport;
- post-capture keyframe and segmentation jobs.

### Pose and skeleton

- framework-neutral joint vocabulary;
- skeleton frames with coordinate-space and source metadata;
- Apple Vision adapter;
- detector capability and quality reporting;
- future Core ML, server, or 3D reconstruction adapters.

### Motion metrics

Reusable calculators will declare required view, joints, phases, dimensionality, calibration,
and confidence policy.

| Metric | Initial useful view | First safe claim |
| --- | --- | --- |
| Shoulder turn | DTL and/or calibrated multi-view | projected shoulder orientation/change |
| Chest turn | DTL and/or calibrated multi-view | projected torso/chest proxy |
| Pelvis turn | DTL and/or calibrated multi-view | projected pelvis/hip proxy |
| X-factor | calibrated inputs preferred | difference between compatible shoulder and pelvis proxies |
| Head movement | FO and DTL | normalized 2D displacement by phase |
| Side bend | FO/DTL with declared projection | projected torso side-bend proxy |
| Hip depth | DTL | normalized 2D hip-depth change |
| Sway | FO | normalized lateral pelvis displacement |
| Early extension | DTL | pelvis movement toward the ball-line proxy |

The roadmap must not market projected proxies as true 3D rotations. Calibrated multi-view or a
validated 3D model is required before making that stronger claim.

### Swing phase

The canonical ordered vocabulary is:

1. Address
2. Takeaway
3. P2
4. P3
5. Top
6. Transition
7. P6
8. Impact
9. Release
10. Finish

Detection is confidence-bearing and partial. A detector can report only the phases supported
by the evidence. User-corrected markers remain distinguishable from automatic markers.

### Launch-monitor hub

- provider registry and selection;
- provider-neutral status and capabilities;
- provider-owned discovery, authorization, credentials, and parsing;
- normalized SI measurements plus original provider payload/provenance;
- common measurement-to-swing association;
- provider diagnostics isolated from user-facing product state;
- mock/file provider for development and regression tests.

Candidate providers are MLM2PRO, Garmin, TrackMan, Foresight, and Uneekor. Their appearance in
this roadmap is not a claim that access, licensing, hardware, or protocol support is currently
available.

### AI Coach

- versioned coaching input built from one swing aggregate;
- structured observation/cause/ball-flight/drill/next-goal output;
- phase and metric citations;
- one-cue live response and deeper post-session report;
- conversation tied to a swing or practice session;
- safety, uncertainty, cost, latency, and privacy gates;
- provider-independent local and hosted inference adapters.

### Practice management

- player profile and handedness;
- practice session, intent, and goal;
- equipment and environment context;
- notes, drills, repetitions, and outcomes;
- trusted personal baseline;
- same-phase and same-context comparison;
- trend analysis that separates measurement/model changes from player changes;
- export, deletion, sync, and coach sharing.

### Presentation

- Live Practice workspace;
- Review/Storyboard workspace;
- Coach workspace;
- History/Progress workspace;
- adaptive tablet split-screen;
- common source controls and provider-neutral status;
- accessibility and hands-free operation.

## Technical milestones

### Milestone 1 — Canonical domain foundation

Purpose: create stable extension points without changing application behavior.

Status: the additive contract, compatibility-adapter, and focused-test slice below is
implemented. This does not mark live ten-phase detection or provider-neutral UI/runtime
migration complete.

Deliverables:

- additive, framework-neutral motion contracts for camera sources/viewpoints, skeleton frames,
  joint identities, phase events, and metric readings;
- the ten ordered canonical swing phases;
- reusable pose-detection, phase-detection, and metric-calculation interfaces;
- a deterministic Apple Vision compatibility adapter that accepts `PoseFrame` plus
  source-only context, derives timestamp and orientation from the frame, declares normalized
  2D coordinates, rejects invalid media time, and uses an explicit versioned map to stable
  neutral joint IDs while omitting unknown joints;
- source-plus-viewpoint-qualified singular metric lookup and all-match metric lookup;
- coherent `MotionMetricReading` construction and decoding: finite values/times/confidence,
  confidence in `0...1`, finite ordered nonnegative time ranges, and availability/value/reason
  combinations that reject contradictions; unavailable reasons are nonempty and bounded;
- provider-neutral launch-monitor ID, descriptor, typed metric-unavailability reason,
  typed status detail/recovery, typed failure, associated-value trust action, measurement,
  event, and provider interface;
- process-local provider event-stream identity, monotonically increasing envelope sequence,
  and a consumer cursor that rejects zero-sequence, wrong-stream, duplicate, and out-of-order
  envelopes;
- structured launch-measurement deduplication keys whose field boundaries participate in
  equality and hashing;
- compatibility mapping/adapters for current Apple Vision and MLM2PRO models where required to
  prove the boundary;
- tests for phase ordering/serialization without fabricated observations, multi-camera
  identity, metric invariant and decode rejection, invalid pose time, joint-map stability and
  omission, source-aware metric access, custom provider identity, typed/redacted MLM2PRO
  mapping, event sequencing/stale rejection, and deduplication field-boundary collisions.

Non-goals:

- no UI migration;
- no persistence schema migration;
- no camera wire-protocol change;
- no second launch provider;
- no new metric claim;
- no login/backend;
- no behavior change in capture, replay, matching, or coaching.

### Milestone 2 — Runtime adapters and session orchestration

Status: the dedicated GolfTrace macOS/iOS CI lanes, the bounded neutral-skeleton shadow
window, and a completion-scoped neutral evidence handoff are in place. Provider-store/UI
migration, session orchestration, and authoritative neutral motion analysis remain
incomplete.

- validate completion-scoped neutral evidence against labeled Face-On and Down-The-Line
  fixtures before promoting it to any phase or metric consumer;
- adopt the already-tested MLM2PRO provider adapter at the composition root while preserving
  behavior;
- introduce a practice-session coordinator and typed domain events;
- replace provider-specific UI observation with provider-neutral view state;
- keep GolfTrace macOS/iOS CI lanes green while each runtime boundary migrates.

Exit condition: existing single-camera and MLM2PRO behavior passes regression and device UAT
through the new boundaries.

### Milestone 3 — Versioned swing aggregate and repository

- add explicit practice, analysis, launch, coach, equipment, and environment manifests;
- introduce a `SwingRepository` interface over the current local package store;
- write deterministic migrations and fixture tests;
- persist structured phase events, skeleton summaries, metric readings, and coach plans;
- preserve old records and replay packages.

Exit condition: a swing can be reloaded with complete provenance and no dependency on current
UI state.

### Milestone 4 — Validated phase engine

- create annotated FO/DTL validation sets with consent and rights metadata;
- implement Address, Takeaway, P2, P3, Top, Transition, P6, Impact Window, Release, and Finish
  incrementally;
- allow user correction and retain both automatic and corrected provenance;
- set per-phase precision/recall and temporal error gates;
- continue to label unconfirmed impact as an impact window.

Exit condition: only phases meeting their quality gate are enabled by default.

### Milestone 5 — Motion metrics v1

- ship normalized head movement, sway, DTL hip-depth, and selected projected turn/side-bend
  metrics;
- make each calculator independent and phase-addressable;
- add camera-framing/calibration checks;
- publish confidence, required view, limitation, and model version;
- build regression and repeatability tests.

Exit condition: every visible number has a definition, unit, source, validation result, and
honest claim level.

### Milestone 6 — Integrated coach and practice loop

- persist structured coaching plans;
- link observations and drills to phase/metric evidence;
- support a next-goal state across swings;
- add spoken one-cue feedback and a deeper review;
- compare against the player's selected, context-compatible baseline;
- track adherence and trend, not a universal swing score.

Exit condition: the user can complete capture → feedback → drill → follow-up without leaving
GolfTrace.

### Milestone 7 — Multi-camera

- register multiple sources;
- ingest FO and DTL independently;
- add common-clock calibration and uncertainty;
- run pose per source and introduce optional fusion;
- design source loss/fallback behavior;
- validate thermal, memory, network, and timeline performance.

Exit condition: each source remains independently reviewable, and fused results never hide
missing or poorly synchronized evidence.

### Milestone 8 — Additional authorized launch providers

- add a provider conformance test kit and mock provider;
- integrate one provider at a time only after access/licensing is confirmed;
- preserve provider-native payloads and normalized measurements;
- validate reconnect, duplicate suppression, units, shot association, and partial capability;
- keep provider configuration out of general practice UI.

Exit condition: changing providers does not change motion, history, coaching, or dashboard
contracts.

### Milestone 9 — One login and synchronization

- define identity, player, device, consent, and sharing boundaries;
- add a GolfTrace-specific backend and repository adapter;
- sync metadata first and media only with explicit policy;
- support offline conflict resolution, export, and deletion;
- provide tablet history/coach views over the same domain model.

Exit condition: one account shows consistent practice history across supported devices without
making the cloud a dependency for live practice.

### Milestone 10 — Calibrated advanced motion and reports

- evaluate validated 3D pose or calibrated multi-view reconstruction;
- promote eligible projected metrics to stronger biomechanical claims only after evaluation;
- add longitudinal AI reports and coach sharing;
- detect model/data drift and reanalysis boundaries.

Exit condition: advanced claims are traceable to a validated method and can be reproduced from
stored evidence.

## Feature priority

### P0 — Foundation and trustworthy daily practice

- Milestone 1 domain contracts;
- provider-neutral MLM2PRO façade with unchanged behavior;
- GolfTrace CI coverage;
- canonical phase/evidence persistence;
- practice-session and next-goal model;
- validated partial phase detection;
- first view-appropriate 2D motion metrics;
- complete hands-free capture/replay loop;
- honest capability and limitation UI.

### P1 — Integrated coaching and improvement

- structured coach chain;
- phase-linked chat and audio cue;
- personal baseline and same-context comparison;
- drill tracking and trend history;
- FO/DTL source registration and calibrated timeline;
- one additional authorized provider;
- tablet-first Review, Coach, and Progress workspaces.

### P2 — Scale and advanced analysis

- simultaneous multi-camera fusion;
- calibrated 3D claims;
- opt-in cloud media sync;
- coach/team collaboration;
- advanced reports and cohort insights;
- further launch-provider integrations;
- model training and reanalysis operations.

Priority is evidence-gated. A visually impressive overlay does not outrank a missing
provenance, synchronization, or repeatability requirement.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| 2D metrics presented as 3D truth | harms trust and coaching validity | metric capability taxonomy, view-specific names, calibration gates |
| False phase or impact detection | sends the user to the wrong frame | partial phase model, confidence, user correction, annotated validation |
| Provider access/licensing uncertainty | can strand product work | official/authorized integrations only, provider-neutral contracts, mocks |
| Camera clock and transport latency | corrupts multi-source comparison | per-source clocks, uncertainty, no fusion outside calibrated overlap |
| Live thermal/latency regression | makes practice unusable | bounded queues, post-capture jobs, device performance budgets |
| Privacy and biometric media | creates legal and user risk | local-first default, consent, encryption, deletion/export, minimal upload |
| AI hallucination | turns weak evidence into confident advice | structured evidence citations, bounded output, confidence and fallback |
| Model/schema drift | invalidates longitudinal trends | producer versions, immutable evidence, migrations, reanalysis labels |
| Large media storage | causes retention loss or cloud cost | asset roles, content hashes, retention policy, optional upload |
| Dashboard scope creep | recreates several apps inside one cluttered screen | task workspaces, progressive disclosure, tablet layout tests |
| Vendor-specific leakage | makes each integration a rewrite | domain façade and provider conformance suite |
| Insufficient real-device testing | simulator success hides hardware faults | hardware matrix, UAT gates, reconnect/thermal/long-session tests |

## Future integrations

### Launch monitors

- MLM2PRO remains the first adapter.
- Garmin, TrackMan, Foresight, and Uneekor are candidates after official access and rights are
  confirmed.
- Each integration must publish only supported capabilities and preserve its original units,
  payload provenance, and timestamp quality.

### Camera and motion providers

- Apple Vision remains the first pose adapter.
- A validated Core ML model, a calibrated 3D service, or another on-device detector can conform
  later.
- Additional iPhones, iPads, or supported cameras join through the source registry and clock
  contract.

### AI providers

- Local rules and fallback coaching remain available.
- OpenRouter/hosted models, GX10 services, and future models remain replaceable inference
  adapters.
- Knowledge sources require citations, rights metadata, and evaluation before influencing
  coaching.

### Product services

- GolfTrace-specific identity and sync;
- opt-in coach sharing and remote review;
- export to common video/data packages;
- tablet dashboard using the same swing aggregate;
- privacy-preserving aggregate analytics only after consent and governance are defined.

No future integration may bypass the evidence model, expose credentials to the UI, or make the
motion engine dependent on a particular launch monitor.

## Delivery workflow

Each milestone follows the requested product-development loop:

```text
Product requirement
  -> architecture/design review
  -> focused Codex implementation
  -> pull request
  -> independent ChatGPT/code review
  -> focused corrections
  -> verified merge
```

Every pull request should state its milestone, non-goals, schema impact, behavior impact,
automated validation, real-device validation still required, and rollback path.
