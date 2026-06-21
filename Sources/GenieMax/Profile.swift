import Foundation

/// The user's body profile — drives every personalized norm (HRmax, zones, BMR/kcal, VO₂max %, sleep need…).
/// age/sex/weight/height/activity differ per person, so the same raw signal yields a different verdict.
public struct Profile: Codable, Equatable, Sendable {
  public var age: Int
  public var male: Bool
  public var weightKg: Double
  public var heightCm: Double
  public var activity: Int            // 0 sedentary … 4 extra-active → PAL multiplier
  public var bodyFatPct: Double?      // C3: optional → enables the Katch-McArdle (lean-mass) BMR, more accurate for lean/athletes
  public var measuredBMR: Double?     // lab/InBody-measured BMR (kcal/day) — most accurate; overrides the formula when set
  // The user's typical sleep window (24h local hours). Bounds the circadian "night" used to detect/finalize main
  // sleep so a long DAYTIME rest can't be logged as a night (anti "fake sleep"). Optional → old saved profiles decode
  // with nil and fall back to the default 23:00→08:00 band (a typical night; tighter than the old 20:00→11:00 so a
  // long daytime rest isn't mistaken for the main sleep). A night-shift worker shifts the
  // window into the day so THEIR daytime sleep is the recorded night. Daytime quiet outside it → handled by the Nap card.
  public var sleepWinStartHour: Int?  // earliest typical bedtime hour, nil → 23
  public var sleepWinEndHour: Int?    // latest typical wake hour, nil → 8
  // Optional date of birth. When set, `age` is kept in sync from it (auto-updates over time) on load + on edit, so
  // the user enters their birthday once instead of a static age. Optional → old saved profiles decode with nil and
  // keep their manually-entered `age` unchanged (back-compat, no migration needed).
  public var birthDate: Date?
  public init(age: Int = 25, male: Bool = true, weightKg: Double = 83, heightCm: Double = 183,
              activity: Int = 2, bodyFatPct: Double? = nil, measuredBMR: Double? = nil,
              sleepWinStartHour: Int? = nil, sleepWinEndHour: Int? = nil, birthDate: Date? = nil) {
    self.age = age; self.male = male; self.weightKg = weightKg; self.heightCm = heightCm
    self.activity = activity; self.bodyFatPct = bodyFatPct; self.measuredBMR = measuredBMR
    self.sleepWinStartHour = sleepWinStartHour; self.sleepWinEndHour = sleepWinEndHour
    self.birthDate = birthDate
  }
  /// Whole years between two dates (calendar-correct, handles leap birthdays). Pure — caller supplies `now`, so
  /// Profile stays clock-free + unit-testable.
  public static func years(from birth: Date, to now: Date) -> Int {
    max(0, Calendar.current.dateComponents([.year], from: birth, to: now).year ?? 0)
  }
  /// Refresh `age` from `birthDate` so it tracks the calendar (no-op when DOB is unset). Call on load + on edit.
  public mutating func syncAgeFromBirth(now: Date) {
    if let b = birthDate, b < now { age = Profile.years(from: b, to: now) }
  }
  public var sleepStartHour: Int { sleepWinStartHour ?? 23 }
  public var sleepEndHour: Int { sleepWinEndHour ?? 8 }
  /// Hour `h` is within the cyclic [start, end) range — handles the wrap past midnight when start > end (e.g. 20→11).
  public static func hourInCyclicRange(_ h: Int, start: Int, end: Int) -> Bool {
    start <= end ? (h >= start && h < end) : (h >= start || h < end)
  }
  /// Is this local hour inside the user's sleep window? (default 23:00–08:00 = a typical night.)
  public func isSleepHour(_ h: Int) -> Bool { Profile.hourInCyclicRange(h, start: sleepStartHour, end: sleepEndHour) }
  /// Middle hour of the sleep window (deepest-sleep anchor) — used to gate "did the strap cover the real night".
  public var sleepMidHour: Int {
    let len = (sleepEndHour - sleepStartHour + 24) % 24
    return (sleepStartHour + len / 2) % 24
  }
  /// Central ~6h of the sleep window — the core hours a real overnight must cover (default ≈ 00:00–06:00).
  public func isSleepCoreHour(_ h: Int) -> Bool {
    Profile.hourInCyclicRange(h, start: (sleepMidHour + 21) % 24, end: (sleepMidHour + 3) % 24)
  }
  public var ageD: Double { Double(age) }
  /// FAO/WHO/UNU physical-activity level (sedentary→extra-active).
  public var pal: Double { [1.2, 1.375, 1.55, 1.725, 1.9][min(max(activity, 0), 4)] }
  public var bmi: Double { let m = heightCm / 100; return m > 0 ? weightKg / (m * m) : 0 }
  /// C3 — BMR (kcal/day): Katch-McArdle (lean-mass) when body-fat% is known (better for lean/athletes), else Mifflin.
  public var bmr: Double {
    if let m = measuredBMR, m > 500 { return m }                  // lab/InBody measurement wins (most accurate)
    if let bf = bodyFatPct, bf > 3, bf < 60 {
      return Physiology.katchMcArdleBMR(weightKg: weightKg, bodyFatPct: bf)
    }
    return Physiology.mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: ageD, male: male)
  }
  public var bmrMethod: String {
    if (measuredBMR ?? 0) > 500 { return "Measured" }
    return (bodyFatPct ?? 0) > 3 ? "Katch-McArdle" : "Mifflin-St Jeor"
  }
  public var mifflin: Double { Physiology.mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: ageD, male: male) }
  /// RMR runs ~10% above true BMR in practice (used interchangeably in most apps; shown for comparison).
  public var rmr: Double { bmr * 1.1 }
  public var tdee: Double { bmr * pal }   // maintenance
}
