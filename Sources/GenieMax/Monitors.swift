import Foundation

/// L3/L4 — live "Monitor" models: motion state, Stress (0–3, WHOOP-style), Energy (Body-Battery analog).
/// Pure + testable; WhoopBLE feeds them the live stream and publishes the readings.

public enum MotionState: String, Sendable, Equatable { case still, moving, active }

public enum Monitors {
  /// Live movement from a smoothed mean |accel|−1g (g). Thresholds tunable on real wrist data.
  public static func motionState(_ accelG: Double) -> MotionState {
    if accelG < 0.03 { return .still }
    if accelG < 0.12 { return .moving }
    return .active
  }
  /// Hysteresis version for the displayed live indicator: asymmetric enter/exit thresholds + a dead-band so
  /// `motionG` hovering near a boundary doesn't chatter still↔moving every IMU frame. Enter moving at 0.05 /
  /// fall back to still at 0.025; enter active at 0.14 / fall back at 0.10.
  public static func motionState(_ accelG: Double, prev: MotionState) -> MotionState {
    switch prev {
    case .still:  return accelG > 0.14 ? .active : (accelG > 0.05 ? .moving : .still)
    case .moving: return accelG > 0.14 ? .active : (accelG < 0.025 ? .still : .moving)
    case .active: return accelG < 0.10 ? (accelG < 0.025 ? .still : .moving) : .active
    }
  }

  public struct StressReading: Equatable, Sendable {
    public let level: Double      // 0...3 (fractional → drives the gauge)
    public let label: String      // Calm / Balanced / Elevated / High / Activity
    public let isActivity: Bool   // movement → physical, not psychological stress
    public init(level: Double, label: String, isActivity: Bool) {
      self.level = level; self.label = label; self.isActivity = isActivity
    }
  }

  /// WHOOP-style stress 0–3 from Baevsky SI vs a personal baseline, motion-aware.
  /// When active, movement dominates HR/HRV → report it as Activity, not stress (WHOOP's motion gate).
  public static func stress(si: Double, baselineMean: Double, baselineSD: Double, motion: MotionState) -> StressReading {
    if motion == .active { return StressReading(level: 3, label: "Exercising", isActivity: true) }
    guard baselineSD > 0, baselineMean > 0, si > 0 else {
      return StressReading(level: 1, label: "Balanced", isActivity: false)   // pre-baseline neutral
    }
    let z = (si - baselineMean) / baselineSD
    let lvl = max(0, min(3, 1.5 + z))                    // center 1.5; ±1.5σ spans 0…3
    return StressReading(level: lvl, label: stressLabel(lvl), isActivity: false)
  }
  public static func stressLabel(_ lvl: Double) -> String {
    lvl < 1 ? "Calm" : (lvl < 2 ? "Balanced" : (lvl < 2.6 ? "Elevated" : "High"))
  }

  /// v2 stress (WHOOP-style): HR ELEVATED + HRV SUPPRESSED vs your resting baseline → 0…3, motion-gated.
  /// Far less spiky than Baevsky SI (no RR-range in a denominator). HRV is optional → HR-only when it's
  /// absent, so a brief RR dropout degrades gracefully instead of collapsing the reading. Returns the RAW
  /// (pre-smoothing) level; the caller EWMA-smooths it. `hrSD`/`hrvSD` are floored to avoid divide-by-tiny.
  public static func stressHRHRV(hr: Double, hrv: Double?, temp: Double? = nil,
                                 hrBase: Double, hrSD: Double, hrvBase: Double?, hrvSD: Double,
                                 tempBase: Double? = nil, tempSD: Double = 0,
                                 ready: Bool, motion: MotionState) -> StressReading {
    if motion == .active { return StressReading(level: 3, label: "Exercising", isActivity: true) }
    // `ready` = the resting baseline has warmed up. Until then (and with no baseline) stay neutral — a tiny
    // baseline has near-zero SD, so normal HR/HRV wobble would otherwise read as "High" (cold-start spike).
    guard ready, hrBase > 0, hr > 0 else { return StressReading(level: 1, label: "Balanced", isActivity: false) }
    func clamp2(_ x: Double) -> Double { max(-2, min(2, x)) }   // one odd sample can't peg the gauge
    // SD floors = real resting variability (HR ~7 bpm, RMSSD ~12 ms) so normal wobble ≠ stress.
    let zHR = clamp2((hr - hrBase) / max(hrSD, 7))             // ~14 bpm above baseline to peak via HR alone
    var z = zHR
    if let hrv = hrv, hrv > 0, let hb = hrvBase, hb > 0 {
      let zHRV = clamp2((hb - hrv) / max(hrvSD, 12))           // HRV below baseline → stress (suppression)
      z = 0.6 * zHR + 0.4 * zHRV                               // HR weighed more (RMSSD is noisier)
    }
    // #5 Fitbit-style skin-temp: a SMALL additive nudge (elevated skin temp ↑ stress). Slow + confounded by
    // ambient → tiny weight, clamped ±1, so it can only shift the level by ≤0.15. Never dominates HR/HRV.
    if let t = temp, let tb = tempBase {
      z += 0.15 * max(-1, min(1, (t - tb) / max(tempSD, 0.3)))
    }
    let lvl = max(0, min(3, 1.5 + z))
    return StressReading(level: lvl, label: stressLabel(lvl), isActivity: false)
  }

  /// Energy "battery" 0–100 (Garmin Body-Battery analog). Heuristic — calibrate vs real day-shape later.
  /// Morning level seeded from last night's recovery + sleep. During warm-up (no Recovery yet, <7 nights) lean on
  /// sleep so a great night isn't dragged down by a neutral 50 default.
  public static func startEnergy(recovery: Double?, sleepScore: Double?) -> Double {
    let s = sleepScore ?? 60
    let r = recovery ?? max(s, 55)
    return max(20, min(100, 0.5 * r + 0.5 * s))
  }
  /// Body Battery as a DERIVED value — recomputed every update as the morning `seed` eroded by the day's
  /// accumulated strain. Stateless, so it can NEVER get stuck at the floor the way a free-running accumulator can
  /// (the old `stepEnergy` could only re-seed at energy≤0 / midnight, so a once-drained battery stayed pinned at 5
  /// all day). Good sleep + a rested day ≈ the seed; a workout drops it proportionally and it self-corrects instantly.
  public static func deriveEnergy(seed: Double, dayStrain: Double) -> Double {
    max(5, min(100, seed - max(0, dayStrain) * 3.2))
  }
  /// Legacy free-running step (kept for reference/tests). Superseded by `deriveEnergy`.
  public static func stepEnergy(_ e: Double, dStrain: Double, stressLevel: Double, dtMin: Double, motion: MotionState) -> Double {
    let strainDrain = max(0, dStrain) * 3.5
    let stressDrain = max(0, stressLevel - 1.0) * 0.05 * dtMin
    let awakeDrain  = 0.02 * dtMin
    let recharge    = (motion == .still && stressLevel < 1.2) ? 0.25 * dtMin : 0
    return max(5, min(100, e - strainDrain - stressDrain - awakeDrain + recharge))
  }
  /// Reserve band for the battery color: 0=very low … 3=high.
  public static func energyBand(_ e: Double) -> Int { e >= 76 ? 3 : (e >= 51 ? 2 : (e >= 26 ? 1 : 0)) }
}
