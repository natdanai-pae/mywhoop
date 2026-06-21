#if os(iOS)
import ActivityKit
import Foundation

/// Shared Live Activity model for an active workout — visible to BOTH the app (starts/updates/ends the activity) and
/// the widget extension (renders it on the Lock Screen + Dynamic Island). Lives in GenieMax so the one type identity
/// is shared across targets. Guarded by `#if os(iOS)` (ActivityKit's types are unavailable on macOS, even though the
/// module imports) so the macOS package build (tests) + the no-BLE Demo still compile.
public struct WorkoutActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var hr: Int            // live heart rate
    public var hrZone: Int        // 0 = none, 1…5 = HR zone (drives the HR colour)
    public var kcal: Int          // calories so far
    public var startedAt: Date    // session start → drives the auto-counting lock-screen timer
    public var paused: Bool
    // adaptive 3rd metric (Run/Walk → distance or steps; else → strain) — pre-formatted by the app
    public var metricText: String // "8.4" / "2.41" / "3210"
    public var metricLabel: String// "strain" / "km" / "steps"
    public var metricSymbol: String // SF Symbol name, e.g. "bolt.fill" / "location.fill"
    // interval timer
    public var round: Int         // round number (0 = no interval timer)
    public var mode: Int          // 0 = off, 1 = Repeat (auto), 2 = Once (knock/tap to continue)
    public var waiting: Bool      // Once: a round finished, awaiting the next (HR shown as "recovering")
    public var roundStartedAt: Date? // current round start (with roundEndsAt → the auto-animating progress bar)
    public var roundEndsAt: Date? // countdown target for the current round (nil when waiting / no interval)
    public init(hr: Int, hrZone: Int, kcal: Int, startedAt: Date, paused: Bool,
                metricText: String, metricLabel: String, metricSymbol: String,
                round: Int, mode: Int, waiting: Bool, roundStartedAt: Date?, roundEndsAt: Date?) {
      self.hr = hr; self.hrZone = hrZone; self.kcal = kcal; self.startedAt = startedAt; self.paused = paused
      self.metricText = metricText; self.metricLabel = metricLabel; self.metricSymbol = metricSymbol
      self.round = round; self.mode = mode; self.waiting = waiting
      self.roundStartedAt = roundStartedAt; self.roundEndsAt = roundEndsAt
    }
  }
  public var type: String       // "Run" / "Cardio" / ...
  public init(type: String) { self.type = type }
}
#endif
