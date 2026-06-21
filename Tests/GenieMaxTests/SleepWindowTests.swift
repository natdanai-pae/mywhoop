import Testing
import Foundation
@testable import GenieMax

// Bout-merge rules behind the nightly in-bed window (extracted from WhoopBLE.boutNightWindow, s#7 part 12).
// Times are "minutes from a base" → seconds; the merge is pure arithmetic so the absolute base is irrelevant.
private func nap(_ startMin: Double, _ endMin: Double) -> Nap {
  Nap(start: startMin * 60, end: endMin * 60, avgHR: 50)
}
// Compare a window against expected (start, end) in MINUTES — Int compare avoids the Double?/Int-literal == pitfall.
private func expectWindow(_ w: (start: Double, end: Double)?, startMin: Int, endMin: Int,
                          _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(w.map { Int($0.start) } == startMin * 60, comment, sourceLocation: sourceLocation)
  #expect(w.map { Int($0.end) } == endMin * 60, comment, sourceLocation: sourceLocation)
}

// REGRESSION (the exact night that shipped wrong): three bouts split by a 97-min mid-night WASO.
// Real values 01:28-02:18 (50m) · 03:55-05:03 (68m) · 05:17-07:07 (110m). The anchor is the longest (05:17-07:07);
// onset must reach back across the 14-min then the 97-min gap to the true 01:28 — NOT stay stuck on 03:55.
@Test func wasoOnsetMergesAcross97MinGap() {
  let bouts = [nap(88, 138), nap(235, 303), nap(317, 427)]   // 01:28 / 02:18 · 03:55 / 05:03 · 05:17 / 07:07
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 88, endMin: 427)  // 01:28 → 07:07
}

// The 120-min onset cap is load-bearing: with the OLD 20-min cap the 97-min gap breaks the merge and onset
// regresses to 03:55 (the bug). This pins the parameter so a future tweak can't silently reintroduce it.
@Test func onsetCapBelow97MinReproducesTheBug() {
  let bouts = [nap(88, 138), nap(235, 303), nap(317, 427)]
  let tooTight = SleepWindow.nightWindow(bouts: bouts, onsetGapSec: 20 * 60)
  #expect(tooTight.map { Int($0.start) } == 235 * 60)   // 03:55 — the old, wrong onset
}

// A short morning lie-in / nap right after waking (25 min, 10-min gap) is NOT comparable to a 7-h night
// (< 0.5× main), so it stays OUT of the wake side — wake is the true 06:00, not the lie-in's end.
@Test func shortMorningLieInExcludedFromWake() {
  let bouts = [nap(1380, 1800), nap(1810, 1835)]   // 23:00→06:00 (420m) · 06:10→06:35 (25m)
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 1380, endMin: 1800)  // lie-in excluded
}

// Biphasic / second sleep: a COMPARABLE later bout (165m ≥ 0.5×180m) across a 15-min gap IS merged.
@Test func biphasicComparableWakeMerges() {
  let bouts = [nap(1380, 1560), nap(1575, 1740)]   // 23:00→02:00 (180m) · 02:15→05:00 (165m)
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 1380, endMin: 1740)  // merged
}

// A genuine pre-sleep nap hours before bed (40 min at 18:00, ~5 h before onset) sits beyond the 120-min cap
// and is excluded — onset stays at the real bedtime.
@Test func preSleepNapBeyondCapExcluded() {
  let bouts = [nap(1080, 1120), nap(1410, 1830)]   // 18:00→18:40 (40m) · 23:30→06:30 (420m)
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 1410, endMin: 1830)  // nap not merged
}

@Test func emptyBoutsReturnNil() {
  #expect(SleepWindow.nightWindow(bouts: []) == nil)
}

// s#7 p14c ("นอนหลายรอบ"): a 45-min mid-night awakening (a bathroom trip / a lie-awake) before a COMPARABLE
// second sleep now MERGES into one night — the wake gap was widened 20→60 min. The old 20-min gap cut the night
// at the first awakening (the premature-finalize symptom on reprocess). The comparability gate is unchanged.
@Test func longerBathroomGapWithComparableSecondSleepMerges() {
  let bouts = [nap(60, 280), nap(325, 520)]   // 01:00→04:40 (220m) · 05:25→08:40 (195m): 45-min gap, 195 ≥ 0.5×220
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 60, endMin: 520)   // merged across the 45-min gap
  // pin the regression: the OLD 20-min wake gap would NOT bridge it → wake truncated at the first awakening (04:40)
  let oldGap = SleepWindow.nightWindow(bouts: bouts, wakeGapSec: 20 * 60)
  #expect(oldGap.map { Int($0.end) } == 280 * 60)
}

// The wider 60-min gap still does NOT glue a short morning doze: a 25-min lie-in (< 0.5× a 7-h night) stays OUT
// regardless of the gap — the comparability gate, not the gap, is what excludes it.
@Test func shortDozeStillExcludedUnderWiderGap() {
  let bouts = [nap(1380, 1800), nap(1815, 1840)]   // 23:00→06:00 (420m) · 06:15→06:40 (25m, 15-min gap ≤ 60)
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 1380, endMin: 1800)  // doze excluded
}

// P2 guard: on fragmented/sparse data the 120-min onset-merge can chain back hours into an implausible window.
// Here 90-min-gap fragments chain to 15:00 → a 15h span (> 13h cap) → fall back to the single longest night bout.
@Test func overLongChainedWindowFallsBackToMainBout() {
  let bouts = [nap(900, 930), nap(1020, 1050), nap(1140, 1170), nap(1260, 1290), nap(1380, 1800)]
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 1380, endMin: 1800)  // 23:00 → 07:00, not the 15h chain
}

// A normal fragmented night (the 97-min-WASO regression, ~5.7h span) stays UNDER the 13h cap → unchanged.
@Test func normalNightUnderCapUnchanged() {
  let bouts = [nap(88, 138), nap(235, 303), nap(317, 427)]
  expectWindow(SleepWindow.nightWindow(bouts: bouts), startMin: 88, endMin: 427)  // cap doesn't interfere
}

// The `isNight` anchor predicate keeps a long DAYTIME nap from outranking a fragmented night: even though the
// nap (180m) is longer than either night fragment, the night bouts are chosen as the anchor + merged.
@Test func nightPredicateAnchorsToNightNotLongDayNap() {
  let dayNap = nap(840, 1020)                        // 14:00→17:00, 180m (longest overall)
  let night1 = nap(1395, 1500)                       // 23:15→01:00, 105m
  let night2 = nap(1515, 1680)                       // 01:15→04:00, 165m
  let w = SleepWindow.nightWindow(bouts: [dayNap, night1, night2]) { s, _ in
    let hod = (s / 60).truncatingRemainder(dividingBy: 1440) / 60   // crude 20:00–11:00 band on the start ts
    return hod >= 20 || hod < 11
  }
  expectWindow(w, startMin: 1395, endMin: 1680)   // anchored to the night, day nap ignored
}
