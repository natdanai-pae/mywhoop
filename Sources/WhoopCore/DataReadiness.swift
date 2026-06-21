import Foundation

/// Which derived metrics need a warm-up before they're trustworthy, and how long. A first-day user can't see a
/// recovery baseline, an HRV trend, or training load yet — so the UI shows a 🔒 with "available in N nights/days"
/// instead of a misleading empty/zero value.
///
/// Periods are grounded in the frontier's published calibration windows + the time constants of each metric:
///  • Recovery: WHOOP calibrates after 4 nights, full baseline at 30 (we surface the 4-night gate).
///  • HRV / RHR / skin-temp / resp baselines: 7-night personal range (Plews; Garmin HRV Status = 7-day rolling).
///  • Sleep score/stages/recovery-index: 1 night. SRI (regularity): needs ≥4 nights of day-to-day comparison.
///  • Sleep need/debt: 3 nights. Resilience: 14 nights.
///  • Training load — ATL(acute)=7-day, CTL(fitness)=42-day EWMA (meaningful ~14d), TSB=CTL−ATL (14d), ACWR=7d/28d (28d).
///  • VO₂max: needs ≥1 qualifying activity (HR + cadence). Trends/charts: ≥3 days to plot a line.
public enum ReadyMetric: String, CaseIterable, Sendable {
  case recovery, hrvBaseline, rhrBaseline, tempBaseline, respBaseline
  case sleepScore, sri, sleepNeed, recoveryIndex
  case ctl, atl, tsb, acwr, vo2max, resilience, trends

  public enum Unit: String, Sendable { case nights, days, activities }

  public var unit: Unit {
    switch self {
    case .ctl, .atl, .tsb, .acwr, .trends: return .days
    case .vo2max: return .activities
    default: return .nights
    }
  }

  /// How many of `unit` must be collected before this metric unlocks.
  public var required: Int {
    switch self {
    case .recoveryIndex, .sleepScore: return 1
    case .vo2max: return 1
    case .sleepNeed: return 3
    case .trends: return 3
    case .sri: return 4
    case .recovery: return 7              // matches RecoveryEngine's 7-night "ready" gate (WHOOP usable ~4, full 30)
    case .atl: return 7
    case .hrvBaseline, .rhrBaseline, .tempBaseline, .respBaseline: return 7
    case .ctl, .tsb: return 14
    case .resilience: return 14
    case .acwr: return 28
    }
  }

  public var title: String {
    switch self {
    case .recovery: return "Recovery"; case .hrvBaseline: return "HRV baseline"; case .rhrBaseline: return "RHR baseline"
    case .tempBaseline: return "Skin-temp baseline"; case .respBaseline: return "Respiratory baseline"
    case .sleepScore: return "Sleep score"; case .sri: return "Sleep consistency"; case .sleepNeed: return "Sleep need"
    case .recoveryIndex: return "Recovery Index"; case .ctl: return "Fitness (CTL)"; case .atl: return "Fatigue (ATL)"
    case .tsb: return "Form (TSB)"; case .acwr: return "ACWR"; case .vo2max: return "VO₂max"; case .resilience: return "Resilience"
    case .trends: return "Trends"
    }
  }
}

public struct DataReadiness {
  /// Remaining count (in the metric's unit) before it unlocks; 0 = ready now.
  public static func remaining(_ m: ReadyMetric, nights: Int, days: Int, activities: Int) -> Int {
    let have: Int = { switch m.unit { case .nights: return nights; case .days: return days; case .activities: return activities } }()
    return max(0, m.required - have)
  }
  public static func locked(_ m: ReadyMetric, nights: Int, days: Int, activities: Int) -> Bool {
    remaining(m, nights: nights, days: days, activities: activities) > 0
  }
}
