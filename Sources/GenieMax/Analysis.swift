import Foundation

/// L4 — live, personalized "what does this result mean for me" summary for a metric/score.
/// Combines the current value with the user's Profile + the personal baseline + cited norms (HealthRef)
/// into a verdict + comparison + action, so the analysis adapts to each body (age/sex/weight/height/activity).
/// Bilingual: pass `thai` for Thai copy.
public struct SummaryCard: Equatable, Sendable {
  public enum Status: String, Sendable { case good, neutral, watch, info }
  /// How much to trust this value (drives the confidence badge + how it's framed).
  public enum Confidence: String, Sendable { case high, medium, estimate, low }
  public let status: Status
  public let headline: String      // verdict incl. the value
  public let detail: String        // personalized comparison (baseline + age/sex norm)
  public let action: String        // what to do next ("" = none)
  public let confidence: Confidence
  public let note: String          // reliability caveat ("" = none)
  public init(_ status: Status, _ headline: String, _ detail: String, _ action: String = "",
              confidence: Confidence = .medium, note: String = "") {
    self.status = status; self.headline = headline; self.detail = detail; self.action = action
    self.confidence = confidence; self.note = note
  }
}

public enum Analysis {
  static func f(_ v: Double, _ d: Int = 0) -> String { String(format: "%.\(d)f", v) }
  /// SWC ±0.5 SD (Plews/Buchheit "smallest worthwhile change"): a deviation only counts as a meaningful
  /// change once it exceeds ±0.5 SD from baseline; inside that band it's normal day-to-day variation (noise).
  public static let swc = 0.5
  static func withinSWC(_ z: Double) -> Bool { abs(z) < swc }
  static func zlabel(_ z: Double, _ thai: Bool) -> String {
    if z >= 1.5 { return thai ? "สูงกว่ามาก" : "well above" }
    if z >= swc { return thai ? "สูงกว่า" : "above" }
    if z <= -1.5 { return thai ? "ต่ำกว่ามาก" : "well below" }
    if z <= -swc { return thai ? "ต่ำกว่า" : "below" }
    return thai ? "อยู่ในช่วงปกติของคุณ" : "within your normal range"
  }

  /// Per-value reliability (condition #1/#2/#5/#7): error tier + baseline maturity + coverage.
  public static func confidence(_ key: String, value: Double?, hasBaseline: Bool) -> SummaryCard.Confidence {
    if value == nil { return .low }                                   // coverage gate
    switch key {
    case "hr", "rhr": return .high
    case "kcal", "spo2", "sleep": return .estimate                    // weakest tiers (Stanford EE / sleep-stage bias)
    case "hrv", "temp", "resp": return hasBaseline ? .medium : .low
    default: return .medium
    }
  }
  static func reliabilityNote(_ key: String, status: SummaryCard.Status, conf: SummaryCard.Confidence, thai: Bool) -> String {
    func t(_ en: String, _ th: String) -> String { thai ? th : en }
    if key == "kcal" { return t("Estimate ±25% — error is higher for some bodies (BMI/skin/sex).", "ค่าประมาณ ±25% — คลาดมากขึ้นในบางคน (BMI/สีผิว/เพศ)") }
    if key == "sleep" { return t("Stage breakdown is an estimate (REM tends low, Deep high).", "สัดส่วนระยะเป็นค่าประมาณ (REM มักต่ำ Deep มักสูง)") }
    if conf == .low { return t("Limited data — read as a rough guide; watch the trend.", "ข้อมูลน้อย — อ่านเป็นแนวทาง ดูเทรนด์") }
    if status == .watch && ["hrv", "rhr", "temp", "resp"].contains(key) {
      return t("Confirm with the multi-day trend before acting — one signal can be noise.", "ยืนยันกับเทรนด์หลายวันก่อนตัดสินใจ — สัญญาณเดียวอาจเป็น noise")
    }
    return ""
  }

  public static func summary(_ key: String, value: Double?, profile p: Profile,
                             baselineMean: Double? = nil, baselineSD: Double? = nil,
                             thai: Bool = false) -> SummaryCard {
    let base = core(key, value: value, profile: p, baselineMean: baselineMean, baselineSD: baselineSD, thai: thai)
    let conf = confidence(key, value: value, hasBaseline: baselineMean != nil)
    let note = reliabilityNote(key, status: base.status, conf: conf, thai: thai)
    return SummaryCard(base.status, base.headline, base.detail, base.action, confidence: conf, note: note)
  }

  static func core(_ key: String, value: Double?, profile p: Profile,
                   baselineMean: Double? = nil, baselineSD: Double? = nil,
                   thai: Bool = false) -> SummaryCard {
    func t(_ en: String, _ th: String) -> String { thai ? th : en }
    let sexNoun = thai ? (p.male ? "ชาย" : "หญิง") : (p.male ? "male" : "female")

    guard let v = value else {
      return SummaryCard(.info, t("Not enough data yet", "ข้อมูลยังไม่พอ"),
        t("This fills in once the strap has logged enough — wear it overnight and let history build.",
          "จะแสดงเมื่อสายเก็บข้อมูลพอแล้ว — ใส่นอนสักคืนให้ประวัติสะสม"))
    }
    let z: Double? = (baselineMean != nil && (baselineSD ?? 0) > 0) ? (v - baselineMean!) / baselineSD! : nil

    switch key {
    case "hrv":
      let typ = HealthRef.hrvTypical(age: p.ageD, male: p.male)
      let norm = t("Typical ≈\(f(typ)) ms for a \(p.age)-yr-old \(sexNoun) (wide person-to-person range).",
                   "ปกติ ≈\(f(typ)) ms สำหรับ\(sexNoun)อายุ \(p.age) ปี (ต่างกันมากในแต่ละคน)")
      if let z = z {
        let good = z >= -swc                                // SWC: only "down" once below −0.5 SD
        let vsBase = withinSWC(z) ? zlabel(z, thai) : "\(zlabel(z, thai)) " + t("your baseline", "baseline ของคุณ")
        return SummaryCard(good ? .good : .watch, "HRV \(f(v)) ms — \(vsBase)", norm,
          good ? (withinSWC(z) ? t("In your normal range — a typical day.", "อยู่ในช่วงปกติ — วันธรรมดา")
                               : t("Recovered — you can take on load today.", "ฟื้นตัวดี — รับภาระได้วันนี้"))
               : t("Down vs your norm — favor an easier day and protect sleep.", "ต่ำกว่าปกติ — เลือกวันเบาและรักษาการนอน"))
      }
      return SummaryCard(.neutral, "HRV \(f(v)) ms",
        norm + t(" Baseline still building (needs ≥7 nights).", " baseline ยังสะสมอยู่ (ต้อง ≥7 คืน)"),
        t("Keep wearing it overnight to learn your normal.", "ใส่นอนต่อเพื่อเรียนรู้ค่าปกติของคุณ"))

    case "rhr":
      let cut = HealthRef.rhrAthleticCut(male: p.male)
      let norm = t("Resting HR 60–100 is normal; <\(f(cut)) is athletic. Lower = fitter/recovered.",
                   "หัวใจขณะพัก 60–100 ปกติ; <\(f(cut)) = ระดับนักกีฬา ยิ่งต่ำ = ฟิต/ฟื้นตัวดี")
      if let z = z, z > 1 {
        return SummaryCard(.watch, t("Resting HR \(f(v)) bpm — up vs baseline", "หัวใจขณะพัก \(f(v)) bpm — สูงกว่า baseline"), norm,
          t("A sustained rise can mean illness, alcohol or under-recovery — check temp & sleep.",
            "ขึ้นต่อเนื่องอาจหมายถึงป่วย แอลกอฮอล์ หรือพักไม่พอ — เช็คอุณหภูมิและการนอน"))
      }
      let good = v < cut
      return SummaryCard(good ? .good : .neutral, t("Resting HR \(f(v)) bpm", "หัวใจขณะพัก \(f(v)) bpm"), norm,
        good ? t("Strong aerobic base.", "พื้นฐานแอโรบิกดี") : t("Trends down as fitness improves.", "จะลดลงเมื่อฟิตขึ้น"))

    case "recovery":
      if v >= 67 { return SummaryCard(.good, t("Recovery \(f(v)) — green", "การฟื้นตัว \(f(v)) — เขียว"),
        t("Your HRV/RHR/sleep are at or above your baseline.", "HRV/RHR/การนอน อยู่ที่หรือสูงกว่า baseline"),
        t("Good day to push strain.", "วันดีให้ดัน strain")) }
      if v >= 34 { return SummaryCard(.neutral, t("Recovery \(f(v)) — yellow", "การฟื้นตัว \(f(v)) — เหลือง"),
        t("Mixed signals vs your baseline.", "สัญญาณผสมเทียบ baseline"),
        t("Train moderate; keep an eye on sleep.", "ฝึกปานกลาง; คอยดูการนอน")) }
      return SummaryCard(.watch, t("Recovery \(f(v)) — red", "การฟื้นตัว \(f(v)) — แดง"),
        t("Your body is below its baseline today.", "วันนี้ร่างกายต่ำกว่า baseline"),
        t("Prioritize rest, hydration and sleep.", "เน้นพัก ดื่มน้ำ และนอน"))

    case "readiness":
      let good = v >= 60
      return SummaryCard(good ? .good : .watch, t("Readiness \(f(v))", "ความพร้อม \(f(v))"),
        t("Blends recovery, sleep and form (TSB).", "รวมการฟื้นตัว การนอน และฟอร์ม (TSB)"),
        good ? t("Ready for load.", "พร้อมรับภาระ") : t("Ease in today.", "ค่อย ๆ เริ่มวันนี้"))

    case "strain":
      // WHOOP bands: light 0–9 / moderate 10–13 / high 14–17 / all-out 18–21
      let band = v >= 18 ? t("all-out", "สุดแรง") : (v >= 14 ? t("high", "หนัก")
               : (v >= 10 ? t("moderate", "ปานกลาง") : t("light", "เบา")))
      return SummaryCard(.neutral, t("Day strain \(f(v,1))/21 — \(band)", "Strain วันนี้ \(f(v,1))/21 — \(band)"),
        t("Cardio load you've put in so far today.", "ภาระหัวใจที่ทำไปแล้ววันนี้"),
        t("Match strain to recovery — push on green days, ease on red.", "จับคู่ strain กับการฟื้นตัว — วันเขียวดัน วันแดงเบา"))

    case "sleep":
      let need = HealthRef.sleepNeed(age: p.ageD)
      let good = v >= 80
      return SummaryCard(good ? .good : (v >= 60 ? .neutral : .watch), t("Sleep score \(f(v))", "คะแนนนอน \(f(v))"),
        t("Scored vs your ~\(f(need,1)) h need and stage balance (NSF: \(p.age >= 65 ? "7–8" : "7–9") h for your age).",
          "เทียบความต้องการ ~\(f(need,1)) ชม. และสมดุลระยะ (NSF: \(p.age >= 65 ? "7–8" : "7–9") ชม. ตามอายุ)"),
        good ? t("Solid night — it lifts today's recovery.", "คืนที่ดี — ช่วยยกการฟื้นตัววันนี้")
             : t("Aim for more time-in-bed and a consistent bedtime.", "เพิ่มเวลาบนเตียงและเข้านอนให้ตรงเวลา"))

    case "vo2":
      let label = HealthRef.vo2Label(v, age: p.ageD, male: p.male)
      let labTH = ["Poor": "แย่", "Fair": "พอใช้", "Good": "ดี", "Excellent": "ดีมาก", "Superior": "ยอดเยี่ยม"][label] ?? label
      let g = HealthRef.vo2Good(age: p.ageD, male: p.male)
      return SummaryCard(["Good", "Excellent", "Superior"].contains(label) ? .good : .neutral,
        t("VO₂max \(f(v,1)) — \(label)", "VO₂max \(f(v,1)) — \(labTH)"),
        t("\"Good\" for a \(p.age)-yr-old \(sexNoun) starts ≈\(f(g)) ml/kg/min (ACSM).",
          "เกณฑ์ 'ดี' ของ\(sexNoun)อายุ \(p.age) ปี เริ่ม ≈\(f(g)) ml/kg/min (ACSM)"),
        t("Improve with Zone-2 volume + intervals; set a true max-HR for accuracy.",
          "พัฒนาด้วย Zone-2 + อินเทอร์วัล; ตั้ง max-HR จริงเพื่อความแม่น"))

    case "stress":
      let i = min(max(Int(v.rounded()), 0), 3)
      let lvl = [t("Calm", "สงบ"), t("Balanced", "สมดุล"), t("Elevated", "เริ่มสูง"), t("High", "สูง")][i]
      return SummaryCard(v < 2 ? .good : .watch, t("Stress \(f(v,1))/3 — \(lvl)", "ความเครียด \(f(v,1))/3 — \(lvl)"),
        t("Live, vs your own quiet baseline; movement is excluded.", "สด เทียบ baseline ตอนสงบของคุณ; ไม่รวมการขยับ"),
        v < 2 ? t("Autonomic load is in check.", "ภาระระบบประสาทอยู่ในเกณฑ์")
              : t("Try slow breathing; bank recovery tonight.", "ลองหายใจช้า ๆ; เก็บการฟื้นตัวคืนนี้"))

    case "energy":
      let band = Monitors.energyBand(v)
      let lbl = [t("very low", "ต่ำมาก"), t("low", "ต่ำ"), t("medium", "กลาง"), t("high", "สูง")][band]
      return SummaryCard(band >= 2 ? .good : .watch, t("Energy \(f(v))% — \(lbl) reserve", "พลังงาน \(f(v))% — สำรอง\(lbl)"),
        t("Built from last night's recovery/sleep, drained by strain & stress.",
          "สร้างจากการฟื้นตัว/การนอนเมื่อคืน ลดด้วย strain และความเครียด"),
        band >= 2 ? t("Tank is healthy — good to go.", "พลังงานดี — ลุยได้")
                  : t("Reserve is low — ease up and recharge.", "สำรองต่ำ — เบาลงและชาร์จ"))

    case "kcal":
      return SummaryCard(.info, t("\(f(v)) kcal today", "\(f(v)) kcal วันนี้"),
        t("Maintenance (TDEE) ≈\(f(p.tdee)) kcal/day for you (BMR \(f(p.bmr)) × activity).",
          "ระดับคงที่ (TDEE) ≈\(f(p.tdee)) kcal/วัน สำหรับคุณ (BMR \(f(p.bmr)) × กิจกรรม)"),
        t("Total = resting (BMR) + active; compare to maintenance for energy balance.",
          "รวม = พื้นฐาน (BMR) + active; เทียบ maintenance เพื่อดูสมดุลพลังงาน"))

    case "steps":
      let good = v >= 8000
      return SummaryCard(good ? .good : .neutral, t("\(f(v)) steps", "\(f(v)) ก้าว"),
        t("A practical daily floor is ~8–10k.", "ขั้นต่ำที่ดีต่อวัน ~8–10k"),
        good ? t("Nice movement volume.", "เคลื่อนไหวได้ดี") : t("A short walk closes the gap.", "เดินสั้น ๆ ก็ถึงเป้า"))

    case "temp":
      if let z = z, z > 1 { return SummaryCard(.watch, t("Skin temp \(f(v,1))°C — above baseline", "อุณหภูมิผิว \(f(v,1))°C — สูงกว่า baseline"),
        t("Deviation from your nightly normal matters, not the absolute.", "ดูส่วนต่างจากค่าปกติกลางคืน ไม่ใช่ค่าดิบ"),
        t("Temp + RHR both up = likely illness; rest.", "อุณหภูมิ + RHR ขึ้นทั้งคู่ = อาจป่วย; พัก")) }
      return SummaryCard(.good, t("Skin temp \(f(v,1))°C — near baseline", "อุณหภูมิผิว \(f(v,1))°C — ใกล้ baseline"),
        t("Tracking your nightly normal.", "ตรงกับค่าปกติกลางคืนของคุณ"))

    case "resp":
      if let z = z, z > 1 { return SummaryCard(.watch, t("Respiratory \(f(v,1)) rpm — elevated", "การหายใจ \(f(v,1)) rpm — สูงขึ้น"),
        t("Vs your nightly baseline (±1–2 rpm flags).", "เทียบ baseline กลางคืน (±1–2 rpm = สัญญาณ)"),
        t("A sustained rise can signal illness or strain.", "ขึ้นต่อเนื่องอาจบ่งชี้ป่วยหรือเครียด")) }
      return SummaryCard(.good, t("Respiratory \(f(v,1)) rpm — normal", "การหายใจ \(f(v,1)) rpm — ปกติ"),
        t("Steady vs your baseline.", "นิ่งเทียบ baseline"))

    case "tsb":
      if v > 5 { return SummaryCard(.good, t("Form (TSB) \(f(v,1)) — fresh", "ฟอร์ม (TSB) \(f(v,1)) — สด"),
        t("Fitness exceeds fatigue.", "ความฟิตมากกว่าความล้า"), t("Good window for a hard session or race.", "ช่วงเหมาะซ้อมหนักหรือแข่ง")) }
      if v < -15 { return SummaryCard(.watch, t("Form (TSB) \(f(v,1)) — fatigued", "ฟอร์ม (TSB) \(f(v,1)) — ล้า"),
        t("Fatigue exceeds fitness.", "ความล้ามากกว่าความฟิต"), t("Back off before you overreach.", "ผ่อนก่อนจะ overreach")) }
      return SummaryCard(.neutral, t("Form (TSB) \(f(v,1)) — balanced", "ฟอร์ม (TSB) \(f(v,1)) — สมดุล"),
        t("Fitness and fatigue are even.", "ฟิตกับล้าพอกัน"), t("Productive training zone.", "โซนฝึกที่ได้ผล"))

    case "weight":
      let cat = HealthRef.bmiCategory(p.bmi)
      let catTH = ["Underweight": "น้ำหนักน้อย", "Healthy": "สุขภาพดี", "Overweight": "น้ำหนักเกิน", "Obese": "อ้วน"][cat] ?? cat
      return SummaryCard(cat == "Healthy" ? .good : .neutral, t("Weight \(f(v,1)) kg", "น้ำหนัก \(f(v,1)) kg"),
        t("BMI \(f(p.bmi,1)) — \(cat) (height \(f(p.heightCm)) cm).", "BMI \(f(p.bmi,1)) — \(catTH) (สูง \(f(p.heightCm)) cm)"),
        t("Watch the smoothed trend, not daily noise.", "ดูเทรนด์ที่เกลี่ยแล้ว ไม่ใช่ค่ารายวัน"))

    case "sri":
      let good = v >= 70
      return SummaryCard(good ? .good : .watch, t("Sleep consistency \(f(v))", "ความสม่ำเสมอการนอน \(f(v))"),
        t("Higher = more regular bed/wake times.", "สูง = เวลานอน/ตื่นสม่ำเสมอ"),
        good ? t("Steady schedule — it boosts recovery.", "ตารางนิ่ง — ช่วยการฟื้นตัว") : t("Aim for the same bedtime nightly.", "เข้านอนเวลาเดิมทุกคืน"))

    case "spo2":
      return SummaryCard(.info, t("SpO₂ index \(f(v)) (rel)", "ดัชนี SpO₂ \(f(v)) (สัมพัทธ์)"),
        t("Relative to your baseline (100) — not a clinical %.", "เทียบ baseline (100) — ไม่ใช่ % ทางคลินิก"),
        t("Watch for sustained overnight dips; verify a real % with a fingertip oximeter.",
          "ดูการดิ่งต่อเนื่องตอนหลับ; ตรวจ % จริงด้วย oximeter ปลายนิ้ว"))

    case "hr":
      return SummaryCard(.info, t("Heart rate \(f(v)) bpm", "อัตราหัวใจ \(f(v)) bpm"),
        t("Live pulse — context depends on what you're doing.", "ชีพจรสด — ขึ้นกับว่ากำลังทำอะไร"))

    default:
      return SummaryCard(.info, "\(f(v,1))", t("Live value.", "ค่าสด"))
    }
  }
}
