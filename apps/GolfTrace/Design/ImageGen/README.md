# GolfTrace ImageGen design set

ชุดนี้สร้างด้วย built-in ImageGen แล้วนำไฟล์ที่ใช้จริงเข้า workspace ไม่อ้างไฟล์จากโฟลเดอร์ชั่วคราว

## ต้นแบบ UX

- `iPhone-Capture-UX-v1.png` — หน้าถ่ายสำหรับซ้อมคนเดียว เรียงสถานะ ภาพสด ปุ่มหลัก และตัวเลือกใช้บ่อยจากบนลงล่าง
- `Mac-Main-UX-v1.png` — ภาพสดเป็นพื้นที่หลัก ผลตัวเลขและ Rapsodo แยกแหล่งที่มา AI Golf Pro อยู่ขวา และ replay อยู่ล่าง
- `Mac-Camera-Rotate-Control-v1.png` — guide แก้ภาพกลับหัวด้วยปุ่ม 180° ใน pill เดียวกับ Zoom; วงสีน้ำเงินหมายถึงกำลังใช้ mount correction
- `Mac-History-Workspace-v1.png` — เปลี่ยนประวัติจาก system popup เป็น workspace เต็มหน้าต่าง: รายการวงทางซ้าย หลักฐาน/Storyboard/MLM2PRO ทางขวา และเปิดคลิปผ่าน shared replay เดิม

Prompt ของ guide ปุ่มหมุน: `Mac-Camera-Rotate-Control-v1.prompt.txt`
Prompt ของ History workspace: `Mac-History-Workspace-v1.prompt.txt`

ภาพหน้าจอจากการใช้งานจริงที่ใช้เป็น reference ก่อนออกแบบ History ถูกเก็บไว้
เฉพาะในเครื่องพัฒนาและถูก `.gitignore` กันออก เพราะอาจมีข้อมูล session หรือบุคคล
ต้นแบบและ prompt ที่เผยแพร่ในโฟลเดอร์นี้จึงไม่พึ่งไฟล์ส่วนตัวเหล่านั้น

Prompt หลัก: `premium sports-tech UI`, ภาษาไทย, พื้นกราไฟต์เข้ม, ขาว/น้ำเงิน, เขียวเฉพาะพร้อม, แดงเฉพาะบันทึก, ผู้ใช้คนเดียว, settings จุดเดียว, ไอคอนมีจุด tracer, ไม่ใช้ dashboard แน่นหรือสีฉูดฉาด

## ภาพคนจัดกล้อง

ไฟล์ที่แอปใช้จริงอยู่ที่ `../../GolfTraceCamera/Sources/Resources/`:

- `GolferFaceOn.png`
- `GolferDownTheLine.png`

Prompt หลัก: ผู้เล่นจริงสัดส่วนมนุษย์ ท่า address มือขวา ชุดไม่มีแบรนด์ ภาพเต็มตัวและไม้ครบ แยก face-on/down-the-line พื้น chroma-key สีเขียวเรียบ แล้วตัดเป็น PNG โปร่งใสด้วยเครื่องมือของ ImageGen skill

## ไอคอนใช้งานจริง

ไฟล์ร่วมของ iPhone และ Mac อยู่ที่ `../../Shared/Resources/`:

- `GolfTraceIconClub.png`
- `GolfTraceIconCameraAngle.png`
- `GolfTraceIconGuideline.png`
- `GolfTraceIconAIPro.png`

Prompt หลัก: ไอคอนเส้นขาวปลายมน อ่านได้ที่ขนาดเล็ก จุด tracer สีน้ำเงิน ไม่มีข้อความ ไม่มีโลโก้ ไม่มีพื้นหลัง/เงา ใช้พื้น chroma-key แล้วตัดเป็น PNG โปร่งใส

ข้อกำหนด: overlay ที่เปลี่ยนตามข้อมูลจริง เช่น จุดข้อต่อ เส้นมือ และ tracer ตามเวลา ยังต้องวาดจากตัวเลขด้วยโค้ด ไม่ใช้ภาพสำเร็จจาก ImageGen
