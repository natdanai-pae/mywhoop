import Testing
import Foundation
@testable import WhoopCore

@Test func workoutAccumulatesStrainZonesCalories() {
  var acc = WorkoutAccumulator(startTs: 0, hrMax: 190, hrRest: 50, tau: 100, weightKg: 83, age: 25)
  // 30 minutes at ~150 bpm, one sample/sec
  for s in 0...1800 { acc.feed(ts: Double(s), hr: 150) }
  let w = acc.session(end: 1800, hrvPre: 60, hrvPost: 48)
  #expect(w.durationSec == 1800)
  #expect(w.hrAvg == 150)
  #expect(w.hrMax == 150 && w.hrMin == 150)
  #expect(w.strain > 0 && w.strain <= 21)
  #expect(w.kcal > 150 && w.kcal < 600)            // ~30 min vigorous
  #expect(w.zoneSec.reduce(0, +) > 1700)           // ~all 1800s assigned to a zone
  #expect(w.hrvPre == 60 && w.hrvPost == 48)
}

@Test func workoutHarderThanEasierHasMoreStrain() {
  var hard = WorkoutAccumulator(startTs: 0, hrMax: 190, hrRest: 50)
  var easy = WorkoutAccumulator(startTs: 0, hrMax: 190, hrRest: 50)
  for s in 0...1200 { hard.feed(ts: Double(s), hr: 170); easy.feed(ts: Double(s), hr: 110) }
  #expect(hard.session(end: 1200).strain > easy.session(end: 1200).strain)
}

@Test func banisterTRIMPUsesSexSpecificCoefficients() {
  let male = Physiology.banisterTRIMP(dtMin: 30, hrr: 0.7, male: true)
  let female = Physiology.banisterTRIMP(dtMin: 30, hrr: 0.7, male: false)
  #expect(female > male)
}

@Test func workoutAccumulatorUsesSexSpecificTRIMP() {
  var male = WorkoutAccumulator(startTs: 0, hrMax: 190, hrRest: 50, male: true)
  var female = WorkoutAccumulator(startTs: 0, hrMax: 190, hrRest: 50, male: false)
  for s in 0...1200 { male.feed(ts: Double(s), hr: 160); female.feed(ts: Double(s), hr: 160) }
  #expect(female.session(end: 1200).strain > male.session(end: 1200).strain)
}

@Test func persistedStateWithWorkoutsCodable() throws {
  var s = PersistedState()
  var acc = WorkoutAccumulator(startTs: 100)
  for t in 100...400 { acc.feed(ts: Double(t), hr: 140) }
  s.workouts.append(acc.session(end: 400))
  let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(s))
  #expect(back == s)
  #expect(back.workouts.count == 1)
}
