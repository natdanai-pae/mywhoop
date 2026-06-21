import Foundation

/// U7 — behavior journal + impact analysis (clean-room of WHOOP's Journal/MPA).
/// Logs behaviors per day, then quantifies each behavior's effect on Recovery via Cohen's d effect size.
public struct JournalEntry: Codable, Equatable {
  public let date: String              // "yyyy-MM-dd"
  public var behaviors: [String]
  /// Phase 2 — optional per-behavior amount/level (1-based index into `BehaviorLevels.scale`).
  /// Only leveled behaviors (alcohol/caffeine/…) carry an entry; binary ones don't. Decodes old
  /// data (pre-levels) as empty so persisted journals keep working.
  public var levels: [String: Int]
  public init(date: String, behaviors: [String], levels: [String: Int] = [:]) {
    self.date = date; self.behaviors = behaviors; self.levels = levels
  }
  enum CodingKeys: String, CodingKey { case date, behaviors, levels }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    date = try c.decode(String.self, forKey: .date)
    behaviors = try c.decode([String].self, forKey: .behaviors)
    levels = try c.decodeIfPresent([String: Int].self, forKey: .levels) ?? [:]
  }
}

/// Phase 2 — behaviors that carry an amount/level. key → ordered level labels (level Int is 1-based).
/// Pure + testable; the UI/AI dossier read labels from here so there's one source of truth.
public enum BehaviorLevels {
  public static let scale: [String: [String]] = [
    "alcohol":    ["1–2", "3–4", "5+"],
    "caffeine":   ["Light", "Moderate", "Heavy"],
    "stress":     ["Mild", "Moderate", "High"],
    "nicotine":   ["Light", "Moderate", "Heavy"],
    "high_sugar": ["A little", "Moderate", "A lot"],
  ]
  public static func hasLevels(_ key: String) -> Bool { scale[key] != nil }
  public static func count(_ key: String) -> Int { scale[key]?.count ?? 0 }
  /// English label for a stored level; nil if the key is unleveled or the level is out of range.
  public static func label(_ key: String, _ level: Int) -> String? {
    guard let s = scale[key], level >= 1, level <= s.count else { return nil }
    return s[level - 1]
  }
}

public struct BehaviorImpact: Equatable {
  public let behavior: String; public let d: Double; public let n: Int
  /// Qualitative label from |d| (Cohen): small 0.2 / medium 0.5 / large 0.8.
  public var label: String {
    let a = abs(d); let dir = d >= 0 ? "higher" : "lower"
    if a < 0.2 { return "no clear effect" }
    return "\(a >= 0.8 ? "large" : (a >= 0.5 ? "moderate" : "small")) — \(dir) recovery"
  }
}

public enum JournalEngine {
  static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
  static func variance(_ a: [Double]) -> Double {
    guard a.count > 1 else { return 0 }; let m = mean(a)
    return a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count - 1)
  }

  /// Cohen's d of a behavior on same-day Recovery (with vs without). nil until ≥3 days each side.
  /// (v1 = same-day association; confound-adjustment via covariates is a later refinement.)
  public static func impact(behavior: String, journal: [JournalEntry], history: DailyHistory) -> BehaviorImpact? {
    let rec = Dictionary(uniqueKeysWithValues: history.days.compactMap { d in d.recovery.map { (d.date, $0) } })
    let logged = Set(journal.filter { $0.behaviors.contains(behavior) }.map { $0.date })
    var withB = [Double](), withoutB = [Double]()
    for (date, r) in rec { if logged.contains(date) { withB.append(r) } else { withoutB.append(r) } }
    guard withB.count >= 3, withoutB.count >= 3 else { return nil }
    let pooled = (((Double(withB.count - 1) * variance(withB)) + (Double(withoutB.count - 1) * variance(withoutB)))
                  / Double(withB.count + withoutB.count - 2)).squareRoot()
    guard pooled > 0 else { return nil }
    return BehaviorImpact(behavior: behavior, d: (mean(withB) - mean(withoutB)) / pooled, n: withB.count)
  }

  /// All behaviors with enough data, ranked by |effect|.
  public static func allImpacts(journal: [JournalEntry], history: DailyHistory) -> [BehaviorImpact] {
    let behaviors = Set(journal.flatMap { $0.behaviors })
    return behaviors.compactMap { impact(behavior: $0, journal: journal, history: history) }
      .sorted { abs($0.d) > abs($1.d) }
  }
}
