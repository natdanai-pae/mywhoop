# GolfTrace UI review

วันที่ตรวจ: 21 ก.ค. 2569
ขอบเขต: macOS dashboard, History, Quick Controls, Advanced Settings, camera states, replay/storyboard และ accessibility

> หมายเหตุ: workflow เต็มของ `gsd-ui-review` ใช้งานไม่ได้เพราะไฟล์อ้างอิงที่ skill ระบุไม่มีในเครื่อง จึงตรวจด้วย fallback 6 pillars; build 24 ผ่าน build/test และ visual UAT บนแอปที่ติดตั้งใน `/Applications` แล้ว

## สรุปคะแนน

| Pillar | คะแนน | สรุป |
| --- | ---: | --- |
| Theme consistency | 9/10 | History ใช้ review canvas ตาม ImageGen guide; Quick Controls และ Settings บางส่วนยังเป็น native container |
| Visual hierarchy | 9/10 | วันที่และคำสั่งเป็น overlay เล็ก; Storyboard โปร่งทับวิดีโอและ PIP ไม่แย่งจุดสนใจ |
| Layout/responsiveness | 8/10 | 8 phase อยู่ครบที่ความกว้างขั้นต่ำ 1080 pt และ PIP/phase width มีขอบเขต responsive |
| States/feedback | 8/10 | กล้องแยก searching/stalled/failed และ hands-free ไม่ล้มบน audio queue แล้ว แต่ error ของ replay/recorder ยังไม่รวมศูนย์ |
| Interaction/accessibility | 8/10 | card/phase มี label/selection และ Replay ซ่อน dashboard ชั้นล่างจาก accessibility แล้ว; divider/timeline ยังขาด adjustable action |
| Evidence honesty | 9/10 | replay/keyframe ใช้เฉพาะไฟล์ที่ผ่าน validation และวงเก่าไม่สร้าง Storyboard/MLM ปลอม |

## Findings

### แก้แล้วใน build 23

1. **History เป็น in-window workspace** — ลบ sheet/panel เก่า เหลือ browser ซ้าย + รายละเอียดขวา และทุกคำสั่ง “ประวัติ” เปิด workspace เดียวกัน

2. **ข้อมูลภาพซื่อสัตย์** — thumbnail มาจาก MOV/JPEG จริงแบบ lazy; ไฟล์หาย/symlink/ชื่อไม่ปลอดภัยแสดงว่าไม่พร้อม และ search ใช้ availability เดียวกับ badge

3. **กล้องมี state-aware UI** — แยกกำลังค้นหา, ต่อแล้วแต่ยังไม่มีเฟรม, stalled/auto reconnect, failed และ stopped

4. **orientation/source ไม่รั่วข้ามกล้อง** — direct iPhone และ fallback ใช้ orientation/half-turn ของตัวเอง; badge และ metadata ใช้อุปกรณ์ที่ส่งเฟรมจริง ไม่ใช่ค่าที่เพิ่งเลือก

5. **คลังเสียบางวงไม่ล้มทั้งหน้า** — package ที่อ่านไม่ได้ถูกแยกไว้ใน `Swings/Recovery`, แจ้งตำแหน่ง, นับพื้นที่ใน quota และวงอื่น/การบันทึกใหม่ยังใช้ได้

6. **History ไม่บัง/ถูก Replay บัง** — เปิด History ระหว่าง replay จะกลับ live ก่อน และ renderer กล้องยัง mount อยู่เพื่อไม่ให้ภาพดำหลังกลับมา

7. **History render ไม่แตะ filesystem ซ้ำ** — ตรวจ replay/keyframe และ symlink บน background ต่อ records snapshot แล้ว card/search/8 phase อ่าน dictionary บน MainActor

8. **Hands-free ไม่ชน MainActor จาก audio queue** — callback ของ AVAudioEngine ส่ง buffer ผ่านตัวรับที่เป็น Sendable และผล speech ค่อยกลับ MainActor; มี regression test เรียก tap จาก background queue

9. **ค้นหาวันที่ตามข้อความที่เห็นได้** — ค้นหา `19 ก.ค.` พบ 15 วงในกลุ่ม 19 ก.ค. จริง โดย index ทั้งรูปแบบวันที่เต็มและแบบย่อ

10. **Preview ใช้พื้นที่ card ตามสัดส่วนจริง** — ภาพแนวตั้ง fit เต็มความสูงที่มี ไม่ย่อเป็นภาพเล็กกลางพื้นดำ

11. **Replay มี interaction layer เดียว** — dashboard และ timeline ชั้นล่างถูกปิด hit testing และซ่อนจาก accessibility ระหว่าง full-window replay

ผล UAT ตัวติดตั้ง build 23: เปิด History, เลือกวง, ค้นหา `19 ก.ค.`, เปิด Replay และกลับ History ผ่านครบ; ระบบฟังคำสั่งยังทำงานและไม่มี crash report ใหม่หลังเปิดแอป

ผลตรวจล่าสุด: **ไม่มี P0/P1 เหลือในขอบเขต History + camera state + hands-free ที่ตรวจรอบนี้**

### แก้แล้วใน build 24

1. **History เป็น review canvas เดียว** — วันที่/รายละเอียดและปุ่มกลับ/เปิด Replay เป็น overlay ขนาดเล็กบนวิดีโอ ทำให้หลักฐานวงอยู่ใน focus โดยไม่เสียพื้นที่ให้ header ขนาดใหญ่

2. **Swing Storyboard โปร่งทับวิดีโอ** — แผง 8 phase สูง 216 pt ใช้พื้นสี alpha จริง เห็นภาพด้านหลัง และทั้ง 8 phase fit ครบแม้หน้าต่างขั้นต่ำ

3. **ตัดค่า Rapsodo ที่ไม่มีข้อมูลออก** — หน้า History ไม่มี Ball Speed, Launch และ Spin card; ไม่แสดง dash ที่ดูเหมือนระบบกำลังรอค่าที่ไม่ได้รับ

4. **Replay ใหม่เป็นกล้องหลัก + Rapsodo PIP และสลับได้** — ใช้ stage-composite MOV ไฟล์เดียวผ่าน Core Image video composition จึงใช้ decoder/timeline กลางเดียว ไม่เปิด player สองตัวให้หลุด sync

5. **พิกัด PIP อิงหลักฐานจริง** — บันทึก normalized rect ของสอง pane เฉพาะ take ที่ตำแหน่งคงที่ ตัด top controls และ timeline ที่ baked-in ออกจาก crop; หาก resize/divider เปลี่ยนระหว่างบันทึกจะซ่อน PIP และแสดง whole-window replay แทน

6. **กู้คืนหลัง persistence ล้มเหลวยังรักษา PIP** — recovery sidecar เก็บ pane layout ที่เชื่อถือได้และส่งกลับไปยัง record เดิม; raw-camera replacement ล้าง metadata เดิมเพื่อไม่ให้แสดง Rapsodo ปลอม

7. **วงเก่ายังซื่อสัตย์** — 20 records ปัจจุบันไม่มี stage pane metadata จึงแสดงวิดีโอเดียวและซ่อน PIP/ปุ่มสลับทั้งหมด

8. **Replay ไม่กระโดด layout ตอนเริ่ม** — auto-play รอ PIP composition พร้อมก่อน; replay ที่ pause อยู่ redraw เฟรมปัจจุบันทันทีหลังติดตั้ง composition

หลักฐาน visual UAT: `Design/ImageGen/Mac-History-ReviewCanvas-build24-UAT.png` ตรวจยืนยัน Storyboard โปร่งทับภาพ, ไม่มี launch metric cards และ legacy replay ไม่มี PIP ปลอม

ผลทดสอบสุดท้าย: 301 ผ่าน, 3 skipped (ชุดที่ต้องใช้ environment/fixture ภายนอก), 0 ล้มเหลว จาก 304 tests

ข้อจำกัดที่ยังต้องทดสอบกับอุปกรณ์: ยังไม่มีวงใหม่ที่บันทึกพร้อม Rapsodo + iPhone กล้องในรอบ UAT นี้ จึงยังไม่ได้ยืนยัน crop/PIP และปุ่ม swap แบบ end-to-end จาก hardware จริง

### P2 — จุดหลุดที่พบสำหรับ refactor ถัดไป

1. **Quick Controls ยังเป็น native popover** — History ถูกถอดออกจาก tab แล้วและเปิด workspace โดยตรง แต่ sources/camera/AI ยังอยู่ใน popup; หากย้ายเป็น in-window inspector ต้องทำ Imagen guide รอบใหม่ก่อน

2. **Error สำคัญยังไม่รวมศูนย์** — replay playback, screen capture และ stage recorder ควรใช้ persistent status/toast และเสียงตอบกลับสำหรับ solo mode

3. **สี Storyboard ยังอิง confidence มากกว่า provenance** — ควรแยกชนิด measured/estimated ออกจากระดับความมั่นใจ

### P2 — ปรับใน refactor ถัดไป

- Advanced Settings เข้าธีมแล้วแต่ยังเป็น modal sheet ขนาดใหญ่
- theme token กระจายใน `GolfTraceTheme`, `DarkSettingsPalette` และสี hard-code ใน Knowledge/Settings
- ปุ่ม “หยุด” การเชื่อมต่อใช้สีแดง ทั้งที่แดงควรสงวนให้ recording/error/destructive
- resize divider และ timeline scrubber ยังไม่มี accessibility adjustable action/keyboard increment
- raw `DisclosureGroup` ยังปนใน Rapsodo, fallback camera, MCP และ AI advanced settings

### P3 — state polish

- Knowledge empty state และ thumbnail เสียยังเป็น plain text/icon
- ควรมี reusable themed Empty, Loading และ Error card

## สิ่งที่ควรคง native

`Menu`, `Picker`, `Toggle`, `Slider`, confirmation ก่อนลบ profile, duplicate-instance alert, save panel และคำสั่งระบบสั้น ๆ ไม่ถือเป็น theme leak

## ข้อเท็จจริงของข้อมูล History ที่ใช้กำกับ UI

- ในเครื่องมี 20 records รุ่นเก่า (`schemaVersion 2`)
- ทั้ง 20 มี replay จริง แต่ไม่มี artifacts, phase/keyframe, camera view หรือ launch-monitor match
- หน้าใหม่จึงต้องสร้าง thumbnail จาก MOV จริงแบบ lazy หรือแสดง placeholder ซื่อสัตย์
- ห้ามสร้างภาพ Storyboard, ค่า MLM2PRO หรือ baseline ที่ไม่มีใน record
