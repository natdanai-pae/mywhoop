# Launch Monitor Provider Architecture

Status: proposed provider-neutral target architecture, with the Milestone 1 additive
contracts, MLM2PRO adapter boundary, and focused tests implemented. The neutral store and UI
migration remain future work.

GolfTrace should treat a launch monitor as an optional measurement provider. Motion
analysis, camera capture, replay, history, and AI Coach must continue to work when no launch
monitor is present. The dashboard must consume normalized capabilities and measurements,
not vendor classes.

This document does not claim integrations with Garmin, TrackMan, Foresight, or Uneekor.
Those names describe future provider adapters that may be built only through documented,
authorized SDKs, APIs, or data interfaces.

## 1. Current implementation

The current MLM2PRO path is concrete and functional in code:

- [`apps/GolfTrace/Sources/LaunchMonitor/MLM2PROBluetoothClient.swift`](../apps/GolfTrace/Sources/LaunchMonitor/MLM2PROBluetoothClient.swift)
  owns CoreBluetooth discovery, trust, authorization, GATT session state, arming,
  heartbeat, measurement delivery, and redacted diagnostics.
- [`apps/GolfTrace/Sources/LaunchMonitor/MLM2PROMeasurementParser.swift`](../apps/GolfTrace/Sources/LaunchMonitor/MLM2PROMeasurementParser.swift)
  parses the measured fields behind a small parsing protocol.
- [`apps/GolfTrace/Sources/LaunchMonitor/LaunchMonitorModels.swift`](../apps/GolfTrace/Sources/LaunchMonitor/LaunchMonitorModels.swift)
  defines `LaunchMonitorShot`, MLM2PRO-oriented connection state, and events.
- [`apps/GolfTrace/Sources/LaunchMonitor/ShotSwingMatchController.swift`](../apps/GolfTrace/Sources/LaunchMonitor/ShotSwingMatchController.swift)
  deterministically associates the nearest pending swing and shot within a default
  eight-second wall-clock window.
- [`apps/GolfTrace/Sources/Records/SwingRecord.swift`](../apps/GolfTrace/Sources/Records/SwingRecord.swift)
  stores a `LaunchMonitorMatch` containing the shot, offset, matching window, and method.
- [`apps/GolfTrace/Sources/GolfTraceApp.swift`](../apps/GolfTrace/Sources/GolfTraceApp.swift)
  constructs `LaunchMonitorController`, subscribes its shot events to history, starts it on
  launch, and stops/flushes it during termination.

`LaunchMonitorShot` already uses SI units for speed and labels smash factor as derived. It
also preserves source and raw measurement bytes. These are good foundations.

The current coupling to remove incrementally is:

- `LaunchMonitorController` is the concrete MLM2PRO CoreBluetooth implementation.
- `LaunchMonitorConnectionState` contains Bluetooth and MLM2PRO-specific workflow states.
- app composition, settings, and dashboard views observe the concrete controller.
- AI evidence uses Rapsodo-specific source names and numeric source code.
- the persisted `LaunchMonitorShot` has a fixed set of fields rather than a
  capability-driven metric collection.

## 2. Goals and non-goals

### Goals

- The UI observes one vendor-neutral store/facade.
- Providers implement a common lifecycle and event interface.
- Capabilities are negotiated at runtime; missing data remains missing.
- Measurements use normalized SI units and preserve raw provenance.
- Motion analysis has no dependency on a provider.
- Matching, deduplication, persistence, and AI consumption work for any provider.
- New providers can be added without modifying dashboard feature logic.
- Credentials and raw vendor traffic never reach the UI or AI request.

### Non-goals

- one universal transport protocol;
- pretending all providers expose the same metrics;
- reverse-engineering private services or bypassing vendor authorization;
- implementing five providers in Milestone 1;
- replacing the working MLM2PRO state machine immediately;
- changing current on-disk records or user-visible behavior in Milestone 1.

## 3. Target boundaries

```text
apps/GolfTrace/Sources/LaunchMonitor/
  Domain/
    LaunchMonitorProviderID.swift
    LaunchMonitorCapabilities.swift
    LaunchMonitorMetric.swift
    LaunchMonitorMeasurement.swift
    LaunchMonitorStatus.swift
    LaunchMonitorError.swift
  Providers/
    LaunchMonitorProvider.swift
    ProviderRegistry.swift
    MLM2PRO/
      MLM2PROProviderAdapter.swift
      existing MLM2PRO transport, authorization, parser, and codec
    Garmin/
      GarminProvider.swift
    TrackMan/
      TrackManProvider.swift
    Foresight/
      ForesightProvider.swift
    Uneekor/
      UneekorProvider.swift
  Store/
    LaunchMonitorStore.swift
    LaunchMonitorSelectionStore.swift
  Matching/
    LaunchMeasurementMatcher.swift
    LaunchMeasurementDeduplicator.swift
  Persistence/
    LaunchMeasurementRecordAdapter.swift
```

Only code required by a milestone should be added. The provider folders above are extension
locations, not placeholders that need to exist now.

Dependency direction:

```text
Dashboard / Settings / AI / History
                 |
                 v
       LaunchMonitorStore API
                 |
                 v
       LaunchMonitorProvider protocol
          /       |       \
   MLM2PRO     future     simulator
    adapter    adapters    adapter
                 |
                 v
      vendor SDK / authorized transport
```

Provider implementations depend on domain contracts. Domain contracts do not import
CoreBluetooth, SwiftUI, a vendor SDK, or persistence.

## 4. Provider identity and registry

Provider identity must be open to future values. A raw-value struct is preferable to a
closed enum:

```swift
struct LaunchMonitorProviderID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String

  static let mlm2pro = Self(rawValue: "mlm2pro")
  static let garmin = Self(rawValue: "garmin")
  static let trackMan = Self(rawValue: "trackman")
  static let foresight = Self(rawValue: "foresight")
  static let uneekor = Self(rawValue: "uneekor")
}
```

A descriptor contains only display-safe metadata:

```swift
struct LaunchMonitorProviderDescriptor: Codable, Equatable, Sendable {
  let id: LaunchMonitorProviderID
  let displayName: String
  let adapterVersion: String
  let transportKinds: Set<LaunchMonitorTransportKind>
  let setupRequirements: [LaunchMonitorSetupRequirement]
}
```

The composition root registers available provider factories. The dashboard receives the
store, never a provider switch statement. Build configuration, entitlement availability,
user selection, and vendor authorization decide which factories are available.

Provider registry responsibilities:

- enumerate adapters shipped in this build;
- create one adapter from a non-secret configuration;
- reject duplicate provider IDs;
- expose adapter compatibility and setup requirements;
- never discover credentials by scanning source files or other applications.

## 5. Capabilities

Capabilities are session data, not assumptions based only on a provider name. They may vary
by model, firmware, subscription, mode, club, or environment.

```swift
struct LaunchMonitorCapabilities: Codable, Equatable, Sendable {
  let measurementMetrics: Set<LaunchMetricID>
  let derivedMetrics: Set<LaunchMetricID>
  let supportedActions: Set<LaunchMonitorActionID>
  let supportsLiveMeasurements: Bool
  let supportsDeviceSelection: Bool
  let supportsOfflineImport: Bool
  let updateSequence: UInt64
}
```

The provider emits a new capability snapshot whenever availability changes. Consumers:

- render only supported controls;
- display unavailable metrics as unavailable, never `0`;
- distinguish device-measured metrics from app-derived values;
- tolerate unknown metric and action IDs;
- save the capability snapshot with provenance when it affects interpretation.

No common interface should force unsupported metrics. A provider that reports ball speed
and total spin but not club path remains fully valid.

The implemented Milestone 1 snapshot uses
`LaunchMonitorMetricUnavailabilityReason` for unavailable entries. Capability reasons are
therefore bounded to a typed vocabulary such as unsupported-by-provider,
unavailable-from-device, authorization-required, or prerequisite-unavailable; adapters do
not publish unrestricted reason text through this boundary. The current MLM2PRO adapter's
`unavailableReasons` map is empty, and the focused suite does not yet include a populated
typed-reason fixture.

## 6. Metric and measurement model

Metric identifiers are extensible raw values with a documented canonical catalog:

```swift
struct LaunchMetricID: RawRepresentable, Codable, Hashable, Sendable {
  let rawValue: String
}

struct LaunchMetricValue: Codable, Equatable, Sendable {
  let id: LaunchMetricID
  let value: Double
  let unit: LaunchMetricUnit
  let origin: LaunchMetricOrigin
  let quality: LaunchMetricQuality
}
```

Canonical values use SI or dimensionless domain units:

| Metric family | Canonical unit |
|---|---|
| speed | metres per second |
| distance | metres |
| angle / axis | degrees |
| spin rate | revolutions per minute |
| time | seconds |
| ratio, confidence | unitless |

Display conversion to mph, yards, or another locale preference happens outside the provider
and outside persistence. A metric stores its actual unit even when the catalog has a
preferred canonical unit, allowing the normalizer to reject or explicitly convert invalid
provider output.

```swift
struct LaunchMonitorMeasurement: Codable, Equatable, Identifiable, Sendable {
  let id: LaunchMeasurementID
  let providerID: LaunchMonitorProviderID
  let deviceID: LaunchMonitorDeviceID
  let sessionID: LaunchMonitorSessionID
  let providerSequence: String?
  let measuredAt: Date?
  let receivedAt: Date
  let metrics: [LaunchMetricValue]
  let provenance: LaunchMeasurementProvenance
}
```

Provenance includes:

- provider and adapter version;
- vendor model and firmware when disclosure is allowed;
- transport and session identity;
- whether time is device-measured or receipt time;
- normalization transforms;
- raw payload hash;
- optional protected raw-artifact reference;
- capability snapshot/version;
- parsing warnings and limitations.

Raw vendor bytes are not a UI field and must not be sent to AI. If retained for authorized
diagnostics, use a bounded encrypted artifact with a retention policy and consent; otherwise
retain only a cryptographic hash and redacted parse metadata. The current
`LaunchMonitorShot.rawMeasurement` must be handled deliberately during a future record
migration.

## 7. Provider interface

An illustrative interface is:

```swift
protocol LaunchMonitorProvider: Sendable {
  var descriptor: LaunchMonitorProviderDescriptor { get }
  var events: AsyncStream<LaunchMonitorProviderEvent> { get }

  func start() async
  func stop() async
  func perform(_ action: LaunchMonitorAction) async throws
}

enum LaunchMonitorProviderEvent: Sendable {
  case status(LaunchMonitorStatus)
  case capabilities(LaunchMonitorCapabilities)
  case devices([LaunchMonitorDeviceDescriptor])
  case challenge(LaunchMonitorChallenge)
  case measurement(LaunchMonitorMeasurement)
  case battery(LaunchMonitorBatteryState)
  case error(LaunchMonitorFailure)
}
```

Milestone 1 uses Combine to match the current app:
`LaunchMonitorProviding.eventPublisher` publishes
`LaunchMonitorProviderEventEnvelope`. Each provider instance exposes a typed,
process-local `eventStreamID`; it is consumer binding identity, not a provider session,
measurement provenance, or durable deduplication key. The MLM2PRO compatibility adapter
starts its envelope sequence at one and increments monotonically without wrapping.
`LaunchMonitorProviderEventCursor` accepts one stream and rejects sequence zero,
wrong-stream, duplicate, and out-of-order envelopes without advancing its cursor.

Longer-term provider/store conformance should require:

- events are ordered within one process-local provider event stream;
- `start` and `stop` are idempotent;
- stopping completes or times out bounded cleanup;
- measurements are delivered only when the provider reports ready;
- provider callbacks are translated before crossing the boundary;
- an adapter never publishes credentials, tokens, or raw packet contents.

## 8. Status, actions, challenges, and errors

### Status

The vendor-neutral lifecycle is:

```text
idle
  -> discovering
  -> awaitingUserAction
  -> connecting
  -> authorizing
  -> preparing
  -> ready
  -> stopping
  -> idle
```

In the implemented Milestone 1 boundary, `LaunchMonitorProviderStatus` contains only typed
`phase`, `detail`, and `recovery` values. It carries no free-form message or device name.
The compatibility adapter deliberately drops authorization user ID/device name and failed
state text while mapping the concrete controller. Device display names cross the boundary
only in discovery candidates and the trust-confirmation action where the UI genuinely needs
them.

The longer-term store may add provider/session identity and localized presentation lookup,
but domain state must not contain unrestricted Thai or English presentation sentences.

### Actions and challenges

The store exposes only actions the current capability/status allows:

- start or stop discovery;
- select, trust, reject, or forget a device;
- supply an authorized credential response;
- retry a recoverable failure;
- arm or disarm when the provider supports it.

A challenge contains a type, opaque challenge ID, expiry, and safe fields required for UI.
The response is passed directly to the selected provider. Generic UI can render common
challenge types; an explicitly isolated provider setup view may be registered for a legally
required vendor flow, but normal dashboard code still does not import the provider.

Milestone 1 exposes only the current safe trust commands. The existing MLM2PRO credential
workflow remains owned by `LaunchMonitorController` and its current settings path; it is not
republished as a generic secure-input action. A later store migration must define an opaque
credential-response boundary before moving that workflow.

The current safe request is an associated-value enum case,
`confirmDeviceTrust(deviceID:deviceDisplayName:)`, rather than a structure containing
free-form title/message fields and unrelated nullable challenge or secure-input fields.

### Errors

```swift
struct LaunchMonitorFailure: Error, Codable, Equatable, Sendable {
  let code: LaunchMonitorFailureCode
  let severity: LaunchMonitorFailureSeverity
  let recovery: LaunchMonitorRecovery
  let providerID: LaunchMonitorProviderID
  let safeDiagnosticContext: [String: String]
}
```

Stable categories include unavailable transport, permission denied, device not found,
untrusted device, authorization required/rejected, incompatible firmware/protocol, timeout,
disconnected, malformed measurement, and storage failure.

Provider error text and vendor payloads are mapped into safe codes. Logs may contain a
bounded redacted provider code, never credentials or unrestricted error payloads. The
existing MLM2PRO diagnostic trace is a strong pattern: fixed event labels, bounded size,
atomic replacement, and redacted states.

Milestone 1 publishes the typed `LaunchMonitorProviderFailure.providerReported` case for a
legacy controller error and discards the controller's raw error string. More granular safe
failure categories require typed evidence from a future adapter revision; they must not be
guessed by parsing presentation text.

## 9. Store: the UI boundary

In the target architecture, `LaunchMonitorStore` will be the only object normal dashboard
and settings views observe:

```swift
@MainActor
protocol LaunchMonitorStoreProtocol: ObservableObject {
  var state: LaunchMonitorViewState { get }
  var latestMeasurement: LaunchMonitorMeasurement? { get }

  func selectProvider(_ id: LaunchMonitorProviderID)
  func start()
  func stop()
  func perform(_ action: LaunchMonitorAction)
}
```

The store will:

- selects and owns one active provider session;
- folds provider events into immutable view state;
- exposes display-safe capabilities, status, challenges, and measurements;
- converts user intent into domain actions;
- forwards normalized measurements to matching/history;
- cancels stale events after provider/session changes;
- persists only non-secret selection preferences;
- coordinates app termination without leaking the provider type.

The UI may display a provider's descriptor name and icon. “The UI does not know the provider”
means it does not cast, import, branch on, or call provider-specific APIs.

`LaunchMonitorStore` is still a target boundary, not the current composition root. Milestone
1 does not construct the MLM2PRO adapter for the dashboard: `GolfTraceApp`, settings, and the
dashboard continue to observe and call the concrete `LaunchMonitorController`. The envelope
and cursor contracts are tested seams for that later migration, not a claim that stale-event
filtering is already wired into the UI runtime.

## 10. Matching and deduplication

Matching is independent of provider transport.

### Deduplication identity

Use the strongest available tuple:

```text
provider ID
+ stable device identity
+ provider session identity
+ provider measurement/shot sequence
```

The strong tuple is represented by a structured, Codable, hashable
`LaunchMonitorMeasurementDeduplicationKey`, never by concatenating strings. Field boundaries
therefore participate in equality and hashing even when a provider identifier contains a
delimiter character.

When a provider has no stable sequence, calculate a bounded content fingerprint from
normalized metrics, device time, and payload hash. Receipt time alone is not an identity.
The deduplicator records which strategy it used.

The current MLM2PRO code correctly distinguishes persistent UUID identity from its
process-local `deviceShotID`. The adapter should preserve both facts; it must not promote the
process-local counter into a globally stable ID.

### Swing association

The current nearest-wall-clock matcher within ±8 seconds is retained during Milestone 1.
A future matcher consumes:

- swing event time and uncertainty;
- measurement device time or receipt time and uncertainty;
- provider latency estimate;
- session identity;
- optional impact evidence from video/audio;
- configured maximum window.

It returns a match with confidence, alternatives considered, time offset, clock method, and
matcher version. Low-confidence or ambiguous results remain pending for user confirmation.
One measurement cannot silently attach to multiple swings.

The matching algorithm never blocks capture or provider delivery. Pending queues are bounded
and persistence occurs off the UI thread.

## 11. Persistence and AI flow

The long-term flow is:

```text
provider adapter
  -> normalized measurement
  -> deduplicator
  -> swing matcher
  -> swing aggregate / practice history
  -> provider-neutral AI evidence
  -> UI presentation units
```

Persistence stores normalized metrics and provenance. Unknown metric IDs must round-trip so a
newer app can interpret records written by a provider adapter without destroying them.

AI receives:

- metric ID, normalized value, and unit;
- measured versus derived origin;
- match confidence and timing limitation;
- provider-neutral evidence source classification;
- safe provider attribution when useful.

AI does not receive raw packets, access tokens, secrets, device identifiers, or trust data.
The current Rapsodo-specific source code in
[`apps/GolfTrace/Sources/AICoach/AIGolfCoachModels.swift`](../apps/GolfTrace/Sources/AICoach/AIGolfCoachModels.swift)
should be migrated only after the neutral measurement model is persisted and tested.

Milestone 1 does not change `SwingRecord`, `LaunchMonitorMatch`, or current AI payloads.

## 12. Provider adapters

### MLM2PRO

The first adapter wraps the existing `LaunchMonitorController`:

- map its concrete connection states to neutral status;
- map device trust to a generic safe action;
- keep authorization as a sanitized neutral status in Milestone 1, then expose a generic
  challenge only after a secure response contract exists;
- map `LaunchMonitorShot` fields into canonical metric values;
- preserve measured SI values, process-local shot ID, and receipt time while keeping raw
  bytes behind the existing controller boundary;
- expose current start, stop, trust, and forget actions; keep the credential path inside
  the current controller/provider boundary;
- leave the existing CoreBluetooth state machine and diagnostics unchanged.

It is an adapter, not a rewrite.

### Garmin, TrackMan, Foresight, and Uneekor

Each future provider:

1. uses a documented and authorized local SDK, cloud API, file export, or open protocol;
2. owns vendor transport and authentication inside its folder;
3. declares runtime capabilities;
4. normalizes units and preserves provenance;
5. passes the provider conformance suite;
6. supplies real-device UAT evidence before being labeled supported.

A provider unavailable for licensing or technical reasons can remain absent. The common
interface does not imply entitlement to a vendor's private data.

### Simulator

A deterministic simulator is a separate provider ID and must be visually labeled as
simulated. Fixtures never masquerade as measured hardware data or enter production
improvement history without an explicit test marker.

## 13. Security and compliance

- Store secrets in Keychain or the vendor's approved secure mechanism.
- Keep credentials out of records, logs, crash metadata, UI state, and AI requests.
- Do not extract tokens from vendor applications or call private R-Cloud endpoints.
- Pin provider network destinations to the documented allowlist when practical.
- Require TLS and validate server identity for network providers.
- Treat BLE/local-network input as untrusted; bound packet sizes and parsing work.
- Make device trust an explicit user action when the transport cannot prove identity.
- Redact serial numbers and stable device IDs in diagnostics and analytics.
- Document raw-data retention, consent, export, and deletion.
- Gate providers by licensing, region, subscription, and vendor terms without weakening the
  rest of GolfTrace.

## 14. Testing

### Contract tests for every provider

- provider ID and descriptor are stable;
- start/stop are idempotent;
- event ordering and stale event-stream rejection;
- capability changes do not fabricate values;
- every emitted metric has a valid unit and finite value;
- measured and derived origins remain distinct;
- unknown metric IDs round-trip;
- credentials and raw payloads never appear in view state or logs;
- malformed and oversized input fails safely;
- termination cleanup is bounded.

### Adapter tests

- provider fixtures map to expected normalized values;
- unit conversions use authoritative formulas;
- optional fields remain absent;
- duplicate vendor events produce one normalized measurement;
- errors map to stable safe categories;
- simulator data is visibly marked simulated.

The implemented Milestone 1 focused suite covers extensible IDs, current six-field MLM2PRO
normalization, absent durable deduplication identity, structured-key delimiter collisions,
typed/redacted status and failure mapping, associated-value trust action, one-stream
monotonic envelope sequencing, and cursor rejection of zero-sequence, wrong-stream,
duplicate, and out-of-order envelopes. It does not claim that a neutral store or second
provider is running in the app.

### Matching tests

- measurement before and after swing;
- exact-window boundaries;
- equal-distance deterministic tie;
- duplicate sequence across reconnect/session boundaries;
- differently partitioned identifier fields that would collide if joined with a delimiter;
- device-time drift and receipt latency;
- one shot near two swings;
- queue bounds and restore after restart.

### Integration and real-device UAT

- connect, authorize, ready, measure, disconnect, reconnect, and stop;
- app restart and trusted-device behavior;
- firmware/model combinations;
- several shots at realistic cadence;
- missing metric capabilities;
- network loss or Bluetooth interruption;
- measurement paired with the correct video and practice record.

Automated fixture tests do not prove that a physical provider is authorized, connected, or
accurate.

## 15. Migration plan

### Milestone 1 — additive contracts

This additive contract/test slice is implemented; it is not the runtime store migration.

- add provider ID, descriptor, typed status detail/recovery, typed capability-unavailability
  reason, typed failure, associated-value trust action, normalized metric, measurement,
  event envelope/cursor, and provider protocol contracts in
  `apps/GolfTrace/Sources/LaunchMonitor/LaunchMonitorProviderContracts.swift`;
- add an adapter/conformance path for the existing MLM2PRO controller;
- add tests in
  `apps/GolfTrace/Tests/LaunchMonitorProviderContractsTests.swift` for extensible IDs,
  capability declaration and missing metrics, SI values, absent fields, typed/redacted
  mapping, event sequencing, stale rejection, deduplication identity, and lifecycle semantics;
- keep `GolfTraceApp`, dashboard/settings, current `LaunchMonitorShot`,
  `LaunchMonitorConnectionState`, matcher, persistence, and AI behavior unchanged.

The implemented Milestone 1 vocabulary is:

| Concern | Contract |
|---|---|
| provider and metric IDs | `LaunchMonitorProviderID`, `LaunchMonitorMetricID`, `LaunchMonitorUnitID` |
| normalized result | `LaunchMonitorMetricValue`, `LaunchMonitorMetricOrigin`, `LaunchMonitorMeasurement` |
| structured deduplication identity | `LaunchMonitorMeasurementDeduplicationKey` |
| runtime capability | `LaunchMonitorCapabilitySnapshot`, typed `LaunchMonitorMetricUnavailabilityReason`, and `capabilitiesChanged` |
| lifecycle | `LaunchMonitorProviderConnectionPhase`, typed `LaunchMonitorProviderStatusDetail`/`LaunchMonitorProviderRecovery`, `LaunchMonitorProviderStatus`, typed `LaunchMonitorProviderFailure`, and `LaunchMonitorProviderEvent` |
| safe user action | associated-value `LaunchMonitorProviderActionRequest` and `LaunchMonitorProviderCommand` |
| event delivery | process-local `LaunchMonitorProviderEventStreamID`, `LaunchMonitorProviderEventEnvelope`, and `LaunchMonitorProviderEventCursor` |
| provider boundary | `LaunchMonitorProviding` with `eventStreamID` and an envelope publisher using Combine to match the current app |
| compatibility adapter | `MLM2PROLaunchMonitorProviderAdapter` |

The adapter normalizes the current six measured MLM2PRO fields and does not copy raw BLE
payload bytes into `LaunchMonitorMeasurement`. It cannot create a durable deduplication key
from the process-local MLM2PRO counter alone: `deduplicationKey` is `nil` until an adapter can
supply both provider-device and provider-session identity. This prevents a convenient local
counter from being represented as a cross-restart identity.

When a provider can supply those identity components, `deduplicationKey` is a structured
value whose provider, device, session, and shot fields remain distinct. The focused tests
include a delimiter-collision fixture proving that differently partitioned fields do not
collapse to one key.

The current UI is not constructed with the adapter in M1. The adapter's typed/redacted event
mapping, envelope sequence, normalized measurement path, and the consumer cursor are
exercised by
`apps/GolfTrace/Tests/LaunchMonitorProviderContractsTests.swift` before the later store
migration.

### Milestone 2 — neutral store at composition root

- introduce `LaunchMonitorStore`;
- run the MLM2PRO adapter through it;
- migrate one UI surface at a time;
- retain a compatibility bridge for history and termination.

### Milestone 3 — normalized persistence and AI evidence

- version the swing aggregate;
- store normalized metric collections and provenance;
- migrate historical `LaunchMonitorShot` records losslessly;
- remove Rapsodo-specific AI source assumptions.

### Milestone 4 — second authorized provider

- select a provider based on verified access and user demand;
- implement its adapter and conformance fixtures;
- validate real hardware;
- verify that no dashboard feature code changes are required.

## 16. Milestone 1 Definition of Done

1. Domain contracts do not import CoreBluetooth, SwiftUI, or a vendor SDK.
2. Provider IDs allow MLM2PRO, Garmin, TrackMan, Foresight, Uneekor, and future unknown IDs.
3. Capabilities distinguish measured, derived, and unavailable metrics, with unavailable
   reasons represented by a typed vocabulary rather than arbitrary text.
4. Normalized values use explicit canonical units and retain provenance.
5. The existing MLM2PRO implementation has an additive adapter or conformance boundary.
6. Status detail/recovery, failure, and trust action are typed; authorization identity and
   raw provider error text are not emitted as status/failure payloads.
7. Every emitted provider event is wrapped with a process-local stream ID and monotonically
   increasing sequence; the consumer cursor rejects sequence zero, wrong-stream, duplicate,
   and out-of-order envelopes.
8. Current UI, persistence schema, matching window, wire protocol, and runtime behavior are
   unchanged.
9. Focused tests cover encoding, unknown IDs, normalized mapping, typed redaction, envelope
   sequencing, stale rejection, missing metrics, structured deduplication identity, and
   identifier field-boundary collision behavior appropriate to the implemented slice.
10. The focused contract tests pass; real-device authorization, connectivity, and accuracy
    remain separate UAT.
