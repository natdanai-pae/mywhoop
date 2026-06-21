import Foundation

/// Proactive coach — composes the push-notification copy for event-driven insights, modeled on WHOOP Daily Outlook /
/// Day-in-Review, the Garmin Morning Report, and Apple's ring-closure nudges. Pure + deterministic (rule-based, no AI):
/// triggers must never depend on a network call. Copy is short (title + 1-2 lines), cites the user's REAL numbers and
/// what they're compared against, and stays quiet when there's nothing actionable (callers gate + dedupe).
public enum ProactiveInsights {

  /// Morning report at wake (sleep finalize or flash backfill) — sleep quality + recovery + today's strain guidance.
  public static func morningReport(sleepScore: Double?, tstH: Double, needH: Double?, deepMin: Int, remMin: Int,
                                   recovery: Double?, hrvMs: Double?, hrvBaseMs: Double?,
                                   rhr: Double?, rhrBase: Double?, strainLo: Int? = nil, strainHi: Int? = nil)
                                   -> (title: String, body: String) {
    var title = "Morning report"
    if let s = sleepScore { title += " — sleep \(Int(s))/100" }
    var parts: [String] = []
    var sleepLine = String(format: "%.1fh", tstH)
    if let n = needH, n > 0 { sleepLine += String(format: " of %.1fh need (%d%%)", n, Int(tstH / n * 100)) }
    sleepLine += " · deep \(deepMin)m · REM \(remMin)m"
    parts.append(sleepLine)
    if let r = recovery {
      parts.append("Recovery \(Int(r))% (\(r >= 67 ? "green — good day to push" : r >= 34 ? "yellow — keep it controlled" : "red — prioritize rest"))")
    }
    var vs: [String] = []
    if let h = hrvMs, let b = hrvBaseMs, b > 0 {
      let d = (h - b) / b * 100
      if abs(d) >= 5 { vs.append(String(format: "HRV %d ms (%+.0f%% vs baseline)", Int(h), d)) }
    }
    if let r = rhr, let b = rhrBase, b > 0 {
      let d = r - b
      if abs(d) >= 2 { vs.append(String(format: "RHR %d (%+.0f vs baseline)", Int(r), d)) }
    }
    if !vs.isEmpty { parts.append(vs.joined(separator: " · ")) }
    if let lo = strainLo, let hi = strainHi { parts.append("Suggested strain today: \(lo)–\(hi)") }
    return (title, parts.joined(separator: "\n"))
  }

  /// Post-workout summary — effort vs HRmax, calories (+how computed), and Move-goal progress with the exact remainder.
  public static func workoutSummary(type: String, minutes: Int, kcal: Int, kcalMethod: String,
                                    avgHR: Int, peakHR: Int, hrMax: Double, strain: Double,
                                    moveDone: Int, moveGoal: Int) -> (title: String, body: String) {
    let title = "\(type) done — \(minutes) min · \(kcal) kcal"
    var parts: [String] = []
    var hrLine = "HR avg \(avgHR), peak \(peakHR)"
    if hrMax > 0 && peakHR > 0 { hrLine += " (\(Int(Double(peakHR) / hrMax * 100))% of your max)" }
    parts.append(hrLine + String(format: " · strain %.1f", strain))
    parts.append("Calories via \(kcalMethod == "MET" ? "activity type (HR stayed low)" : "heart rate")")
    if moveGoal > 0 {
      parts.append(moveDone >= moveGoal ? "Move goal hit: \(moveDone)/\(moveGoal) kcal 🎉"
                                        : "Move goal: \(moveDone)/\(moveGoal) kcal — \(moveGoal - moveDone) to go")
    }
    return (title, parts.joined(separator: "\n"))
  }

  /// Sustained high stress while INACTIVE — motion-aware (exercise is excluded by the caller), explains the evidence.
  public static func stressAlert(level: Double, minutes: Int, hr: Int?, rhr: Double?) -> (title: String, body: String) {
    let title = String(format: "Stress high — %.1f/3 for %d min", level, minutes)
    var body = "You're not moving, so this isn't exercise"
    if let h = hr, let r = rhr, r > 0 { body += " — HR \(h) vs resting \(Int(r))" }
    body += ". Try 5 slow breaths (longer exhale), water, or a short walk."
    return (title, body)
  }

  /// Evening Move-goal nudge when the day is slipping (fired once, late afternoon, only if clearly behind).
  public static func moveNudge(done: Int, goal: Int) -> (title: String, body: String) {
    ("Move goal: \(done)/\(goal) kcal",
     "\(goal - done) kcal to go — a brisk ~\(max(10, Int(Double(goal - done) / 5.0))) min walk would close it.")
  }

  /// Move-goal completion (ring closed).
  public static func moveDone(goal: Int) -> (title: String, body: String) {
    ("Move goal closed — \(goal) kcal 🎉", "Active burn target hit for today.")
  }

  /// Tonight's recommended bedtime (WHOOP Sleep-Planner style): wake anchor − tonight's need (incl. strain + debt).
  public static func bedtime(bedMin: Int, wakeMin: Int, needH: Double, debtH: Double) -> (title: String, body: String) {
    func hm(_ m: Int) -> String { String(format: "%02d:%02d", (m % 1440) / 60, m % 60) }
    var body = String(format: "Tonight's need is %.1fh", needH)
    if debtH >= 0.5 { body += String(format: " (incl. %.1fh sleep debt)", debtH) }
    body += " to wake at your usual \(hm(wakeMin)) — start winding down."
    return ("Bedtime tonight ~\(hm(bedMin))", body)
  }

  /// Evening day-in-review (Garmin Body-Battery daily summary / WHOOP Day-in-Review style).
  public static func dayInReview(strain: Double, steps: Int, activeKcal: Int, totalKcal: Int,
                                 energy: Double, hardZoneMin: Int) -> (title: String, body: String) {
    var parts = [String(format: "Strain %.1f/21 · %d steps · %d kcal (%d active)", strain, steps, totalKcal, activeKcal)]
    if hardZoneMin > 0 { parts.append("\(hardZoneMin) min in Z3+") }
    parts.append("Energy now \(Int(energy))/100" + (energy < 30 ? " — running low, favor an early night" : ""))
    return ("Day in review", parts.joined(separator: "\n"))
  }

  /// Daytime inactivity nudge (Garmin Move alert / Apple stand ring).
  public static func inactivityNudge(stillMin: Int) -> (title: String, body: String) {
    ("On your feet — still for \(stillMin) min",
     "A 5-min walk restarts circulation and nudges your energy back up.")
  }

  /// Recovery dropped into the red, or fell sharply vs yesterday → proactively flag it (notification copy).
  public static func recoveryAlert(today: Double, yesterday: Double?) -> (title: String, body: String)? {
    let drop = (yesterday ?? today) - today
    guard today < 34 || drop >= 15 else { return nil }
    let title = "Recovery \(Int(today))% — ease off today"
    let body = today < 34 ? "In the red. Prioritize rest, hydration, and an early night."
                          : "Down \(Int(drop)) pts vs yesterday — you're under-recovered."
    return (title, body)
  }

  /// HRV well below the user's own baseline (z ≤ −1.3) → autonomic stress / under-recovery flag (notification copy).
  public static func hrvLowAlert(rmssd: Double, z: Double) -> (title: String, body: String)? {
    guard z <= -1.3 else { return nil }
    return ("HRV low — \(Int(rmssd)) ms", "Well below your baseline. Stress, poor sleep, alcohol or illness can do this — go easy.")
  }
  /// Skin temperature elevated vs the nightly baseline (Δ ≥ +0.5°C) → early illness / strain signal.
  public static func skinTempHighAlert(deltaC: Double) -> (title: String, body: String)? {
    guard deltaC >= 0.5 else { return nil }
    return (String(format: "Skin temp +%.1f°C", deltaC),
            "Higher than your baseline overnight. Often an early sign of illness or heavy load — watch how you feel.")
  }
  /// Several short nights in a row → accumulating sleep debt (notification copy).
  public static func sleepStreakAlert(nights: Int, avgH: Double) -> (title: String, body: String)? {
    guard nights >= 3 else { return nil }
    return ("\(nights) short nights in a row", String(format: "Averaging %.1fh — sleep debt is stacking up. Protect tonight's sleep.", avgH))
  }

  /// Monday-morning weekly report (WHOOP weekly performance assessment style): fitness trend, sleep, training shape.
  public static func weeklyReport(weekStrain: Double, prevWeekStrain: Double, sessions: Int,
                                  avgSleepH: Double, avgSleepScore: Double?, avgRecovery: Double?,
                                  monotony: Double?, steps: Int, kcal: Int) -> (title: String, body: String) {
    let d = weekStrain - prevWeekStrain
    let trend = prevWeekStrain <= 0 ? "" : d > 2 ? " — load ↑" : d < -2 ? " — load ↓" : " — load steady"
    var parts = [String(format: "Training: %.0f strain over %d sessions (prev week %.0f)", weekStrain, sessions, prevWeekStrain)]
    var sleepLine = String(format: "Sleep: %.1fh avg", avgSleepH)
    if let s = avgSleepScore { sleepLine += " · score \(Int(s))" }
    if let r = avgRecovery { sleepLine += " · recovery \(Int(r))%" }
    parts.append(sleepLine)
    if let m = monotony {
      if m > 2.0 { parts.append(String(format: "Monotony %.1f — same load every day raises overuse risk; vary hard/easy days", m)) }
      else { parts.append(String(format: "Monotony %.1f — good hard/easy variation", m)) }
    }
    parts.append("Totals: \(steps) steps · \(kcal) kcal")
    return ("Weekly report\(trend)", parts.joined(separator: "\n"))
  }

  /// Passive irregular-rhythm SCREENING confirmed a persistent pattern (Apple-IRN-style multi-reading confirmation).
  /// NON-DIAGNOSTIC — never says "AFib"; frames it as a screening signal to confirm with a clinician / an ECG.
  public static func afScreenAlert(irregular: Int, total: Int) -> (title: String, body: String) {
    ("Irregular rhythm noticed — \(irregular) of last \(total) checks",
     "Several background heart-rhythm readings looked irregular. This isn't a diagnosis — consider seeing a clinician or taking an ECG.")
  }

  /// Elevated HR at rest (Garmin abnormal-HR pattern): sustained, while still, NOT exercising. Wellness tone, not medical.
  public static func abnormalRestHR(hr: Int, rhr: Double?, minutes: Int) -> (title: String, body: String) {
    var body = "You're still and not exercising"
    if let r = rhr, r > 0 { body += " — that's \(hr - Int(r)) above your resting \(Int(r))" }
    body += ". Stress, caffeine, heat or illness can do this; worth a check-in if it persists."
    return ("HR \(hr) at rest for \(minutes) min", body)
  }
}
