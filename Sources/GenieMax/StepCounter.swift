import Foundation

/// L1 — pedometer over the IMU accel stream. Counts upward threshold crossings of |accel|−1g with a
/// refractory gap (one accel peak ≈ one step). Crude (we get one accel sample per IMU frame, not the
/// full array) but a standard peak-count heuristic; tune threshold/refractory on real walking data.
public struct StepCounter: Equatable {
  public var threshold: Double      // g above 1g to count as a peak
  public var refractory: Int        // min samples between steps (debounce)
  public private(set) var steps: Int
  private var lastAbove: Bool
  private var lastStepIdx: Int
  private var idx: Int

  public init(threshold: Double = 0.08, refractory: Int = 2) {
    self.threshold = threshold; self.refractory = refractory
    steps = 0; lastAbove = false; lastStepIdx = -1000; idx = 0
  }

  /// Feed one accel magnitude deviation (|accel|−1g, g).
  public mutating func feed(_ mag: Double) {
    let above = mag > threshold
    if above && !lastAbove && (idx - lastStepIdx) >= refractory { steps += 1; lastStepIdx = idx }
    lastAbove = above; idx += 1
  }
}
