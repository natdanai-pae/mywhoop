import Testing
import Foundation
@testable import WhoopCore

/// The configurable sleep-window schedule that bounds main-sleep detection (anti "fake sleep", night-shift friendly).
struct ProfileScheduleTests {
  @Test func defaultWindowIsTypicalNight() {
    let p = Profile()                     // nil/nil → default 23:00–08:00 (a typical night)
    #expect(p.sleepStartHour == 23)
    #expect(p.sleepEndHour == 8)
    #expect(p.isSleepHour(23))            // boundary start (inclusive)
    #expect(p.isSleepHour(3))             // core night
    #expect(p.isSleepHour(7))             // pre-wake (in window)
    #expect(!p.isSleepHour(8))            // boundary end (exclusive)
    #expect(!p.isSleepHour(22))           // just before bedtime → NOT sleep
    #expect(!p.isSleepHour(14))           // mid-afternoon → NOT sleep (the fake-sleep case)
  }

  @Test func nightShiftWindowFlipsDayAndNight() {
    let p = Profile(sleepWinStartHour: 9, sleepWinEndHour: 17)   // sleeps ~09:00–17:00
    #expect(p.isSleepHour(12))            // midday IS this user's sleep
    #expect(p.isSleepHour(9))
    #expect(!p.isSleepHour(17))           // boundary end exclusive
    #expect(!p.isSleepHour(2))            // their night = awake
    #expect(!p.isSleepHour(22))
  }

  @Test func coreHoursTrackTheWindowMidpoint() {
    let def = Profile()                   // 23→08, midpoint ≈ 03:00
    #expect(def.sleepMidHour == 3)
    #expect(def.isSleepCoreHour(2))       // deep-night core
    #expect(def.isSleepCoreHour(5))
    #expect(!def.isSleepCoreHour(10))     // morning lie-in is in-window but NOT core
    let ns = Profile(sleepWinStartHour: 9, sleepWinEndHour: 17)   // midpoint ≈ 13:00
    #expect(ns.sleepMidHour == 13)
    #expect(ns.isSleepCoreHour(13))
    #expect(ns.isSleepCoreHour(12))
    #expect(!ns.isSleepCoreHour(3))       // their deep night is mid-afternoon, not 03:00
  }

  @Test func cyclicRangeHelper() {
    #expect(Profile.hourInCyclicRange(23, start: 20, end: 11))   // wraps midnight
    #expect(Profile.hourInCyclicRange(0, start: 20, end: 11))
    #expect(!Profile.hourInCyclicRange(12, start: 20, end: 11))
    #expect(Profile.hourInCyclicRange(12, start: 9, end: 17))    // non-wrapping
    #expect(!Profile.hourInCyclicRange(8, start: 9, end: 17))
  }

  @Test func windowSurvivesCodecRoundTripAndOldData() throws {
    let p = Profile(sleepWinStartHour: 9, sleepWinEndHour: 17)
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Profile.self, from: data)
    #expect(back.sleepStartHour == 9 && back.sleepEndHour == 17)
    // Old saved profiles have no sleep-window keys → must decode to the default band (not crash).
    let old = "{\"age\":30,\"male\":true,\"weightKg\":80,\"heightCm\":180,\"activity\":2}"
    let legacy = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
    #expect(legacy.sleepStartHour == 23 && legacy.sleepEndHour == 8)
  }
}
