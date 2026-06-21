import Foundation

/// In-app plain-language help for every metric & feature. Four short, benefit-first lines:
/// purpose (what to look at it for), benefit (what you get), compare (against what),
/// next (what to look at next). Surfaced as a GuideCard on each Metric-Detail / feature screen.
public struct MetricGuide: Equatable, Sendable {
  public let purpose: String   // what to look at it for
  public let benefit: String   // what you get out of it
  public let compare: String   // what to compare against
  public let next: String      // what to look at next ("" = none)
  public init(_ purpose: String, _ benefit: String, _ compare: String, _ next: String = "") {
    self.purpose = purpose; self.benefit = benefit; self.compare = compare; self.next = next
  }
}

public enum MetricGuides {
  /// Look up by a stable key (MetricKind name or feature id). Returns nil if none.
  public static func guide(_ key: String) -> MetricGuide? { table[key] }
  /// Localized lookup — Thai when `thai`, else English.
  public static func guide(_ key: String, thai: Bool) -> MetricGuide? { (thai ? thaiTable[key] : table[key]) }

  static let table: [String: MetricGuide] = [
    // ── Heart ───────────────────────────────────────────────────────────────
    "hr": MetricGuide(
      "How hard your heart is working right now.",
      "Read effort, stress or calm in real time.",
      "Your resting HR and HR zones.",
      "Open HRV for recovery, or Zones for effort."),
    "rhr": MetricGuide(
      "Your heart's floor, measured each night asleep.",
      "A rising RHR is the #1 early sign of illness or overtraining.",
      "Your own 7-day baseline — lower = fitter / recovered.",
      "Pair with Skin Temp: both rising = likely getting sick."),
    "hrv": MetricGuide(
      "How recovered your nervous system is.",
      "Higher vs baseline = ready to train; a drop = back off.",
      "Your 7-day baseline band, not other people.",
      "Check Recovery — HRV is its biggest driver."),
    "sdnn": MetricGuide(
      "A broader HRV measure (overall variability).",
      "Backs up RMSSD; steadier = better adapted.",
      "Your own baseline.",
      "Use RMSSD as the primary HRV read."),
    "stress": MetricGuide(
      "How much load your autonomic system is under.",
      "Watch daytime stress build and recover.",
      "Your personal range — it's spiky, so watch the trend.",
      "High all day? Check Recovery and Sleep."),
    // ── Respiratory & Temp ─────────────────────────────────────────────────
    "resp": MetricGuide(
      "Breaths per minute while you sleep.",
      "A steady rise can flag illness or hard training.",
      "Your nightly baseline (±1–2 bpm = a flag).",
      "Cross-check RHR and Skin Temp for illness."),
    "temp": MetricGuide(
      "How far skin temperature drifts overnight.",
      "A sustained +0.5°C hints at illness or cycle phase.",
      "Your own baseline — the deviation, not the absolute.",
      "Two-signal illness check: Temp + RHR both up."),
    // ── Fitness ─────────────────────────────────────────────────────────────
    "vo2": MetricGuide(
      "Your aerobic fitness ceiling.",
      "Track long-term fitness gains.",
      "Age/sex population norms (percentile).",
      "Set a real max-HR in Settings for accuracy."),
    "ctl": MetricGuide(
      "Your fitness — load built up over ~6 weeks.",
      "Rising = getting fitter.",
      "Its slow trend, balanced against fatigue (ATL).",
      "Watch Form (TSB) so you don't dig too deep."),
    "atl": MetricGuide(
      "Your fatigue — load from the last ~week.",
      "Spikes mean you're loading hard right now.",
      "Against fitness (CTL).",
      "Check Form (TSB = fitness − fatigue)."),
    "tsb": MetricGuide(
      "Your form — fresh vs fatigued.",
      "Positive = tapered & fresh; negative = carrying fatigue.",
      "The 0 line: very high = detraining, very low = overreaching.",
      "Plan hard days when form is neutral-to-positive."),
    // ── Activity ────────────────────────────────────────────────────────────
    "strain": MetricGuide(
      "How much cardio load you put in today (0–21).",
      "Match effort to how recovered you are.",
      "Your Recovery — green day = push, red = ease.",
      "See the Strain × Recovery balance in Trends."),
    "steps": MetricGuide(
      "Daily movement volume.",
      "A simple activity floor for the day.",
      "Your goal / 7-day average.",
      "Calories for energy, Strain for cardio load."),
    "kcal": MetricGuide(
      "Energy burned — resting (BMR) plus active.",
      "See the active part you earned on top of baseline.",
      "Your daily average.",
      "Pair with Strain to see effort vs burn."),
    // ── Body ────────────────────────────────────────────────────────────────
    "weight": MetricGuide(
      "Body-mass trend.",
      "See the real direction through daily noise.",
      "Your smoothed trend, not single days."),
    "spo2": MetricGuide(
      "Relative blood-oxygen trend (experimental).",
      "Spot unusual dips over time.",
      "Your own trend only — not a clinical %."),
    // ── Composite scores ─────────────────────────────────────────────────────
    "recovery": MetricGuide(
      "One score for how ready your body is today.",
      "Decide push vs rest in a glance.",
      "Green ≥67 / Yellow 34–66 / Red <34.",
      "Tap Contributors to see what drove it."),
    "readiness": MetricGuide(
      "Today's go/ease call from recovery + sleep + form.",
      "One number to plan your day around.",
      "≥60 = ready for load.",
      "Open Coach for what to actually do."),
    // ── Sleep ─────────────────────────────────────────────────────────────────
    "sleep": MetricGuide(
      "How well you slept — score, stages and timing.",
      "Sleep is the biggest lever on Recovery.",
      "Your sleep need and a regular schedule (SRI).",
      "Low Recovery? Start here."),
    "sri": MetricGuide(
      "How regular your sleep/wake times are.",
      "A steady schedule itself improves recovery.",
      "Higher = more regular; below 70 = drifting.",
      "Set a consistent bedtime."),
    "sleepDebt": MetricGuide(
      "Hours of sleep you owe vs your need.",
      "Catch a deficit before it drags you down.",
      "Zero = caught up.",
      "Prioritize sleep tonight if it's climbing."),
    // ── Features ──────────────────────────────────────────────────────────────
    "zones": MetricGuide(
      "Time spent in each heart-rate zone.",
      "See if training was easy, moderate or hard.",
      "A polarized mix: mostly easy + some hard.",
      "Strain sums this into one load number."),
    "pmc": MetricGuide(
      "Fitness, Fatigue and Form on one chart.",
      "See whether you're building fitness or burning out.",
      "The Form line vs 0 — positive = fresh.",
      "Time hard blocks when fitness rises and form isn't deeply negative."),
    "scatter": MetricGuide(
      "Did you train hard on recovered days?",
      "Spot risky hard-on-red days.",
      "Top-right (hard + green) is ideal.",
      "Aim your strain at green days."),
    "journal": MetricGuide(
      "Tag behaviors to learn what helps or hurts you.",
      "Personal proof — e.g. alcohol lowers your recovery.",
      "Each behavior's effect on YOUR recovery.",
      "Check Impacts after a few logs."),
    "workout": MetricGuide(
      "Live session strain, HR, zones and calories.",
      "Gauge effort during a workout in real time.",
      "Your strain target for the day.",
      "Review it later in Activities."),
    "energy": MetricGuide(
      "Your battery — builds with rest, drains with effort & stress.",
      "Plan the day around how much is left in the tank.",
      "Reserve bands: high 76+, medium 51+, low 26+, very low <26.",
      "Low? Ease strain and protect tonight's sleep."),
    "motion": MetricGuide(
      "Whether you're still, moving, or active right now.",
      "Tells the Stress monitor to separate effort from stress.",
      "Live from the wrist motion sensor.",
      "Active reading? Your stress score reflects exercise, not tension."),
  ]

  static let thaiTable: [String: MetricGuide] = [
    "hr": MetricGuide(
      "หัวใจกำลังทำงานหนักแค่ไหนตอนนี้",
      "อ่านความเหนื่อย/เครียด/สงบ แบบเรียลไทม์",
      "เทียบกับ RHR และโซนหัวใจของคุณ",
      "ดู HRV เพื่อการฟื้นตัว หรือ Zones เพื่อความหนัก"),
    "rhr": MetricGuide(
      "อัตราหัวใจขณะพัก วัดทุกคืนตอนหลับ",
      "RHR ที่สูงขึ้นคือสัญญาณป่วย/โอเวอร์เทรนอันดับ 1",
      "เทียบ baseline 7 วันของคุณ — ต่ำ = ฟิต/ฟื้นตัวดี",
      "ดูคู่กับอุณหภูมิผิว: ขึ้นทั้งคู่ = กำลังจะป่วย"),
    "hrv": MetricGuide(
      "ระบบประสาทฟื้นตัวดีแค่ไหน",
      "สูงกว่า baseline = พร้อมเทรน, ลดลง = พักก่อน",
      "เทียบ baseline 7 วันของคุณ ไม่ใช่คนอื่น",
      "ดู Recovery — HRV คือตัวขับเคลื่อนหลัก"),
    "sdnn": MetricGuide(
      "ค่าความแปรปรวนหัวใจแบบกว้าง",
      "ใช้ยืนยัน RMSSD; นิ่ง = ปรับตัวดี",
      "เทียบ baseline ของคุณ",
      "ใช้ RMSSD เป็นค่าหลัก"),
    "stress": MetricGuide(
      "ระบบประสาทอัตโนมัติแบกภาระแค่ไหน",
      "ดูความเครียดสะสมและคลายตัวระหว่างวัน",
      "เทียบช่วงปกติของคุณ — แกว่งง่าย ให้ดูเทรนด์",
      "สูงทั้งวัน? ดู Recovery และการนอน"),
    "resp": MetricGuide(
      "อัตราหายใจขณะหลับ (ครั้ง/นาที)",
      "ค่อยๆ สูงขึ้น = อาจป่วยหรือเทรนหนัก",
      "เทียบ baseline กลางคืน (±1–2 = สัญญาณเตือน)",
      "เช็ค RHR และอุณหภูมิผิวประกอบ"),
    "temp": MetricGuide(
      "อุณหภูมิผิวเบี่ยงจากปกติแค่ไหนตอนกลางคืน",
      "+0.5°C ต่อเนื่อง = อาจป่วยหรือรอบเดือน",
      "เทียบ baseline ของคุณ — ดูส่วนต่าง ไม่ใช่ค่าดิบ",
      "เช็คป่วย 2 สัญญาณ: อุณหภูมิ + RHR ขึ้นพร้อมกัน"),
    "vo2": MetricGuide(
      "เพดานความฟิตแบบแอโรบิก",
      "ติดตามความฟิตระยะยาว",
      "เทียบเกณฑ์ประชากรตามอายุ/เพศ",
      "ตั้ง max-HR จริงใน Settings เพื่อความแม่นยำ"),
    "ctl": MetricGuide(
      "ความฟิต — ภาระสะสมราว 6 สัปดาห์",
      "สูงขึ้น = ฟิตขึ้น",
      "ดูเทรนด์ช้าๆ คู่กับความล้า (ATL)",
      "ดู Form (TSB) อย่าขุดลึกเกินไป"),
    "atl": MetricGuide(
      "ความล้า — ภาระจากราว 1 สัปดาห์ล่าสุด",
      "พุ่งขึ้น = กำลังเทรนหนักอยู่",
      "เทียบกับความฟิต (CTL)",
      "ดู Form (TSB = ฟิต − ล้า)"),
    "tsb": MetricGuide(
      "ฟอร์ม — สด vs ล้า",
      "บวก = เทเปอร์/สด, ลบ = ยังแบกความล้า",
      "เทียบเส้น 0: สูงมาก = ฟิตตก, ต่ำมาก = โอเวอร์รีช",
      "วางวันหนักตอนฟอร์มเป็นกลางถึงบวก"),
    "strain": MetricGuide(
      "วันนี้ใส่ภาระให้หัวใจไปเท่าไหร่ (0–21)",
      "จับคู่ความหนักกับระดับการฟื้นตัว",
      "เทียบ Recovery — เขียว = ซัด, แดง = เบาๆ",
      "ดูสมดุล Strain × Recovery ในแท็บแนวโน้ม"),
    "steps": MetricGuide(
      "ปริมาณการเคลื่อนไหวรายวัน",
      "พื้นฐานความ active ของวัน",
      "เทียบเป้าหมาย/ค่าเฉลี่ย 7 วัน",
      "ดู Calories สำหรับพลังงาน, Strain สำหรับภาระหัวใจ"),
    "kcal": MetricGuide(
      "พลังงานที่เผา — พื้นฐาน (BMR) + active",
      "เห็นส่วน active ที่ออกแรงเพิ่มจากพื้นฐาน",
      "เทียบค่าเฉลี่ยรายวัน",
      "ดูคู่ Strain เทียบความหนักกับการเผา"),
    "weight": MetricGuide(
      "เทรนด์น้ำหนักตัว",
      "เห็นทิศทางจริงผ่าน noise รายวัน",
      "เทียบเทรนด์ที่เกลี่ยแล้ว ไม่ใช่รายวัน"),
    "spo2": MetricGuide(
      "เทรนด์ออกซิเจนในเลือดแบบสัมพัทธ์ (ทดลอง)",
      "จับการตกผิดปกติตามเวลา",
      "เทียบเทรนด์ตัวเอง — ไม่ใช่ค่าทางคลินิก"),
    "recovery": MetricGuide(
      "คะแนนเดียวบอกร่างกายพร้อมแค่ไหนวันนี้",
      "ตัดสินใจซัดหรือพักได้ในแวบเดียว",
      "เขียว ≥67 / เหลือง 34–66 / แดง <34",
      "แตะ Contributors ดูว่าอะไรทำให้ได้คะแนนนี้"),
    "readiness": MetricGuide(
      "คำแนะนำซัด/เบา จาก recovery + นอน + ฟอร์ม",
      "ตัวเลขเดียวไว้วางแผนทั้งวัน",
      "≥60 = พร้อมรับภาระ",
      "เปิด Coach ดูว่าควรทำอะไรต่อ"),
    "sleep": MetricGuide(
      "หลับดีแค่ไหน — คะแนน, ระยะ, เวลา",
      "การนอนคือคันโยกใหญ่สุดของ Recovery",
      "เทียบความต้องการนอน + ความสม่ำเสมอ (SRI)",
      "Recovery ต่ำ? เริ่มดูที่นี่"),
    "sri": MetricGuide(
      "เวลานอน/ตื่นสม่ำเสมอแค่ไหน",
      "ตารางนิ่งช่วยการฟื้นตัวโดยตรง",
      "สูง = สม่ำเสมอ, ต่ำกว่า 70 = เริ่มเพี้ยน",
      "ตั้งเวลาเข้านอนให้คงที่"),
    "sleepDebt": MetricGuide(
      "ชั่วโมงนอนที่ติดหนี้เทียบความต้องการ",
      "จับการขาดทุนก่อนจะฉุดคุณ",
      "ศูนย์ = ตามทันแล้ว",
      "ถ้าเพิ่มขึ้น คืนนี้ให้ความสำคัญกับการนอน"),
    "zones": MetricGuide(
      "เวลาที่อยู่ในแต่ละโซนหัวใจ",
      "ดูว่าเทรนเบา ปานกลาง หรือหนัก",
      "มิกซ์แบบ polarized: เบาเยอะ + หนักบ้าง",
      "Strain รวมค่านี้เป็นภาระก้อนเดียว"),
    "pmc": MetricGuide(
      "ฟิต ล้า ฟอร์ม ในกราฟเดียว",
      "ดูว่ากำลังสร้างความฟิตหรือกำลังพัง",
      "เทียบเส้น Form กับ 0 — บวก = สด",
      "วางบล็อกหนักตอนฟิตขึ้นและฟอร์มไม่ติดลบลึก"),
    "scatter": MetricGuide(
      "เทรนหนักในวันที่ฟื้นตัวดีไหม?",
      "จับวันที่ฝืนหนักทั้งที่ยังแดง",
      "มุมขวาบน (หนัก + เขียว) ดีที่สุด",
      "เล็ง strain ไปที่วันเขียว"),
    "journal": MetricGuide(
      "แท็กพฤติกรรมเพื่อรู้ว่าอะไรช่วย/ฉุด",
      "หลักฐานส่วนตัว เช่น แอลกอฮอล์ลด recovery",
      "ผลของแต่ละพฤติกรรมต่อ recovery ของคุณ",
      "ดู Impacts หลังบันทึกไปไม่กี่ครั้ง"),
    "workout": MetricGuide(
      "strain/HR/โซน/แคลอรี่ ของเซสชันแบบสด",
      "วัดความหนักระหว่างออกกำลังกายเรียลไทม์",
      "เทียบ strain เป้าหมายของวัน",
      "ดูย้อนหลังในแท็บกิจกรรม"),
    "energy": MetricGuide(
      "แบตเตอรี่ร่างกาย — เติมตอนพัก ลดตอนออกแรง/เครียด",
      "วางแผนทั้งวันจากพลังงานที่เหลือ",
      "ระดับ: สูง 76+, กลาง 51+, ต่ำ 26+, ต่ำมาก <26",
      "เหลือน้อย? ลดความหนักและรักษาการนอนคืนนี้"),
    "motion": MetricGuide(
      "ตอนนี้คุณอยู่นิ่ง กำลังขยับ หรือเคลื่อนไหวแรง",
      "บอกให้ Stress monitor แยกการออกแรงออกจากความเครียด",
      "อ่านสดจากเซ็นเซอร์การเคลื่อนไหวที่ข้อมือ",
      "ถ้า active อยู่ คะแนนเครียดจะสะท้อนการออกกำลังกาย ไม่ใช่ความตึงเครียด"),
  ]
}
