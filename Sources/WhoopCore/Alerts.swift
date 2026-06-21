import Foundation

/// L4 — actionable alerts. Each rule is transparent and fires from explicit signal conditions.
public struct Alert: Equatable {
  public enum Severity: String, Equatable { case info, watch, warn }
  public let id: String
  public let severity: Severity
  public let message: String
  public init(id: String, severity: Severity, message: String) {
    self.id = id; self.severity = severity; self.message = message
  }
}

/// Inputs are pre-computed signals (mostly CUSUM/score outputs from L2/L3).
public struct AlertSignals {
  public var rhrCusumHigh: Bool, tempCusumHigh: Bool, respHigh: Bool, hrvCusumLow: Bool
  public var tsb: Double, acwr: Double?, recovery: Double, sleepDebtHours: Double
  public var sriDropping: Bool, dataQualityOK: Bool, chronicUnderRecovery: Bool
  public init(rhrCusumHigh: Bool = false, tempCusumHigh: Bool = false, respHigh: Bool = false,
              hrvCusumLow: Bool = false, tsb: Double = 0, acwr: Double? = nil, recovery: Double = 50,
              sleepDebtHours: Double = 0, sriDropping: Bool = false, dataQualityOK: Bool = true,
              chronicUnderRecovery: Bool = false) {
    self.rhrCusumHigh = rhrCusumHigh; self.tempCusumHigh = tempCusumHigh; self.respHigh = respHigh
    self.hrvCusumLow = hrvCusumLow; self.tsb = tsb; self.acwr = acwr; self.recovery = recovery
    self.sleepDebtHours = sleepDebtHours; self.sriDropping = sriDropping; self.dataQualityOK = dataQualityOK
    self.chronicUnderRecovery = chronicUnderRecovery
  }
}

public enum Alerts {
  public static func evaluate(_ s: AlertSignals) -> [Alert] {
    var out = [Alert]()
    // ⭐ 2-signal illness: RHR-CUSUM↑ AND temp-CUSUM↑ (resp↑ = 3rd confirmation → escalate)
    if s.rhrCusumHigh && s.tempCusumHigh {
      out.append(Alert(id: "illness", severity: s.respHigh ? .warn : .watch,
        message: "Possible illness onset (resting HR + skin-temp rising\(s.respHigh ? " + respiratory" : "")) — consider rest."))
    }
    // overreaching: HRV falling + very negative form + high acute load
    if s.hrvCusumLow && s.tsb < -10 && (s.acwr ?? 0) > 1.5 {
      out.append(Alert(id: "overreaching", severity: .warn,
        message: "Overreaching: HRV trending down, form very negative, acute load high — back off."))
    }
    // optimal training window: recovery green AND fresh form
    if s.recovery >= 67 && s.tsb >= 0 {
      out.append(Alert(id: "optimal_train", severity: .info,
        message: "Good day to push: recovery is green and form is fresh."))
    }
    // detraining
    if let a = s.acwr, a < 0.8 {
      out.append(Alert(id: "detraining", severity: .info, message: "Training load dropping (ACWR < 0.8)."))
    }
    if s.sleepDebtHours > 5 {
      out.append(Alert(id: "sleep_debt", severity: .watch, message: "Accumulated sleep debt — prioritize sleep tonight."))
    }
    // chronic under-recovery: repeatedly loading hard on low recovery
    if s.chronicUnderRecovery {
      out.append(Alert(id: "under_recovery", severity: .warn,
        message: "High strain on low recovery several days running — schedule an easy day."))
    }
    if s.sriDropping {
      out.append(Alert(id: "circadian_drift", severity: .watch, message: "Irregular sleep timing — stabilize your schedule."))
    }
    if !s.dataQualityOK {
      out.append(Alert(id: "data_quality", severity: .info, message: "Some metrics are uncertain today (signal gaps)."))
    }
    return out
  }
}
