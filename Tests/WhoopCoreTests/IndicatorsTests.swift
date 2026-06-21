import Testing
import Foundation
@testable import WhoopCore

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

@Test func zscoreBasic() {
  #expect(approx(Indicators.zscore(15, mean: 10, sd: 2), 2.5))
  #expect(approx(Indicators.zscore(5, mean: 10, sd: 2), -2.5))
  #expect(approx(Indicators.zscore(7, mean: 10, sd: 0), 0))   // guard div0
}

@Test func ewmaStreaming() {
  // α=0.25, seed=800: 800 → 802.5 → 799.375 → 800.78125
  let e = Indicators.ewma([800, 810, 790, 805], alpha: 0.25)
  #expect(approx(e[0], 800))
  #expect(approx(e[1], 802.5))
  #expect(approx(e[2], 799.375))
  #expect(approx(e[3], 800.78125))
}

@Test func cusumDetectsStepShift() {
  // five 0s then five 2s; mean0 sd1 k0.5 h5 → S+ = 1.5,3,4.5,6 → alarm at index 8
  let x = [0.0, 0, 0, 0, 0, 2, 2, 2, 2, 2]
  let alarms = Indicators.cusumAlarms(x, mean: 0, sd: 1, k: 0.5, h: 5)
  #expect(alarms.first == 8)
}

@Test func cusumQuietOnFlat() {
  let x = [Double](repeating: 0, count: 20)
  #expect(Indicators.cusumAlarms(x, mean: 0, sd: 1).isEmpty)
}

@Test func tirFractions() {
  let x = Array(1...10).map(Double.init)            // 1..10
  let t = Indicators.tir(x, edges: [5])             // <5 : >=5
  #expect(approx(t[0], 0.4))                          // 1,2,3,4
  #expect(approx(t[1], 0.6))                          // 5..10
}

@Test func cvComputes() {
  // [9,10,11] mean10 popSD=√(2/3) → cv=√(2/3)/10
  #expect(approx(Indicators.cv([9, 10, 11]), (2.0/3).squareRoot() / 10))
}

@Test func ewmaControlChartFlagsShift() {
  // flat at 10 then jump to 20 (mean10 sd1) → EWMA must breach upper limit eventually
  let x = [10.0, 10, 10, 10, 20, 20, 20, 20]
  let cc = Indicators.ewmaControlChart(x, mean: 10, sd: 1, lambda: 0.2, L: 3)
  #expect(!cc.violations.isEmpty)
  #expect(cc.violations.allSatisfy { $0 >= 4 })     // only after the shift
}
