import Foundation

/// Passive irregular-rhythm (AFib) SCREENING — the confirmation state machine, modeled on Apple's
/// Irregular Rhythm Notification (FDA De Novo DEN180042). WELLNESS / EXPERIMENTAL ONLY — NOT a medical
/// device and does NOT diagnose atrial fibrillation or any condition. It only counts how many recent
/// background rhythm CHECKS (each already classified by `RhythmCheck` from broadcast RR-intervals) came
/// back irregular, and — to avoid false alarms — requires a multi-reading confirmation before surfacing
/// anything. A single irregular reading never alerts.
///
/// Apple's published rule: ~"5 of 6 sequential checks classified irregular within 48 h" → confirmed.
/// Noisy / insufficient checks are NOT valid evidence and are excluded by the caller before they reach here.
public struct AFCheck: Equatable {
  public let ts: Date          // when the check completed
  public let isIrregular: Bool // RhythmResult.category == .irregular (noisy/insufficient never reach here)
  public init(ts: Date, isIrregular: Bool) {
    self.ts = ts
    self.isIrregular = isIrregular
  }
}

public enum AFStatus: String, Equatable {
  case clear        // recent valid checks are regular — nothing to flag
  case monitoring   // ≥1 recent irregular but not yet confirmed (in the confirmation window)
  case flagged      // confirmation met (≥N of last M valid checks irregular within the window)
}

public struct AFOutcome: Equatable {
  public let status: AFStatus
  public let recentIrregularCount: Int   // irregular among the last `confirmWindow` valid checks
  public let validChecksInWindow: Int    // valid checks within `windowHours` of `now`
  public let lastCheck: Date?
}

public enum AFScreen {
  /// Evaluate the screening status from a time-ordered log of VALID checks (noisy/insufficient already
  /// excluded by the caller). Pure + deterministic.
  /// - confirmIrregular/confirmWindow: Apple's "≥5 of last 6" rule.
  /// - resetRegular: a run of this many consecutive regular checks clears a flagged/monitoring state.
  /// - windowHours: the 48-h confinement for the confirmation (and the freshness window for display).
  ///
  /// Cadence (≥10 min between checks so 6 checks span hours, not seconds) is enforced by the RUNNER that
  /// appends to the log, not here — this machine just folds whatever valid checks it is given.
  public static func evaluate(checks: [AFCheck], now: Date,
                              windowHours: Double = 48,
                              confirmIrregular: Int = 5,
                              confirmWindow: Int = 6,
                              resetRegular: Int = 3) -> AFOutcome {
    let sorted = checks.sorted { $0.ts < $1.ts }
    guard !sorted.isEmpty else {
      return AFOutcome(status: .clear, recentIrregularCount: 0, validChecksInWindow: 0, lastCheck: nil)
    }

    // Fold chronologically: a flagged state persists until a clean run of regular checks resets it
    // (mirrors Apple keeping the notification "on" until the rhythm looks regular again).
    var status: AFStatus = .clear
    var consecutiveRegular = 0
    for (i, c) in sorted.enumerated() {
      if c.isIrregular {
        consecutiveRegular = 0
        // last `confirmWindow` checks ending here, confined to the trailing `windowHours`.
        let windowStart = c.ts.addingTimeInterval(-windowHours * 3600)
        let recent = sorted[0...i].filter { $0.ts >= windowStart }.suffix(confirmWindow)
        let irq = recent.filter { $0.isIrregular }.count
        if irq >= confirmIrregular {
          status = .flagged
        } else if status != .flagged {
          status = .monitoring          // confirmation phase — seen an irregular, not yet enough
        }
      } else {
        consecutiveRegular += 1
        if consecutiveRegular >= resetRegular { status = .clear }   // clean run resets flagged/monitoring
      }
    }

    // Display fields relative to `now`.
    let windowStart = now.addingTimeInterval(-windowHours * 3600)
    let inWindow = sorted.filter { $0.ts >= windowStart }
    let recentIrregular = sorted.suffix(confirmWindow).filter { $0.isIrregular }.count
    return AFOutcome(status: status,
                     recentIrregularCount: recentIrregular,
                     validChecksInWindow: inWindow.count,
                     lastCheck: sorted.last?.ts)
  }
}
