import Foundation

/// P4 — derived sleep "architecture" read off the stored hypnogram track (0=Deep 1=Light 2=REM 3=Wake). Pure +
/// testable. The raw track is NOISY (rank-allocation + downsampling produce 1-epoch REM/Wake flips real sleep
/// never makes), so everything here first `smooth`s it, and `cycles` MERGES REM episodes split by a brief arousal
/// — otherwise a fragmented night reads as "13 cycles" instead of the true ~4–6.
public enum SleepArchitecture {
  /// Despeckle: a lone epoch flanked by a matching pair (e.g. Light–REM–Light) snaps to its neighbours. Two passes
  /// converge most short runs. Used for BOTH the counts and the displayed graph so they always agree.
  public static func smooth(_ hyp: [Int]) -> [Int] {
    guard hyp.count >= 3 else { return hyp }
    var h = hyp
    for _ in 0..<2 {
      var out = h
      for i in 1..<(h.count - 1) where h[i] != h[i - 1] && h[i - 1] == h[i + 1] { out[i] = h[i - 1] }
      h = out
    }
    return h
  }

  /// REM-period start indices after MERGING episodes separated by < `gap` epochs of NREM (a brief arousal, not a
  /// genuine descent back into NREM). `cycles` and `remOnsets` share this so the count and the boundary lines agree.
  private static func remPeriodStarts(_ hyp: [Int], gap: Int = 3) -> [Int] {
    let rem = segments(hyp).filter { $0.stage == 2 }
    guard !rem.isEmpty else { return [] }
    var starts = [rem[0].startIdx]
    for i in 1..<rem.count where (rem[i].startIdx - rem[i - 1].endIdx - 1) >= gap { starts.append(rem[i].startIdx) }
    return starts
  }

  /// Estimated sleep cycles = distinct REM PERIODS (merged across brief arousals), capped at a physiological 8.
  public static func cycles(_ hyp: [Int]) -> Int { min(8, remPeriodStarts(smooth(hyp)).count) }

  /// Awakenings = real WAKE bouts between sleep onset and final wake (despeckled → micro-arousals don't inflate it).
  public static func awakenings(_ hyp: [Int]) -> Int {
    let h = smooth(hyp)
    guard let first = h.firstIndex(where: { $0 != 3 }),
          let last = h.lastIndex(where: { $0 != 3 }), first < last else { return 0 }
    var c = 0
    for i in (first + 1)...last where h[i] == 3 && h[i - 1] != 3 { c += 1 }
    return c
  }

  /// Cycle-boundary marks for the hypnogram = the merged REM-period starts (so the dashed lines match `cycles`).
  public static func remOnsets(_ hyp: [Int]) -> [Int] { remPeriodStarts(smooth(hyp)) }

  // ── Phase B: contiguous stage runs → the "key moments" the summary card surfaces (index ranges; the UI maps
  //    indices → clock via the stored hypnoStartMin/hypnoEpochMin, keeping this engine pure). ──
  public struct StageSegment: Equatable { public let stage: Int, startIdx: Int, endIdx: Int }   // endIdx inclusive
  public static func segments(_ hyp: [Int]) -> [StageSegment] {
    var out = [StageSegment](); var i = 0
    while i < hyp.count {
      var j = i; while j + 1 < hyp.count && hyp[j + 1] == hyp[i] { j += 1 }
      out.append(StageSegment(stage: hyp[i], startIdx: i, endIdx: j)); i = j + 1
    }
    return out
  }

  public struct KeyMoment: Equatable, Identifiable {
    public enum Kind: String { case deep, rem, awakening }
    public let kind: Kind, startIdx: Int, endIdx: Int
    public var id: String { "\(kind.rawValue)-\(startIdx)" }
    public var epochs: Int { endIdx - startIdx + 1 }
  }
  /// Notable events, time-ordered: the longest Deep block, the longest REM window, and each mid-night awakening.
  /// Runs on the SMOOTHED track so micro-blips don't surface as fake awakenings.
  public static func keyMoments(_ hyp: [Int]) -> [KeyMoment] {
    let h = smooth(hyp)
    let segs = segments(h)
    var out = [KeyMoment]()
    if let d = segs.filter({ $0.stage == 0 }).max(by: { $0.endIdx - $0.startIdx < $1.endIdx - $1.startIdx }) {
      out.append(KeyMoment(kind: .deep, startIdx: d.startIdx, endIdx: d.endIdx))
    }
    if let r = segs.filter({ $0.stage == 2 }).max(by: { $0.endIdx - $0.startIdx < $1.endIdx - $1.startIdx }) {
      out.append(KeyMoment(kind: .rem, startIdx: r.startIdx, endIdx: r.endIdx))
    }
    if let first = h.firstIndex(where: { $0 != 3 }), let last = h.lastIndex(where: { $0 != 3 }), first < last {
      for s in segs where s.stage == 3 && s.startIdx > first && s.endIdx < last {
        out.append(KeyMoment(kind: .awakening, startIdx: s.startIdx, endIdx: s.endIdx))
      }
    }
    return out.sorted { $0.startIdx < $1.startIdx }
  }
}
