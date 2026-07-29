# Golf Swing2 — ไอเดียฟีเจอร์สำหรับ Rapsodo + iPhone Camera ชุดปัจจุบัน

> เอกสารนี้เป็น **ตัวเลือกสำหรับตัดสินใจ** ไม่ใช่คำสั่งให้ทำทุกอย่างพร้อมกัน
>
> หลักเรียงลำดับคือ **ทำได้จริงก่อน → ต้องต่อยอดจากข้อมูลเดิม → ต้องวิจัยหรือรออุปกรณ์/สิทธิ์**
>
> เป้าหมายคือให้ผู้เล่นซ้อมคนเดียวได้ โดยใช้ iPhone เป็นกล้องวิเคราะห์, ใช้ Mac เป็นตัวประมวลผล/บันทึกทั้งแอป
> และใช้ภาพ Rapsodo เป็นบริบทประกอบ โดยไม่ทำ OCR หรือแปลงพิกเซลบนหน้าจอให้เป็นค่าที่อ้างว่า Rapsodo วัด

---

## 1. เป้าหมายของ Golf Swing2

วงจรใช้งานที่ต้องการคือ:

```text
พูดหรือกดเริ่มหนึ่งวง
  → Countdown / Tempo (ถ้าเปิด)
  → iPhone ส่งภาพกล้องให้ Mac
  → Mac ตรวจวงและบันทึกทั้งหน้าต่าง GolfTrace
  → สร้าง phase/keyframe จากภาพกล้อง iPhone
  → Replay + Storyboard + Guideline ที่ผู้ใช้เลือก
  → เทียบกับ baseline ของตัวเอง
  → AI Pro ให้หนึ่ง cue / drill และเปิด phase ที่อ้างถึงได้
  → พร้อมตีวงถัดไปโดยไม่ต้องเดินกลับมากด Mac
```

หลักผลิตภัณฑ์ที่ต้องรักษา:

- **วงดีของผู้ใช้เองก่อน** ไม่ใช้คะแนนรวมตัดสินว่าวงถูกหรือผิด
- Guideline คือเส้นหรือช่วงอ้างอิงที่ผู้ใช้เลือก ไม่ใช่กฎสากล
- แยกคำว่า `วัดได้`, `คำนวณ 2D`, `ประมาณ`, `AI อนุมาน` และ `ข้อมูลไม่พอ` ให้เห็นชัด
- Rapsodo, กล้อง, AI และ baseline ต้องคง provenance แยกจากกัน
- Storyboard ต้องแสดงเฉพาะ phase ที่มีหลักฐาน ไม่สร้างภาพหรือเวลาปะทะลูกปลอมเพื่อให้ครบ 8 ช่อง

---

## 2. สถานะระบบจริงในปัจจุบัน

| ส่วน | สิ่งที่มีแล้ว | ข้อจำกัดที่ต้องยอมรับก่อนวางแผน |
|---|---|---|
| iPhone camera | ส่ง H.264 ความเร็วสูง, orientation และ practice settings ไป Mac | Capture FPS กับ Pose FPS เป็นคนละค่า; ต้อง refresh Hardware UAT กับ build ปัจจุบัน |
| วิเคราะห์ร่างกาย | Apple Vision 2D, ข้อต่อ, กึ่งกลางมือ, hand trace, tempo และ metric ร่างกายบางส่วน | ยังไม่มี club/shaft/club-head detector และไม่ใช่ 3D |
| Phase | มี `Address`, `Top จากการกลับทิศมือ` และ `ช่วงมือกลับโดยประมาณ` | ยังไม่ใช่ 8 phase และช่วงมือกลับไม่ใช่ impact ที่ยืนยันจากลูกหรือหัวไม้ |
| Replay | บันทึกหน้าต่าง GolfTrace ทั้งหน้าจอที่ 60 FPS พร้อมภาพ Rapsodo, กล้องและ overlay; มี raw H.264 ring buffer สำหรับ fallback export | Stage replay เหมาะเป็นหลักฐาน session แต่ไม่ใช่ต้นทาง keyframe ความเร็วสูง และ raw camera clip ยังไม่ได้เก็บคู่กับ record ตามปกติ |
| Player | มี timeline กลาง, seek, 0.25×/0.5×/1× และเดินทีละเฟรม | ยังไม่มี phase bookmark ถาวรหรือ player เปรียบเทียบสองวง |
| Swing record | เก็บ summary, hand trace, metric, replay และ launch match ที่มีจริง | ยังไม่เก็บ practice context, evidence timeline, phase markers, keyframe, baseline, chat หรือ drill แบบถาวร |
| Guideline | เลือก `วงดีของฉัน / ท่าเตรียม / แนวสวิง / การหมุน / จังหวะ / ปิด` ได้ | `วงดีของฉัน` ปัจจุบันยังเป็นวงล่าสุด ไม่ใช่วงดีที่ผู้ใช้เลือก; บางเส้นเป็น visual guide สำเร็จรูป |
| AI Pro | รับ numeric evidence, ถามด้วยเสียง, ให้ focus, evidence, drill, confidence, limitation และ TTS บน Mac | ยังเป็น one-shot; ยังไม่มี chat history, phase action chip หรือการบันทึกคำตอบกับ swing record |
| Tempo / เสียง | มี engine 3:1: Start → Top → Impact cue → Finish | ยังไม่ได้ผูกกับปุ่ม/voice capture flow; เสียงที่ iPhone ยังไม่มีช่องส่งกลับจาก Mac |
| Rapsodo | แสดงหน้าจอข้างกล้องและอยู่ใน full-app replay | Mirror เป็นพิกเซลเพื่อดูย้อนหลังเท่านั้น; structured launch data ใช้ได้เมื่อมี `LaunchMonitorShot` ที่รับและจับคู่สำเร็จจริง |

ข้อสรุปสำคัญ: **ระบบมีฐานพอสำหรับ Storyboard รุ่นแรก แต่ยังไม่พอสำหรับอ้างว่าเห็นครบ 8 phase,
impact จริง, club path หรือ 3D**

---

## 3. ลำดับความเป็นไปได้ของไอเดีย

ระดับความเป็นไปได้:

- **A — ต่อของเดิมได้เลย:** ไม่ต้องสร้าง vision model ใหม่
- **B — ทำได้หลังเพิ่ม data foundation:** ต้องเก็บ context, phase, เวลา หรือ keyframe ให้ถาวรก่อน
- **C — ต้องทำ quality gate/ชุดทดสอบ:** ทำ UI ได้ แต่คุณภาพภาพหรือ alignment อาจไม่น่าเชื่อถือ
- **D — งานวิจัยหรือ external gate:** ต้องมี detector, calibration, กล้องเพิ่ม หรือสิทธิ์ข้อมูลที่ยังไม่มี

| อันดับ | ไอเดีย | ความเป็นไปได้ | เหตุผล | Priority แนะนำ |
|---:|---|:---:|---|:---:|
| 1 | Guideline แบบเลือกได้และไม่ตัดสินวง | A | ตัวเลือก, overlay และ provenance ส่วนใหญ่มีแล้ว; ต้องแก้ความหมายและปิดผลที่ยังวัดไม่ได้ | P0 |
| 2 | Voice สั่งหนึ่งวง + Countdown + Tempo | A | Recorder, detector, AI microphone และ tempo engine มีแล้ว; งานหลักคือ state machine และกันคำสั่งซ้ำ | P0 |
| 3 | เก็บ context + phase + replay clock + keyframe ถาวร | A–B | เป็นฐานที่ปลดล็อก Storyboard, baseline, AI deep-link และ comparison | P0 |
| 4 | Adaptive Storyboard ในกรอบ 8 phase | B | เริ่มจาก phase ที่มีหลักฐานและแสดงช่องที่หาไม่ได้อย่างซื่อสัตย์ | P0 |
| 5 | เลือก “วงดีของฉัน” และเทียบ metric แบบบริบทเดียวกัน | B | Record/replay มีแล้ว แต่ต้องเพิ่ม baseline ID, handedness และ context matching | P0 |
| 6 | AI Pro ผูก phase + action chip + drill session + เสียง | B | AI รับ phase/metric แล้ว แต่ต้อง persist คำตอบและเพิ่ม output ที่ seek replay ได้ | P1 |
| 7 | Side-by-side เฟรม phase เดียวกัน | B | ใช้ keyframe สองวงง่ายกว่าการ sync วิดีโอสอง player และอ่านความต่างได้ชัด | P1 |
| 8 | ตรวจ Takeaway/Half/Delivery/Extension ให้ครบใกล้ 8 phase | B–C | ทำได้จาก wrist/body heuristic แต่ต้องเทียบกับเฟรมที่คนติดป้ายก่อนเปิดใช้จริง | P1 |
| 9 | Cutout sequence ที่ไม่ดูเป็นผี | C | ต้อง segmentation หลังวง, crop/alignment และ fallback; mask มักไม่รวมไม้ครบ | P1 |
| 10 | Overlay baseline แบบ align / split wipe / synchronized video | C | ต้อง phase sync, scale, orientation และ body registration ที่เสถียร | P2 |
| 11 | Club-head, shaft, confirmed impact, 3D หรือหลายกล้อง | D | ต้อง dataset/model/calibration หรือ sensor เพิ่ม; Vision pose อย่างเดียวตอบไม่ได้ | P2 / Research |

### ตัวเลือกเริ่มงาน

#### ตัวเลือก A — ใช้ซ้อมจริงเร็วที่สุด (แนะนำ)

ทำ P0 ตามลำดับ: voice one-take → evidence persistence → Adaptive Storyboard → baseline → guideline ที่ซื่อสัตย์

ผลที่ได้: ผู้ใช้ตีคนเดียว, ได้ replay/phase ที่เชื่อถือได้, เลือกวงดีและได้รับ cue เดียว โดยไม่รอ cutout หรือ 8 phase เต็ม

#### ตัวเลือก B — เน้น Storyboard ก่อน

ทำ data foundation + 8-slot UI + keyframe extractor + phase validation ก่อน AI/chat

ผลที่ได้: เห็น Storyboard เร็ว แต่ phase ที่ยังหาไม่ได้ต้องแสดง `—` หรือ `ยังไม่มั่นใจ` ไม่เติมภาพเดา

#### ตัวเลือก C — เน้น AI Pro ก่อน

Persist phase/evidence/advice → action chip → drill session → voice/TTS

ผลที่ได้: AI คุยต่อเนื่องและพาไปดูหลักฐานได้ แต่ visual comparison/cutout มาทีหลัง

#### ตัวเลือก D — เน้นภาพสวยแบบผลิตภัณฑ์โชว์

Cutout + aligned overlay + synchronized comparison

ผลที่ได้: ภาพเด่นที่สุด แต่ความเสี่ยงสูงสุด และไม่ควรเริ่มก่อน phase/keyframe/baseline foundation

---

## 4. Swing Storyboard / สไลด์วง 8 phase

### 4.1 ใช้ “8 ช่องแบบ adaptive” ไม่ใช่บังคับให้มีข้อมูลครบ 8

กรอบ Storyboard ยังคงใช้ชื่อ 8 phase เพื่อให้ผู้ใช้เรียนรู้ลำดับเดิมทุกวง:

1. Address
2. Takeaway
3. Half Backswing
4. Top
5. Delivery
6. Impact Window
7. Extension
8. Finish

แต่สถานะของแต่ละช่องต้องเป็นหนึ่งในนี้:

- `วัดได้` — มีเฟรม/pose ที่ตรงเงื่อนไขและผ่าน confidence gate
- `ประมาณจากมือ 2D` — phase มาจาก wrist/hand reversal หรือ threshold บนภาพ
- `เลือกเอง` — ผู้ใช้ขยับ marker และยืนยันเฟรมเอง
- `ยังไม่มั่นใจ` — ไม่มีหลักฐานพอ; ไม่แสดง thumbnail ปลอม

คำว่า `Impact` ในรุ่นแรกต้องแสดงเป็น **Impact Window — ช่วงมือกลับโดยประมาณ** จนกว่าจะมี club/ball/audio detector
ที่ผ่าน validation จึงเปลี่ยนเป็น confirmed impact ได้

### 4.2 Phase ที่เหมาะกับแต่ละรอบ

| รอบ | Phase ที่แสดงได้ | วิธีหา |
|---|---|---|
| P0 | Address, Top estimated, Impact Window estimated, Finish | state detector + hand reversal + session end |
| P1 | เพิ่ม Takeaway, Half Backswing, Delivery, Extension | body/wrist threshold ที่ทดสอบกับเฟรมติดป้าย |
| P2 | ยืนยัน Impact และ phase ที่ผูกกับ shaft/club | detector หรือ sensor ที่ผ่าน quality gate |

### 4.3 Keyframe ต้องมาจากกล้อง iPhone ไม่ใช่ screenshot ทั้ง dashboard

ควรแยก asset ตามหน้าที่:

1. `Stage Replay` — วิดีโอหน้าต่าง GolfTrace ทั้งหน้าจอ เห็น Rapsodo + iPhone + overlay ตามที่ผู้ใช้เห็นจริง
2. `Camera Analysis Clip` — ช่วง raw H.264 จาก iPhone ring buffer พร้อม source PTS; เก็บถาวรเมื่อผู้ใช้เลือกหรืออย่างน้อยคงไว้จน extract asset เสร็จ
3. `Camera Keyframes` — ภาพนักกอล์ฟจาก Camera Analysis Clip/decoded stream ตาม phase timestamp สำหรับ Storyboard/cutout/comparison

การเก็บ raw clip ทุกวงอาจใช้พื้นที่สูง จึงให้เลือก retention ได้ แต่ต้องห้ามลบ source segment ก่อนสร้าง keyframe,
pose snapshot และ timestamp map สำเร็จ หากเลือกไม่เก็บ raw clip ถาวร ต้องยังตรวจย้อนกลับได้จาก hash/metadata ของ asset ที่สร้างแล้ว

ทุก keyframe ต้องเก็บ:

- `recordID`, `phaseID`, `sourceTimestamp`, `replayTimestamp`
- orientation และ source dimensions
- phase confidence และ source type
- pose snapshot/hash ของไฟล์
- model/evidence schema version

เมื่อแตะการ์ด phase:

- เปิด replay เดิม
- seek ไป `replayTimestamp`
- pause
- แสดงชื่อ phase, provenance, confidence และ limitation
- อนุญาตให้ผู้ใช้เลื่อนหนึ่งเฟรมแล้วกด `ยืนยันเฟรมนี้`

---

## 5. ภาพตัดคนเรียงลำดับแบบไม่ดูเป็นผี

### หลักภาพที่แนะนำ

อันดับแรกไม่ควรเริ่มจากการนำคนโปร่งใสหลายคนมาทับกัน เพราะอ่านยากและขอบ mask จะดูหลอน

ลำดับวิธีแสดงจากเสี่ยงน้อยไปมาก:

1. **Camera card crop** — ภาพจริง 8 ใบ crop รอบนักกอล์ฟให้ขนาดใกล้กัน
2. **Matte card** — คงคนทึบ 100% แล้ว dim/blur ฉากหลังเดิม
3. **Opaque cutout** — ตัดคนทึบวางบนพื้นหลังสีเดียว เฉพาะเมื่อ mask ผ่าน quality gate
4. **Pose/contour overlay** — ใช้เส้น pose หรือ contour ของ baseline แทนร่างโปร่งใสอีกคน
5. **Crossfade/split wipe** — ให้ผู้ใช้ลากดูทีละสองภาพ แทนการเห็นเงาซ้อนค้าง

### Quality gate สำหรับ cutout

- ทำ segmentation **หลังวงจบเท่านั้น** ไม่ทำใน live 120 FPS path
- ตรวจว่าหัว, ลำตัว, ข้อมือ, ขาและข้อเท้าอยู่ใน mask ก่อนใช้
- ขยาย mask เล็กน้อยและ feather เฉพาะขอบ ห้ามทำทั้งตัวโปร่งใส
- Crop และ scale ด้วย pose bounding box; align จากข้อเท้า/กึ่งกลางสะโพกตามมุมกล้อง
- ไม่อ้างว่า club/shaft อยู่ใน cutout เพราะ person segmentation อาจตัดไม้ออก
- ถ้า confidence ต่ำ, หลุดเฟรม, มีหลายคน หรือ mask ขาด ให้ fallback เป็น Camera card ทันที
- ภาพต้นฉบับและ replay ห้ามถูกแก้ไขหรือเขียนทับ

---

## 6. เปรียบเทียบวงตัวเอง, overlay และ baseline

### 6.1 Baseline ต้องเป็นวงที่ผู้ใช้เลือกจริง

ปุ่มใน History:

- `ตั้งเป็นวงอ้างอิง`
- `ยกเลิกวงอ้างอิง`
- `เทียบกับวงนี้`

Baseline ต้องผูกอย่างน้อยกับ:

- ผู้เล่น
- มือถนัด
- ไม้/กลุ่มไม้
- มุมกล้อง (`หลังแนวตี` หรือ `ด้านหน้า`)
- orientation/framing profile
- analysis model/evidence schema version
- launch data ที่มีจริง (optional)
- retention pin เพื่อไม่ให้ระบบลบ record ที่ baseline อ้างอยู่

หากบริบทไม่ตรง ให้แสดงเหตุผล เช่น `คนละมุมกล้อง` หรือ `คนละไม้` และไม่สรุปว่า “ดีขึ้น/แย่ลง” แบบรวม

### 6.2 ลำดับโหมด comparison

| รอบ | โหมด | สิ่งที่เปรียบเทียบ |
|---|---|---|
| P0 | Metric delta | tempo, hand path, posture 2D และค่าที่มี provenance เดียวกัน |
| P1 | Phase still side-by-side | keyframe phase เดียวกัน พร้อม lock phase |
| P1 | Pose/hand corridor | เส้น pose/มือของ baseline บนภาพปัจจุบันหลัง align |
| P2 | Split wipe / crossfade | ภาพจริงสองวงที่ scale/translate แล้ว |
| P2 | Synchronized video | player สองตัว lock phase และเวลา normalized |

Overlay เริ่มต้นควรใช้ **เส้นหรือ contour ของ baseline** มากกว่าร่างคนจริง opacity ต่ำ เพื่อลดภาพผีและเห็นความต่างชัดกว่า

Rapsodo:

- ค่า launch ที่จับคู่สำเร็จสามารถแสดงเป็น card เปรียบเทียบแยกต่างหาก
- ภาพหน้าจอ Rapsodo ใน replay เป็นหลักฐานให้คนดู ไม่ใช้ OCR และไม่ป้อนเป็น measured metric ให้ AI
- Storyboard และ baseline ต้องยังทำงานได้แม้ Rapsodo ไม่เชื่อมต่อ

---

## 7. Guideline แบบเลือกได้และไม่ตัดสินวง

### 7.1 แบ่งชนิดให้ชัด

| ชนิด | ตัวอย่าง | ภาษาที่ใช้ |
|---|---|---|
| Visual reference | แนวตั้งกล้อง, visual corridor, กรอบหัว/สะโพก | “เส้นช่วยดูที่เลือก” |
| Camera measured 2D | pose, hand center, torso tilt 2D | “วัดจากภาพ 2D” |
| Derived | tempo, displacement, span reduction | “คำนวณจาก…” |
| Personal baseline | corridor จากวงดีที่ผู้ใช้เลือก | “ต่างจากวงอ้างอิง…” |
| AI suggestion | cue/drill | “แนวทางที่ควรลอง” |
| Unavailable | หลุดเฟรม/confidence ต่ำ | “ข้อมูลยังไม่พอ” |

### 7.2 Guideline ที่ควรเปิดในแต่ละ priority

#### P0

- `ปิดทั้งหมด`
- `Tempo` — เทียบ target ที่ผู้ใช้เลือกกับ hand-tempo ที่วัดได้
- `Posture 2D` — แสดงค่าหรือช่วงเฉพาะเมื่อมี target ชัดเจน
- `Hand trace` — ระบุเสมอว่าเป็นกึ่งกลางมือ ไม่ใช่หัวไม้
- `Visual corridor` — เปลี่ยนชื่อจาก swing plane หากยังเป็นเส้นสำเร็จรูป
- `วงดีของฉัน` — เปิดได้เมื่อมี baseline ที่เลือกและ context ตรงเท่านั้น

#### P1

- Head/pelvis window จาก baseline
- Hand corridor แยกตาม phase
- Setup repeatability
- Guideline profile: `พื้นฐาน / วงดีของฉัน / ตาม drill / กำหนดเอง`

#### P2

- Club/shaft/impact guideline เฉพาะ detector ที่ผ่าน validation
- 3D guideline เฉพาะระบบที่มี calibration และ model card

### 7.3 สถานะผลลัพธ์

ใช้สามสถานะ:

- `อยู่ในช่วงที่เลือก`
- `ต่างจากช่วงที่เลือก`
- `ข้อมูลยังไม่พอ`

หลีกเลี่ยง:

- สีแดง/เขียวโดยไม่มีข้อความ
- คะแนนรวมวงสวิง
- คำว่า `ผิด`, `ถูก`, `โปร`, `perfect`
- สรุปเหตุ–ผลจาก metric เดียว

---

## 8. AI Pro, Chat ผูกกับ Phase, Drill และเสียง

### 8.1 สิ่งที่มีแล้วและควรใช้ต่อ

AI Pro มีฐานสำหรับ:

- คำถามจากข้อความหรือ push-to-talk
- numeric evidence จาก pose/metric/phase
- structured launch data เมื่อรับมาจริง
- focus เดียว, evidence summary, drill, confidence, limitations
- TTS ภาษาไทยบน Mac

งานสำคัญไม่ใช่ให้ AI ดูวิดีโอดิบทุกวง แต่คือทำให้ข้อมูลเหล่านี้ **ผูกกับ record และ phase แบบถาวร**

### 8.2 Chat message contract

ทุกข้อความที่อ้างวงต้องเก็บ:

- `sessionID`, `recordID`, `phaseID`, `tMs`
- evidence/metric IDs ที่ใช้
- baseline record ID ถ้ามี
- guideline/profile ที่เปิดอยู่
- launch match ID ถ้ามีจริง
- transcript, advice, drill, confidence และ limitations

คำตอบควรมี action chip:

- `เปิด Address`
- `เปิด Top โดยประมาณ`
- `เปิด Impact Window`
- `เทียบ Baseline`
- `เริ่ม Drill 5 ลูก`
- `ฟังซ้ำ`

ถ้า phase/keyframe ไม่มี ห้ามส่ง chip หรืออ้างว่า AI เห็นเฟรมนั้น

### 8.3 Drill session

Drill หนึ่งรายการควรมี:

- cue เดียว
- จำนวนครั้ง เช่น 3 rehearsal + 5 ลูก
- metric/guideline ที่สังเกตเพียง 1–3 ตัว
- baseline หรือวงก่อนเริ่ม drill
- stop condition เช่น `ครบ 5 ลูก` หรือ `tracking ต่ำสองครั้งติด`
- before/after summary โดยใช้คำว่า `เปลี่ยนไป` ไม่ใช้ `ดีขึ้น` หากผลลูกหรือเป้าหมายยังไม่ยืนยัน

### 8.4 Voice, Countdown และ Tempo

แยกไมค์สองหน้าที่:

1. **Capture command** — `กอล์ฟเทรซ เริ่มวง`, `กอล์ฟเทรซ ยกเลิก`
2. **AI question** — push-to-talk หลังวง

Flow ที่นำไปใช้ใน P0.1:

```text
รับ “กอล์ฟเทรซ เริ่มวง” บน Mac
  → AI ตอบ “รับคำสั่งแล้ว เตรียมตี” พร้อมสถานะบนจอ
  → 3–2–1
  → เริ่ม stage recorder หนึ่งรายการเมื่อนับจบ
  → เล่น Tempo ถ้าเปิด
  → ฟังเฉพาะคำสั่ง exact phrase และพัก listener ขณะ AI/TTS ใช้เสียง
  → detector ยืนยันวงและบันทึกหนึ่ง record
  → AI แจ้งว่ากำลังสร้างรีเพลย์
  → เก็บ history + replay สำเร็จจริงก่อน AI พูดว่า “บันทึกแล้ว”
  → เปิด replay และกลับไปรอฟังวงถัดไป
```

ทุก state ต้องมี visual response และ voice response ที่สั้นพอสำหรับคนซ้อมคนเดียวซึ่งกำลังจับไม้:

- พร้อมฟัง: แสดง wake phrase ชัดเจน
- รับคำสั่ง/นับถอยหลัง: พูดเฉพาะ acknowledgement และ `สาม–สอง–หนึ่ง`
- จรดลูก/สวิง: ไม่พูด coaching ยาว; รับ `กอล์ฟเทรซ ยกเลิก` ได้ก่อนวงถูก commit
- Finalizing: แจ้งว่ากำลังเก็บ replay; หากเกิน 45 วินาทีให้แจ้งว่ายังเก็บไฟล์อยู่และห้ามทิ้ง recorder
- Replay ready: พูดหลัง history และ video persistence สำเร็จเท่านั้น แล้วแจ้งว่าพร้อมวงถัดไป

หาก raw-camera fallback export หรือ persistence ล้มเหลว ต้องส่ง error กลับ state machine และกลับสู่สถานะที่เริ่มใหม่ได้
ห้ามค้าง active take ถาวร และห้ามเปิด replay ของ take เก่าจากการเปลี่ยน URL ระหว่าง recovery

เหตุผลที่เริ่มรับเสียงบน Mac ก่อน:

- ไม่เพิ่มภาระ/ความร้อนให้ iPhone ที่กำลังส่งภาพความเร็วสูง
- recorder และ session state อยู่บน Mac อยู่แล้ว
- ไม่ต้องเพิ่ม audio session ที่อาจชน camera capture บน iPhone

Tempo เริ่มต้นใช้ 3:1 (backswing 1.2 วินาที / downswing 0.4 วินาที) แต่ต้องมีโหมด:

- ปิด
- Countdown อย่างเดียว
- Countdown + Tempo
- Custom tempo

TTS ต้องหยุดทันทีเมื่อเริ่มวงใหม่ และเสียงที่ iPhone ต้องไม่แสดงเป็นตัวเลือกพร้อมใช้จนกว่าจะมี Mac-to-iPhone audio/control channel จริง

---

## 9. Roadmap P0 → P2

### P0 — Trusted Solo Loop + Storyboard Foundation

#### เป้าหมาย

ทำให้การตีหนึ่งวงสร้าง record ที่ตรวจย้อนกลับได้ และแสดง Storyboard/baseline โดยไม่อ้าง phase เกินหลักฐาน

#### งาน

1. Refresh Hardware UAT ด้วย Mac/iPhone build ปัจจุบัน
2. Voice one-take + Countdown/Tempo + ปุ่ม/Spacebar fallback
3. เพิ่ม record schema สำหรับ player, handedness, club, camera view, orientation/framing, source FPS, pose FPS, settings revision และ model version
4. Persist full evidence packet หรือ phase/timeline subset ที่สร้างซ้ำได้
5. สร้าง mapping ระหว่าง source camera timestamp กับ stage replay timestamp
6. Export/retain raw Camera Analysis Clip จาก H.264 ring buffer และ Extract/hash Camera Keyframes หลังวงโดยไม่บล็อก live pipeline
7. ทำ 8-slot Adaptive Storyboard โดยเริ่มจาก 4 anchor phase
8. แตะ phase แล้ว seek/pause replay และให้ผู้ใช้แก้ marker ได้
9. เลือก baseline ที่ context ตรง, pin ไม่ให้ retention ลบ และเทียบ metric แบบ provenance เดียวกัน
10. แก้ Guideline ให้แยก visual guide/measured/derived/unavailable
11. แสดงและ Persist AI focus/evidence/drill/limitations กับ record แม้ยังไม่ทำ chat history เต็ม

#### Definition of Done — P0

- Hardware UAT บน build ปัจจุบันบันทึก FPS, orientation, pose alignment และ replay ด้วยค่าจริง
- Hardware smoke test อย่างน้อย 10 วงต่อเนื่องโดยไม่แตะ Mac และชุด validation อย่างน้อย 30 คลิป: 15 หลังแนวตี + 15 ด้านหน้า โดยระบุกรณีที่ pose มองไม่เห็น
- Voice command หนึ่งครั้งสร้างได้สูงสุดหนึ่ง saved record; timeout/ยกเลิกไม่เหลือ replay หรือ history หลอก
- AI ตอบด้วยเสียงและสถานะบนจอครบทุก transition; ช่วง address/swing ไม่มี coaching ยาวหรือเสียงสองระบบทับกัน
- คำว่า `บันทึกแล้ว` เกิดหลัง history และ replay persistence สำเร็จ; export/persistence failure ต้องตอบกลับและเริ่มวงใหม่ได้
- Camera-only loop ผ่านได้เมื่อปิด Rapsodo และปิด AI
- ทุก record ที่บันทึกสำเร็จเปิดใหม่แล้ว context, phase, replay, keyframe และ baseline link ไม่หาย; baseline ที่ pin ไว้ไม่ถูก retention ลบ
- Storyboard แสดง 2–4 phase ที่มีหลักฐานและแสดง `ยังไม่มั่นใจ` ในช่องที่เหลือ; ห้ามเติมเวลาเดาเพื่อให้ครบ 8
- Storyboard พร้อมภายใน 3 วินาทีที่ p95 หลัง replay พร้อม บน MacBook Pro เครื่องใช้งานจริง
- แตะ phase แล้ว seek คลาดไม่เกิน 100 ms จาก marker ที่บันทึก; phase ที่ผู้ใช้แก้ต้องกลับมาจุดเดิมหลังเปิดแอปใหม่
- Impact ต้องใช้ label `Impact Window โดยประมาณ` จนกว่าจะมี detector ยืนยัน
- Guideline ทุกอันมี provenance/limitation; confidence ต่ำแสดง `ข้อมูลยังไม่พอ`
- `วงดีของฉัน` ไม่มี fallback เป็นวงล่าสุดหรือเส้นกลางปลอมเมื่อยังไม่เลือก baseline
- Storyboard extraction และ persistence ทำงานเบื้องหลัง และ median live displayed FPS ของวงถัดไปไม่ลดเกิน 5% จาก baseline UAT
- ภาพ Rapsodo อยู่ใน full-app replay ตามที่แสดงจริง แต่ไม่มี OCR หรือค่าที่สร้างจากพิกเซล
- Unit/integration tests ของ schema migration, phase seek, cancel/discard, baseline matching และ missing-data fallback ผ่านทั้งหมด

---

### P1 — 8-Phase Coaching + Comparison + Phase-Aware AI

#### เป้าหมาย

เพิ่ม phase ที่ตรวจได้จาก 2D, comparison ที่อ่านง่าย และ AI/drill ที่อ้าง phase จริง

#### งาน

1. เพิ่ม detector สำหรับ Takeaway, Half Backswing, Delivery และ Extension
2. สร้างชุดคลิปติดป้ายโดยคนสำหรับ phase validation
3. Side-by-side keyframe ที่ lock phase
4. Baseline pose/hand corridor ที่ align ด้วย ankle/hip anchor
5. Cutout/Matte card หลังวง พร้อม quality gate และ fallback
6. Guideline profile และ drill session 3–5 ลูก
7. Record-scoped AI chat + phase/time action chips
8. แสดง transcript ให้แก้ก่อนส่ง AI
9. Persist advice/drill/chat และยกเลิก TTS เมื่อเริ่มวงใหม่

#### Definition of Done — P1

- ใช้ validation set อย่างน้อย 50 วง ครอบคลุมสองมุม, เสื้อ/ฉากหลัง/แสงต่างกัน และกรณีไม้หลุดเฟรม
- ในคลิปที่ pose ผ่าน quality gate ระบบแสดง phase ได้อย่างน้อย 6/8 ช่องในอย่างน้อย 80% ของวง
- Top estimated มี median error ไม่เกิน 100 ms และ Takeaway/Half/Delivery/Extension ไม่เกิน 150 ms เทียบกับเฟรมที่คนติดป้าย
- Impact ยังคงเป็น estimated window เว้นแต่ detector แยกต่างหากผ่าน P2 gate
- Cutout ที่ไม่ผ่าน mask/pose gate fallback เป็นภาพจริง 100%; ห้ามมีช่องว่างหรือร่างขาดที่ยังติด label ว่าผ่าน
- Side-by-side ใช้ baseline เฉพาะ player/handedness/club/view/model ที่เข้ากัน หรือแสดง mismatch ชัดเจน
- Bookmark/drawing/phase correction เปิดใหม่แล้วยังอยู่เฟรมเดิม 10/10 records ที่สุ่มตรวจ
- AI action chip seek ไม่เกิน 100 ms จาก phase ที่อ้าง และคำตอบต้องระบุ swing/phase/evidence/limitation
- ชุดทดสอบ AI อย่างน้อย 30 คำถามไม่มีการสร้าง Rapsodo metric, club path, impact หรือ 3D ที่ input ไม่มี
- Drill เก็บ cue, reps, stop condition และ before/after context ครบ; ไม่อ้าง causal improvement จากกล้องอย่างเดียว
- Transcript แก้ได้ก่อนส่ง และ TTS หยุดทุกครั้งเมื่อ detector เริ่มวงใหม่

---

### P2 — Advanced Visuals, Club/Impact และ Multi-Source Analysis

#### เป้าหมาย

เพิ่ม visual comparison ระดับลึกและ metric ที่ต้องมี model/sensor/calibration ใหม่ โดยไม่ลดมาตรฐาน provenance

#### งานที่เลือกทำได้

1. Split wipe / crossfade ของ phase ที่ align แล้ว
2. Synchronized dual-video comparison
3. Club/shaft/club-head detector
4. Confirmed impact จากภาพ/เสียง/sensor ที่ sync กัน
5. Monocular 3D แบบมี model card หรือ calibrated multi-camera
6. Long-term trend แยกตาม player/club/view/baseline profile
7. Official Rapsodo adapter หรือ approved export/partner path หากมีสิทธิ์และ contract ชัดเจน
8. Mac-to-iPhone control/audio channel หากต้องการให้ iPhone พูด cue

#### Definition of Done — P2

- Visual overlay align แล้ว anchor residual ไม่เกิน 2% ของความกว้างภาพใน validation set และผู้ใช้ปิด alignment ได้
- Dual-video sync คลาดไม่เกิน 2 frames ที่ phase anchor ร่วมกัน
- Club/shaft detector ต้องผ่าน held-out precision อย่างน้อย 95% ก่อนแสดงเส้นที่เรียกว่า club/shaft
- Confirmed impact error ไม่เกิน 2 source frames บน held-out set ก่อนเปลี่ยน label จาก `Impact Window`
- 3D ทุก metric มี model card, calibration requirement, ground-truth error และ confidence; metric ที่ไม่ผ่านเกณฑ์ไม่แสดง
- Multi-camera sync คลาดไม่เกิน 1 frame และบันทึก calibration ต่อ session
- Trend ใช้อย่างน้อย 10 วงใน context เดียวกัน และ cross-context exclusion ผ่าน 100%
- Structured Rapsodo value ใช้ `sourceType = rapsodoMeasured` เฉพาะ event/export/API ที่รับจริงและจับคู่ได้; pixels-only mirror ไม่ถูกยกระดับเป็น metric
- ฟีเจอร์ P2 ทุกตัวมี kill switch/fallback และไม่ทำให้ camera-only P0 loop ใช้งานไม่ได้

---

## 10. Dependency Map

```text
Hardware UAT + Solo-loop ที่เสถียร
  ├─ Voice / Countdown / Tempo
  └─ Persist context + evidence + clock mapping
       └─ Camera keyframes
            └─ Adaptive Storyboard
                 ├─ User-selected baseline
                 │    ├─ Metric comparison
                 │    ├─ Phase still side-by-side
                 │    └─ Pose/hand overlay
                 ├─ Phase-aware AI chat
                 │    └─ Drill session + before/after
                 └─ Cutout cards

Labeled dataset + detector validation
  ├─ 8-phase expansion
  ├─ Club/shaft detector
  └─ Confirmed impact

Calibration + กล้องหรือ sensor เพิ่ม
  └─ 3D / multi-camera

Approved Rapsodo path
  └─ Structured launch card / AI context / trend (optional)
```

---

## 11. สิ่งที่ไม่ควรทำ

- บังคับ Storyboard ให้ครบ 8 phase ด้วย interpolation ที่ผู้ใช้มองไม่เห็นว่าเป็นค่าประมาณ
- เรียกช่วงมือกลับว่า impact จริง
- เรียก hand trace ว่า club-head path
- เรียก shoulder/hip projection 2D ว่ามุมหมุน 3D
- ใช้ latest swing เป็น “วงดีของฉัน” โดยผู้ใช้ไม่ได้เลือก
- ซ้อนคนโปร่งใสหลายร่างเป็นค่าเริ่มต้นจนดูเป็นผี
- ใช้ person segmentation แบบ live จนภาพ 120 FPS หรือ pose กระตุก
- ให้ AI อ้างว่าเห็น keyframe เมื่อ `imageContentID` ยังไม่มี
- ส่ง raw video ทุกวงให้ AI แทน numeric evidence/keyframe ที่เลือก
- อ่านค่าจากภาพ Rapsodo ด้วย OCR หรือเรียกพิกเซลบน mirror ว่า measured launch data
- ให้ AI พูดยาวหลายเรื่องหลังตีหนึ่งวง
- ทำ P2 แล้วทำให้ camera-only solo loop ใช้งานไม่ได้

---

## 12. ข้อเสนอการตัดสินใจ

ลำดับที่เหมาะกับฮาร์ดแวร์และโค้ดปัจจุบันที่สุดคือ:

1. **P0.1 Voice one-take + Countdown/Tempo** — quick win และแก้ปัญหาบันทึกรัว
2. **P0.2 Evidence/phase/keyframe persistence** — ฐานข้อมูลกลางของ Swing2
3. **P0.3 Adaptive Storyboard + phase seek** — ส่งคุณค่าที่ผู้ใช้เห็นทันที
4. **P0.4 User-selected baseline + honest guideline** — เริ่มเปรียบเทียบวงตัวเองโดยไม่ตัดสิน
5. **P1.1 Phase-aware AI + drill session** — ใช้ข้อมูลที่เชื่อถือได้แล้วค่อยให้ AI อธิบาย
6. **P1.2 Side-by-side + cutout fallback** — เพิ่ม visual หลัง alignment พร้อม
7. **P2 Club/impact/3D/Rapsodo structured integration** — ทำเมื่อผ่าน detector/vendor gate

ถ้าเลือกทำเพียง vertical slice เดียว ให้เลือกข้อ 2–4 ร่วมกัน:

> บันทึก phase + keyframe ของวง → แสดง Adaptive Storyboard → แตะ seek → ตั้งวงนั้นเป็น baseline → เทียบวงถัดไป

นี่คือ slice ที่พิสูจน์แกนหลักของ Golf Swing2 ได้ครบ โดยยังไม่ต้องเสี่ยงกับ cutout, club detector หรือ 3D ก่อนเวลา

---

## แหล่งแนวคิดผลิตภัณฑ์

ใช้เพื่อดูรูปแบบ UX ที่ผลิตภัณฑ์ประกาศว่ามี ไม่ใช้เป็นหลักฐานความแม่นยำของ GolfTrace:

- [Onform Golf](https://onform.com/sports/golf/)
- [V1 Sports](https://swing-analysis.v1sports.com/)
- [GolfFix Swing Analysis](https://notice.golffix.io/en/guide/analysis)
- [Sportsbox AI](https://www.sportsbox.ai/)
