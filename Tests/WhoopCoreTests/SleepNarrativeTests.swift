import Testing
@testable import WhoopCore

@Test func narrativeFlagsLowRemAndShortSleep() {
  // deep ~22% (ok), REM ~7% (low), only 5.9h vs 8h need → improve must call out REM + more time in bed.
  let i = SleepNarrative.build(deep: 80, rem: 25, light: 250, wake: 20, cycles: 4, awakenings: 1, tstH: 5.9, needH: 8, age: 25)
  #expect(i.improve.contains { $0.lowercased().contains("rem") })
  #expect(i.improve.contains { $0.lowercased().contains("time in bed") })
  #expect(i.summary.contains("4 cycles"))
}

@Test func narrativeKeepsWhenHealthy() {
  // deep ~19%, REM ~23%, 7.7h, 1 awakening → keep-heavy, no stage-improvement nags.
  let i = SleepNarrative.build(deep: 84, rem: 102, light: 250, wake: 18, cycles: 5, awakenings: 1, tstH: 7.7, needH: 8, age: 25)
  #expect(!i.keep.isEmpty)
  #expect(!i.improve.contains { $0.lowercased().contains("rem") })
  #expect(i.summary.lowercased().contains("healthy range"))
}

@Test func narrativeFlagsFragmentation() {
  // many awakenings → improve mentions sleeping through / screens / temperature.
  let i = SleepNarrative.build(deep: 84, rem: 100, light: 250, wake: 40, cycles: 5, awakenings: 5, tstH: 7.2, needH: 8, age: 25)
  #expect(i.summary.contains("fragmented"))
  #expect(i.improve.contains { $0.lowercased().contains("screens") })
}
