import Foundation

/// One recorded lap/split within a session — either an interval round that completed, or a manual Lap press during a
/// continuous workout. Each captures the segment since the previous lap.
public struct Lap: Codable, Equatable, Sendable {
  public var index: Int
  public var durationSec: Double
  public var distanceKm: Double
  public var avgHR: Int
  public var kcal: Int
  public init(index: Int, durationSec: Double, distanceKm: Double, avgHR: Int, kcal: Int) {
    self.index = index; self.durationSec = durationSec; self.distanceKm = distanceKm; self.avgHR = avgHR; self.kcal = kcal
  }
}

/// L1/L3 — a workout/activity session: per-session strain, HR stats, zones, calories, HRV-response.
/// (The whole-day strain still accumulates separately; a session is a bounded sub-window.)
public struct WorkoutSession: Codable, Equatable, Identifiable {
  public var id: String                    // start-ts key
  public var start: Double, end: Double
  public var durationSec: Double
  public var hrMin: Int, hrAvg: Int, hrMax: Int
  public var zoneSec: [Double]             // 5 (Z1..Z5)
  public var strain: Double                // Banister 0-21 for the session
  public var kcal: Double
  public var hrvPre: Double?, hrvPost: Double?
  public var type: String = "Cardio"       // Run / Bike / Strength / Cardio / Other (chosen at start)
  public var kcalMethod: String = "HR"     // D2: "HR" (steady elevated → HR-based) | "MET" (HR didn't rise → type-MET)
  public var steps: Int = 0                // G2: steps taken during the session (live sessions only)
  public var distanceKm: Double = 0        // G2: cadence/stride-estimated distance (walk/run)
  public var laps: [Lap] = []              // interval rounds + manual Lap splits
  public init(id: String, start: Double, end: Double, durationSec: Double, hrMin: Int, hrAvg: Int,
              hrMax: Int, zoneSec: [Double], strain: Double, kcal: Double,
              hrvPre: Double? = nil, hrvPost: Double? = nil, type: String = "Cardio", kcalMethod: String = "HR",
              steps: Int = 0, distanceKm: Double = 0, laps: [Lap] = []) {
    self.id = id; self.start = start; self.end = end; self.durationSec = durationSec
    self.hrMin = hrMin; self.hrAvg = hrAvg; self.hrMax = hrMax; self.zoneSec = zoneSec
    self.strain = strain; self.kcal = kcal; self.hrvPre = hrvPre; self.hrvPost = hrvPost
    self.type = type; self.kcalMethod = kcalMethod; self.steps = steps; self.distanceKm = distanceKm; self.laps = laps
  }
  // Back-compat decode: older persisted sessions lack `type` / `kcalMethod` (encode stays synthesized).
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
    durationSec = try c.decode(Double.self, forKey: .durationSec)
    hrMin = try c.decode(Int.self, forKey: .hrMin); hrAvg = try c.decode(Int.self, forKey: .hrAvg)
    hrMax = try c.decode(Int.self, forKey: .hrMax); zoneSec = try c.decode([Double].self, forKey: .zoneSec)
    strain = try c.decode(Double.self, forKey: .strain); kcal = try c.decode(Double.self, forKey: .kcal)
    hrvPre = try c.decodeIfPresent(Double.self, forKey: .hrvPre)
    hrvPost = try c.decodeIfPresent(Double.self, forKey: .hrvPost)
    type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Cardio"
    kcalMethod = try c.decodeIfPresent(String.self, forKey: .kcalMethod) ?? "HR"
    steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
    distanceKm = try c.decodeIfPresent(Double.self, forKey: .distanceKm) ?? 0
    laps = try c.decodeIfPresent([Lap].self, forKey: .laps) ?? []
  }
}

/// P1/P4 — one per-minute HR sample in the all-day ring (Codable so it persists for manual-log across app-kill).
/// G3: also carries the cumulative step count so auto-detect can derive cadence (→ classify the activity type).
public struct HRMin: Codable, Equatable, Sendable {
  public let ts: Double; public let hr: Int; public let steps: Int
  public init(ts: Double, hr: Int, steps: Int = 0) { self.ts = ts; self.hr = hr; self.steps = steps }
  enum CodingKeys: String, CodingKey { case ts, hr, steps }
  public init(from d: Decoder) throws {                       // back-compat: older rings lack `steps`
    let c = try d.container(keyedBy: CodingKeys.self)
    ts = try c.decode(Double.self, forKey: .ts); hr = try c.decode(Int.self, forKey: .hr)
    steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 0
  }
}

/// G3 — rule-based activity classification from cadence (steps/min) + intensity (avg HRR). Best-effort within our
/// sensors (HR + accel/steps; no GPS/gyro). High steady cadence = Run; moderate = Walk; few steps + high HR = Bike;
/// few steps + moderate HR = Strength.
public enum ActivityClassifier {
  public static func classify(cadenceSPM: Double, avgHRR: Double) -> String {
    if cadenceSPM >= 140 { return "Run" }
    if cadenceSPM >= 70 { return "Walk" }
    if avgHRR >= 0.55 { return "Bike" }
    return "Strength"
  }
}

/// Live accumulator — feed HR samples while a workout is active, then snapshot a `WorkoutSession`.
public struct WorkoutAccumulator {
  let startTs, hrMax, hrRest, tau, weightKg, age, heightCm: Double
  let male: Bool
  let maxGapSec: Double               // max dt counted per step: ~5s for live HR (1-2s spacing); ~90s for
                                      // reconstructed 1-min windows (manual-log / auto-detect) so they aren't under-counted
  var lastTs: Double?
  var trimp = 0.0
  var zoneSec = [Double](repeating: 0, count: 5)
  var kcal = 0.0
  var hrSum = 0, hrCount = 0, hrMin = 1000, hrMaxSeen = 0
  public init(startTs: Double, hrMax: Double = 190.5, hrRest: Double = 53,
              tau: Double = 100, weightKg: Double = 83, age: Double = 25,
              heightCm: Double = 183, male: Bool = true, maxGapSec: Double = 5) {
    self.startTs = startTs; self.hrMax = hrMax; self.hrRest = hrRest
    self.tau = tau; self.weightKg = weightKg; self.age = age
    self.heightCm = heightCm; self.male = male; self.maxGapSec = maxGapSec; lastTs = nil
  }

  public mutating func feed(ts: Double, hr: Int) {
    guard (40...220).contains(hr) else { return }
    hrSum += hr; hrCount += 1; hrMin = Swift.min(hrMin, hr); hrMaxSeen = Swift.max(hrMaxSeen, hr)
    defer { lastTs = ts }
    guard let last = lastTs else { return }
    let dt = Swift.min(Swift.max(ts - last, 0), maxGapSec)
    let hrr = Swift.max(0, Swift.min(1, (Double(hr) - hrRest) / (hrMax - hrRest)))
    trimp += Physiology.banisterTRIMP(dtMin: dt / 60.0, hrr: hrr, male: male)
    zoneSec[Physiology.karvonenZone(hr: Double(hr), hrMax: hrMax, hrRest: hrRest)] += dt
    kcal += Physiology.branchedKcalPerMin(hr: Double(hr), accelG: nil, weightKg: weightKg,
              heightCm: heightCm, age: age, male: male, hrMax: hrMax, hrRest: hrRest) * (dt / 60.0)
  }

  public var strain: Double { Scores.strain(trimp: trimp, tau: tau) }
  public var kcalLive: Double { kcal }                                   // live workout calories (real-time)
  public var avgHRLive: Int { hrCount > 0 ? hrSum / hrCount : 0 }
  public var peakHRLive: Int { hrCount > 0 ? hrMaxSeen : 0 }
  public var zoneSecLive: [Double] { zoneSec }

  public func session(end: Double, hrvPre: Double? = nil, hrvPost: Double? = nil) -> WorkoutSession {
    WorkoutSession(id: String(Int(startTs)), start: startTs, end: end, durationSec: Swift.max(0, end - startTs),
      hrMin: hrCount > 0 ? hrMin : 0, hrAvg: hrCount > 0 ? hrSum / hrCount : 0, hrMax: hrMaxSeen,
      zoneSec: zoneSec, strain: strain, kcal: kcal, hrvPre: hrvPre, hrvPost: hrvPost)
  }

  /// P1 — build a WorkoutSession from an arbitrary (ts,hr) window (manual-log / auto-detect reuse the live math).
  public static func build(samples: [(ts: Double, hr: Int)], hrMax: Double, hrRest: Double, tau: Double,
                           weightKg: Double, age: Double, heightCm: Double, male: Bool, type: String) -> WorkoutSession? {
    guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }
    var acc = WorkoutAccumulator(startTs: first.ts, hrMax: hrMax, hrRest: hrRest, tau: tau,
                                 weightKg: weightKg, age: age, heightCm: heightCm, male: male, maxGapSec: 90)
    for s in samples { acc.feed(ts: s.ts, hr: s.hr) }
    var session = acc.session(end: last.ts)
    session.type = type
    let minutes = (last.ts - first.ts) / 60
    let avgHRR = max(0, (Double(session.hrAvg) - hrRest) / Swift.max(1, hrMax - hrRest))   // D2 HR-gate
    let r = Physiology.reconcileSessionKcal(hrKcal: session.kcal, type: type, weightKg: weightKg,
                                            minutes: minutes, avgHRR: avgHRR)
    session.kcal = r.kcal; session.kcalMethod = r.method
    return session
  }
}

/// P3 — passive activity auto-detection (WHOOP-style): find a completed block of continuously elevated HR.
public enum AutoDetect {
  /// Returns the index window [start,end] of the most recent COMPLETED elevated block (HRR ≥ 0.3 ≈ Zone 2+),
  /// lasting ≥ minMinutes and followed by ≥ cooldownMin non-elevated samples (HR returned to baseline). nil if none.
  /// `hr` is a per-minute series. Caller checks the resulting strain ≥ 8 before logging.
  public static func scan(hr: [Double], hrRest: Double, hrMax: Double,
                          minMinutes: Int = 15, cooldownMin: Int = 3) -> (start: Int, end: Int)? {
    guard hr.count >= minMinutes + cooldownMin, hrMax > hrRest else { return nil }
    let thr = hrRest + 0.3 * (hrMax - hrRest)
    func elevated(_ i: Int) -> Bool { hr[i] >= thr }
    var best: (Int, Int)? = nil
    var i = 0
    while i < hr.count {
      guard elevated(i) else { i += 1; continue }
      var j = i
      while j + 1 < hr.count && elevated(j + 1) { j += 1 }            // run [i...j]
      let after = (j + 1)..<Swift.min(hr.count, j + 1 + cooldownMin)
      if after.count >= cooldownMin, after.allSatisfy({ !elevated($0) }), (j - i + 1) >= minMinutes {
        best = (i, j)                                                  // keep the latest completed block
      }
      i = j + 1
    }
    return best
  }
}
