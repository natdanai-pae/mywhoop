import Foundation

/// U7 — rule-based daily coaching narrative from the day's metrics (templated; LLM layer optional later).
public struct Insight: Equatable {
  public enum Kind: String { case recovery, strain, sleep, form, general }
  public let kind: Kind
  public let text: String
  public init(kind: Kind, text: String) { self.kind = kind; self.text = text }
}

public enum InsightEngine {
  /// Recommended day-strain range from this morning's recovery.
  public static func strainTarget(recovery: Double?) -> ClosedRange<Int> {
    guard let r = recovery else { return 8...12 }
    if r >= 67 { return 14...18 }
    if r >= 34 { return 8...12 }
    return 4...8
  }

  public static func daily(recovery: Double?, tsb: Double?, sleepScore: Double?, sleepDebt: Double) -> [Insight] {
    var out = [Insight]()
    if let r = recovery {
      let band = r >= 67 ? "green — primed for a hard session" : (r >= 34 ? "moderate — keep effort controlled" : "low — prioritize recovery today")
      out.append(.init(kind: .recovery, text: "Recovery \(Int(r)) — \(band)."))
    } else {
      out.append(.init(kind: .recovery, text: "Recovery is warming up — keep wearing the strap overnight."))
    }
    let t = strainTarget(recovery: recovery)
    out.append(.init(kind: .strain, text: "Suggested strain today: \(t.lowerBound)–\(t.upperBound)."))
    if let f = tsb {
      let s = f >= 5 ? "fresh and tapered" : (f >= -10 ? "balanced" : "carrying fatigue — ease off")
      out.append(.init(kind: .form, text: "Form (TSB) \(String(format: "%+.1f", f)) — \(s)."))
    }
    if sleepDebt > 5 {
      out.append(.init(kind: .sleep, text: "Sleep debt \(String(format: "%.1f", sleepDebt))h — aim for an earlier night."))
    } else if let ss = sleepScore {
      out.append(.init(kind: .sleep, text: "Sleep score \(Int(ss)) — \(ss >= 80 ? "well rested" : "room to improve")."))
    }
    return out
  }
}
