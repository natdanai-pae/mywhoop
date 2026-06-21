import Foundation

/// L3/L5 — nightly Recovery + Readiness from sleep-window vitals vs personal baselines.
/// Recovery = 100·Φ(0.55·zHRV −0.20·zRHR −0.10·zRR +0.15·zSleep) (missing terms = neutral z=0).
/// z is computed vs the baseline BEFORE folding tonight in (compare to history). Warms up over ≥7 nights.
public struct RecoveryResult: Equatable {
  public let recovery: Double?    // 0-100, nil while warming up
  public let readiness: Double?   // 0-100 headline
  public let ready: Bool
  public let nights: Int          // baseline observation count
  public init(recovery: Double?, readiness: Double?, ready: Bool, nights: Int) {
    self.recovery = recovery; self.readiness = readiness; self.ready = ready; self.nights = nights
  }
}

/// One input's contribution to the Recovery score (Oura-style decomposition — "what's driving today's score").
public struct RecoveryContributor: Equatable, Sendable {
  public let key: String        // "HRV" / "RHR" / "Resp" / "Sleep"
  public let z: Double          // standardized deviation vs your baseline
  public let weighted: Double   // signed effect on the score (+ boosts, − drags), = weight · z · polarity
  public init(key: String, z: Double, weighted: Double) { self.key = key; self.z = z; self.weighted = weighted }
}

public enum RecoveryEngine {
  /// Decompose Recovery into its weighted contributors from a day's record vs the current baselines.
  /// Display-only (baselines already include the night → tiny self-bias, directionally correct). nil until ready.
  public static func contributors(_ r: DailyRecord, state: PersistedState) -> [RecoveryContributor]? {
    guard let zh = r.lnRMSSD.flatMap({ state.hrvBaseline.z($0) }),
          let zr = r.rhr.flatMap({ state.rhrBaseline.z($0) }) else { return nil }
    let zrr = r.resp.flatMap { state.respBaseline.z($0) } ?? 0
    let zs = r.sleepScore.flatMap { state.sleepBaseline.z($0) } ?? 0
    let w = state.params.recoveryWeights                 // [zHRV, zRHR, zRR, zSleep] = [0.55,0.20,0.10,0.15]
    return [RecoveryContributor(key: "HRV",   z: zh,  weighted:  w[0] * zh),
            RecoveryContributor(key: "RHR",   z: zr,  weighted: -w[1] * zr),
            RecoveryContributor(key: "Resp",  z: zrr, weighted: -w[2] * zrr),
            RecoveryContributor(key: "Sleep", z: zs,  weighted:  w[3] * zs)]
  }

  /// Process one night. Mutates `state` (folds tonight into the rolling baselines).
  public static func process(hrv: Double, rhr: Double, resp: Double?, sleepScore: Double?,
                             tsbNorm: Double = 50, illnessPenalty: Double = 0,
                             state: inout PersistedState) -> RecoveryResult {
    let lnHRV = log(max(hrv, 1))
    // z vs history (pre-update)
    let zHRV = state.hrvBaseline.z(lnHRV)
    let zRHR = state.rhrBaseline.z(rhr)
    let zResp = resp.flatMap { state.respBaseline.z($0) }
    let zSleep = sleepScore.flatMap { state.sleepBaseline.z($0) }
    // fold tonight in
    state.hrvBaseline.update(lnHRV)
    state.rhrBaseline.update(rhr)
    if let r = resp { state.respBaseline.update(r) }
    if let s = sleepScore { state.sleepBaseline.update(s) }
    // need the two dominant terms before surfacing a score
    guard let zh = zHRV, let zr = zRHR else {
      return RecoveryResult(recovery: nil, readiness: nil, ready: false, nights: state.hrvBaseline.n)
    }
    let rec = Scores.recovery(zHRV: zh, zRHR: zr, zRR: zResp ?? 0, zSleep: zSleep ?? 0,
                              weights: state.params.recoveryWeights)
    let rdy = Scores.readiness(recovery: rec, sleepScore: sleepScore ?? rec,
                               tsbNorm: tsbNorm, illnessPenalty: illnessPenalty)
    return RecoveryResult(recovery: rec, readiness: rdy, ready: true, nights: state.hrvBaseline.n)
  }

  /// Convenience: process one night straight from a staged `SleepResult`. Returns nil if the night
  /// isn't usable (staging failed, or no sleep RHR/HRV to compare). Otherwise folds it into the baselines.
  public static func processNight(_ sleep: SleepResult, tsbNorm: Double = 50, illnessPenalty: Double = 0,
                                  state: inout PersistedState) -> RecoveryResult? {
    guard sleep.ok, let rhr = sleep.rhr, let hrv = sleep.sleepHRV else { return nil }
    return process(hrv: hrv, rhr: rhr, resp: sleep.sleepResp, sleepScore: sleep.sleepScore,
                   tsbNorm: tsbNorm, illnessPenalty: illnessPenalty, state: &state)
  }
}
