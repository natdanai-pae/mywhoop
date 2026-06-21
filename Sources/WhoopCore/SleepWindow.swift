import Foundation

/// Picks the night's in-bed window (onset → wake) from a set of detected sleep bouts (the same `NapDetector.Nap`
/// bouts the Nap card uses). PURE — no BLE / Calendar dependency beyond the injected `isNight` predicate — so the
/// merge rules below can be unit-tested against synthetic bout sets (see SleepWindowTests).
///
/// Why a "window" and not just the longest bout: a real night is fragmented (WASO awakenings split it into several
/// bouts) and the strap also captures a morning lie-in / pre-sleep nap as separate bouts. We pick the longest NIGHT
/// bout as the anchor, then:
///   • WAKE side (forward): merge a LATER bout only if it's COMPARABLE (≥ `wakeMinFrac` × main) and within
///     `wakeGapSec` — biphasic / second sleep. A short bout after a get-up (morning lie-in / nap) stays OUT.
///   • ONSET side (backward): merge an EARLIER bout regardless of length within `onsetGapSec` — sleep before a WASO
///     is part of the same night. The cap rejects a genuinely separate pre-sleep nap (which sits hours earlier).
public enum SleepWindow {
  /// - Parameters:
  ///   - bouts: detected sleep bouts (any order).
  ///   - isNight: predicate marking a bout (by its start/end ts) as occurring overnight — used only to choose the
  ///     anchor bout, so a long daytime nap can't outrank a fragmented night. Defaults to "always night" (for tests).
  ///   - wakeGapSec / wakeMinFrac / onsetGapSec: the merge tunables. Defaults MATCH the values tuned on real nights
  ///     (60-min comparable-wake gap, 0.5× comparability, 120-min WASO onset cap — the cap that fixed the 97-min
  ///     mid-night awakening leaving onset stuck on a late bout, s#7 part 12).
  ///     s#7 part 14c: the wake gap was widened 20→60 min so a longer mid-night awakening (a bathroom trip / a
  ///     20-40 min lie-awake before falling back asleep) still merges the COMPARABLE second sleep into the same
  ///     night — "นอนหลายรอบ" / biphasic. The 0.5× comparability gate is KEPT so a short morning doze / lie-in
  ///     (not a real second sleep) is still excluded regardless of the wider gap.
  public static func nightWindow(bouts: [Nap],
                                 isNight: (Double, Double) -> Bool = { _, _ in true },
                                 wakeGapSec: Double = 60 * 60,
                                 wakeMinFrac: Double = 0.5,
                                 onsetGapSec: Double = 120 * 60,
                                 maxDurSec: Double = 13 * 3600) -> (start: Double, end: Double)? {
    let bouts = bouts.sorted { $0.start < $1.start }
    let pool = bouts.filter { isNight($0.start, $0.end) }
    guard let main = (pool.isEmpty ? bouts : pool).max(by: { $0.durationMin < $1.durationMin }) else { return nil }
    var startTs = main.start, endTs = main.end
    let mainDur = Double(main.durationMin)
    for b in bouts where b.start >= endTs {
      if b.start - endTs <= wakeGapSec, Double(b.durationMin) >= wakeMinFrac * mainDur { endTs = b.end } else { break }
    }
    for b in bouts.reversed() where b.end <= startTs {
      if startTs - b.end <= onsetGapSec { startTs = b.start } else { break }
    }
    // Guard: a real main sleep is ≤ ~12h. If the merges chained into an implausibly long window (fragmented/sparse
    // data — e.g. a 14-18h span), fall back to the single longest consolidated bout rather than a garbage window.
    if endTs - startTs > maxDurSec { return (main.start, main.end) }
    return (startTs, endTs)
  }
}
