import Foundation

/// L5 — personal rolling baselines + tunable calibration, all Codable for local store + Firebase mirror.

/// EWMA rolling baseline (mean + variance) with the ≥7-observation readiness gate (gray-out before).
/// α per the lock: HRV readiness 0.25 (~7d); RHR/temp slow context 0.0645 (~30d).
public struct RollingBaseline: Codable, Equatable {
  public var alpha: Double
  public private(set) var n: Int
  public private(set) var mean: Double
  public private(set) var variance: Double
  public init(alpha: Double = 0.25) { self.alpha = alpha; n = 0; mean = 0; variance = 0 }

  public var sd: Double { variance.squareRoot() }
  public var ready: Bool { n >= 7 }                       // gate: don't surface z until ≥7 obs

  public mutating func update(_ x: Double) {
    n += 1
    if n == 1 { mean = x; variance = 0; return }
    let d = x - mean
    mean += alpha * d                                     // EWMA mean (West incremental)
    variance = (1 - alpha) * (variance + alpha * d * d)   // EWMA variance
  }
  /// z-score vs baseline, or nil while warming up / degenerate.
  public func z(_ x: Double) -> Double? { (ready && sd > 0) ? (x - mean) / sd : nil }
}

/// Tunable parameters (calibrated over time / after a WHOOP unlock).
public struct CalibrationParams: Codable, Equatable {
  public var strainTau: Double
  public var cusumK: Double
  public var cusumH: Double
  public var measuredHRmax: Double?                       // overrides Tanaka when set (A3)
  public var recoveryWeights: [Double]                    // [zHRV, zRHR, zRR, zSleep]
  public init(strainTau: Double = 100, cusumK: Double = 0.5, cusumH: Double = 5,
              measuredHRmax: Double? = nil, recoveryWeights: [Double] = [0.55, 0.20, 0.10, 0.15]) {
    self.strainTau = strainTau; self.cusumK = cusumK; self.cusumH = cusumH
    self.measuredHRmax = measuredHRmax; self.recoveryWeights = recoveryWeights
  }
  /// Measured HRmax wins; else Tanaka fallback (removes ±10bpm error when measured).
  public func hrMax(age: Double) -> Double { measuredHRmax ?? Physiology.tanakaHRmax(age: age) }
}

/// The whole persisted state (Codable → local file + Firebase mirror).
public struct PersistedState: Codable, Equatable {
  public var hrvBaseline: RollingBaseline
  public var rhrBaseline: RollingBaseline
  public var respBaseline: RollingBaseline
  public var sleepBaseline: RollingBaseline
  public var tempBaseline: RollingBaseline
  public var params: CalibrationParams
  public var history: DailyHistory
  public var workouts: [WorkoutSession]
  public var journal: [JournalEntry]
  public var profile: Profile
  public var intakeKcal: Double?      // C4 (legacy): today's logged food intake — superseded by intakeLog
  public var intakeDate: String?      // yyyy-MM-dd the legacy intake applies to
  public var intakeLog: [String: Double]  // E3: per-day food intake (yyyy-MM-dd → kcal) for the long-term log/graph
  public var intakeEntries: [String: [IntakeEntry]]  // F1: per-day meal entries (day total = their sum)
  public var favoriteFoods: [IntakeEntry]            // F1: starred foods for one-tap re-add
  public var calorieGoal: Int                        // 0 = lose, 1 = maintain, 2 = gain → daily intake target offset
  public var moveGoal: Int                           // Apple-style daily ACTIVE-energy goal (kcal), independent of eating
  public var aiProvider: Int                         // 0 = Anthropic (native) · 1 = OpenAI-compatible (OpenRouter/OpenAI/local)
  public var aiBaseURL: String                       // OpenAI-compatible base URL, e.g. https://openrouter.ai/api/v1
  public var aiModel: String                         // model id, e.g. google/gemini-2.5-flash
  public var bodyScans: [BodyScan]                   // body-composition scans (InBody photos), time series for the Body screen
  public var coachMemo: String                       // user-provided "about me / goals" injected into the AI coach dossier
  // #3 — DAYTIME-resting baselines for the live Stress Monitor (WHOOP-style ~14-day reference). One observation
  // per day (that day's still-sample resting mean) → a STABLE center, persisted across launches. Distinct from
  // the sleeping rhr/temp baselines above (awake-resting HR ≠ sleeping RHR).
  public var restHRBaseline: RollingBaseline
  public var restHRVBaseline: RollingBaseline
  public var restTempBaseline: RollingBaseline
  public var restBaselineDate: String                // last yyyy-MM-dd we fed an observation (≤1/day across restarts)
  public init() {
    hrvBaseline = RollingBaseline(alpha: 0.25)     // 7-day readiness (Plews)
    rhrBaseline = RollingBaseline(alpha: 0.0645)   // 30-day
    respBaseline = RollingBaseline(alpha: 0.0645)
    sleepBaseline = RollingBaseline(alpha: 0.0645)
    tempBaseline = RollingBaseline(alpha: 0.0645)
    params = CalibrationParams()
    history = DailyHistory()
    workouts = []
    journal = []
    profile = Profile()
    intakeLog = [:]
    intakeEntries = [:]
    favoriteFoods = []
    calorieGoal = 1                                  // maintain by default
    moveGoal = 500                                   // Apple's default Move goal
    aiProvider = 0; aiBaseURL = ""; aiModel = ""     // default Anthropic-native
    bodyScans = []
    coachMemo = ""
    restHRBaseline = RollingBaseline(alpha: 0.13)    // ~14-day resting reference (fed 1×/day)
    restHRVBaseline = RollingBaseline(alpha: 0.13)
    restTempBaseline = RollingBaseline(alpha: 0.13)
    restBaselineDate = ""
  }

  // encode is synthesized; decode is back-compat (older persisted blobs lack `history`/`workouts`/`profile`).
  enum CodingKeys: String, CodingKey {
    case hrvBaseline, rhrBaseline, respBaseline, sleepBaseline, tempBaseline, params, history, workouts, journal, profile
    case intakeKcal, intakeDate, intakeLog, intakeEntries, favoriteFoods, calorieGoal, moveGoal
    case aiProvider, aiBaseURL, aiModel, bodyScans, coachMemo
    case restHRBaseline, restHRVBaseline, restTempBaseline, restBaselineDate
  }
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    hrvBaseline = try c.decode(RollingBaseline.self, forKey: .hrvBaseline)
    rhrBaseline = try c.decode(RollingBaseline.self, forKey: .rhrBaseline)
    respBaseline = try c.decode(RollingBaseline.self, forKey: .respBaseline)
    sleepBaseline = try c.decode(RollingBaseline.self, forKey: .sleepBaseline)
    tempBaseline = try c.decode(RollingBaseline.self, forKey: .tempBaseline)
    params = try c.decode(CalibrationParams.self, forKey: .params)
    history = try c.decodeIfPresent(DailyHistory.self, forKey: .history) ?? DailyHistory()
    workouts = try c.decodeIfPresent([WorkoutSession].self, forKey: .workouts) ?? []
    journal = try c.decodeIfPresent([JournalEntry].self, forKey: .journal) ?? []
    profile = try c.decodeIfPresent(Profile.self, forKey: .profile) ?? Profile()
    intakeKcal = try c.decodeIfPresent(Double.self, forKey: .intakeKcal)
    intakeDate = try c.decodeIfPresent(String.self, forKey: .intakeDate)
    var log = try c.decodeIfPresent([String: Double].self, forKey: .intakeLog) ?? [:]
    if log.isEmpty, let k = intakeKcal, let d = intakeDate { log[d] = k }   // migrate legacy single-day intake
    intakeLog = log
    intakeEntries = try c.decodeIfPresent([String: [IntakeEntry]].self, forKey: .intakeEntries) ?? [:]
    favoriteFoods = try c.decodeIfPresent([IntakeEntry].self, forKey: .favoriteFoods) ?? []
    calorieGoal = try c.decodeIfPresent(Int.self, forKey: .calorieGoal) ?? 1
    moveGoal = try c.decodeIfPresent(Int.self, forKey: .moveGoal) ?? 500
    aiProvider = try c.decodeIfPresent(Int.self, forKey: .aiProvider) ?? 0
    aiBaseURL = try c.decodeIfPresent(String.self, forKey: .aiBaseURL) ?? ""
    aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? ""
    bodyScans = try c.decodeIfPresent([BodyScan].self, forKey: .bodyScans) ?? []
    coachMemo = try c.decodeIfPresent(String.self, forKey: .coachMemo) ?? ""
    restHRBaseline = try c.decodeIfPresent(RollingBaseline.self, forKey: .restHRBaseline) ?? RollingBaseline(alpha: 0.13)
    restHRVBaseline = try c.decodeIfPresent(RollingBaseline.self, forKey: .restHRVBaseline) ?? RollingBaseline(alpha: 0.13)
    restTempBaseline = try c.decodeIfPresent(RollingBaseline.self, forKey: .restTempBaseline) ?? RollingBaseline(alpha: 0.13)
    restBaselineDate = try c.decodeIfPresent(String.self, forKey: .restBaselineDate) ?? ""
  }
}
