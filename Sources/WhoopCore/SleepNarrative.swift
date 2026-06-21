import Foundation

/// Phase C — the rule-based reading shown in the "What your sleep means" card. The AI layer adds a night-specific
/// tip on top in the UI (hybrid); this is the always-on, offline base. Generated in English to match the app's
/// other analysis copy. Targets cited: AASM/WHOOP/Oura (Deep 13–25%, REM 20–25%, efficiency ≥85%, few awakenings).
public struct SleepInsight: Equatable {
  public let summary: String     // one-paragraph "what this shows"
  public let keep: [String]      // green — what's working, how to protect it
  public let improve: [String]   // amber — what to work on, how
}

public enum SleepNarrative {
  public static func build(deep: Int, rem: Int, light: Int, wake: Int, cycles: Int, awakenings: Int,
                           tstH: Double, needH: Double, age: Double) -> SleepInsight {
    let tst = max(1, deep + rem + light)
    let tib = max(1, deep + rem + light + wake)
    let deepPct = Double(deep) / Double(tst) * 100
    let remPct = Double(rem) / Double(tst) * 100
    let eff = Double(tst) / Double(tib) * 100
    let n = HealthRef.sleepStageNorms(age: age)
    let deepOK = n.deep.contains(deepPct), remOK = n.rem.contains(remPct)

    let h = Int(tstH), m = Int((tstH - Double(h)) * 60 + 0.5)
    var s = "\(h)h \(String(format: "%02d", m))m of sleep across \(cycles) cycle\(cycles == 1 ? "" : "s"). "
    if deepOK && remOK { s += "Deep and REM are both in a healthy range — solid, recoverable sleep." }
    else if deepPct < n.deep.lowerBound { s += "Deep sleep (the body's physical repair) ran light tonight." }
    else if remPct < n.rem.lowerBound { s += "REM (memory & mood) ran short tonight." }
    else { s += "Stage balance is roughly where it should be." }
    if awakenings >= 3 { s += " The night was a touch fragmented (\(awakenings) awakenings)." }

    var keep = [String](), improve = [String]()
    if deepOK { keep.append("Deep sleep is on target — keep a consistent bedtime and a cool, dark room.") }
    else if deepPct < n.deep.lowerBound { improve.append("Boost deep sleep: train earlier in the day, skip late alcohol, and get more total time in bed.") }
    if remOK { keep.append("REM is on target — it lives in the back half, so your steady wake time is helping.") }
    else if remPct < n.rem.lowerBound { improve.append("Lift REM: avoid alcohol near bedtime and hold a consistent wake time (REM peaks toward morning).") }
    if awakenings >= 3 || eff < 85 { improve.append("Sleep through more soundly: cut screens before bed, steady the room temperature, limit late caffeine.") }
    else { keep.append("Few awakenings and good efficiency — your wind-down routine is working.") }
    if tstH < needH - 0.5 { improve.append(String(format: "Spend more time in bed — the biggest lever. Aim for about %.1fh.", needH)) }
    else { keep.append("You met your sleep need — protect this duration.") }

    return SleepInsight(summary: s, keep: keep, improve: improve)
  }
}
