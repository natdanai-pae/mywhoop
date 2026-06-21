#if os(iOS)
import AppIntents

/// Interactive Live Activity buttons (iOS 17+). A `LiveActivityIntent` runs in the APP's process — so its `perform()`
/// can drive the live workout. WhoopCore can't see the app's `WhoopBLE` singleton (that's in WhoopUI), so the app
/// registers the actual actions here at launch; the intents just invoke them. Shared in WhoopCore so BOTH the app and
/// the widget extension compile against the same intent types. The closures are set once at launch and invoked on the
/// main queue, so `nonisolated(unsafe)` is sound here.
public enum WorkoutIntentActions {
  public nonisolated(unsafe) static var onLap: () -> Void = {}        // advance the round (= startIntervalRound, = a knock)
  public nonisolated(unsafe) static var onEnd: () -> Void = {}        // stop the workout
  public nonisolated(unsafe) static var onTogglePause: () -> Void = {} // P4
}

@available(iOS 17.0, *)
public struct LapIntent: LiveActivityIntent {
  public static let title: LocalizedStringResource = "Next round"
  public init() {}
  public func perform() async throws -> some IntentResult { WorkoutIntentActions.onLap(); return .result() }
}

@available(iOS 17.0, *)
public struct EndWorkoutIntent: LiveActivityIntent {
  public static let title: LocalizedStringResource = "End workout now"
  public init() {}
  public func perform() async throws -> some IntentResult { WorkoutIntentActions.onEnd(); return .result() }
}

@available(iOS 17.0, *)
public struct TogglePauseIntent: LiveActivityIntent {
  public static let title: LocalizedStringResource = "Pause or resume"
  public init() {}
  public func perform() async throws -> some IntentResult { WorkoutIntentActions.onTogglePause(); return .result() }
}
#endif
