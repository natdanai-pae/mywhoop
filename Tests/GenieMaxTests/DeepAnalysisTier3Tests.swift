import Testing
import Foundation
@testable import GenieMax

// (8) Training Effect + recovery time
@Test func trainingEffectBands() {
  #expect(Physiology.trainingEffect(strain: 3) == "Minor")
  #expect(Physiology.trainingEffect(strain: 12) == "Improving")
  #expect(Physiology.trainingEffect(strain: 19) == "Overreaching")
}

@Test func recoveryHoursScalesWithStrainAndState() {
  let poor = Physiology.recoveryHours(strain: 16, recovery: 30)
  let great = Physiology.recoveryHours(strain: 16, recovery: 90)
  #expect(poor > great)                         // worse recovery → longer
  #expect(great >= 0 && poor <= 72)
}

// (7) Autonomic balance: SD1≫ → parasympathetic; SD1≪ → sympathetic
@Test func autonomicBalanceDirection() {
  #expect(Physiology.autonomicBalance(sd1: 40, sd2: 50).label == "Parasympathetic (recovery)")
  #expect(Physiology.autonomicBalance(sd1: 10, sd2: 60).label == "Sympathetic (stress)")
  #expect(Physiology.autonomicBalance(sd1: 10, sd2: 0).ratio == 0)   // guard
}
