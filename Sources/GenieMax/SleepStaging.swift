import Foundation

/// L1/L3 — sleep window detection + staging. Port of dashboard stageSleep:
/// 60s epochs → Cole-Kripke weighted activity (self-calibrating) → longest sleep run (merge <10min gaps) →
/// physiology multi-feature scores (HR/HRV/RRV/temp/position) → rank-allocate to AASM proportions →
/// HMM-style median+bout smoothing. Target accuracy = WHOOP's own κ≈0.47 (heuristic, not PSG).
public struct SleepSample: Codable, Equatable {      // Codable → the night buffer persists to disk (survives app kill)
  public let ts: Double; public let hr: Double?; public let hrv: Double?
  public let hrSource: String?; public let hrvSource: String?; public let hrvQuality: Int?
  public let motion: Double; public let resp: Double?; public let temp: Double?
  public let spo2: Double?                            // relative SpO₂ index (~100 = baseline), for the sleep trend
  public init(ts: Double, hr: Double?, hrv: Double?, motion: Double, resp: Double?, temp: Double?, spo2: Double? = nil,
              hrSource: String? = nil, hrvSource: String? = nil, hrvQuality: Int? = nil) {
    self.ts = ts; self.hr = hr; self.hrv = hrv; self.hrSource = hrSource; self.hrvSource = hrvSource; self.hrvQuality = hrvQuality
    self.motion = motion; self.resp = resp; self.temp = temp; self.spo2 = spo2
  }
}
public struct SleepResult: Equatable {
  public let ok: Bool
  public let tibH: Double, tstH: Double; public let eff: Int
  public let deep: Int, rem: Int, light: Int, wake: Int, nEp: Int
  // sleep-window vitals for Recovery (nil when !ok or the feature was absent in the data)
  public let rhr: Double?, sleepHRV: Double?, sleepResp: Double?, sleepScore: Double?
  public let rhrSource: String?, sleepHRVSource: String?, sleepHRVQuality: Int?
  // per-epoch stage track for the hypnogram, downsampled to ≤120 points. 0=Deep 1=Light 2=REM 3=Wake.
  public let hypnogram: [Int]
  // P2: sleeping HR sampled at the SAME stride as `hypnogram` (1:1, gap-filled) → the hypnogram HR overlay. Empty if no HR.
  public var hrTrack: [Double] = []
  // Phase A: clock anchor for the hypnogram time axis — ts of hypnogram[0] and seconds each downsampled point spans.
  public var hypnoStartTs: Double? = nil
  public var hypnoEpochSec: Double = 60
  // ── PASS 2 (HR/HRV/temp-refined), kept ALONGSIDE the actigraphy values above for comparison ──
  public let tstRefinedH: Double    // total sleep time after removing still-but-HR-elevated ("awake") epochs
  public let effRefined: Int        // refined efficiency %
  public let onsetTrimMin: Int      // refined onset is this many minutes LATER than the actigraphy onset
  public let wakeTrimMin: Int       // refined wake is this many minutes EARLIER than the actigraphy wake
  public let napLikely: Bool        // #4 circadian: main block midpoint falls in the daytime (likely a nap)
  // True when the chosen night block is bounded by a mid-stream DATA GAP (the strap stopped streaming) AND we
  // captured < 5 h — i.e. only a fragment of the night, not a confident full night. Caller should warn + offer
  // Backfill instead of presenting it as complete (it's still real data, just incomplete).
  public var partial: Bool = false
  // ABSOLUTE onset/wake unix-ts of the refined main sleep period. Use these for display/storage — the
  // trim fields are relative to the actigraphy onset, NOT the buffer start, so buffer.first+trim is wrong
  // whenever the sleep period begins mid-buffer (e.g. an evening of wear before sleep).
  public var onsetTs: Double? = nil, wakeTs: Double? = nil
  // Actigraphy main-block edges = the TIME-IN-BED window the duration/stages are counted over. Use THESE for the
  // displayed bedtime→wake clock so it agrees with "Xh asleep" (the refined onsetTs/wakeTs trim still-but-awake
  // edges, so they're a tighter "core sleep" window that can read shorter than the asleep total → confusing).
  public var winStartTs: Double? = nil, winEndTs: Double? = nil
}

public enum SleepStaging {
  static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
  static func std(_ a: [Double]) -> Double {                 // JS `||1` fallback
    if a.isEmpty { return 1 }
    let m = mean(a); let v = (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
    return v == 0 ? 1 : v
  }
  static func mergedSource(_ raw: [String?]) -> String? {
    let sources = raw.compactMap { $0 }.filter { !$0.isEmpty }
    guard !sources.isEmpty else { return nil }
    let uniq = Set(sources)
    if uniq.count == 1 { return sources[0] }
    if uniq.contains(where: { $0.contains("candidate") }) { return "mixed_candidate" }
    if uniq.contains("rr") && uniq.contains("ppg") { return "mixed_rr_ppg" }
    return "mixed"
  }
  struct Epoch {
    var ts: Double; var hr: Double?; var hrv: Double?; var mot: Double; var resp: Double?; var temp: Double?
    var hrSource: String?; var hrvSource: String?; var hrvQuality: Int?
  }

  /// Pick the main sleep block from the per-epoch sleep/wake flags. Runs of sleep merge across <10-min wake
  /// gaps, but a real TIME discontinuity (missing data — the strap stopped streaming) is a HARD break: epochs
  /// are compacted, so without this a multi-hour hole would make the epochs on either side adjacent in the
  /// array and merge a partial night with daytime wear into one bogus block (→ a far-too-early "onset" when
  /// finalizing a buffer that lost hours mid-stream). Among the blocks, prefer the one centred in the circadian
  /// night (longest such, ≥1 h); only if none qualify fall back to the overall longest, so single-block nights
  /// are unaffected. `partial` = the chosen block is bordered by a data gap AND under 5 h → only a fragment.
  /// `wasoMergeMin` (epochs ≈ minutes) = how long a wake run inside a sleep block may be before it SPLITS the block.
  /// Default 10 keeps the original behavior (and protects nap staging / un-bounded buffers from gluing distinct
  /// blocks). The night-finalize paths pass a larger value (60) so a mid-night awakening — a bathroom trip / a
  /// short lie-awake — stays a Wake band INSIDE the one night block instead of splitting it and truncating the
  /// night at the first awakening (s#7 part 14c, "นอนหลายรอบ"). A real TIME discontinuity is still a hard break.
  static func mainBlock(ep: [Epoch], sleepFlag: [Int], wasoMergeMin: Int = 10) -> (si: Int, ei: Int, partial: Bool)? {
    let GAPBREAK = 15.0 * 60                                    // >15 min with no samples → split the block here
    var blocks = [(Int, Int)](); var cur: (Int, Int)? = nil; var gap = 0
    for i in 0..<sleepFlag.count {
      if i > 0, ep[i].ts - ep[i - 1].ts > GAPBREAK, let c = cur { blocks.append(c); cur = nil; gap = 0 }
      if sleepFlag[i] == 1 { if cur == nil { cur = (i, i) } else { cur!.1 = i }; gap = 0 }
      else if cur != nil { gap += 1; if gap > wasoMergeMin { blocks.append(cur!); cur = nil } }
    }
    if let c = cur { blocks.append(c) }
    if blocks.isEmpty { return nil }
    func isNight(_ b: (Int, Int)) -> Bool {
      guard (b.1 - b.0 + 1) >= 60 else { return false }        // ≥1 h: a tiny night blip mustn't beat the real night
      let h = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: ep[(b.0 + b.1) / 2].ts))
      return h >= 20 || h < 11
    }
    let nightBlocks = blocks.filter(isNight)
    let pool = nightBlocks.isEmpty ? blocks : nightBlocks
    let main = pool.reduce(pool[0]) { ($1.1 - $1.0 > $0.1 - $0.0) ? $1 : $0 }
    let si: Int = main.0
    let ei: Int = main.1
    // Trim a trailing post-wake DOZE / morning LIE-IN so the morning wake = end of the MAIN sleep. A ~10-min
    // morning awakening is merged as WASO (gap ≤10 epochs), which otherwise glues a trailing doze/lie-in (e.g.
    // 07:16–08:59 of still, low-HR rest) onto the night and pushes "wake" far too late. RULE: peel off any trailing
    // [≥5-min wake][sleep bout] where the bout is markedly SHORTER than the consolidated sleep before it (ratio,
    // not an absolute cap — handles a 40-min doze AND a ~2-h lie-in) and the main sleep is already ≥3 h. A normal
    // mid-night WASO is safe: its following bout is comparable to / longer than the sleep before, so it never trims.
    var endIdx = ei
    while true {
      var b = endIdx
      while b > si && sleepFlag[b] == 1 { b -= 1 }         // b = last wake epoch before the trailing sleep bout
      if b <= si { break }                                 // reached the start with no qualifying wake gap
      let trailBout = endIdx - b                            // trailing sleep length (epochs ≈ minutes)
      var w = b
      while w > si && sleepFlag[w] == 0 { w -= 1 }          // w = last sleep epoch before the wake gap
      let wakeGap = b - w
      let sleepBefore = w - si                              // consolidated sleep ahead of the gap (epochs ≈ minutes)
      if w > si, wakeGap >= 4, sleepBefore >= 180, Double(trailBout) < 0.5 * Double(sleepBefore) {
        endIdx = w                                          // cut at the real wake; loop to peel a further doze
      } else { break }
    }
    let precededByGap = si > 0 && ep[si].ts - ep[si - 1].ts > GAPBREAK
    let followedByGap = ei < ep.count - 1 && ep[ei + 1].ts - ep[ei].ts > GAPBREAK
    let partial = (precededByGap || followedByGap) && (endIdx - si + 1) < 5 * 60
    return (si, endIdx, partial)
  }

  public static func stage(_ rows: [SleepSample], wasoMergeMin: Int = 10) -> SleepResult {
    let fail = SleepResult(ok: false, tibH: 0, tstH: 0, eff: 0, deep: 0, rem: 0, light: 0, wake: 0, nEp: 0,
                           rhr: nil, sleepHRV: nil, sleepResp: nil, sleepScore: nil,
                           rhrSource: nil, sleepHRVSource: nil, sleepHRVQuality: nil, hypnogram: [],
                           tstRefinedH: 0, effRefined: 0, onsetTrimMin: 0, wakeTrimMin: 0, napLikely: false)
    if rows.filter({ $0.hr != nil }).count < 120 { return fail }
    let EP = 60.0

    // 1) resample to 60s epochs (maxMotion, mean of the rest)
    var ep = [Epoch]()
    var bk: Int? = nil
    var bhr = [Double](), bhrv = [Double](), bmot = 0.0, bresp = [Double](), btemp = [Double]()
    var bhrSrc = [String?](), bhrvSrc = [String?](), bhrvQ = [Int]()
    func flush() {
      ep.append(Epoch(ts: Double(bk!) * EP,
        hr: bhr.isEmpty ? nil : mean(bhr), hrv: bhrv.isEmpty ? nil : mean(bhrv),
        mot: bmot, resp: bresp.isEmpty ? nil : mean(bresp), temp: btemp.isEmpty ? nil : mean(btemp),
        hrSource: mergedSource(bhrSrc), hrvSource: mergedSource(bhrvSrc),
        hrvQuality: bhrvQ.isEmpty ? nil : Int((Double(bhrvQ.reduce(0, +)) / Double(bhrvQ.count)).rounded())))
    }
    for r in rows {
      let k = Int((r.ts / EP).rounded(.down))
      if bk == nil || bk! != k {
        if bk != nil { flush() }
        bk = k; bhr = []; bhrv = []; bmot = 0; bresp = []; btemp = []; bhrSrc = []; bhrvSrc = []; bhrvQ = []
      }
      if let h = r.hr { bhr.append(h); bhrSrc.append(r.hrSource) }
      if let v = r.hrv { bhrv.append(v); bhrvSrc.append(r.hrvSource); if let q = r.hrvQuality { bhrvQ.append(q) } }
      bmot = max(bmot, r.motion)
      if let rs = r.resp { bresp.append(rs) }
      if let t = r.temp { btemp.append(t) }
    }
    if bk != nil { flush() }
    if ep.count < 60 { return fail }

    // 2) Cole-Kripke weighted activity → sleep/wake (self-calibrating 90th-pct → ~20 counts)
    let W: [Double] = [106, 54, 58, 76, 230, 74, 67]
    let mot = ep.map { $0.mot }
    let sm = mot.sorted()
    let hiRaw = sm[Int((Double(sm.count) * 0.9).rounded(.down))]
    let hi = hiRaw > 0 ? hiRaw : 0.05
    let SC = hi > 0 ? 20 / hi : 400
    func ck(_ i: Int) -> Double {
      var s = 0.0
      for k in -4...2 { let j = i + k; if j < 0 || j >= mot.count { continue }; s += W[k + 4] * mot[j] * SC }
      return 0.0001 * s
    }
    let sleepFlag = (0..<ep.count).map { ck($0) < 1 ? 1 : 0 }

    // 3) main sleep period (longest run, merging <10-min wake gaps; splits on real data gaps; prefers the
    // circadian night; flags gap-truncated fragments). Extracted to a helper to keep stage() type-checkable.
    guard let mb = mainBlock(ep: ep, sleepFlag: sleepFlag, wasoMergeMin: wasoMergeMin) else { return fail }
    let (si, ei, nightPartial) = mb
    let win = Array(ep[si...ei])
    if win.count < 60 { return fail }

    // 4) features
    var isWake = [Bool]()
    isWake.reserveCapacity(win.count)
    for i in 0..<win.count {
      let activityWake = ck(si + i) >= 1
      let motionWake = win[i].mot > hi * 0.6
      let missingHR = win[i].hr == nil
      isWake.append(activityWake || motionWake || missingHR)
    }
    let sIdx = (0..<win.count).filter { !isWake[$0] }
    if sIdx.isEmpty { return fail }
    func sub(_ key: (Epoch) -> Double?) -> [Double] { sIdx.compactMap { key(win[$0]) } }
    let shr = sub { $0.hr }; let mHR = mean(shr); let sdHR = std(shr)
    let shrv = sub { $0.hrv }; let mHRV: Double? = shrv.isEmpty ? nil : mean(shrv); let sdHRV = shrv.isEmpty ? 1 : std(shrv)
    let tmps = sub { $0.temp }.sorted(); let medTemp: Double? = tmps.isEmpty ? nil : tmps[tmps.count / 2]
    var rrv = [Int: Double]()
    for i in sIdx {
      var wn = [Double]()
      for k in -2...2 { let j = i + k; if j >= 0 && j < win.count, let r = win[j].resp { wn.append(r) } }
      if wn.count >= 3 { rrv[i] = std(wn) }
    }
    let rv = sIdx.compactMap { rrv[$0] }; let mRRV: Double? = rv.isEmpty ? nil : mean(rv); let sdRRV = rv.isEmpty ? 1 : std(rv)
    // S2 — absolute respiratory RATE (deep = slow steady breathing; REM/light = faster/variable). Was RRV-only.
    let resps = sub { $0.resp }; let mResp: Double? = resps.isEmpty ? nil : mean(resps); let sdResp = resps.isEmpty ? 1 : std(resps)

    var Fdeep = [Int: Double](), Frem = [Int: Double]()
    let n = Double(win.count)
    for i in sIdx {
      let e = win[i]; let pos = Double(i) / n; let mins = i
      let zhr = (e.hr! - mHR) / sdHR
      let zhrv = (mHRV != nil && e.hrv != nil && e.hrv! != 0) ? (e.hrv! - mHRV!) / sdHRV : 0
      let zrrv = (mRRV != nil && rrv[i] != nil) ? (rrv[i]! - mRRV!) / sdRRV : 0
      let zresp = (mResp != nil && e.resp != nil) ? (e.resp! - mResp!) / sdResp : 0   // S2: resp-rate level
      let td = (medTemp != nil && e.temp != nil) ? (e.temp! - medTemp!) : 0
      let motPen = e.mot / (hi == 0 ? 1 : hi)
      let earlyBias = pos < 0.4 ? 0.6 : (pos > 0.6 ? -0.6 : 0)
      let lateBias = pos > 0.55 ? 0.6 : (pos < 0.35 ? -0.6 : 0)
      // Deep: low HR, HIGH stable HRV (parasympathetic), low RRV, SLOW breathing, warmer skin, front-loaded.
      let deepScore = -zhr + 0.3 * zhrv - 0.4 * zrrv - 0.3 * zresp
      Fdeep[i] = deepScore + 0.5 * td - motPen + earlyBias
      // REM: high/variable HR, LOW HRV (sympathetic) [S3 fix: was +0.3], variable+faster breathing, back-loaded.
      let remScore = zhr - 0.3 * zhrv + 0.4 * zrrv + 0.2 * zresp - motPen + lateBias
      Frem[i] = mins < 70 ? -1e9 : remScore
    }

    // rank-allocate to AASM-typical proportions
    let nS = sIdx.count
    let remN = Int((0.26 * Double(nS)).rounded())
    let deepN = Int((0.22 * Double(nS)).rounded())
    let remSet = Set(sIdx.sorted { Frem[$0]! > Frem[$1]! }.prefix(remN).filter { Frem[$0]! > -1e8 })
    let deepSet = Set(sIdx.filter { !remSet.contains($0) }.sorted { Fdeep[$0]! > Fdeep[$1]! }.prefix(deepN))

    var stages = (0..<win.count).map { i -> String in
      if isWake[i] { return "Wake" }
      if remSet.contains(i) { return "REM" }
      if deepSet.contains(i) { return "Deep" }
      return "Light"
    }

    // 5) HMM-style smoothing: median(w3, first-seen tie-break) then dissolve isolated bouts (2 passes)
    func mode3(_ arr: [String], _ i: Int) -> String {
      let lo = max(0, i - 1), hi2 = min(arr.count, i + 2)
      var counts = [String: Int](); var order = [String]()
      for x in arr[lo..<hi2] { if counts[x] == nil { order.append(x) }; counts[x, default: 0] += 1 }
      var best = order[0]
      for q in order where counts[q]! > counts[best]! { best = q }
      return best
    }
    var sm3 = (0..<stages.count).map { mode3(stages, $0) }
    for _ in 0..<2 { for i in 1..<(sm3.count - 1) where sm3[i] != sm3[i - 1] && sm3[i - 1] == sm3[i + 1] { sm3[i] = sm3[i - 1] } }

    func cnt(_ s: String) -> Int { sm3.filter { $0 == s }.count }
    let asleep = sm3.filter { $0 != "Wake" }.count

    // hypnogram track (0=Deep 1=Light 2=REM 3=Wake), downsampled to ≤120 points for compact storage.
    func code(_ s: String) -> Int { s == "Deep" ? 0 : (s == "Light" ? 1 : (s == "REM" ? 2 : 3)) }
    let step = max(1, (sm3.count + 119) / 120)        // ceil → guarantees ≤120 points
    let hypno = stride(from: 0, to: sm3.count, by: step).map { code(sm3[$0]) }
    let hypnoStartTs = win.first?.ts                  // Phase A: clock anchor for the time axis
    let hypnoEpochSec = Double(step) * EP             // wall-clock seconds each downsampled point spans
    // P2: HR track for the overlay, sampled at the same stride and forward-filled (seeded with the first real
    // reading) so it aligns 1:1 with `hypno` and never carries a 0/nil hole.
    let hrRaw = stride(from: 0, to: sm3.count, by: step).map { win[$0].hr }
    var hrTrack = [Double](repeating: 0, count: hrRaw.count)
    var carryHR = hrRaw.compactMap { $0 }.first ?? 0
    for i in hrRaw.indices { if let v = hrRaw[i] { carryHR = v }; hrTrack[i] = carryHR }

    // ---- sleep-window vitals for Recovery (METRICS-INDICATORS-SPEC §3 + tuning-lock #10) ----
    // RHR = min of 5-min (5-epoch) moving-avg sleeping HR. shr = asleep-epoch HR, chronological.
    var rhr: Double? = nil
    var rhrSource: String? = nil
    let hrPairs = sIdx.compactMap { i -> (Double, String?)? in
      guard let h = win[i].hr else { return nil }
      return (h, win[i].hrSource)
    }
    if hrPairs.count >= 5 {
      var lo = Double.infinity
      var loSources = [String?]()
      for i in 0...(hrPairs.count - 5) {
        let slice = hrPairs[i..<(i + 5)]
        let avg = slice.map { $0.0 }.reduce(0, +) / 5
        if avg < lo {
          lo = avg
          loSources = slice.map { $0.1 }
        }
      }
      rhr = lo
      rhrSource = mergedSource(loSources)
    }
    // sleep HRV = mean RMSSD in Deep (SWS most reproducible, accuracy #2); fallback = mean asleep HRV.
    let deepHRVEpochs = (0..<win.count).filter { sm3[$0] == "Deep" && win[$0].hrv != nil }
    let deepHRV = deepHRVEpochs.compactMap { win[$0].hrv }
    let sleepHRV: Double? = !deepHRV.isEmpty ? mean(deepHRV) : (shrv.isEmpty ? nil : mHRV)
    let sleepHRVSource = !deepHRV.isEmpty
      ? mergedSource(deepHRVEpochs.map { win[$0].hrvSource })
      : mergedSource(sIdx.compactMap { win[$0].hrv == nil ? nil : win[$0].hrvSource })
    let sleepHRVQuality: Int? = {
      let qs = (!deepHRV.isEmpty ? deepHRVEpochs : sIdx).compactMap { win[$0].hrv == nil ? nil : win[$0].hrvQuality }
      return qs.isEmpty ? nil : Int((Double(qs.reduce(0, +)) / Double(qs.count)).rounded())
    }()
    // sleep resp = mean asleep respiratory rate.
    let sresp = sub { $0.resp }
    let sleepResp: Double? = sresp.isEmpty ? nil : mean(sresp)
    // Sleep Score 0-100: duration/need-dominant + efficiency + stage-balance (deep+REM). SRI/latency
    // deferred (need multi-night / onset). Weights tunable; vendor exact coefficients are proprietary.
    let tst = Double(asleep) / 60.0, need = 8.0                  // hours; TODO personalize sleep need
    let durC = min(1, tst / need)
    let effC = Double(asleep) / Double(win.count)
    let stageC = min(1, Double(cnt("Deep") + cnt("REM")) / (0.40 * Double(max(asleep, 1))))
    let sleepScoreComposite = 0.55 * durC + 0.25 * effC + 0.20 * stageC
    let sleepScore = 100 * sleepScoreComposite

    // ── PASS 2 — refine sleep/wake with HR (+HRV) so "still but awake" stops counting as sleep ──
    // #1 HR in the wake gate, #2 HR-drop onset, #3 HRV confirm, #4 circadian nap flag. Computed alongside
    // the actigraphy result above (does NOT change it). HR floor ≈ nightly sleeping trough.
    var refinedAwake = [Bool](repeating: false, count: win.count)
    let asleepHRs = (0..<win.count).filter { sm3[$0] != "Wake" }.compactMap { win[$0].hr }
    if asleepHRs.count >= 5 {
      var floor = Double.infinity
      for i in 0...(asleepHRs.count - 5) { floor = min(floor, asleepHRs[i..<(i + 5)].reduce(0, +) / 5) }
      let meanA = mean(asleepHRs)
      let thr = floor + max(8.0, 0.5 * max(0, meanA - floor))    // >~8 bpm above the sleeping trough → likely awake
      for i in 0..<win.count {
        if sm3[i] == "Wake" { refinedAwake[i] = true; continue }
        guard let h = win[i].hr else { continue }
        let hrvHigh = (mHRV != nil && win[i].hrv != nil) ? win[i].hrv! > mHRV! : false   // #3: high HRV ⇒ likely real sleep
        if h > thr && !hrvHigh { refinedAwake[i] = true }
      }
    }
    // #2 refined onset = first of ≥3 consecutive truly-asleep epochs; refined wake = last truly-asleep epoch.
    func runStart() -> Int { for i in 0..<win.count where !refinedAwake[i] {
      if i + 2 < win.count && !refinedAwake[i + 1] && !refinedAwake[i + 2] { return i } }; return 0 }
    let rOn = runStart()
    let rWake = (0..<win.count).last { !refinedAwake[$0] } ?? (win.count - 1)
    let refinedAsleep = (rOn...max(rOn, rWake)).filter { !refinedAwake[$0] }.count
    let tstRefined = Double(refinedAsleep) / 60.0
    let effRef: Int
    if win.count > 0 {
      let refinedEffFrac = Double(refinedAsleep) / Double(win.count)
      effRef = Int((refinedEffFrac * 100).rounded())
    } else {
      effRef = 0
    }
    // #4 circadian: is the main block centered in the daytime (likely a nap, not the main sleep)?
    let midHour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: win[win.count / 2].ts))
    let napLikely = (10...20).contains(midHour) && tst < 4

    // Precompute into locals — the SleepResult init has enough args that inlining these blows the type-checker.
    let tibH: Double = Double(ei - si + 1) / 60.0
    let effFrac: Double = Double(asleep) / Double(win.count)
    let effPct: Int = Int((effFrac * 100.0).rounded())
    let wakeTrim: Int = max(0, win.count - 1 - rWake)
    let onsetIdx: Int = min(rOn, win.count - 1)
    let wakeIdx: Int = max(0, min(rWake, win.count - 1))
    let onsetTsOut: Double = win[onsetIdx].ts
    let wakeTsOut: Double = win[wakeIdx].ts

    var result = SleepResult(ok: true, tibH: tibH, tstH: tst,
      eff: effPct,
      deep: cnt("Deep"), rem: cnt("REM"), light: cnt("Light"), wake: cnt("Wake"), nEp: win.count,
      rhr: rhr, sleepHRV: sleepHRV, sleepResp: sleepResp, sleepScore: sleepScore,
      rhrSource: rhrSource, sleepHRVSource: sleepHRVSource, sleepHRVQuality: sleepHRVQuality, hypnogram: hypno,
      hrTrack: hrTrack, hypnoStartTs: hypnoStartTs, hypnoEpochSec: hypnoEpochSec,
      tstRefinedH: tstRefined, effRefined: effRef, onsetTrimMin: rOn,
      wakeTrimMin: wakeTrim, napLikely: napLikely, partial: nightPartial,
      onsetTs: onsetTsOut, wakeTs: wakeTsOut)
    result.winStartTs = win.first?.ts        // time-in-bed window edges (set post-init to keep the init type-checkable)
    result.winEndTs = win.last?.ts
    return result
  }

  /// Is the tail of the night a CONFIRMED sustained wake (a real morning get-up) rather than a brief mid-night
  /// arousal (a bathroom trip that returns to sleep within minutes)? `recentHR` = the last ~25 min of sleeping-HR
  /// samples; `floor` = the night's sleeping-HR floor (~10th-pct). A real wake holds HR clearly off the floor for
  /// most of the window; a brief stir is only a small fraction. The auto-finalize "seal" gate (s#7 p14c) — keeping
  /// this PURE makes the load-bearing anti-premature-finalize decision unit-testable.
  public static func isSustainedWake(recentHR: [Double], floor: Double, fracThreshold: Double = 0.8) -> Bool {
    guard recentHR.count >= 15 else { return false }
    let elevated = recentHR.filter { $0 >= floor + 8 }.count
    return Double(elevated) / Double(recentHR.count) >= fracThreshold
  }

  /// Recovery Index (Oura-style) — how soon after falling asleep your HR settled near its nightly low.
  /// Earlier stabilization = more of the night spent recovering → higher score. Returns (hoursToStable, 0-100 score).
  /// Samples are ~per-minute; needs ≥30. nil if HR never sustainably settles.
  public static func recoveryIndex(_ rows: [SleepSample]) -> (h: Double, score: Int)? {
    let hr = rows.compactMap { $0.hr }
    guard hr.count >= 30 else { return nil }
    // Robust trough: the 5th-percentile HR, NOT the raw minimum. A single spurious-low artifact minute (BLE glitch)
    // would otherwise drag the reference down and make the `trough+band` window so tight that real deep-sleep HR
    // never qualifies → the index returned nil on nearly every real (noisy/gappy) night. Percentile + a tolerant
    // window (≥75% of ~15 samples within band, not 20 strictly-consecutive) lets it fire on real HR while the
    // synthetic clean-night test still scores high.
    let sorted = hr.sorted()
    let trough = sorted[max(0, sorted.count / 20)]                 // 5th percentile
    let win = 15
    for i in 0..<(hr.count - win) where hr[i] <= trough + 5 {      // entered the near-floor band
      let window = hr[i..<min(hr.count, i + win)]
      let within = window.filter { $0 <= trough + 8 }.count        // …and mostly stays settled (~15 min)
      if Double(within) / Double(window.count) >= 0.75 {
        let hours = Double(i) / 60.0
        let totalH = Double(hr.count) / 60.0
        let score = Int(max(0, min(100, 100 * (1 - hours / max(totalH, 1)))))
        return (hours, score)
      }
    }
    return nil
  }
}
