import Testing
import Foundation
@testable import GenieMax

@Test func coachContextIncludesKeyMetrics() {
  let ctx = CoachContext.build(recovery: 72, readiness: 71, strain: 11.2, tsb: -2, sleepScore: 84,
    sleepDebt: 5.7, hrv: 58, rhr: 52, sri: 88, behaviorsToday: ["alcohol"],
    impacts: [BehaviorImpact(behavior: "alcohol", d: -0.9, n: 6)])
  #expect(ctx.contains("Recovery: 72"))
  #expect(ctx.contains("Sleep debt"))
  #expect(ctx.contains("alcohol"))
}

@Test func proactiveInsightCopy() {
  let m = ProactiveInsights.morningReport(sleepScore: 82, tstH: 7.2, needH: 7.8, deepMin: 95, remMin: 110,
    recovery: 64, hrvMs: 52, hrvBaseMs: 60, rhr: 58, rhrBase: 54, strainLo: 8, strainHi: 12)
  #expect(m.title.contains("82"))
  #expect(m.body.contains("7.2h") && m.body.contains("92%"))     // tst vs need
  #expect(m.body.contains("Recovery 64%") && m.body.contains("yellow"))
  #expect(m.body.contains("-13%"))                                // HRV vs baseline
  #expect(m.body.contains("RHR 58") && m.body.contains("+4"))
  #expect(m.body.contains("8–12"))

  let w = ProactiveInsights.workoutSummary(type: "Run", minutes: 42, kcal: 480, kcalMethod: "HR",
    avgHR: 152, peakHR: 178, hrMax: 195, strain: 13.4, moveDone: 480, moveGoal: 500)
  #expect(w.title.contains("Run") && w.title.contains("480 kcal"))
  #expect(w.body.contains("91% of your max"))
  #expect(w.body.contains("20 to go"))

  let sAlert = ProactiveInsights.stressAlert(level: 2.6, minutes: 14, hr: 92, rhr: 54)
  #expect(sAlert.title.contains("2.6") && sAlert.title.contains("14 min"))
  #expect(sAlert.body.contains("92") && sAlert.body.contains("54") && sAlert.body.contains("not moving"))

  #expect(ProactiveInsights.moveDone(goal: 500).title.contains("500"))
  let n = ProactiveInsights.moveNudge(done: 200, goal: 500)
  #expect(n.body.contains("300 kcal to go") && n.body.contains("60 min"))

  let b = ProactiveInsights.bedtime(bedMin: 22 * 60 + 40, wakeMin: 6 * 60 + 50, needH: 8.1, debtH: 1.2)
  #expect(b.title.contains("22:40"))
  #expect(b.body.contains("8.1h") && b.body.contains("1.2h") && b.body.contains("06:50"))

  let d = ProactiveInsights.dayInReview(strain: 12.3, steps: 8400, activeKcal: 600, totalKcal: 2400,
                                        energy: 24, hardZoneMin: 35)
  #expect(d.body.contains("12.3") && d.body.contains("8400") && d.body.contains("35 min"))
  #expect(d.body.contains("running low"))                       // energy 24 < 30 → early-night hint

  #expect(ProactiveInsights.inactivityNudge(stillMin: 75).title.contains("75"))
  let a = ProactiveInsights.abnormalRestHR(hr: 112, rhr: 54, minutes: 12)
  #expect(a.title.contains("112") && a.body.contains("58 above"))

  let wk = ProactiveInsights.weeklyReport(weekStrain: 62, prevWeekStrain: 48, sessions: 5,
    avgSleepH: 7.1, avgSleepScore: 81, avgRecovery: 58, monotony: 2.3, steps: 52000, kcal: 16800)
  #expect(wk.title.contains("load ↑"))
  #expect(wk.body.contains("62 strain") && wk.body.contains("5 sessions") && wk.body.contains("48"))
  #expect(wk.body.contains("7.1h") && wk.body.contains("81") && wk.body.contains("58%"))
  #expect(wk.body.contains("2.3") && wk.body.contains("overuse"))   // monotony >2 → warning
  let wkOK = ProactiveInsights.weeklyReport(weekStrain: 50, prevWeekStrain: 49, sessions: 4,
    avgSleepH: 7.5, avgSleepScore: nil, avgRecovery: nil, monotony: 1.4, steps: 0, kcal: 0)
  #expect(wkOK.title.contains("steady") && wkOK.body.contains("good hard/easy"))

  #expect(ProactiveInsights.recoveryAlert(today: 28, yesterday: 60)?.title.contains("28%") == true)   // red
  #expect(ProactiveInsights.recoveryAlert(today: 50, yesterday: 70)?.body.contains("20 pts") == true) // sharp drop
  #expect(ProactiveInsights.recoveryAlert(today: 72, yesterday: 70) == nil)                             // fine → quiet

  #expect(ProactiveInsights.hrvLowAlert(rmssd: 38, z: -1.6)?.title.contains("38 ms") == true)
  #expect(ProactiveInsights.hrvLowAlert(rmssd: 55, z: -0.5) == nil)                                      // within range → quiet
  #expect(ProactiveInsights.skinTempHighAlert(deltaC: 0.7)?.title.contains("+0.7") == true)
  #expect(ProactiveInsights.skinTempHighAlert(deltaC: 0.2) == nil)
  #expect(ProactiveInsights.sleepStreakAlert(nights: 3, avgH: 5.4)?.title.contains("3 short") == true)
  #expect(ProactiveInsights.sleepStreakAlert(nights: 2, avgH: 5.4) == nil)
}

@Test func ruleCoachRoutesByIntent() {
  let train = RuleCoach.answer("what should I train today?", recovery: 75, readiness: 72, strain: 8,
    tsb: 2, sleepDebt: 1, topImpact: nil)
  #expect(train.contains("14") || train.contains("strain") || train.contains("hard"))

  let lowRec = RuleCoach.answer("why is my recovery low?", recovery: 35, readiness: 40, strain: 14,
    tsb: -12, sleepDebt: 6, topImpact: BehaviorImpact(behavior: "alcohol", d: -0.8, n: 6))
  #expect(lowRec.lowercased().contains("recovery"))
  #expect(lowRec.contains("sleep debt") || lowRec.contains("alcohol") || lowRec.contains("fatigue"))

  let sleep = RuleCoach.answer("how was my sleep?", recovery: 60, readiness: 60, strain: 8,
    tsb: 0, sleepDebt: 7, topImpact: nil)
  #expect(sleep.lowercased().contains("sleep"))
}
