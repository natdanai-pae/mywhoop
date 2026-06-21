import Foundation

/// L4 — "reads the chart" for the user in depth: the time window it covers, the shape of the series
/// (trend ↗→↘ + magnitude, variability, where the latest point sits, range, outliers), what HEALTH
/// indicator the picture reflects, and a concrete recommendation. Insight-first, each line ≤1 sentence.
public struct TrendReading: Equatable, Sendable {
  public let window: String          // time span covered ("Last 60 days (~2 months)")
  public let headline: String        // the one takeaway (trend + arrow + magnitude)
  public let shows: [String]         // what the picture conveys (variability / latest-vs-avg / range / outliers)
  public let signal: String          // which health indicator this reflects + what the trend implies
  public let good: String            // what the shape does well ("" = none)
  public let improve: String         // what to improve from the shape ("" = none)
  public let recommendation: String  // concrete next step
  public init(window: String, headline: String, shows: [String], signal: String,
              good: String, improve: String, recommendation: String) {
    self.window = window; self.headline = headline; self.shows = shows; self.signal = signal
    self.good = good; self.improve = improve; self.recommendation = recommendation
  }
}

/// Cadence of the points being read, so the window can be expressed in the right unit.
public enum ChartTimeUnit: Sendable { case day, night, hour, minute, live, overnight }

public enum ChartNarrator {
  /// `higherBetter`: true = up is good (HRV/recovery), false = down is good (RHR/stress), nil = neutral (TSB/temp).
  /// `unit` + count → the explicit lookback window. `metricKey` → the health-indicator meaning + recommendation.
  public static func read(_ s: [Double], higherBetter: Bool?, thai: Bool,
                          unit: ChartTimeUnit = .day, metricKey: String = "") -> TrendReading {
    func t(_ en: String, _ th: String) -> String { thai ? th : en }
    func fmt(_ v: Double) -> String { abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
    guard s.count >= 4 else {
      return TrendReading(window: "", headline: t("Not enough points to read the chart yet.", "ยังมีจุดน้อยเกินไปที่จะอ่านกราฟ"),
                          shows: [], signal: "", good: "", improve: "", recommendation: "")
    }
    let n = s.count
    let mean = s.reduce(0, +) / Double(n)
    let sd = (s.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n)).squareRoot()
    let k = max(1, n / 3)
    let firstAvg = s.prefix(k).reduce(0, +) / Double(k)
    let lastAvg = s.suffix(k).reduce(0, +) / Double(k)
    let delta = lastAvg - firstAvg
    let rising = delta > 0.3 * sd, falling = delta < -0.3 * sd
    let cv = mean != 0 ? sd / abs(mean) : 0
    let swinging = cv > 0.20, steady = cv < 0.08 && sd > 0
    let last = s.last!, mn = s.min()!, mx = s.max()!
    let hasSpike = s.contains { $0 > mean + 2 * sd }
    let hasDip = s.contains { $0 < mean - 2 * sd }
    let favorable = (higherBetter == true && rising) || (higherBetter == false && falling)
    let unfavorable = (higherBetter == true && falling) || (higherBetter == false && rising)

    // --- window (how far back) ---
    let window: String
    switch unit {
    case .day:
      let months = n / 30
      window = months >= 1 ? t("Last \(n) days (~\(months) month\(months > 1 ? "s" : ""))", "ย้อนหลัง \(n) วัน (~\(months) เดือน)")
                           : t("Last \(n) days", "ย้อนหลัง \(n) วัน")
    case .night: window = t("Last \(n) nights", "ย้อนหลัง \(n) คืน")
    case .hour:  window = t("Last \(n) hours", "ย้อนหลัง \(n) ชั่วโมง")
    case .minute:
      let h = n / 60
      window = h >= 1 ? t("\(n) min (~\(h)h, last night)", "\(n) นาที (~\(h) ชม. เมื่อคืน)") : t("Last \(n) min", "ย้อนหลัง \(n) นาที")
    case .live:
      let mins = max(1, n / 3)                          // hrSeries samples ~every 20s → 3/min
      window = t("Last ~\(mins) min (live)", "ช่วงสด ~\(mins) นาทีล่าสุด")
    case .overnight: window = t("Last night (full night)", "เมื่อคืน (ตลอดคืน)")
    }

    // --- headline (trend + arrow + magnitude) ---
    let arrow = rising ? "↗" : (falling ? "↘" : "→")
    let word = rising ? t("trending up", "แนวโน้มขึ้น") : (falling ? t("trending down", "แนวโน้มลง") : t("holding steady", "ค่อนข้างนิ่ง"))
    let pct = firstAvg != 0 ? delta / abs(firstAvg) * 100 : 0
    let mag = abs(pct) >= 3 ? String(format: t(" (%+.0f%% vs start)", " (%+.0f%% จากช่วงต้น)"), pct) : ""
    let headline = "\(word) \(arrow)\(mag)"

    // --- what the picture shows ---
    var shows: [String] = []
    let varWord = swinging ? t("high day-to-day swing", "แกว่งวันต่อวันสูง")
                : (steady ? t("very consistent", "สม่ำเสมอมาก") : t("moderate variability", "แปรปรวนปานกลาง"))
    shows.append(t("Variability: \(varWord) (CV \(Int((cv * 100).rounded()))%).", "ความแปรปรวน: \(varWord) (CV \(Int((cv * 100).rounded()))%)"))
    let rel = last > mean + 0.5 * sd ? t("above", "สูงกว่า") : (last < mean - 0.5 * sd ? t("below", "ต่ำกว่า") : t("near", "ใกล้"))
    shows.append(t("Latest \(fmt(last)) sits \(rel) the average \(fmt(mean)).", "ค่าล่าสุด \(fmt(last)) อยู่\(rel)ค่าเฉลี่ย \(fmt(mean))"))
    shows.append(t("Range over the window: \(fmt(mn))–\(fmt(mx)).", "ช่วงค่าในกราฟ: \(fmt(mn))–\(fmt(mx))"))
    if hasSpike { shows.append(t("One unusually high point — worth checking that day.", "มีจุดสูงผิดปกติ — ลองดูว่าวันนั้นเกิดอะไร")) }
    if hasDip { shows.append(t("One unusually low point — worth checking that day.", "มีจุดต่ำผิดปกติ — ลองดูว่าวันนั้นเกิดอะไร")) }

    // --- health-indicator meaning + recommendation (metric-specific, direction-aware) ---
    func dir(_ up: String, _ down: String, _ flat: String) -> String { favorable ? up : (unfavorable ? down : flat) }
    var signal = "", reco = ""
    switch metricKey {
    case "hrv":
      signal = t("HRV reflects autonomic balance and recovery capacity.", "HRV สะท้อนสมดุลระบบประสาทอัตโนมัติและความสามารถในการฟื้นตัว")
        + dir(t(" Rising = improving adaptation.", " ขึ้น = ปรับตัว/ฟื้นตัวดีขึ้น"), t(" Falling = fatigue/stress building.", " ลง = ความล้า/ความเครียดสะสม"), t(" Holding steady.", " ค่อนข้างนิ่ง"))
      reco = dir(t("Training is well tolerated — maintain or progress.", "รับภาระการฝึกไหว — คงไว้หรือเพิ่มได้"),
                 t("Ease load and prioritize sleep until it recovers.", "ลดภาระการฝึก เน้นนอน จนกว่าจะฟื้น"),
                 t("Stable — keep your routine and sleep consistent.", "นิ่งดี — รักษากิจวัตรและการนอนให้สม่ำเสมอ"))
    case "rhr":
      signal = t("Resting HR tracks cardiovascular fitness and recovery.", "หัวใจขณะพักบอกความฟิตหัวใจและการฟื้นตัว")
        + dir(t(" Falling = improving fitness/recovery.", " ลง = ฟิต/ฟื้นตัวดีขึ้น"), t(" Rising = fatigue, illness, or under-recovery.", " ขึ้น = ล้า/ป่วย/ฟื้นไม่พอ"), t(" Holding steady.", " ค่อนข้างนิ่ง"))
      reco = dir(t("Good sign — keep up your routine.", "สัญญาณดี — รักษากิจวัตรไว้"),
                 t("Watch for illness/overreaching; add recovery and sleep.", "ระวังป่วย/ฝึกหนักเกิน; เพิ่มการพักและการนอน"),
                 t("Normal — no action needed.", "ปกติ — ยังไม่ต้องทำอะไร"))
    case "recovery":
      signal = t("Daily readiness from HRV, RHR and sleep — how primed you are to take on load.", "ความพร้อมรายวันจาก HRV/RHR/การนอน — บอกว่าพร้อมรับภาระแค่ไหน")
      reco = dir(t("Trending greener — good window to push training.", "เขียวขึ้น — ช่วงดีที่จะฝึกหนัก"),
                 t("Trending lower — favor easy/recovery days.", "ต่ำลง — เน้นวันเบา/ฟื้นตัว"),
                 t("Match training to each day's score.", "ปรับการฝึกตามคะแนนแต่ละวัน"))
    case "vo2":
      signal = t("VO₂max estimates aerobic fitness (endurance capacity).", "VO₂max ประเมินความฟิตแอโรบิก (ความอึด)")
        + dir(t(" Rising = endurance improving.", " ขึ้น = ความอึดดีขึ้น"), t(" Falling = detraining.", " ลง = ฟิตถดถอย"), "")
      reco = dir(t("Keep the aerobic work that's driving this.", "ทำคาร์ดิโอแบบเดิมที่ทำให้ดีขึ้นต่อไป"),
                 t("Add steady aerobic sessions to rebuild it.", "เพิ่มคาร์ดิโอสม่ำเสมอเพื่อฟื้นความฟิต"),
                 t("Consistent aerobic training maintains it.", "คาร์ดิโอสม่ำเสมอช่วยรักษาระดับ"))
    case "steps":
      signal = t("Daily movement volume — overall activity level.", "ปริมาณการเคลื่อนไหวรายวัน — ระดับกิจกรรมโดยรวม")
      reco = dir(t("Activity climbing — nice.", "กิจกรรมเพิ่มขึ้น — ดีมาก"),
                 t("Movement dropping — add short walks.", "เคลื่อนไหวน้อยลง — เพิ่มการเดินสั้นๆ"),
                 t("Holding a steady activity level.", "ระดับกิจกรรมค่อนข้างคงที่"))
    case "stress":
      signal = t("Autonomic stress load through the day.", "ภาระความเครียดของระบบประสาทระหว่างวัน")
      reco = dir(t("Easing — recovery is working.", "ลดลง — การฟื้นตัวได้ผล"),
                 t("Climbing — build in breaks and breathing.", "สูงขึ้น — เพิ่มช่วงพักและการหายใจ"),
                 t("Steady — manage with regular breaks.", "นิ่ง — จัดการด้วยการพักเป็นช่วง"))
    case "resp":
      signal = t("Respiratory rate is usually very stable; a sustained rise can flag illness or strain.", "อัตราการหายใจปกติจะนิ่งมาก; ถ้าขึ้นต่อเนื่องอาจบ่งชี้ป่วยหรือภาระหนัก")
      reco = (unfavorable || hasSpike) ? t("If it stays elevated, watch for illness.", "ถ้ายังสูงต่อเนื่อง ให้ระวังการป่วย")
                                       : t("Normal and stable — no action.", "ปกติและนิ่ง — ไม่ต้องทำอะไร")
    case "temp":
      signal = t("Skin-temp deviation; swings can reflect illness, menstrual cycle, or environment.", "ส่วนต่างอุณหภูมิผิว; การแกว่งอาจมาจากการป่วย รอบเดือน หรือสภาพแวดล้อม")
      reco = (hasSpike || swinging) ? t("A sustained rise alongside high RHR can signal illness.", "ถ้าสูงต่อเนื่องพร้อม RHR สูง อาจกำลังป่วย")
                                    : t("Within your normal band.", "อยู่ในช่วงปกติของคุณ")
    case "kcal":
      signal = t("Daily energy expenditure (estimate).", "พลังงานที่ใช้ต่อวัน (ค่าประมาณ)")
      reco = t("Use the trend, not the exact number — calories are an estimate.", "ดูแนวโน้ม ไม่ใช่ตัวเลขเป๊ะ — แคลอรี่เป็นค่าประมาณ")
    case "strain":
      signal = t("Cardiovascular load accumulated each day.", "ภาระต่อหัวใจที่สะสมในแต่ละวัน")
      reco = t("Balance hard days against your recovery scores.", "สมดุลวันหนักกับคะแนนการฟื้นตัว")
    case "tsb":
      signal = t("Form/freshness = fitness minus fatigue. Positive = fresh, negative = fatigued.", "ฟอร์ม = ความฟิตลบความล้า บวก = สด ลบ = ล้า")
      reco = last < 0 ? t("Negative form — schedule recovery before hard work.", "ฟอร์มติดลบ — พักก่อนฝึกหนัก")
                      : t("Fresh — a good window for a hard session.", "สด — ช่วงดีสำหรับฝึกหนัก")
    case "weight":
      signal = t("Body-mass trend; read the slope, not daily noise.", "แนวโน้มน้ำหนัก; ดูความชัน ไม่ใช่ความผันผวนรายวัน")
      reco = t("Weigh at a consistent time for a cleaner trend.", "ชั่งเวลาเดิมทุกวันเพื่อแนวโน้มที่สะอาด")
    case "hr":
      signal = t("Heart rate shows current cardiovascular demand — read it with context (rest, activity, stress, caffeine).", "อัตราหัวใจบอกภาระของหัวใจขณะนั้น — ดูตามบริบท (พัก/ออกแรง/เครียด/คาเฟอีน)")
      reco = rising ? t("Climbing — normal if you're active; at rest, check stress/caffeine/hydration.", "กำลังขึ้น — ปกติถ้ากำลังเคลื่อนไหว; ถ้านั่งพักอยู่ ให้ดูความเครียด/คาเฟอีน/การดื่มน้ำ")
           : falling ? t("Settling down — a calming cardiovascular state.", "กำลังลดลง — หัวใจเข้าสู่ภาวะสงบ")
           : t("Steady — a stable cardiovascular state.", "นิ่ง — หัวใจอยู่ในภาวะคงที่")
    case "spo2":
      signal = t("Relative blood-oxygen trend overnight — not a clinical %; read dips, not the absolute number.", "เทรนด์ออกซิเจนในเลือดแบบสัมพัทธ์ตอนหลับ — ไม่ใช่ % ทางคลินิก; ดูการดิ่ง ไม่ใช่ตัวเลขสัมบูรณ์")
      reco = hasDip ? t("A dip stands out — verify with a fingertip oximeter.", "มีช่วงดิ่งเด่น — ตรวจยืนยันด้วย oximeter ปลายนิ้ว")
                    : t("Stable through the night — no notable desaturation.", "นิ่งทั้งคืน — ไม่มีการดิ่งที่น่ากังวล")
    default:
      signal = t("Shows how this metric moves over time relative to your own baseline.", "แสดงการเปลี่ยนแปลงของค่าตามเวลาเทียบกับ baseline ของคุณ")
      reco = dir(t("Trending favorably — keep it up.", "แนวโน้มดี — รักษาไว้"),
                 t("Trending unfavorably — worth a closer look.", "แนวโน้มไม่ดี — ควรดูใกล้ชิด"),
                 t("Holding steady.", "ค่อนข้างนิ่ง"))
    }

    // --- good / improve (shape quality) ---
    var good = "", improve = ""
    if favorable { good = t("Moving the right way — keep it up.", "ไปถูกทาง — รักษาไว้") }
    else if steady { good = t("Nicely consistent day to day.", "สม่ำเสมอดีในแต่ละวัน") }
    else if higherBetter == nil && !swinging { good = t("Stable and in range.", "นิ่งและอยู่ในเกณฑ์") }

    if unfavorable { improve = t("Heading the wrong way — worth addressing.", "กำลังไปผิดทาง — ควรจัดการ") }
    else if swinging { improve = t("Lots of swing — aim for more consistency.", "แกว่งเยอะ — ทำให้สม่ำเสมอขึ้น") }
    else if hasSpike || hasDip { improve = t("One day stands out — check what happened.", "มีวันที่ผิดปกติ — ลองดูว่าวันนั้นเกิดอะไร") }
    if good.isEmpty && improve.isEmpty { good = t("Looks healthy and steady.", "ดูปกติและนิ่งดี") }

    return TrendReading(window: window, headline: headline, shows: shows, signal: signal,
                        good: good, improve: improve, recommendation: reco)
  }
}
