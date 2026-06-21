import Testing
import Foundation
@testable import WhoopCore

// Passive AFib screening — confirmation state machine (Apple IRN-style, non-diagnostic).

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
// helper: a check `h` hours after t0
private func chk(_ h: Double, _ irregular: Bool) -> AFCheck {
  AFCheck(ts: t0.addingTimeInterval(h * 3600), isIrregular: irregular)
}

// No checks → clear, no last check.
@Test func emptyLogIsClear() {
  let o = AFScreen.evaluate(checks: [], now: t0)
  #expect(o.status == .clear)
  #expect(o.lastCheck == nil)
  #expect(o.validChecksInWindow == 0)
}

// All regular checks → clear.
@Test func allRegularIsClear() {
  let checks = (0..<8).map { chk(Double($0) * 0.5, false) }   // every 30 min, all regular
  let o = AFScreen.evaluate(checks: checks, now: t0.addingTimeInterval(8 * 3600))
  #expect(o.status == .clear)
  #expect(o.recentIrregularCount == 0)
}

// A single irregular check NEVER flags — only monitoring (avoid false alarm).
@Test func singleIrregularIsMonitoringNotFlagged() {
  let checks = [chk(0, false), chk(0.5, false), chk(1, true)]
  let o = AFScreen.evaluate(checks: checks, now: t0.addingTimeInterval(1.5 * 3600))
  #expect(o.status == .monitoring)
  #expect(o.recentIrregularCount == 1)
}

// 5 of 6 sequential irregular within 48 h → flagged (Apple rule).
@Test func fiveOfSixIrregularIsFlagged() {
  // 6 checks spaced 1 h apart: regular, then 5 irregular.
  let checks = [chk(0, false), chk(1, true), chk(2, true), chk(3, true), chk(4, true), chk(5, true)]
  let o = AFScreen.evaluate(checks: checks, now: t0.addingTimeInterval(5 * 3600))
  #expect(o.status == .flagged)
  #expect(o.recentIrregularCount == 5)
}

// Only 4 of 6 irregular → stays monitoring, NOT flagged.
@Test func fourOfSixIsNotFlagged() {
  let checks = [chk(0, true), chk(1, false), chk(2, true), chk(3, false), chk(4, true), chk(5, true)]
  let o = AFScreen.evaluate(checks: checks, now: t0.addingTimeInterval(5 * 3600))
  #expect(o.status == .monitoring)
  #expect(o.recentIrregularCount == 4)
}

// 5 irregular but spread WIDER than 48 h apart → never 5-in-a-48h-window → not flagged.
@Test func irregularSpreadBeyond48hIsNotFlagged() {
  // 6 irregular checks every 15 h → any 48-h window holds at most 4 of them.
  let checks = (0..<6).map { chk(Double($0) * 15.0, true) }
  let now = t0.addingTimeInterval(75 * 3600)
  let o = AFScreen.evaluate(checks: checks, now: now)
  #expect(o.status != .flagged)
}

// Once flagged, a run of 3 consecutive regular checks resets to clear.
@Test func flaggedResetsAfterThreeRegular() {
  var checks = [chk(0, false), chk(1, true), chk(2, true), chk(3, true), chk(4, true), chk(5, true)]
  // ...then 3 clean readings
  checks += [chk(6, false), chk(7, false), chk(8, false)]
  let o = AFScreen.evaluate(checks: checks, now: t0.addingTimeInterval(8 * 3600))
  #expect(o.status == .clear)
}

// Two regular after a flag is NOT enough to reset (still flagged).
@Test func twoRegularDoesNotReset() {
  var checks = [chk(0, false), chk(1, true), chk(2, true), chk(3, true), chk(4, true), chk(5, true)]
  checks += [chk(6, false), chk(7, false)]   // only 2 regular
  let o = AFScreen.evaluate(checks: checks, now: t0.addingTimeInterval(7 * 3600))
  #expect(o.status == .flagged)
}

// validChecksInWindow only counts checks within the 48-h freshness window of `now`.
@Test func windowCountExcludesStaleChecks() {
  let checks = [chk(0, false), chk(1, false), chk(60, false), chk(61, false)]  // first two are >48h before now
  let now = t0.addingTimeInterval(62 * 3600)
  let o = AFScreen.evaluate(checks: checks, now: now)
  #expect(o.validChecksInWindow == 2)
  #expect(o.lastCheck == checks.last?.ts)
}
