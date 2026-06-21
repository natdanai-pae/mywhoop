import Testing
@testable import GenieMax

@Test func cyclesCountRemPeriods() {
  // 0=Deep 1=Light 2=REM 3=Wake. Three well-separated REM periods (≥3-epoch NREM gaps) → 3 cycles.
  let hyp = [3,3, 1,0,0, 2,2, 1,1,1, 2,2, 0,0,0, 2,2, 1, 3,3]
  #expect(SleepArchitecture.cycles(hyp) == 3)
  #expect(SleepArchitecture.remOnsets(hyp) == [5, 10, 15])
}

@Test func cyclesMergeBriefArousalAndDespeckle() {
  // a 2-epoch interruption between REM bouts = the SAME period → ONE cycle, not two.
  #expect(SleepArchitecture.cycles([1,1, 2,2, 3, 1, 2,2, 1,1]) == 1)
  // alternating single-epoch Light/REM noise (downsampling speckle) → not 6 cycles.
  #expect(SleepArchitecture.cycles([1,2,1,2,1,2,1,2,1,2,1,2]) <= 2)
  // physiological cap at 8 even for an absurdly fragmented night.
  let manyRem = (0..<20).flatMap { _ in [1,1,1,1,1,2,2] }
  #expect(SleepArchitecture.cycles(manyRem) == 8)
}

@Test func awakeningsExcludeLeadingAndTrailingWake() {
  // leading wake (0,1) and trailing wake (17,18) don't count; the mid-night wake bout at index 13 does.
  let hyp = [3,3, 1,0,0,1,2,2, 1,0,1,2,2, 3, 1,2,2, 3,3]
  #expect(SleepArchitecture.awakenings(hyp) == 1)
}

@Test func architectureHandlesEdgeCases() {
  #expect(SleepArchitecture.cycles([]) == 0)
  #expect(SleepArchitecture.awakenings([3,3,3]) == 0)        // all wake → no sleep, no awakenings
  #expect(SleepArchitecture.cycles([0,1,0,1]) == 0)          // no REM at all → 0 cycles
  // a single contiguous REM block is ONE period, not many
  #expect(SleepArchitecture.cycles([1,2,2,2,2,1]) == 1)
}

@Test func keyMomentsPickLongestBlocksAndMidNightWake() {
  // 0=Deep 1=Light 2=REM 3=Wake
  let hyp = [3,3, 1,0,0,0,1,2,2, 3, 1,0,1,2,2,2,1, 3,3]
  let km = SleepArchitecture.keyMoments(hyp)
  let deep = km.first { $0.kind == .deep }
  #expect(deep?.startIdx == 3 && deep?.endIdx == 5)        // longest deep block (3 epochs), not the lone 0 at idx 11
  let rem = km.first { $0.kind == .rem }
  #expect(rem?.startIdx == 13 && rem?.endIdx == 15)        // longest REM window (3), not 7–8
  let awk = km.filter { $0.kind == .awakening }
  #expect(awk.count == 1 && awk.first?.startIdx == 9)      // only the mid-night wake; leading/trailing excluded
  #expect(km.map { $0.startIdx } == km.map { $0.startIdx }.sorted())   // time-ordered
  #expect(SleepArchitecture.segments([0,0,1,1,1,2]).count == 3)
}
