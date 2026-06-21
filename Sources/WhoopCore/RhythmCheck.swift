import Foundation

/// T1b — rule-based HEART RHYTHM CHECK from RR-intervals (no ECG, no RE needed).
/// WELLNESS / EXPERIMENTAL ONLY — this is NOT a medical device and does NOT diagnose
/// atrial fibrillation or any condition. It summarises beat-to-beat regularity from the
/// strap's broadcast RR-intervals (the same RR set HRV uses) so a user can spot a
/// persistently irregular pattern and decide to seek a clinical ECG.
public struct RhythmResult: Equatable, Codable {
  public let beats: Int            // clean physiologic intervals used
  public let meanHR: Int           // bpm
  public let rmssd: Double         // ms — successive-difference variability
  public let sdnn: Double          // ms — overall RR dispersion
  public let cv: Double            // SDNN / meanRR (0…1) — coefficient of variation
  public let ectopicFraction: Double // fraction of beats >20% off the median RR
  public let artifactFraction: Double // fraction of successive intervals with an implausible jump (missed/extra beats)
  public let category: Category
  public let sd1: Double           // ms — Poincaré short axis (for the plot)
  public let sd2: Double           // ms — Poincaré long axis
  public let coSEn: Double         // Coefficient of Sample Entropy — disorder (AF-like) measure
  public let entropy: Double       // normalised Shannon entropy of RR [0,1]
  public let tpr: Double           // turning-point ratio [0,1] — disorder proxy
  public let rr: [Double]          // the clean physiologic intervals used (for the scatter + tachogram)

  public enum Category: String, Equatable, Codable {
    case insufficient   // not enough beats yet
    case noisy          // too many beat artifacts (loose strap / motion) — reading not trustworthy, retry
    case regular        // tight, steady rhythm
    case variable       // normal beat-to-beat variability (e.g. sinus arrhythmia)
    case irregular      // markedly irregular — consider a clinical ECG if it persists
  }
}

public enum RhythmCheck {
  /// Analyse a window of RR-intervals (milliseconds). Beats outside 300–2000 ms are dropped
  /// as non-physiologic. Classification is conservative and intentionally NON-diagnostic.
  /// - thresholds: CV<0.06 & few ectopics ⇒ regular; CV<0.12 ⇒ variable; else ⇒ irregular.
  ///   (Healthy sinus RR-CV ≈ 0.03–0.08; AF/irregular ≈ 0.15+.)
  public static func analyze(rr rawRR: [Double], minBeats: Int = 30) -> RhythmResult {
    let rr = rawRR.filter { $0 > 300 && $0 < 2000 }
    guard rr.count >= minBeats else {
      return RhythmResult(beats: rr.count, meanHR: 0, rmssd: 0, sdnn: 0, cv: 0,
                          ectopicFraction: 0, artifactFraction: 0, category: .insufficient,
                          sd1: 0, sd2: 0, coSEn: 0, entropy: 0, tpr: 0, rr: rr)
    }
    let n = Double(rr.count)
    let meanRR = rr.reduce(0, +) / n
    let sdnn = (rr.map { ($0 - meanRR) * ($0 - meanRR) }.reduce(0, +) / n).squareRoot()
    let diff = zip(rr.dropFirst(), rr).map { $0 - $1 }
    let rmssd = diff.isEmpty ? 0 : (diff.map { $0 * $0 }.reduce(0, +) / Double(diff.count)).squareRoot()
    let cv = meanRR > 0 ? sdnn / meanRR : 0
    let sd1 = rmssd / (2.0).squareRoot()
    let sd2 = max(0, 2 * sdnn * sdnn - sd1 * sd1).squareRoot()

    // ectopics = beats far from the median RR (missed/extra beats / true irregularity)
    let sorted = rr.sorted()
    let median = sorted[sorted.count / 2]
    let ectopics = median > 0 ? rr.filter { abs($0 - median) > 0.20 * median }.count : 0
    let ectopicFraction = Double(ectopics) / n

    // artifacts = big SUCCESSIVE jumps (a dropped/extra beat doubles/halves one interval). Broadcast RR is
    // bursty, so a noisy capture produces these — we must NOT call that "irregular". Gate on them first.
    let jumpThresh = max(250.0, 0.40 * median)
    let jumps = diff.filter { abs($0) > jumpThresh }.count
    let artifactFraction = diff.isEmpty ? 0 : Double(jumps) / Double(diff.count)

    // Track-1 AF-discrimination features (Lake-Moorman CoSEn / Shannon entropy / TPR). TPR separates the
    // *disorder* of AF from ordered high-variability (a slow drift / sinus arrhythmia) that CV alone can't.
    let coSEn = RhythmFeatures.coSEn(rr)
    let entropy = RhythmFeatures.shannonEntropy(rr)
    let tpr = RhythmFeatures.turningPointRatio(rr)

    // SUSTAINED-disorder test — the key AF-vs-artifact discriminator, using a ROBUST (outlier-resistant) spread.
    // MAD = median absolute deviation. A handful of big PPG spikes / missed-beat doubles / isolated ectopics on
    // an otherwise-steady strip barely move the MAD (the majority of beats sit near the median) → robustCV low.
    // True AF is dispersed across the WHOLE strip (every beat varies) → MAD large → robustCV high. So plain CV
    // (which a few spikes inflate) flags both, but robustCV separates "a steady base with spikes" from real AF.
    let devs = rr.map { abs($0 - median) }.sorted()
    let mad = devs[devs.count / 2]
    let robustCV = median > 0 ? (1.4826 * mad) / median : cv   // 1.4826 → MAD≈SD for a normal distribution
    let sustainedDisorder = robustCV >= 0.10                   // the bulk is dispersed, not just a few outliers

    let category: RhythmResult.Category
    if artifactFraction > 0.25 {
      category = .noisy                                  // signal too corrupted to judge — ask for a cleaner reading
    } else if (cv >= 0.12 || ectopicFraction >= 0.10) && !sustainedDisorder && artifactFraction > 0.08 {
      category = .noisy                                  // looked irregular, but it's a few big spikes on a steady base → bad capture, retry
    } else if (cv >= 0.12 || ectopicFraction >= 0.10) && tpr >= 0.25 && sustainedDisorder {
      category = .irregular                              // dispersion AND disorder AND it survives spike removal (truly sustained)
    } else if cv < 0.06 && ectopicFraction < 0.05 {
      category = .regular
    } else {
      category = .variable                               // includes ordered high-variability (drift) → not "irregular"
    }

    let meanHR = meanRR > 0 ? Int((60000.0 / meanRR).rounded()) : 0
    return RhythmResult(beats: rr.count, meanHR: meanHR, rmssd: rmssd, sdnn: sdnn, cv: cv,
                        ectopicFraction: ectopicFraction, artifactFraction: artifactFraction,
                        category: category, sd1: sd1, sd2: sd2,
                        coSEn: coSEn, entropy: entropy, tpr: tpr, rr: rr)
  }
}
