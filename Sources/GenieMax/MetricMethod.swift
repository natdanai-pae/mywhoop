import Foundation

/// Deep "how is this computed" provenance for each metric/insight — shown behind a small ⓘ button.
/// Five fields: what measures it, the formula, the analysis structure, what it's compared against, and an
/// accuracy/fit note so the user can judge how well the estimate matches them.
public struct MetricMethod: Equatable, Sendable {
  public let source: String       // measured from
  public let formula: String      // the math
  public let structure: String    // analysis pipeline / baseline
  public let comparison: String   // compared against what
  public let accuracy: String     // how to judge fit / known error
  public init(_ source: String, _ formula: String, _ structure: String, _ comparison: String, _ accuracy: String) {
    self.source = source; self.formula = formula; self.structure = structure
    self.comparison = comparison; self.accuracy = accuracy
  }
}

public enum MetricMethods {
  /// Localized lookup — Thai when `thai` (falls back to English if a Thai entry is missing).
  public static func method(_ key: String, thai: Bool) -> MetricMethod? {
    thai ? (thaiTable[key] ?? table[key]) : table[key]
  }

  static let table: [String: MetricMethod] = [
    "hr": MetricMethod(
      "Optical PPG at the wrist (and the strap's broadcast HR).",
      "Beats per minute from detected pulse peaks.",
      "Smoothed for display; it's the raw input to almost every other metric.",
      "Your resting HR and HR zones.",
      "PPG HR is ~2–3 bpm of ECG at rest; less accurate during fast motion."),
    "rhr": MetricMethod(
      "Sleeping heart rate (PPG) through the night.",
      "Minimum of the 5-minute moving average of HR while asleep.",
      "One value per night; a CUSUM control chart watches for a sustained rise.",
      "Your own 7-day baseline; athletic <60, normal 60–100 bpm.",
      "WHOOP RHR vs ECG: CCC 0.91, ~3% error. Should track your true morning pulse."),
    "hrv": MetricMethod(
      "Beat-to-beat RR intervals (PPG/broadcast), best from the sleep window.",
      "RMSSD = √(mean of squared successive RR differences); stored as ln(RMSSD).",
      "Malik-filter RR → nightly RMSSD → 7-day EWMA baseline + control chart + CUSUM.",
      "Your 7-day rolling baseline band (Plews method), not other people.",
      "Target = WHOOP CCC 0.94 / MAPE 8.2% vs ECG once sleep-window PPG-HRV is wired."),
    "sdnn": MetricMethod(
      "The same RR intervals used for RMSSD.",
      "SDNN = standard deviation of all RR intervals.",
      "Computed alongside RMSSD from one shared RR set.",
      "Your own baseline.",
      "Broader HRV measure; more sensitive to recording length than RMSSD."),
    "stress": MetricMethod(
      "Live HR + HRV (RR intervals), skin temp when available, and wrist motion.",
      "0–3 monitor from HR above resting baseline + HRV below baseline, with a small temperature nudge.",
      "Baseline built from quiet (still) samples; motion gates exercise out.",
      "Your resting HR/HRV/temp baselines.",
      "Directional autonomic-activation signal; raw Baevsky SI is separate when shown."),
    "resp": MetricMethod(
      "RR/PPG-derived breathing when available; K18 respiratory fields remain candidate-only.",
      "Use RSA from RR oscillation for validated paths; do not promote K18 candidate resp into product metrics.",
      "Nightly baseline + CUSUM.",
      "Your nightly baseline (±1–2 bpm flags).",
      "Most stable asleep; candidate custom fields are excluded until source labels are added."),
    "temp": MetricMethod(
      "Skin-temperature sensor on the strap.",
      "We track the deviation Δ from your nightly baseline, not the absolute °C.",
      "Nightly baseline + CUSUM (pairs with RHR for a 2-signal illness flag).",
      "Your own baseline; flags a sustained +0.5°C.",
      "Skin (not core) temperature — the trend matters more than the number."),
    "vo2": MetricMethod(
      "Your HRmax and resting HR.",
      "Uth 2004: VO₂max ≈ 15.3 · HRmax / RHR.",
      "Recomputed as HRmax / RHR refine.",
      "ACSM age/sex percentile norms.",
      "Hinges on a measured HRmax — a Tanaka estimate adds ±10 bpm; record a real max to tighten it."),
    "ctl": MetricMethod(
      "Your daily Strain (training load).",
      "CTL = exponentially-weighted moving average of load, τ = 42 days.",
      "Banister impulse-response model (TrainingPeaks PMC).",
      "Its own slow trend, balanced against fatigue (ATL).",
      "Deterministic — as exact as the load input; needs ≥7 days to settle."),
    "atl": MetricMethod(
      "Your daily Strain.",
      "ATL = EWMA of load, τ = 7 days.",
      "Same PMC model, short time-constant.",
      "Against fitness (CTL).",
      "Deterministic; reacts within days."),
    "tsb": MetricMethod(
      "Fitness (CTL) and fatigue (ATL).",
      "TSB (form) = CTL − ATL.",
      "PMC; positive = fresh, negative = fatigued.",
      "The 0 line; very high = detraining, very low = overreaching.",
      "Deterministic; meaningful once CTL/ATL have ≥7 days."),
    "strain": MetricMethod(
      "HR through the day + your HRmax and resting HR.",
      "Banister TRIMP uses sex-specific factors: male 0.64·e^(1.92·HRR), female 0.86·e^(1.67·HRR); Strain = 21·(1 − e^(−TRIMP/τ)).",
      "Accumulates through the day; τ sets the curve steepness.",
      "Your Recovery (push on green, ease on red).",
      "τ is uncalibrated until fit to ~20–30 real WHOOP day-strain values."),
    "steps": MetricMethod(
      "Wrist accelerometer.",
      "Peak-count of |accel|−1g above a threshold with a refractory gap.",
      "Continuous count, reset daily.",
      "Your goal / 7-day average.",
      "Validated ~1.5% walking; under-counts arm-still activities."),
    "kcal": MetricMethod(
      "HR + wrist motion + your profile (age/sex/weight/height).",
      "Mifflin BMR floor + Keytel HR-path (high HR) blended with an accel-path (low HR) by HR-reserve.",
      "Per-minute integration; daily total = resting (BMR) + active.",
      "Your daily average.",
      "HR-only calories run ±20–30%; the branched model + BMR floor reduce that."),
    "recovery": MetricMethod(
      "Sleep-window HRV, resting HR, respiratory rate and sleep score.",
      "Recovery = 100·Φ(0.55·zHRV − 0.20·zRHR − 0.10·zRR + 0.15·zSleep).",
      "Each input z-scored vs your ≥7-night baseline, summed, mapped through the normal CDF Φ.",
      "Green ≥67 / Yellow 34–66 / Red <34.",
      "Directionally sound; the 4 weights are hand-set — calibrate vs WHOOP after unlock."),
    "readiness": MetricMethod(
      "Recovery + sleep score + form (TSB), minus an illness penalty.",
      "Weighted blend of those inputs into 0–100.",
      "Daily composite.",
      "≥60 = ready for load.",
      "Untuned blend — treat as a guide, not a verdict."),
    "sleep": MetricMethod(
      "Overnight wrist motion + HR/HRV/temperature.",
      "Cole-Kripke activity → sleep/wake; features rank-allocated to AASM stage %; Score = 0.55·dur/need + 0.25·eff + 0.20·stage-balance.",
      "60-s epochs → longest sleep window → staging → HMM-style smoothing.",
      "Your sleep need (8 h default) + AASM stage targets.",
      "Heuristic staging; target κ≈0.47 vs PSG (WHOOP-class, above Fitbit 0.41)."),
    "sri": MetricMethod(
      "Your sleep-onset and wake times.",
      "Sleep Regularity Index from the SD of noon-shifted onset/wake times → 0–100.",
      "Multi-night.",
      "Higher = more regular; below 70 = drifting.",
      "Needs several nights of data to be meaningful."),
    "sleepDebt": MetricMethod(
      "Nightly time-asleep vs your sleep need.",
      "Sum over 7 days of (need − time-asleep).",
      "Rolling cumulative deficit.",
      "0 = caught up.",
      "Depends on the sleep-need target (8 h default)."),
    "zones": MetricMethod(
      "HR + your HRmax and resting HR.",
      "Karvonen %HRR = (HR − RHR) / (HRmax − RHR); zones at 50/60/70/80/90%.",
      "Minutes accumulate per zone (time-in-range).",
      "The Karvonen zone bands.",
      "Only as good as your HRmax — measure it for accurate zones."),
    "energy": MetricMethod(
      "Strain, stress and motion + last night's recovery & sleep.",
      "Battery 0–100: starts at 0.5·recovery + 0.5·sleep; drains with strain/stress/movement, recharges at calm rest.",
      "Per-minute integration (a Body-Battery analog).",
      "Reserve bands (high 76+ … very low <26).",
      "Heuristic model — the drain/recharge rates still need calibration."),
    "motion": MetricMethod(
      "Wrist accelerometer.",
      "Smoothed |accel|−1g → still / moving / active thresholds.",
      "EWMA of acceleration magnitude, updated live.",
      "Thresholds (still <0.03 g, active >0.12 g).",
      "Coarse posture/activity sense; thresholds tunable on real movement."),
    "weight": MetricMethod(
      "Manual entry (or a connected scale).",
      "Shown as an EWMA-smoothed trend; BMI = kg / m².",
      "Smoothing suppresses day-to-day water-weight noise.",
      "Your own smoothed trend.",
      "As accurate as what you log."),
    "spo2": MetricMethod(
      "Red/IR optical ratio on the strap.",
      "A relative trend from the RED/IR ratio (EWMA-smoothed) — not an absolute %.",
      "Trend only.",
      "Your own trend.",
      "Experimental; the true clinical % is cloud-computed and not available here."),
    "scatter": MetricMethod(
      "Each day's Strain and Recovery.",
      "A point per day: Recovery (x) vs Strain (y), colored by recovery.",
      "Last 30 days.",
      "Top-right = trained hard on a recovered day.",
      "A visual relationship, not a single score."),
    "pmc": MetricMethod(
      "Your daily Strain (load).",
      "CTL (τ42, fitness), ATL (τ7, fatigue), TSB = CTL − ATL (form).",
      "Banister impulse-response / TrainingPeaks Performance Management Chart.",
      "The Form line vs 0.",
      "Deterministic; needs ≥7 days to settle."),
    "journal": MetricMethod(
      "Your behavior tags + daily Recovery.",
      "Cohen's d = (mean Recovery with − without) / pooled SD.",
      "Splits days by whether you logged the behavior.",
      "Days you did vs didn't do it.",
      "Correlational (confounded); more logs = clearer effect."),
    "insights": MetricMethod(
      "Your Recovery, form (TSB), sleep score and sleep debt.",
      "Rule thresholds map your metrics to a recommendation; the optional AI coach adds an LLM over the same data + journal.",
      "Deterministic rules first; an opt-in LLM layer second.",
      "Your own current values.",
      "Guidance, not medical advice."),
    "musclefat": MetricMethod(
      "InBody's Muscle-Fat Analysis — three bars: Weight, Skeletal Muscle Mass (SMM), and Body Fat Mass, each shown against the healthy average for someone your height and sex.",
      "Each bar = your value ÷ its 100%-normal (the dashed line). Connecting the tips of the three bars draws a shape that reads as a letter — C, I or D.",
      "C-shape — the Body Fat bar is the longest (fat outweighs muscle): intervention type, focus on building muscle and lowering fat. I-shape — all three bars are about the same length: balanced, a healthy baseline. D-shape — the Muscle bar is the longest, reaching past Weight and Fat: strong / athletic, the ideal. Higher muscle and lower fat push you from C → I → D.",
      "The 100%-normal line is the average for your height and sex (we estimate normals from BMI 22, your body-fat norm, and SMM ≈ half of lean mass) — not a direct comparison to other people.",
      "It's a quick visual summary of the same numbers — the actual SMM/fat values and their trend over scans matter more than the single letter. Not a medical diagnosis."),
  ]

  static let thaiTable: [String: MetricMethod] = [
    "hr": MetricMethod(
      "เซ็นเซอร์แสง PPG ที่ข้อมือ (และ HR ที่สายส่งออกมา)",
      "จำนวนครั้งต่อนาที จากการจับยอดคลื่นชีพจร",
      "เกลี่ยให้นิ่งเพื่อแสดงผล เป็นค่าตั้งต้นของแทบทุก metric",
      "เทียบกับ RHR และโซนหัวใจของคุณ",
      "PPG คลาดจาก ECG ~2–3 bpm ตอนพัก, แม่นน้อยลงตอนขยับเร็ว"),
    "rhr": MetricMethod(
      "อัตราหัวใจขณะหลับ (PPG) ตลอดคืน",
      "ค่าต่ำสุดของค่าเฉลี่ยเคลื่อนที่ 5 นาทีของ HR ขณะหลับ",
      "1 ค่า/คืน; CUSUM เฝ้าการเพิ่มขึ้นต่อเนื่อง",
      "baseline 7 วันของคุณ; นักกีฬา <60, ปกติ 60–100 bpm",
      "WHOOP RHR เทียบ ECG: CCC 0.91, ~3% — ควรตรงกับชีพจรตอนเช้าจริง"),
    "hrv": MetricMethod(
      "ช่วง RR ระหว่างจังหวะหัวใจ (PPG) ดีสุดจากช่วงหลับ",
      "RMSSD = √(ค่าเฉลี่ยของผลต่าง RR ติดกันยกกำลังสอง); เก็บเป็น ln(RMSSD)",
      "กรอง Malik → RMSSD รายคืน → baseline EWMA 7 วัน + control chart + CUSUM",
      "แถบ baseline 7 วันของคุณ (วิธี Plews) ไม่ใช่คนอื่น",
      "เป้า = WHOOP CCC 0.94 / MAPE 8.2% เทียบ ECG เมื่อต่อ PPG-HRV ช่วงหลับ"),
    "sdnn": MetricMethod(
      "ชุด RR เดียวกับที่ใช้คำนวณ RMSSD",
      "SDNN = ส่วนเบี่ยงเบนมาตรฐานของ RR ทั้งหมด",
      "คำนวณคู่กับ RMSSD จาก RR ชุดเดียว",
      "baseline ของคุณ",
      "วัด HRV แบบกว้าง ไวต่อความยาวการบันทึกมากกว่า RMSSD"),
    "stress": MetricMethod(
      "HR + HRV (RR) สด, อุณหภูมิผิวถ้ามี และการเคลื่อนไหวข้อมือ",
      "สเกล 0–3 จาก HR สูงกว่า baseline พัก + HRV ต่ำกว่า baseline พร้อมตัว nudged จากอุณหภูมิเล็กน้อย",
      "baseline จากช่วงอยู่นิ่ง; การขยับถูกกรองแยกออก",
      "baseline HR/HRV/อุณหภูมิขณะพักของคุณ",
      "บอกระดับการกระตุ้นระบบประสาท; ค่า Baevsky SI ดิบเป็นคนละค่าถ้ามีแสดง"),
    "resp": MetricMethod(
      "RR/PPG-derived breathing when available; K18 respiratory fields remain candidate-only.",
      "Use RSA from RR oscillation for validated paths; do not promote K18 candidate resp into product metrics.",
      "baseline รายคืน + CUSUM",
      "baseline กลางคืน (±1–2 bpm = สัญญาณ)",
      "Most stable asleep; candidate custom fields are excluded until source labels are added."),
    "temp": MetricMethod(
      "เซ็นเซอร์อุณหภูมิผิวบนสาย",
      "ดูส่วนต่าง Δ จาก baseline กลางคืน ไม่ใช่ค่าดิบ °C",
      "baseline รายคืน + CUSUM (คู่กับ RHR เป็นธงป่วย 2 สัญญาณ)",
      "baseline ของคุณ; เตือนเมื่อ +0.5°C ต่อเนื่อง",
      "เป็นอุณหภูมิผิว (ไม่ใช่แกนกลาง) — ดูเทรนด์สำคัญกว่าตัวเลข"),
    "vo2": MetricMethod(
      "HRmax และ RHR ของคุณ",
      "Uth 2004: VO₂max ≈ 15.3 · HRmax / RHR",
      "คำนวณใหม่เมื่อ HRmax/RHR แม่นขึ้น",
      "เกณฑ์ percentile ตามอายุ/เพศ (ACSM)",
      "ขึ้นกับ HRmax ที่วัดจริง — Tanaka คลาด ±10 bpm; วัด max จริงเพื่อความแม่น"),
    "ctl": MetricMethod(
      "Strain รายวัน (ภาระฝึก)",
      "CTL = ค่าเฉลี่ยถ่วงน้ำหนักแบบ exponential ของภาระ, τ = 42 วัน",
      "โมเดล Banister (TrainingPeaks PMC)",
      "เทรนด์ช้าของตัวเอง คู่กับความล้า (ATL)",
      "เป็นสูตรตายตัว — แม่นเท่าข้อมูลภาระ; ต้อง ≥7 วันจึงนิ่ง"),
    "atl": MetricMethod(
      "Strain รายวัน",
      "ATL = EWMA ของภาระ, τ = 7 วัน",
      "PMC โมเดลเดียวกัน ค่าคงเวลาสั้น",
      "เทียบกับความฟิต (CTL)",
      "สูตรตายตัว; ตอบสนองภายในไม่กี่วัน"),
    "tsb": MetricMethod(
      "ความฟิต (CTL) และความล้า (ATL)",
      "TSB (ฟอร์ม) = CTL − ATL",
      "PMC; บวก = สด, ลบ = ล้า",
      "เส้น 0; สูงมาก = ฟิตตก, ต่ำมาก = โอเวอร์รีช",
      "สูตรตายตัว; มีความหมายเมื่อ CTL/ATL ครบ ≥7 วัน"),
    "strain": MetricMethod(
      "HR ตลอดวัน + HRmax และ RHR ของคุณ",
      "Banister TRIMP ใช้ตัวคูณตามเพศ: ชาย 0.64·e^(1.92·HRR), หญิง 0.86·e^(1.67·HRR); Strain = 21·(1 − e^(−TRIMP/τ))",
      "สะสมตลอดวัน; τ กำหนดความชันของเส้น",
      "Recovery ของคุณ (เขียว = ซัด, แดง = เบา)",
      "τ ยังไม่ calibrate จนกว่าจะ fit กับ day-strain จริงของ WHOOP ~20–30 ค่า"),
    "steps": MetricMethod(
      "เซ็นเซอร์ความเร่งที่ข้อมือ",
      "นับยอด |accel|−1g ที่เกิน threshold พร้อมช่วง refractory",
      "นับต่อเนื่อง รีเซ็ตรายวัน",
      "เป้า / ค่าเฉลี่ย 7 วันของคุณ",
      "แม่น ~1.5% ตอนเดิน; นับขาดกิจกรรมที่แขนไม่ขยับ"),
    "kcal": MetricMethod(
      "HR + การเคลื่อนไหว + โปรไฟล์ (อายุ/เพศ/น้ำหนัก/ส่วนสูง)",
      "พื้น Mifflin BMR + เส้น Keytel (HR สูง) ผสมเส้น accel (HR ต่ำ) ตาม HR-reserve",
      "อินทิเกรตรายนาที; รวมทั้งวัน = พื้นฐาน (BMR) + active",
      "ค่าเฉลี่ยรายวันของคุณ",
      "แคลจาก HR ล้วนคลาด ±20–30%; โมเดล branched + พื้น BMR ช่วยลด"),
    "recovery": MetricMethod(
      "HRV/RHR/อัตราหายใจ ช่วงหลับ + คะแนนนอน",
      "Recovery = 100·Φ(0.55·zHRV − 0.20·zRHR − 0.10·zRR + 0.15·zSleep)",
      "แต่ละค่าทำ z-score เทียบ baseline ≥7 คืน รวมกัน แล้วผ่าน CDF ปกติ Φ",
      "เขียว ≥67 / เหลือง 34–66 / แดง <34",
      "ทิศทางถูก; น้ำหนัก 4 ตัวตั้งมือ — calibrate เทียบ WHOOP เมื่อ unlock"),
    "readiness": MetricMethod(
      "Recovery + คะแนนนอน + ฟอร์ม (TSB) ลบโทษป่วย",
      "ผสมถ่วงน้ำหนักเป็น 0–100",
      "composite รายวัน",
      "≥60 = พร้อมรับภาระ",
      "ยังไม่จูน — ใช้เป็นแนวทาง ไม่ใช่คำตัดสิน"),
    "sleep": MetricMethod(
      "การเคลื่อนไหว + HR/HRV/อุณหภูมิ ตลอดคืน",
      "Cole-Kripke → หลับ/ตื่น; จัดสรร feature ตามสัดส่วน AASM; คะแนน = 0.55·ระยะ/need + 0.25·eff + 0.20·สมดุลระยะ",
      "epoch 60 วิ → ช่วงหลับยาวสุด → staging → เกลี่ยแบบ HMM",
      "ความต้องการนอน (8 ชม.) + เป้าระยะตาม AASM",
      "staging แบบ heuristic; เป้า κ≈0.47 เทียบ PSG (ระดับ WHOOP, เหนือ Fitbit 0.41)"),
    "sri": MetricMethod(
      "เวลานอน-ตื่นของคุณ",
      "Sleep Regularity Index จาก SD ของเวลานอน/ตื่น (เลื่อนเที่ยง) → 0–100",
      "หลายคืน",
      "สูง = สม่ำเสมอ; ต่ำกว่า 70 = เริ่มเพี้ยน",
      "ต้องมีข้อมูลหลายคืนจึงมีความหมาย"),
    "sleepDebt": MetricMethod(
      "เวลาหลับรายคืนเทียบความต้องการ",
      "ผลรวม 7 วันของ (need − เวลาหลับ)",
      "หนี้สะสมแบบ rolling",
      "0 = ตามทัน",
      "ขึ้นกับเป้าความต้องการนอน (8 ชม.)"),
    "zones": MetricMethod(
      "HR + HRmax และ RHR ของคุณ",
      "Karvonen %HRR = (HR − RHR)/(HRmax − RHR); โซนที่ 50/60/70/80/90%",
      "สะสมเวลาในแต่ละโซน (time-in-range)",
      "แถบโซน Karvonen",
      "แม่นเท่า HRmax ของคุณ — วัด max จริงเพื่อโซนที่ถูก"),
    "energy": MetricMethod(
      "Strain/เครียด/การเคลื่อนไหว + recovery & นอนเมื่อคืน",
      "แบต 0–100: เริ่มที่ 0.5·recovery + 0.5·นอน; ลดด้วย strain/เครียด/ขยับ, เติมตอนพักสงบ",
      "อินทิเกรตรายนาที (อนาล็อกของ Body-Battery)",
      "ระดับสำรอง (สูง 76+ … ต่ำมาก <26)",
      "เป็นโมเดล heuristic — อัตราลด/เติมยังต้อง calibrate"),
    "motion": MetricMethod(
      "เซ็นเซอร์ความเร่งที่ข้อมือ",
      "|accel|−1g ที่เกลี่ยแล้ว → threshold นิ่ง/ขยับ/เคลื่อนไหวแรง",
      "EWMA ของขนาดความเร่ง อัปเดตสด",
      "threshold (นิ่ง <0.03 g, แรง >0.12 g)",
      "บอกท่าทาง/กิจกรรมแบบหยาบ; ปรับ threshold ได้ตามการขยับจริง"),
    "weight": MetricMethod(
      "กรอกเอง (หรือเชื่อมเครื่องชั่ง)",
      "แสดงเป็นเทรนด์เกลี่ย EWMA; BMI = กก. / ม.²",
      "การเกลี่ยลด noise น้ำหนักน้ำรายวัน",
      "เทรนด์ที่เกลี่ยแล้วของคุณ",
      "แม่นเท่าที่คุณบันทึก"),
    "spo2": MetricMethod(
      "อัตราส่วนแสง Red/IR บนสาย",
      "เทรนด์สัมพัทธ์จากอัตราส่วน RED/IR (เกลี่ย EWMA) — ไม่ใช่ % สัมบูรณ์",
      "ดูเทรนด์อย่างเดียว",
      "เทรนด์ของคุณเอง",
      "ทดลอง; % ทางคลินิกจริงคำนวณบนคลาวด์ ยังไม่มีในนี้"),
    "scatter": MetricMethod(
      "Strain และ Recovery รายวัน",
      "1 จุด/วัน: Recovery (x) เทียบ Strain (y) ระบายสีตาม recovery",
      "30 วันล่าสุด",
      "มุมขวาบน = ฝึกหนักในวันที่ฟื้นตัวดี",
      "เป็นความสัมพันธ์เชิงภาพ ไม่ใช่คะแนนเดียว"),
    "pmc": MetricMethod(
      "Strain รายวัน (ภาระ)",
      "CTL (τ42, ฟิต), ATL (τ7, ล้า), TSB = CTL − ATL (ฟอร์ม)",
      "Banister / Performance Management Chart ของ TrainingPeaks",
      "เส้น Form เทียบ 0",
      "สูตรตายตัว; ต้อง ≥7 วันจึงนิ่ง"),
    "journal": MetricMethod(
      "แท็กพฤติกรรม + Recovery รายวัน",
      "Cohen's d = (Recovery เฉลี่ยวันที่ทำ − วันที่ไม่ทำ) / pooled SD",
      "แยกวันตามที่บันทึกพฤติกรรมไว้หรือไม่",
      "วันที่ทำ vs ไม่ทำ",
      "เป็นความสัมพันธ์ (มีตัวกวน); ยิ่งบันทึกมาก ยิ่งชัด"),
    "insights": MetricMethod(
      "Recovery, ฟอร์ม (TSB), คะแนนนอน และหนี้นอนของคุณ",
      "กฎ threshold แมปค่าของคุณเป็นคำแนะนำ; AI coach (ถ้าเปิด) เพิ่มชั้น LLM เหนือข้อมูลเดียวกัน + บันทึก",
      "ใช้กฎตายตัวก่อน แล้วชั้น LLM แบบ opt-in",
      "ค่าปัจจุบันของคุณเอง",
      "เป็นคำแนะนำ ไม่ใช่คำวินิจฉัยทางการแพทย์"),
    "musclefat": MetricMethod(
      "Muscle-Fat Analysis ของ InBody — 3 บาร์: น้ำหนัก, กล้ามเนื้อโครงร่าง (SMM) และมวลไขมัน แต่ละบาร์เทียบกับค่าเฉลี่ยที่ดีของคนส่วนสูง+เพศเดียวกับคุณ",
      "แต่ละบาร์ = ค่าของคุณ ÷ ค่าปกติ 100% (เส้นประ) เอาปลายของทั้ง 3 บาร์มาลากต่อกัน จะได้รูปทรงคล้ายตัวอักษร — C, I หรือ D",
      "ทรง C — บาร์ไขมันยาวสุด (ไขมันมากกว่ากล้าม): ต้องปรับ เน้นเพิ่มกล้าม ลดไขมัน · ทรง I — ทั้ง 3 บาร์ยาวพอ ๆ กัน: สมดุล พื้นฐานดี · ทรง D — บาร์กล้ามยาวสุด นำหน้าน้ำหนักและไขมัน: แข็งแรง/นักกีฬา ดีที่สุด · ยิ่งกล้ามเยอะไขมันน้อย ยิ่งเลื่อนจาก C → I → D",
      "เส้น 100% คือค่าเฉลี่ยของคนส่วนสูง+เพศเดียวกับคุณ (เราประเมินจาก BMI 22, เกณฑ์ไขมันตามวัย/เพศ และ SMM ≈ ครึ่งหนึ่งของมวลไร้ไขมัน) — ไม่ใช่เทียบกับคนอื่นโดยตรง",
      "เป็นภาพสรุปของตัวเลขชุดเดียวกัน — ค่าจริงของ SMM/ไขมันและเทรนด์ข้าม scan สำคัญกว่าตัวอักษรตัวเดียว ไม่ใช่คำวินิจฉัยทางการแพทย์"),
  ]
}
