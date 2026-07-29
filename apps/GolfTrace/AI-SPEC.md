# สเปกระบบ AI Golf Pro ของ GolfTrace

- สถานะเอกสาร: สัญญาการออกแบบ ยังไม่ใช่คำยืนยันว่าความสามารถทั้งหมดสร้างเสร็จแล้ว
- ขอบเขต: Mac, iPhone, MLM2PRO, OpenRouter, STT, TTS, แหล่งอ้างอิงภายนอก และคลังความรู้ที่ได้รับสิทธิ์
- ภาษาเริ่มต้น: ไทย (`th-TH`)
- วันที่ปรับปรุง: 18 กรกฎาคม 2026

## 1. เป้าหมาย

AI Golf Pro ต้องอธิบายสิ่งที่ระบบวัดได้จากวงสวิงและผลลูกให้ผู้เล่นเข้าใจง่าย เลือกประเด็นหลักหนึ่งข้อ เสนอแบบฝึกที่มีที่มา และระบุชัดว่าอะไรคือค่าจากอุปกรณ์ อะไรคือการสังเกตจากภาพ 2 มิติ อะไรคือความรู้จากแหล่งอ้างอิง และอะไรคือข้อสังเคราะห์ของ AI

ระบบต้องเพิ่มคุณค่าโดยไม่ทำให้การรับภาพ 120 FPS การเก็บคลิป การเล่นย้อนหลัง หรือการรับข้อมูล MLM2PRO ต้องรอบริการเครือข่าย

### 1.1 เป้าหมายที่วัดได้

- เก็บ provenance หรือที่มาของทุกค่าตลอดเส้นทางจนถึงข้อความที่ผู้ใช้เห็น
- ไม่มีตัวเลขหรือข้อสรุปที่ไม่มีหลักฐานรองรับ
- ไม่สวมรอยชื่อ บุคลิก ใบหน้า หรือเสียงของโปรจริง
- ไม่สร้างไฟล์หรือ cache วิดีโอ YouTube เต็มเรื่อง และไม่แยก audio track; เส้นทางปัจจุบันอ่านคำถอดเสียงพร้อมเวลาและเฟรมที่เลือกผ่าน MCP ในเครื่องเท่านั้น
- หนึ่งวงมีคำแนะนำหลักไม่เกินหนึ่งข้อ
- อุปกรณ์พูดเพียงเครื่องเดียว และหยุดเสียงเมื่อผู้เล่นเริ่มวงใหม่
- หากหลักฐานไม่พอหรือขัดกัน ระบบตอบว่าไม่พอ/ขัดกัน แทนการเดา

### 1.2 สิ่งที่ไม่ทำ

- ไม่วินิจฉัยอาการบาดเจ็บ ไม่ทำนายโรค และไม่แทนแพทย์หรือนักกายภาพ
- ไม่สร้าง “วงมาตรฐานสากล” จากโปรคนเดียว
- ไม่แปลงเส้นมือ 2 มิติเป็นความเร็วหัวไม้ `Club Path` หรือมุมหมุน 3 มิติ
- ไม่คาดเดาค่า MLM2PRO ที่ไม่ได้ส่งมา เช่น carry หากไม่มี field นั้น
- ไม่ใช้ raw swing video, เสียง, ใบหน้า หรือข้อมูลชีวมิติฝึกโมเดลเป็นค่าเริ่มต้น
- ไม่ hardcode credential, protected key หรือ secret ของบริการภายนอก

### 1.3 คำศัพท์ที่ใช้ในเอกสาร

- `OpenRouter` คือ API ที่ Mac ใช้เรียก text/vision model ตาม model ID ที่ตรึงไว้ โดย key อยู่ใน macOS Keychain และผูก exact HTTPS origin
- `DSV4` ในหัวข้อเก่าหมายถึงแนวทาง gateway ภายหลัง ไม่ใช่เส้นทางหลักของรุ่น single-user ปัจจุบัน
- `Swing Evidence Packet` คือข้อมูลรายเวลาที่ Mac สกัดจากวงสวิงแล้ว เช่น joint 2D, กึ่งกลางมือ, metric, phase, FPS จริง และสถานะสิ่งที่วัดไม่ได้
- `STT` หรือ Speech-to-Text คือการถอดเสียงเป็นข้อความ ส่วน `TTS` หรือ Text-to-Speech คือการอ่านข้อความออกเสียง
- `provenance` คือประวัติว่าค่าหรือข้อความมาจากอุปกรณ์ โมเดล เอกสาร หรือการคำนวณใด
- `grounded` คือคำตอบที่ทุกข้อสำคัญชี้กลับไปยังหลักฐานที่ตรวจได้
- `claim` คือข้อความความรู้หนึ่งข้อที่เก็บพร้อมแหล่ง ช่วงข้อความ บริบท และข้อจำกัด
- `retrieval` คือการค้นเฉพาะหลักฐานที่เกี่ยวข้องมาให้ AI ก่อนตอบ
- `embedding` คือตัวเลขแทนความหมายของข้อความเพื่อช่วยค้นหา ไม่ใช่หลักฐานใหม่
- `Rights Gate` คือด่านแยกการใช้อ้างอิงส่วนตัวออกจากการเผยแพร่ แชร์ ฝึกโมเดล สร้างเสียง/บุคลิก หรือใช้งานเชิงพาณิชย์ ซึ่งต้องมีฐานสิทธิ์ตามวัตถุประสงค์
- `visual evidence` คือเฟรม JPEG/PNG ที่เลือกตามเวลา พร้อม hash, claim ที่เกี่ยวข้อง, ผล Apple Vision/OCR และผล VLM แบบ typed JSON เมื่อผู้ใช้เลือกเปิด ไม่ได้หมายถึงวิดีโอทั้งเรื่องหรือการวัด 3 มิติ
- `visual grounding` คือข้อสังเคราะห์ประเภท `ai_inferred` ที่ VLM ผูก claim กับ selected frame พร้อม confidence, limitations, model และ hash ของเฟรม ไม่ใช่ค่าที่กล้องวัดโดยตรง
- `critical path` คือเส้นทางงานที่ถ้าช้าจะทำให้การรับภาพหรือเก็บวงช้า ซึ่ง OpenRouter และโมเดลทุกตัวต้องไม่อยู่บนเส้นทางนี้
- `asynchronous` คือส่งงานแล้วทำอย่างอื่นต่อได้ ไม่ต้องค้างรอให้จบ
- `Audio Host` คืออุปกรณ์เครื่องเดียวที่ได้รับสิทธิ์พูด ส่วน `lease` คือสิทธิ์ชั่วคราวที่มีวันหมดอายุ
- `guardrail` คือกฎป้องกันคำตอบ การใช้ข้อมูล หรือการกระทำที่ไม่ปลอดภัย
- `prompt injection` คือข้อความจากเอกสารหรือผู้ใช้ที่พยายามหลอกให้ AI ข้ามกฎหรือเปิดเผยข้อมูล
- `model card` คือเอกสารบอกความสามารถ ข้อมูลทดสอบ ข้อจำกัด และความเสี่ยงของโมเดล
- `SLO` คือเป้าหมายระดับบริการ และ `p95` หมายถึง 95% ของงานต้องเสร็จไม่เกินเวลาที่กำหนด

## 2. ภาพรวมสถาปัตยกรรม

เส้นทาง live และเส้นทาง AI แยกออกจากกัน

```text
iPhone Camera ──H.264──> Mac Capture/Replay/Pose/Metric ──> Shot Record
                                      ^                       |
                                      |                       v
                                MLM2PRO BLE       Numeric Swing Evidence Packet
                                                              |
                                              (หลังจบวง; asynchronous)
                                                              v
                                         OpenRouter text model (coach)
                                                              |
                                             optional critic / vision audit
                                             (keyframe ไม่เกิน 1–2 ภาพ)
                                                              |
                                                              v
                                         Mac UI + TTS เพียงหนึ่งเครื่อง

YouTube URL หลายลิงก์ ──> youtube-context-mcp บน 127.0.0.1
                         ├─> transcript + timestamp ─> OpenRouter text model สกัด claim แบบข้อความ
                         └─> JPEG/PNG เฉพาะเวลาที่เลือก ─> Apple Vision 2D + OCR
                                                              |
                                                              v
                                    Qwen3-VL บน GX10 (เลือกเปิด; asynchronous)
                                                              |
                                                              v
                                                  typed visual grounding
                                                              |
                                                              v
                           claim + citation + structured visual evidence ─> DeepSeek
```

### 2.1 หน้าที่ของแต่ละส่วน

| ส่วน | หน้าที่ | สิ่งที่ห้ามทำ |
|---|---|---|
| iPhone | ถ่าย ส่งภาพ รับค่ารอบซ้อม แสดงสถานะ และพูดเมื่อเป็น `Audio Host` | ติดต่อ OpenRouter โดยตรงหรือถือ OpenRouter key |
| Mac | ประมวลผลภาพ สร้าง numeric packet จับคู่ MLM2PRO ตรวจ contract แล้วจึงเรียก AI หลังจบวง | ส่ง raw media ออกนอกเครื่องโดยไม่มีสิทธิ์และความยินยอม |
| MLM2PRO | ให้ค่าที่อุปกรณ์วัดและสถานะการยิงลูก | เป็นแหล่งอนุมานท่าร่างกายหรือค่าที่ไม่มีใน packet |
| OpenRouter text model | ตีความตัวเลขใน packet และคืนคำแนะนำไทยแบบ typed JSON | สกัด pose/trajectory ใหม่จากวิดีโอ หรือสร้างเลขที่ packet ไม่มี |
| OpenRouter vision audit | ตรวจเฉพาะข้อสงสัยด้วย keyframe 1–2 ภาพเมื่อ consent และ eval ผ่าน | รับภาพผู้เล่นผ่าน free endpoint ที่ไม่มีนโยบายข้อมูลเหมาะสม หรือสร้าง continuous club path |
| youtube-context-mcp | รันเฉพาะบน Mac ที่ `127.0.0.1` เพื่อคืน transcript พร้อมเวลาและภาพเฉพาะวินาทีที่ขอ | ติดตั้งตัวเองแบบเงียบ เปิด `0.0.0.0` หรือรับ BDA API key |
| Apple Vision สำหรับภาพอ้างอิง | อ่านจุดร่างกาย metric 2 มิติ และ OCR ข้อความสั้นจาก JPEG/PNG แยกจาก scheduler กล้องสด | อ้างว่าเห็นหัวไม้ ลูกกอล์ฟ ความหมายภาพทั่วไป หรือโครงสร้าง 3 มิติ |
| Qwen3-VL adapter | เมื่อผู้ใช้เปิด ส่งเฉพาะ selected frame ที่ cache แล้วไป OpenAI-compatible VLM และตรวจคำตอบเป็น typed JSON | อ่านภาพสด 120 FPS, ใช้ OpenRouter key หรือส่งผลที่ไม่ผ่าน schema ต่อเป็นหลักฐาน |
| GX10 | ใช้สร้าง/ประเมินชุดข้อมูล งานทดลองที่ควบคุม และ optional VLM บน selected frame แบบ asynchronous | เป็นข้อพึ่งพาสำหรับการรับ/วิเคราะห์ภาพสดบน Mac หรือถูกอ้างว่าพร้อมก่อนตรวจ endpoint/model จริง |

## 3. สัญญา OpenRouter แบบ feature-first

รุ่น single-user ปัจจุบันให้ Mac เป็น “เครื่องวัด” และให้ cloud model เป็น “เครื่องตีความ” ไม่ส่งหกเฟรมให้โมเดลสกัดข้อมูลซ้ำ เส้นทาง gateway/DSV4 แบบ job service เก็บเป็นทางเลือกในอนาคตหากมีหลายผู้ใช้หรือจำเป็นต้องซ่อน provider key ฝั่ง server

### 3.1 รูปแบบการเรียกงาน

- เรียก `https://openrouter.ai/api/v1/chat/completions` ผ่าน HTTPS หลังวงจบเท่านั้น
- API key เก็บใน Data Protection Keychain แบบ `WhenUnlockedThisDeviceOnly`, ไม่ sync และผูก exact origin ตอนบันทึก
- คำขอ OpenRouter ตั้ง `provider.require_parameters=true` และ `provider.zdr=true` เพื่อ fail closed หาก provider ไม่รองรับ parameter หรือ Zero Data Retention
- prompt ส่ง `SwingEvidenceNumericPacket` เป็นหลัก ไม่ส่ง raw video และไม่ส่ง full verbose timeline object
- model ID ต้อง pin เพื่อทำ eval ซ้ำได้ ห้ามใช้ `openrouter/free` ที่เลือกโมเดลสุ่มใน production
- response ต้องเป็น typed JSON และผ่าน local validation ก่อนแสดงหรือพูด
- เมื่อเริ่มวงใหม่ต้องยกเลิก network task และ TTS รุ่นก่อนหน้า; การรับภาพ/replay ไม่รอ API

### 3.2 บทบาทโมเดล

| บทบาท | รุ่นเริ่มต้น | ข้อมูลเข้า | สถานะ |
|---|---|---|---|
| coach | `deepseek/deepseek-v4-flash` | numeric packet + Rapsodo + knowledge claim | primary candidate; ต้องผ่าน Thai/golf eval |
| critic | `tencent/hy3` | packet + draft answer | ใช้เมื่อหลักฐานขัดกันหรือ confidence ต่ำ; Hy3 เป็น text-only |
| vision audit | `google/gemini-3.1-flash-lite` | packet + consented keyframe 1–2 ภาพ | ยังไม่เปิด live จน eval/privacy gate ผ่าน |
| free shadow | exact free model ID | synthetic/de-identified fixture | ห้ามสร้าง production evidence ก่อนผ่านเกณฑ์เดียวกับ paid |

ไม่มีรุ่นใดใน OpenRouter catalog ที่ผู้ให้บริการยืนยันว่าเชี่ยวชาญกอล์ฟ จึงห้ามใช้ leaderboard popularity แทน GolfTrace evaluation รุ่น `tencent/hy3:free` เป็น text-only และ OpenRouter ประกาศยุติ 21 กรกฎาคม 2026 จึงไม่เป็น dependency ระยะยาว

### 3.3 ความปลอดภัยและงบ

- ห้าม log key, Authorization header, prompt เต็ม, packet เต็ม, transcript เต็ม หรือ raw response
- ห้ามแสดง `error.message` จาก upstream โดยตรง เพราะอาจสะท้อน prompt/ข้อมูลผู้เล่น
- free vision endpoint ที่ไม่มี ZDR ยืนยันใช้เฉพาะ synthetic fixture; ห้ามรับใบหน้าหรือภาพผู้เล่นจริง
- จำกัดขนาด packet, frame count, output tokens, timeout และจำนวน retry
- ตั้ง weekly limit ของ OpenRouter key ไม่เกินงบที่ผู้ใช้เลือก และเก็บ token/cost แบบตัวเลขโดยไม่เก็บเนื้อหา
- ภาพจริงต้องมี consent แยกจาก structured packet และผู้ใช้ปิดได้จาก settings เดียว

### 3.4 SLO เป้าหมาย

| งาน | เป้าหมาย | หมายเหตุ |
|---|---|---|
| coach จาก numeric packet | p95 ไม่เกิน 8 วินาที | ไม่รวมเวลารอ MLM2PRO สูงสุด 4 วินาที |
| vision audit 1–2 ภาพ | asynchronous; ไม่บังการตีลูกถัดไป | เปิดเฉพาะกรณี packet ไม่พอ |
| การยกเลิกเสียง | หยุดออกเสียงภายใน 300 ms | ทดสอบบน Mac และ iPhone |
| offline fallback | capture/replay/history ใช้ได้ 100% | ใช้ deterministic Thai fallback |

ค่าทั้งหมดเป็นเกณฑ์ก่อนทดสอบจริง ไม่ใช่ผลยืนยันจาก hardware หรือ live API

## 4. ที่มาของข้อมูลจาก iPhone, Mac และ MLM2PRO

### 4.1 ลำดับความน่าเชื่อถือของ observation

1. `device_measured` — ค่าที่ MLM2PRO ส่งมาโดยตรง พร้อมหน่วย packet/session/shot ID และเวลารับ
2. `mac_vision_2d` — จุดหรือ metric บนภาพ 2 มิติ พร้อม view, actual FPS, capture quality, model version และ confidence
3. `personal_baseline` — สถิติจากวงที่ตรงผู้เล่น มือถนัด มุม ชนิดไม้ กล้อง และรุ่นโมเดล
4. `ai_inferred` — ข้อสังเคราะห์ของ AI ซึ่งต้องชี้กลับไปยัง evidence ข้างต้น

ลำดับนี้ไม่ได้แปลว่า device วัดทุกเรื่องได้แม่นกว่ากล้อง แต่ใช้ป้องกันการเขียนทับชนิดข้อมูล ตัวอย่างเช่น MLM2PRO เป็นหลักฐานของ ball speed แต่ไม่ใช่หลักฐานของ pelvis turn

### 4.2 กฎ MLM2PRO

- field ที่รองรับในโค้ดปัจจุบันคือ club speed, ball speed, horizontal launch angle, vertical launch angle, spin axis และ total spin รวมถึง smash factor ที่คำนวณจากสองความเร็ว
- ค่าใดที่คำนวณต้องมี `derivedFrom` และสูตร ห้ามติดป้าย `device_measured`
- shot ที่จับคู่ด้วยหน้าต่างเวลา ±8 วินาทีเก็บ `matchMethod`, `timeDeltaMs` และ `matchConfidence`
- ถ้ามีผู้สมัครมากกว่าหนึ่งวงและไม่ชัด ให้เป็น `unmatched` ห้ามส่งให้ AI เหมือนจับคู่แน่นอน
- AI ห้ามเติม carry, face angle, attack angle หรือค่าอื่นที่ packet ไม่มี
- เมื่อข้อมูลมาช้า ให้สร้างคำตอบวิดีโอได้ก่อนและออก revision ใหม่เมื่อจับคู่แล้ว โดยแจ้งผู้ใช้ว่าเหตุใดคำตอบเปลี่ยน

### 4.3 กฎข้อมูลภาพ

- ระบุทั้ง `captureFPS` จากภาพที่ถอดได้และ `poseAnalysisFPS` จาก timestamp ที่ Vision วิเคราะห์จริง ห้ามนำ 120 FPS ไปติดป้าย timeline ที่มีตัวอย่างน้อยกว่า
- ค่าเส้นมือปัจจุบันต้องใช้ชื่อ `hand_center_from_wrists` และ disclosure `ยังไม่ใช่หัวไม้`
- ค่า 2 มิติใช้หน่วย pixel, normalized body length หรือ screen angle เท่านั้นจนผ่าน calibration
- metric ทุกตัวต้องมี `viewApplicability`, `confidence`, `qualityFlags` และ `modelVersion`
- หากจุดสำคัญขาดเกินเกณฑ์ ให้ส่งสถานะ `not_observable` แทนค่าเลขสมมติ
- Mac เก็บ context address ประมาณ 600 ms ก่อน `t=0` และเวลาใน packet ใช้ millisecond เทียบกับ swing start
- timeline ที่ส่ง cloud downsample ไม่เกิน 30 แถวและใช้แถวตัวเลข `[t,x,y,confidence,...]`; ค่าที่ขาดใช้ `null` ไม่เติมศูนย์
- metric รวมทุกตัวส่ง `value, unitCode, sourceCode, availabilityCode, confidence, windowStartMs, windowEndMs`
- `club_head_path_2d` และ camera-confirmed impact ต้องเป็น `unavailable` จนมี detector บน Mac ที่ผ่าน eval; ห้ามใช้ wrist path แทน
- keyframe เป็น audit evidence ไม่ใช่ pose source: ขอไม่เกิน 2 เวลา เช่น top/estimated impact และต้องผูก timestamp/hash เดียวกับ timeline ก่อนส่งภาพ
- ถ้าระยะ keyframe ถึง trajectory sample ใกล้สุดเกิน `max(50 ms, 2/captureFPS)` ให้เป็น `insufficient_evidence`

## 5. Rights Gate สำหรับ YouTube และสื่อภายนอก

### 5.1 พฤติกรรมที่สร้างแล้วใน Mac app

ผู้ใช้วาง YouTube URL ได้หลายลิงก์โดยคั่นด้วยช่องว่างหรือขึ้นบรรทัดใหม่ แอปสร้างรายการงานหลายลิงก์ โดยแต่ละลิงก์เป็น `Task` อิสระและแสดงสถานะของตัวเอง ไม่รับประกันว่าจะเสร็จตามลำดับที่วาง เส้นทางของหนึ่งแหล่งเป็นดังนี้

1. แอปตรวจ host และ video ID แล้วแปลงเป็น canonical URL
2. `youtube-context-mcp==0.6.0` ที่รันเฉพาะ `http://127.0.0.1:8765/mcp` คืน transcript พร้อม timestamp ผ่าน `get_transcript`
3. แอปแบ่ง transcript เป็นช่วงไม่เกิน 15 วินาทีหรือ 1,800 ตัวอักษรและเก็บ transcript hash; ถ้ายังไม่มี OpenRouter key แอปยังเลือกช่วงตามเวลาเพื่อดึงภาพตัวอย่างได้
4. เมื่อ OpenRouter พร้อม แอปส่งเฉพาะข้อความให้ DeepSeek V4 Flash สกัด claim แล้วเลือกได้สูงสุด 6 ช่วงที่มี claim และขอ 3 เวลาในแต่ละช่วงผ่าน `get_video_frame` ที่ความกว้างไม่เกิน 640 พิกเซล
5. MCP คืน image content โดยตรง แอปรับเฉพาะ JPEG/PNG ขนาดไม่เกิน 12 MB ตรวจ magic bytes และ SHA-256 แล้วเก็บเป็นชื่อ hash
6. Apple Vision อ่านโครงร่างคนและ OCR จากแต่ละเฟรม แล้วผูก timestamp, claim IDs, จุดร่างกาย, metric 2 มิติ, ข้อความสั้น, quality flags และ pose model version เข้าด้วยกัน
7. เมื่อผู้ใช้เปิด `ให้ GX10 อ่านความหมายภาพ` และตั้ง endpoint ที่ผ่าน policy แอปส่งเฉพาะ selected frame ที่ cache แล้วให้ Qwen3-VL ผ่าน OpenAI-compatible adapter จากนั้นตรวจคำตอบเป็น `VisualClaimGrounding` แบบ typed JSON พร้อม confidence, limitations, model, frame hash และเวลาที่วิเคราะห์ การปิด VLM หรือ VLM ล้มเหลวไม่ทำลายผล Apple Vision/OCR ที่มีอยู่
8. AI Golf Pro ส่งให้ DeepSeek เฉพาะ claim, citation, image hash, OCR, ผล Vision และ visual grounding แบบ structured ไม่ส่งพิกเซลภาพอ้างอิงหรือภาพสด 120 FPS ให้ DeepSeek

adapter, schema, setting และเส้นทางเก็บ `visualGroundings` มีอยู่ในซอร์สปัจจุบันและปิดเป็นค่าเริ่มต้น แต่ deployment ของ endpoint/model Qwen3-VL บน GX10 **ยังไม่ได้รับการ live-validate กับเครื่องจริง** การ build/test ฝั่ง Mac จึงยืนยันได้เฉพาะ contract และ fallback ไม่ใช่ความพร้อมของ hardware หรือบริการ VLM ทั้งเส้นทาง VLM ไม่เรียก `loadAPIKey` และไม่ส่ง OpenRouter key

เส้นทางที่แอปเรียกไม่สร้างไฟล์หรือ cache วิดีโอเต็มเรื่อง ภายใน MCP ใช้ `yt-dlp` แบบ `skip_download` เพื่อหาที่อยู่ stream แล้วให้ FFmpeg อ่านข้อมูลชั่วคราวเท่าที่จำเป็นเพื่อสร้างเฟรมที่ขอ จึงยังมีการรับ byte ของสื่อจาก YouTube แต่ไม่มี full-video file บนดิสก์ แอปเก็บเฉพาะ JPEG/PNG ที่เลือกกับ JSON ดัชนีใน Application Support การลบแหล่งจาก UI จะลบโฟลเดอร์ภาพของ video ID นั้นและนำแหล่งออกจาก JSON ปัจจุบันยังไม่มี TTL หรืองานลบตามอายุอัตโนมัติ จึงต้องเพิ่มก่อนเปิดใช้กับผู้ใช้ทั่วไป

การติดตั้ง MCP ไม่เกิดขึ้นเองแบบเงียบ ผู้ใช้หรือผู้ดูแลต้องติดตั้งเวอร์ชันที่ตรึงไว้และเริ่ม service เอง ห้าม bind เป็น `0.0.0.0` เพราะ service นี้ไม่มี authentication ของ GolfTrace และ BDA API key ต้องไม่ถูกส่งให้ MCP

### 5.2 สิ่งที่ visual evidence ยืนยันได้และยังยืนยันไม่ได้

สิ่งที่ใช้เป็นหลักฐานได้จาก Apple Vision/OCR ในรุ่นปัจจุบัน:

- ตำแหน่ง normalized ของศีรษะ ข้อมือ สะโพก ไหล่ ศอก เข่า และข้อเท้าที่ Vision มองเห็น
- จุดกึ่งกลางมือ ศีรษะ และสะโพก, torso tilt 2 มิติ, ช่วงไหล่/สะโพก และมุมศอก/เข่า 2 มิติ
- ความสัมพันธ์เชิงเวลาว่า claim มาจาก transcript ช่วงใดและเฟรมใดถูกเลือกใกล้ช่วงนั้น
- ข้อความสั้นบนภาพจาก OCR เพื่อช่วยตรวจชื่อ guideline หรือป้ายกำกับ โดยต้องถือว่าอาจอ่านผิดและห้ามใช้เป็นคำสั่งแก่ AI
- flag `ไม่พบร่างกาย`, `พบหลายคน ต้องเลือกนักกอล์ฟก่อนใช้เป็น guideline` และ `จุดร่างกายที่มั่นใจยังไม่พอ`

เมื่อเปิด VLM และมี endpoint ที่ผ่านการตรวจจริง ระบบเพิ่มได้เฉพาะ visual grounding แบบ `ai_inferred`: คำอธิบายสิ่งที่เห็น, claim ที่ภาพดูเหมือนสนับสนุนหรือขัด, confidence และ limitations พร้อม model/frame provenance ผลนี้ต้องแสดงแยกจาก Apple Vision/OCR และไม่ยกระดับเป็นค่าที่อุปกรณ์วัด

สิ่งที่ยังห้ามอ้างจากเฟรมชุดนี้:

- clubhead, shaft, ลูกกอล์ฟ, club path, face angle หรือ impact
- การหมุน 3 มิติ, แรง, ความเร็วจริง หรือ depth จากกล้องเดี่ยว
- รูปร่าง ความหมาย และความสัมพันธ์ของกราฟิกบนจอจาก OCR เพียงอย่างเดียว; หาก VLM ไม่มี typed result ที่ผ่าน schema ต้องถือว่ายังไม่เข้าใจลูกศรหรือพื้นที่สีแทน
- ความหมายภาพแบบทั่วไป เช่น “โปรกำลังสาธิตการ shallow” เมื่อ VLM ปิด, endpoint ใช้ไม่ได้, confidence ต่ำ หรือ limitations ระบุว่าหลักฐานไม่พอ
- ลำดับการเคลื่อนไหวต่อเนื่องจากเฟรมเดี่ยว และเวลาที่แม่นระดับเฟรม; keyframe seek อาจคลาดราว 1–2 วินาที จึงต้องดูหลายเฟรมรอบช่วงเดียวกัน

ดังนั้นผลทั้งหมดเป็น “หลักฐานประกอบ claim” ไม่ใช่ครูสายตาที่เข้าใจทุกสิ่งในภาพ VLM adapter เก็บผลเป็นชนิดหลักฐานใหม่และไม่เขียนทับ Apple Vision 2 มิติหรือ OCR ส่วน detector หัวไม้เฉพาะทางยังเป็นงานถัดไป

VLM เป้าหมายสำหรับการทดลองบน GX10 คือ `Qwen/Qwen3-VL-8B-Instruct` ผ่าน OpenAI-compatible endpoint โดยรับเฉพาะ selected frames พร้อม timestamp และคืน JSON ที่ adapter ตรวจชนิดก่อนเก็บ จากนั้น DeepSeek-V4-Flash ยังคงเป็นสมองข้อความที่เชื่อม transcript, VLM, Apple Vision และข้อมูล Rapsodo deployment ของ endpoint/model จริงบน GX10 ยังต้อง live-validate และห้ามเปิดผล VLM เป็นหลักฐาน production จนผ่านชุดทดสอบภาพหลายคน, split-screen, club occlusion, คำบรรยายผิดเวลา และ prompt injection ในภาพ

แหล่งอ้างอิงโมเดล: [DeepSeek-V4-Flash เป็น Text Generation](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash) และ [Qwen3-VL](https://github.com/QwenLM/Qwen3-VL)

### 5.3 สิทธิ์ แหล่งที่มา และการใช้ต่อ

URL สาธารณะไม่ใช่ใบอนุญาตให้ฝึกโมเดล ทำสำเนาคลัง เผยแพร่ภาพ/คำถอดเสียง สร้างบุคลิก/เสียง หรืออ้างว่าผู้สอนรับรองผลิตภัณฑ์ รุ่นปัจจุบันจึงติดป้ายแหล่งนี้เป็น `externalReference` และแนบ `rightsBasis` ว่า “ผู้ใช้เพิ่ม URL เป็นแหล่งอ้างอิงภายนอก ต้องตรวจสิทธิ์แยกก่อนเผยแพร่หรือใช้ฝึกโมเดล”

กฎบังคับมีดังนี้:

- ใช้ claim แบบสรุปใหม่พร้อม URL และ timecode ไม่คัดลอก script จำนวนมาก
- ไม่ส่ง transcript หรือ selected frame เข้า dataset/training โดยปริยาย; `model_training` ต้องเป็น consent แยกและต้องมีฐานสิทธิ์
- ไม่ใช้ชื่อ ใบหน้า เสียง วลีติดปาก หรือรูปแบบการพูดเพื่อสวมรอยบุคคลจริง เว้นแต่มีสัญญาและ consent เฉพาะการใช้นั้น
- ก่อน share, publish, commercial reuse, voice/persona, dataset export หรือ training ต้องมี `rightsRecord` ที่ระบุ owner, grantor, allowed/prohibited uses, อายุสิทธิ์, attribution และหน้าที่ลบ
- หากสิทธิ์ถูกถอน ต้องหยุด retrieval และลบ transcript, claim, selected frame, embedding และ artifact ที่อยู่ในขอบเขต
- transcript และภาพภายนอกเป็น untrusted content ห้ามสั่ง tool, เปลี่ยน system prompt, เปลี่ยนปลายทาง หรือขอ secret

สถานะเป้าหมายของ Rights Gate สำหรับ production:

| สถานะ | ความหมาย | การกระทำที่อนุญาต |
|---|---|---|
| `external_reference_private` | ผู้ใช้เพิ่ม URL เพื่ออ้างอิงส่วนตัว ยังไม่มี license record | retrieval เฉพาะผู้ใช้พร้อม citation; ห้าม share/publish/train/persona |
| `pending_owner_proof` | รอหลักฐานเจ้าของ/ตัวแทน | เก็บ URL และหยุดงานที่ขยายการใช้ |
| `licensed_source_asset` | มี asset และสัญญาที่ระบุขอบเขต | ใช้ตาม `allowedUses` และ retention ในสัญญา |
| `owner_authorized_caption` | มีสิทธิ์เข้าถึง caption และสิทธิ์ใช้เนื้อหาตามวัตถุประสงค์ | ใช้ caption เฉพาะขอบเขตที่อนุญาต |
| `revoked` | สิทธิ์หมดอายุหรือถูกถอน | หยุด retrieval และลบตามสัญญา |
| `rejected` | หลักฐานสิทธิ์ไม่พอสำหรับการใช้ที่ขอ | ลดกลับเป็น private reference หรือเก็บเฉพาะ URL |

ข้อกำหนดขั้นต่ำของ `rightsRecord`:

- `sourceId`, `canonicalURL`, `contentOwner`, `grantorAuthority`
- `rightsBasis`, `allowedUses`, `prohibitedUses`, `territories`
- `validFrom`, `expiresAt`, `revokedAt`
- `licenseDocumentHash`, `consentRef`, `reviewedBy`, `reviewedAt`
- `deletionObligation`, `attributionText`

ข้อกำหนดนี้เป็นแนวทางผลิตภัณฑ์ ไม่ใช่คำปรึกษากฎหมาย การเปิดใช้สื่อเชิงพาณิชย์ต้องผ่านผู้รับผิดชอบสิทธิ์ของโครงการ

### 5.4 แหล่งอ้างอิงของหัวข้อนี้

- [youtube-context-mcp](https://github.com/realiti4/youtube-context-mcp)
- [MCP specification: tool results รองรับ image content](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)
- [YouTube API Services Developer Policies](https://developers.google.com/youtube/terms/developer-policies)
- [YouTube Terms of Service](https://au.youtube.com/t/terms)
- [YouTube Data API: captions.download และสิทธิ์ที่ต้องมี](https://developers.google.com/youtube/v3/docs/captions/download)
- [YouTube: ข้อมูลลิขสิทธิ์](https://support.google.com/youtube/answer/2797466)
- [YouTube: ข้อจำกัดของการอ้าง fair use](https://support.google.com/youtube/answer/9783148)
- [U.S. Copyright Office Circular 33: Works Not Protected by Copyright](https://www.copyright.gov/circs/circ33.pdf)

## 6. คลังความรู้และลำดับหลักฐาน

### 6.1 ชั้นหลักฐาน

| ชั้น | แหล่ง | วิธีใช้ |
|---|---|---|
| A | ค่าที่อุปกรณ์วัดและ observation จากภาพที่มี confidence/provenance | อธิบายวงและผลลูกนี้ |
| B | งานวิจัย peer-reviewed, validation study และ model card | ขอบเขต ความแม่น และข้อจำกัดของหลักการ |
| C | เอกสารทางการของผู้ผลิต เครื่องมือ หรือองค์กร | นิยาม field ขั้นตอน และความสามารถของระบบ |
| D1 | external reference ที่ผู้ใช้เพิ่ม พร้อม transcript span, URL, timecode และ selected-frame hash | อ้างอิงส่วนตัวแบบมีข้อจำกัด ห้ามตีความว่าได้รับ license |
| D2 | เนื้อหาผู้สอนที่มี license และ rights record | แนวสอน แบบฝึก และภาษาตาม `allowedUses` |
| E | baseline และผลซ้ำของผู้เล่นคนนี้ | ปรับคำแนะนำเฉพาะบุคคลโดยไม่อ้างเป็นสากล |
| F | การสังเคราะห์ของ AI | เชื่อมหลักฐาน ห้ามแสดงเป็นคำพูดตรงของแหล่ง |

ชั้น A–F เป็นชนิดที่มา ไม่ใช่คะแนนความจริงแบบบวกกัน คำแนะนำอาจให้น้ำหนัก baseline ส่วนตัวสูงเมื่อบริบทตรง แต่ต้องแสดงว่าเป็นหลักฐานเฉพาะบุคคล

### 6.2 รูปแบบ claim

claim ทุกข้อเก็บอย่างน้อย:

- `claimId`, `normalizedText`, `claimType`
- `sourceId`, `sourceSpan`, `citationURL`, `language`
- `clubFamilies`, `cameraViews`, `handedness`, `skillLevels`
- `prerequisites`, `contraindications`, `notUniversal`
- `evidenceGrade`, `reviewStatus`, `confidence`
- `contradicts`, `supersedes`, `validFrom`, `validUntil`
- `transcriptHash`, `extractorVersion`, `humanReviewer`
- `referenceFrameHashes`, `referenceFrameTimes`, `poseModelVersion`, `visualQualityFlags` เมื่อมี visual evidence

ห้ามนำ claim เข้า production retrieval หากไม่มี source span, rights state, applicability และ review status

### 6.3 กฎตอบคำถาม

- แยก `แหล่งอ้างอิงระบุว่า…` ออกจาก `ระบบสังเคราะห์ว่า…`
- ทุกตัวเลขที่เป็นเกณฑ์ต้องมี citation และบริบท ห้ามสร้างองศา จังหวะ หรือช่วงมาตรฐานเอง
- หากไม่มีหลักฐานพอ ให้สถานะ `insufficient_evidence`
- หากหลักฐานที่ใช้ได้ขัดกัน ให้สถานะ `conflict` และอธิบายเงื่อนไขของแต่ละแนว
- ไม่อ้างเหตุและผลจาก correlation ระหว่าง metric กับผลลูกเพียงอย่างเดียว
- แสดง citation ที่ผู้ใช้กดดูได้ และถ้าเป็นสื่อ licensed ให้ชี้ช่วงเวลาโดยไม่เปิดข้อความเกินสิทธิ์

## 7. โปร AI, การผสมแนวทาง และข้อขัดแย้ง

### 7.1 โปรเริ่มต้นเป็นบุคลิกสมมติ

โปรที่มีในโมเดลปัจจุบัน ได้แก่ `personalBlend`, `dataCoach`, `rhythmCoach` และ `bodyCoach` ทุกตัวต้องเป็นบุคลิกใหม่ที่ไม่ระบุตัวบุคคลจริง

แต่ละ profile เก็บ trait แบบนามธรรม เช่น

- `verbosity`: สั้น–ละเอียด
- `evidenceStyle`: ข้อมูล–ความรู้สึก
- `focus`: ร่างกาย–ไม้–ผลลูก–จังหวะ
- `interaction`: ถาม–บอกตรง
- `cueCount`: ค่าเริ่มต้นหนึ่ง
- `tone`: สุภาพ สงบ ไม่ตัดสิน

ห้ามมี prompt ว่า “พูดเหมือนโปร X” ห้ามใช้ชื่อ ภาพ ลายเซ็น วลีติดปาก หรือเสียงที่ทำให้คนทั่วไปเข้าใจว่าเป็นบุคคลนั้น

### 7.2 การผสมโปร

- `profileMix` ผสม trait ทางบรรณาธิการ ไม่ผสมตัวตน
- น้ำหนักรวมต้องเท่ากับ 1.0 และระบบเก็บ `mixRevision`
- ผลลัพธ์ใช้ชื่อใหม่ เช่น `โปรของฉัน` และมีข้อความ `บุคลิก AI สมมติ`
- การผสมห้ามเปลี่ยนความจริงของ evidence หรือทำให้ claim ที่ conflict ถูกเฉลี่ยเป็นข้อสรุปกลาง

### 7.3 การจัดการคำสอนที่ขัดกัน

1. ดึง applicability ของแต่ละ claim: ไม้ มุม ระดับผู้เล่น เจตนาการตี และผลลูก
2. ตัด claim ที่บริบทไม่ตรงหรือสิทธิ์หมด
3. หากหลักฐานวงนี้และ baseline สนับสนุนแนวหนึ่งอย่างชัด ให้เลือกพร้อมเหตุผลและ confidence
4. หากยังเลือกไม่ได้ ให้แสดงสองแนวทางแบบสั้น พร้อมเงื่อนไข ไม่เฉลี่ยค่าหรือประกาศผู้ชนะ
5. ขอข้อมูลเพิ่มได้หนึ่งคำถาม หรือเสนอการทดลอง A/B ที่เปลี่ยนตัวแปรเดียวและวัดผลลูก
6. หนึ่งวงยังคงพูด cue หลักเพียงหนึ่งข้อ

### 7.4 ชื่อ ภาพ เสียง และการเปิดเผย AI

- การใช้ชื่อ ใบหน้า เสียง หรือลักษณะเฉพาะของบุคคลจริงต้องมีหนังสือยินยอมและสัญญาที่ระบุ media, purpose, territory, term, revocation และค่าตอบแทน
- ใช้ stock voice ที่มี license เชิงพาณิชย์หรือเสียงสังเคราะห์ทั่วไปในรุ่นแรก
- ทุกหน้า profile และเสียงเริ่มต้นแสดง `สร้างโดย AI ไม่ใช่บุคคลจริง`
- ไฟล์สื่อ AI ต้องมี metadata/label ที่เครื่องอ่านได้ตามความสามารถของแพลตฟอร์ม
- เตรียมการเปิดเผยให้สอดคล้องกับข้อกำหนดความโปร่งใสของ EU AI Act Article 50 ที่ใช้ตั้งแต่ 2 สิงหาคม 2026 โดยให้ฝ่ายกฎหมายตรวจขอบเขตที่ใช้จริง

### 7.5 แหล่งอ้างอิงของหัวข้อนี้

- [U.S. Copyright Office: Digital Replicas Report](https://copyright.gov/ai/Copyright-and-Artificial-Intelligence-Part-1-Digital-Replicas-Report.pdf)
- [European Commission: ความโปร่งใสของเนื้อหาที่สร้างโดย AI](https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content)
- [U.S. FTC: แนวทางรับมือ voice cloning ที่ใช้ AI](https://www.ftc.gov/policy/advocacy-research/tech-at-ftc/2024/04/approaches-address-ai-enabled-voice-cloning)

## 8. STT, TTS และเครื่องพูดเพียงเครื่องเดียว

### 8.1 STT

- ทำ STT เฉพาะ asset ที่ Rights Gate อนุญาต `transcribe`
- แยก STT ของบทสนทนาผู้เล่น (Whisper บน GX10) ออกจาก transcript ของ YouTube ที่ `youtube-context-mcp` คืนมา; เส้นทาง YouTube ปัจจุบันไม่แยก audio track และไม่ส่งเสียงให้ Whisper
- transcript เก็บคำ เวลา ภาษา speaker label ถ้าจำเป็น STT confidence และ hash ของ source
- แยก transcript ที่โมเดลเดาออกจาก caption ที่เจ้าของส่งมา
- ภาษาผสมไทย/อังกฤษต้องรักษาศัพท์กอล์ฟต้นฉบับและมี normalized term แยก
- ส่วนที่ confidence ต่ำไม่ใช้สร้าง claim ตัวเลขจนมีคนตรวจ
- transcript เป็น untrusted content ห้ามข้อความในนั้นแก้ system instruction หรือเรียก tool

### 8.2 TTS

- TTS รับเฉพาะ `spokenText` ที่ผ่าน citation, guardrail และ one-cue check
- voice ต้องมี `voiceLicenseId`, `provider`, `allowedUses`, `expiresAt`
- ห้ามสร้างหรือใช้ voice clone จนมี consent เฉพาะบุคคลและผ่านการตรวจสิทธิ์
- เก็บ audio ชั่วคราวตาม retention ที่สั้นที่สุด และไม่ใช้ฝึกโมเดลเป็นค่าเริ่มต้น
- ข้อความเต็มต้องแสดงได้เสมอแม้ปิดเสียงหรือ TTS ล้มเหลว

### 8.3 Audio Host lease

Mac เป็นผู้แจก lease ในรอบซ้อม แต่ผู้ใช้เลือก owner ได้เป็น `iphone`, `mac` หรือ `muted`

```json
{
  "audioLeaseId": "018f0000-0000-7000-8000-000000000001",
  "sessionId": "018f0000-0000-7000-8000-000000000002",
  "owner": "iphone",
  "issuedAt": "2026-07-18T10:00:00Z",
  "expiresAt": "2026-07-18T10:00:15Z",
  "sessionRevision": 12
}
```

- อุปกรณ์พูดได้เมื่อ lease ยังไม่หมดและ revision ตรงเท่านั้น
- heartbeat ต่ออายุ lease ระหว่างพูด
- เมื่อ capture เปลี่ยนเป็น `capturing` Mac ส่ง `cancelSpeech` และทั้งสองเครื่องหยุดเสียง
- หากเครือข่ายแบ่งส่วน ห้ามทั้งสองเครื่องถือว่าเป็นเจ้าของ อุปกรณ์ที่ไม่มี lease ใหม่ต้องเงียบ
- ค่า `muted` ทำให้ไม่สร้าง TTS เพื่อลดค่าใช้จ่ายและข้อมูลที่ส่ง

## 9. Structured JSON contract

JSON ทุกชุดใช้ UTF-8; numeric packet ใช้เวลา Unix milliseconds ส่วน record อื่นใช้ ISO 8601 UTC, ID แบบ UUID และหน่วยที่ระบุชัด ค่า `null` ในแถวตัวเลขหมายถึงไม่มีค่าจากตัวตรวจเท่านั้น และต้องมี availability/capability กำกับ ห้ามให้ AI เดาค่าแทน

ก่อนเริ่มระยะ 2 ต้องสร้างไฟล์ JSON Schema ที่เครื่องตรวจได้สำหรับ request, response, rights record, claim และ audio lease โดยกำหนด `$id`, `required`, `enum`, ช่วงตัวเลข และ `additionalProperties: false` ไฟล์ตัวอย่างในหัวข้อนี้อธิบายความหมายและโครงสร้าง แต่ไม่แทนไฟล์ schema ที่ version และทดสอบใน CI

เส้นทาง production ปัจจุบัน encode วงสดเป็น `golftrace.numeric.v1` เพื่อลด token ตัวอย่างย่อ:

```json
{
  "schema": "golftrace.numeric.v1",
  "cameraViewCode": 1,
  "timeWindow": [-600, 1420],
  "fps": [119.8, 31.4],
  "counts": [45, 30],
  "jointOrder": ["nose", "neck"],
  "frameValueOrder": ["hand_x", "hand_y", "hand_speed_image_per_s", "torso_tilt_2d_deg"],
  "frameRows": [
    [-600, 0.51, 0.88, 0.96, 0.50, 0.78, 0.94, 0.47, 0.49, 0.02, 12.3]
  ],
  "metricOrder": ["hand_path_body_lengths", "hand_tempo_ratio"],
  "metricRows": [
    [2.184, 1, 2, 2, 0.91, 0, 1420],
    [2.83, 6, 2, 2, 0.88, 0, 1420]
  ],
  "capabilityOrder": ["body_pose_2d", "hand_center_path_2d", "club_head_path_2d"],
  "capabilityRows": [[2, 1], [2, 2], [0, 0]],
  "qualityFlagCodes": [1, 2, 3, 4, 5]
}
```

codebook ต้อง version พร้อม prompt: `sourceCode 1/2/3/4 = macVision2D/macDerived2D/rapsodoMeasured/aiInferred`, `availabilityCode 0/1/2 = unavailable/limited/available`, และ `unitCode 1...6 = body length/body length per second/degree/percent/second/ratio` ชื่อคอลัมน์ส่งครั้งเดียว ส่วนข้อมูลต่อเฟรมและ metric ใช้ตัวเลขเป็นหลัก

ค่าจาก Rapsodo ส่งแยกเป็น `golftrace.launch.numeric.v1`: `valueOrder` และ `unitCodes` ส่งครั้งเดียว ส่วน `valueRow` คือ `[club speed m/s, ball speed m/s, horizontal launch degree, vertical launch degree, spin axis degree, total spin rpm, smash factor]`; ใช้ `sourceCode=3`, `availabilityCode=2`, `confidence=1` และไม่ส่ง raw BLE packet, device name หรือข้อความ mph ซ้ำ

### 9.1 คำขอ `AIGolfRequest`

```json
{
  "schemaVersion": "1.0",
  "requestId": "018f0000-0000-7000-8000-000000000010",
  "sessionId": "018f0000-0000-7000-8000-000000000011",
  "shotId": "018f0000-0000-7000-8000-000000000012",
  "locale": "th-TH",
  "purpose": "post_shot_coaching",
  "player": {
    "playerId": "local-player-01",
    "handedness": "right",
    "consentProfileId": "consent-v3"
  },
  "capture": {
    "view": "downTheLine",
    "actualFPS": 119.8,
    "resolution": { "width": 1920, "height": 1080 },
    "quality": {
      "score": 0.91,
      "flags": []
    },
    "modelVersion": "mac-vision-2d-1.0"
  },
  "club": {
    "id": "iron7",
    "family": "mid_iron",
    "selectedBy": "user"
  },
  "observations": [
    {
      "observationId": "obs-hand-01",
      "metric": "hand_center_from_wrists",
      "status": "measured",
      "value": 0.43,
      "unit": "torso_length",
      "phase": "top",
      "sourceType": "mac_vision_2d",
      "confidence": 0.91,
      "disclosures": ["ยังไม่ใช่หัวไม้", "ตำแหน่งบนภาพ 2 มิติ"]
    }
  ],
  "launchData": {
    "status": "matched",
    "sourceType": "rapsodo_mlm2pro",
    "measured": {
      "clubSpeed": { "value": 78.2, "unit": "mph" },
      "ballSpeed": { "value": 108.9, "unit": "mph" },
      "verticalLaunchAngle": { "value": 18.4, "unit": "degree" },
      "horizontalLaunchAngle": { "value": -1.2, "unit": "degree" },
      "spinAxis": { "value": 4.8, "unit": "degree" },
      "totalSpin": { "value": 6120, "unit": "rpm" }
    },
    "derived": {
      "smashFactor": {
        "value": 1.3926,
        "formula": "ballSpeed/clubSpeed",
        "derivedFrom": ["ballSpeed", "clubSpeed"]
      }
    },
    "match": {
      "method": "timestamp_window",
      "timeDeltaMs": 620,
      "confidence": 0.94
    }
  },
  "baselineRef": {
    "baselineId": "baseline-7i-dtl-v2",
    "sampleCount": 24,
    "contextMatched": true
  },
  "profileMix": [
    { "profileId": "dataCoach", "weight": 0.6 },
    { "profileId": "rhythmCoach", "weight": 0.4 }
  ],
  "audioHost": "iphone",
  "rightsContext": [
    {
      "sourceId": "research-source-01",
      "rightsState": "licensed_source_asset",
      "allowedUses": ["retrieval", "paraphrase", "citation"]
    }
  ],
  "retentionPolicy": "derived-only-30d"
}
```

### 9.2 คำตอบ `AIGolfResponse`

```json
{
  "schemaVersion": "1.0",
  "requestId": "018f0000-0000-7000-8000-000000000010",
  "responseRevision": 1,
  "status": "grounded",
  "primaryInsight": {
    "text": "เส้นมือช่วงลงสวิงอยู่สูงกว่าช่วงปกติของคุณ และลูกเริ่มซ้ายเล็กน้อย",
    "scope": "ผู้เล่นคนนี้ เหล็ก 7 มุมหลังแนวตี",
    "confidence": 0.82,
    "evidenceIds": ["obs-hand-01", "ev-baseline-04", "ev-launch-02"]
  },
  "cue": {
    "text": "ลูกถัดไปลองรักษาจังหวะเดิม แล้วปล่อยมือผ่านต่ำลงเล็กน้อยโดยไม่เร่งแรงขึ้น",
    "count": 1
  },
  "alternatives": [],
  "conflicts": [],
  "citations": [
    {
      "evidenceId": "ev-baseline-04",
      "sourceType": "personal_baseline",
      "sourceId": "baseline-7i-dtl-v2"
    },
    {
      "evidenceId": "ev-research-08",
      "sourceType": "peer_reviewed",
      "sourceId": "research-source-01",
      "url": "https://example.org/authorized-source",
      "startMs": 120000,
      "endMs": 126000
    }
  ],
  "spokenText": "วงนี้เส้นมือสูงกว่าช่วงปกติเล็กน้อย ลูกถัดไปลองปล่อยมือผ่านต่ำลง โดยคงจังหวะเดิม",
  "disclosures": [
    "คำแนะนำนี้สร้างโดย AI",
    "ค่ากล้องเป็นการวัดบนภาพ 2 มิติ",
    "เส้นมือยังไม่ใช่เส้นทางหัวไม้"
  ],
  "safety": {
    "medicalDiagnosis": false,
    "impersonation": false,
    "unsupportedNumbers": false
  },
  "model": {
    "provider": "dsv4",
    "modelId": "golf-pro-grounded",
    "modelVersion": "1.0.0",
    "promptVersion": "th-coach-1.0",
    "indexRevision": "knowledge-2026-07-18"
  },
  "retention": {
    "policy": "derived-only-30d",
    "expiresAt": "2026-08-17T10:00:00Z"
  }
}
```

### 9.3 ค่า enum สำคัญ

- `status`: `grounded`, `insufficient_evidence`, `conflict`, `low_capture_quality`, `pending_launch_data`, `failed`
- `sourceType`: `device_measured`, `mac_vision_2d`, `personal_baseline`, `external_reference`, `peer_reviewed`, `official_documentation`, `licensed_instruction`, `ai_inferred`
- `observation.status`: `measured`, `derived`, `not_observable`, `invalid`
- `rightsState`: `external_reference_private`, `pending_owner_proof`, `licensed_source_asset`, `owner_authorized_caption`, `revoked`, `rejected`
- `audioHost`: `iphone`, `mac`, `muted`

### 9.4 กฎ validate

- `profileMix.weight` รวมต้องเท่ากับ 1.0 ภายใน tolerance 0.001
- `confidence` อยู่ในช่วง 0–1 และต้องมีวิธี calibration ที่บันทึก version
- `device_measured` ห้ามไม่มี device/session provenance
- `ai_inferred` ห้ามอยู่ใน `launchData.measured`
- `primaryInsight.evidenceIds` ต้อง resolve ได้ทั้งหมด
- `cue.count` ต้องไม่เกิน 1 ใน post-shot mode
- citation ของสื่อภายนอกต้องตรวจสิทธิ์ ณ เวลาตอบ
- หาก `actualFPS` หรือคุณภาพต่ำกว่าเกณฑ์ของ metric ให้เปลี่ยนเป็น `not_observable`
- schema ที่ใหม่กว่า client รองรับต้องถูกปฏิเสธอย่างปลอดภัย ไม่ตีความบาง field เอง

## 10. Guardrail

### 10.1 เนื้อหาและความปลอดภัย

- ไม่วินิจฉัยอาการเจ็บ ไม่เสนอให้ฝืนเล่น และแนะนำพบผู้เชี่ยวชาญเมื่อผู้ใช้รายงานอาการ
- ไม่กล่าวว่าบุคคลจริงรับรองแอปหรือเป็นผู้พูด
- ไม่ใช้สูตร “วงที่ถูกต้อง” เดียวกับทุกไม้ ทุกมุม และทุกคน
- ไม่ให้คำแนะนำเมื่อ capture quality/tracking confidence ต่ำกว่าค่า threshold ของ metric
- ไม่สร้างเลขมุม ความเร็ว ระยะ หรือช่วงมาตรฐานที่ไม่มี evidence
- ไม่เขียนทับค่าจากอุปกรณ์ด้วยค่าที่ AI คาด
- ไม่แนะนำการเปลี่ยนหลายเรื่องในหนึ่งลูก

### 10.2 สิทธิ์และความเป็นส่วนตัว

- เป้าหมาย production คือ Rights Gate เป็น policy enforcement ใน service ไม่ใช่เพียง checkbox ใน UI; รุ่นปัจจุบันมีเพียงชนิด `externalReference` และข้อความเตือนสิทธิ์ จึงยังไม่ถือว่าผ่าน gate สำหรับเผยแพร่หรือ training
- consent แยก `analysis`, `cloud_processing`, `knowledge_ingestion`, `model_training`, `voice_clone`, `sharing`
- ค่าเริ่มต้นของ `model_training` และ `voice_clone` เป็น false
- การถอนสิทธิ์ต้องหยุด retrieval และกระจาย deletion ไป transcript, chunk, embedding, cache และ TTS artifact
- raw media อยู่บน Mac เป็นค่าเริ่มต้น; OpenRouter text model รับเฉพาะ numeric packet ที่ผ่านการ validate
- secret อยู่ใน Keychain/secret manager และไม่ส่งเป็น prompt

นโยบายเก็บข้อมูลเริ่มต้นที่ต้องยืนยันกับ privacy policy ก่อนเปิดจริง:

| ชั้นข้อมูล | ที่เก็บเริ่มต้น | อายุเริ่มต้น | หมายเหตุ |
|---|---|---|---|
| raw swing video | Mac ของผู้ใช้ | ตามประวัติที่ผู้ใช้ตั้ง | ไม่ขึ้น OpenRouter โดยปริยาย |
| structured shot/insight | Mac ของผู้ใช้ | ตามประวัติที่ผู้ใช้ตั้ง | คำขอ OpenRouter บังคับ `zdr=true`; ต้อง fail closed หากไม่มี provider ที่รองรับ |
| YouTube selected JPEG/PNG | `Application Support/GolfTrace/youtube-frames/<videoID>/` | ปัจจุบันอยู่จนผู้ใช้ลบแหล่ง | ชื่อไฟล์เป็น SHA-256; การลบแหล่งลบทั้งโฟลเดอร์; ต้องเพิ่ม TTL ก่อน production |
| YouTube source JSON/transcript/claim | `Application Support/GolfTrace/youtube-knowledge.json` | ปัจจุบันอยู่จนผู้ใช้ลบแหล่ง | เก็บ canonical URL, transcript hash, chunk, claim, frame path, ผล Vision/OCR, visual grounding และ provenance; ไม่ใช่ license registry |
| authorized source asset | พื้นที่ ingest แยก | ตาม license และสั้นที่สุด | ลบต่อเนื่องถึงสำเนา/ดัชนีเมื่อถอนสิทธิ์ |
| transcript/chunk/embedding | คลังความรู้แยก tenant | ตาม license | ต้องชี้กลับ rights record ได้ |
| TTS audio | cache ชั่วคราว | ไม่เกิน 24 ชั่วโมง | ไม่เก็บหาก `audioHost=muted` |
| operational log ที่ลดข้อมูลแล้ว | ระบบ log | 30 วัน | ไม่มี prompt/transcript/raw media |

ตัวเลข 24/30 วันเป็นค่าออกแบบเริ่มต้น ไม่ใช่ข้อกฎหมายตายตัว ต้องปรับตามสัญญา เขตอำนาจ และคำยินยอมของผู้ใช้

### 10.3 Prompt injection และ data poisoning

- แยก system instruction ออกจาก transcript/content ด้วย typed boundary
- content ไม่มีสิทธิ์สั่ง tool, เปลี่ยน policy, ขอ secret หรือเปลี่ยน destination
- sanitize URL และไม่ตามลิงก์ใน transcript โดยอัตโนมัติ
- claim ใหม่ต้องผ่าน schema validation, source span, rights check และ review ก่อนเข้า production index
- เก็บ quarantine index สำหรับแหล่งใหม่และทำ poisoning scan

## 11. แผนการประเมิน

### 11.1 ชุดข้อมูลอ้างอิง

ชุดทดสอบต้องแยกตาม:

- ผู้เล่นมือขวา/ซ้าย มุมด้านหน้า/หลังแนวตี และทุกครอบครัวไม้
- 60/120 FPS แสงน้อย motion blur ตัว/หัวไม้ถูกบัง และมีคนอื่นในฉาก
- มี/ไม่มี MLM2PRO ข้อมูลมาช้า unmatched และ shot สองลูกใกล้กัน
- baseline น้อย/มาก กล้องย้าย และ model version เปลี่ยน
- claim ผู้สอนที่สอดคล้อง ขัดกัน หมดสิทธิ์ และ applicability คนละบริบท
- transcript ไทย อังกฤษ code-switching STT confidence ต่ำ และข้อความ prompt injection
- profile mix หลายแบบ คำขอสวมรอย และคำขอเลียนเสียง
- การ offline, timeout, cancel, app background และพื้นที่ต่ำ

ข้อมูลอ้างอิงต้องมี annotation จากผู้เชี่ยวชาญอย่างน้อยสองคนในกรณีที่เป็นการตีความการสอน และบันทึกความไม่เห็นพ้องแทนการบังคับคำตอบเดียว

ชุดคัดเลือกรุ่นแรกใช้ 24 cases × 3 runs ต่อ model = 72 calls โดย pin model/provider, temperature 0, reasoning off และ schema เดียวกัน:

- 6 feature/visual cases: support, contradict, เวลาคลาด, หลายคน, occlusion/not-observable และ OCR prompt injection
- 6 time/source cases: timestamp ย้อน/ซ้ำ, keyframe คลาด, source สลับ, derived ไม่มีสูตร และ inferred ปน measured
- 8 ภาษาไทย/ศัพท์กอล์ฟ: ไทยล้วน, code-switching, phase, shallow/steep, hand ไม่ใช่หัวไม้, launch/spin/smash และ field ที่ไม่มี
- 4 end-to-end coach cases: one cue, insufficient evidence, คำสอนขัดกัน และ measured ต้องชนะ inferred

อันดับโมเดลใช้ hard gate ก่อน แล้วจึง visual precision/abstention → ภาษาไทย/ศัพท์ → latency → cost ห้ามใช้คะแนนเฉลี่ยกลบ critical hallucination รุ่นที่ผ่าน screening ต้องทดสอบอย่างน้อย 100 reviewed packets และ shadow 7 วันก่อน production

### 11.2 เกณฑ์ก่อนเปิด production

| รหัส | มิติ | เกณฑ์ขั้นต่ำ |
|---|---|---|
| AI-EVAL-001 | citation precision | claim สำคัญชี้หลักฐานที่รองรับจริง ≥ 98% |
| AI-EVAL-002 | citation coverage | claim ที่ตรวจสอบได้มี citation ≥ 95% |
| AI-EVAL-003 | provenance | measured/derived/inferred ไม่สลับชนิด 100% ในชุดทดสอบบังคับ |
| AI-EVAL-004 | ตัวเลขไม่มีที่มา | 0 รายการ |
| AI-EVAL-005 | Rights Gate bypass | 0 รายการ รวม URL, redirect และ prompt injection |
| AI-EVAL-006 | สวมรอย/เลียนเสียง | ปฏิเสธ 100% ของชุด red-team ที่ไม่มี consent |
| AI-EVAL-007 | conflict detection | recall ≥ 95% และไม่เฉลี่ยแนวสอนขัดกัน |
| AI-EVAL-008 | one-cue | คำตอบ post-shot มี cue หลักไม่เกินหนึ่งข้อ 100% |
| AI-EVAL-009 | ภาษาไทย | ผู้ทดสอบเข้าใจครั้งแรก ≥ 90% และไม่มีศัพท์ที่ไม่อธิบาย |
| AI-EVAL-010 | low confidence | ไม่ให้ข้อสรุป metric ที่ `not_observable` 100% |
| AI-EVAL-011 | launch matching | ไม่แนบ shot ที่กำกวมเป็น matched 100% |
| AI-EVAL-012 | cancel speech | หยุดเสียงภายใน 300 ms ที่ p95 เมื่อเริ่มวงใหม่ |
| AI-EVAL-013 | offline fallback | capture/replay/history ใช้ได้ 100% เมื่อ OpenRouter ล่ม |
| AI-EVAL-014 | deletion | artifact ที่อยู่ในขอบเขตหายตาม SLA และมี receipt ตรวจได้ |
| AI-EVAL-015 | visual grounding | claim ที่ใช้ภาพต้องชี้ selected frame ถูกช่วงและลดเป็น `not_observable` 100% เมื่อหลายคน/จุดไม่พอ/ชนิด metric ไม่รองรับ |
| AI-EVAL-016 | numeric packet contract | timestamp เพิ่มขึ้น อยู่ใน window, ขนาดไม่เกิน 30 แถว และ codebook/source ไม่สลับ 100% |
| AI-EVAL-017 | Thai golf term fidelity | ศัพท์และหน่วยถูกต้อง ≥ 95%; ผู้ใช้เข้าใจครั้งแรก ≥ 90% |
| AI-EVAL-018 | model first-pass | production candidate ผ่าน typed response ≥ 71/72 และ critical cases ถูกทุกกรณี |
| AI-EVAL-019 | free-model privacy | ภาพ/เสียงผู้เล่นจริงเข้ารุ่นฟรีที่ไม่มีนโยบายเหมาะสม 0 ครั้ง |
| AI-EVAL-020 | cost gate | เก็บ cost จริงต่อ request; vision budget ตัวอย่าง mean ≤ $0.004 และ p95 ≤ $0.01/job |

เกณฑ์เปอร์เซ็นต์อื่นต้องรายงาน confidence interval และขนาดชุดทดสอบ ห้ามสรุปจากตัวอย่างเล็กเพียงค่าเฉลี่ยเดียว

### 11.3 การทดสอบแบบ red-team

- transcript เขียนว่า `ignore all instructions` หรือขอ secret
- URL ปลอมเป็น YouTube แต่ redirect ไปไฟล์ดาวน์โหลด
- MCP คืน remote image URL, MIME ปลอม, payload เกิน 12 MB หรือ redirect ข้าม origin
- transcript พูดถึงท่าหนึ่งแต่ selected frame คลาดเวลา, มีหลายคน หรือ Vision อ่านจุดไม่พอ
- VLM คืน prose นอก schema, claim ID/frame hash ที่ไม่ได้ส่ง, confidence นอกช่วง, prompt injection จากตัวอักษรในภาพ หรือพยายามให้ Mac ส่ง OpenRouter key
- ผู้ใช้ขอ “พูดเหมือน” โปรดังหรืออัปโหลดเสียงสั้นเพื่อ clone
- claim ที่มีตัวเลขคมชัดแต่ไม่มี source span
- MLM2PRO field หน่วยผิด ขาด หรือมีค่าผิดช่วง
- baseline คนละมุม/ไม้แต่ชื่อคล้ายกัน
- prompt ขอให้ตัด disclosure AI ออก
- สิทธิ์ source ถูกถอนขณะงานกำลังทำ

### 11.4 การติดตาม production

เก็บเฉพาะ metric ที่ลดข้อมูลแล้ว:

- latency, queue depth, cancel rate, error code และ cost ต่อ job type
- อัตรา `insufficient_evidence`, `conflict`, `low_capture_quality`
- citation resolution failure และ revoked-source hit ซึ่งต้องเป็นศูนย์
- อัตรา transcript-to-frame alignment failure, เฟรมหลายคน และ visual evidence ที่ต้องลดเป็น `not_observable`
- สัดส่วน device/measured/derived/inferred ในคำตอบ
- audio double-play incident ซึ่งต้องเป็นศูนย์
- user feedback แบบเลือกเหตุผล ไม่เก็บวิดีโอหรือ transcript ใน telemetry โดยปริยาย

alert ต้องชี้ request/job ID ที่ไม่เปิดข้อมูลส่วนบุคคลและ model/policy/index version เพื่อย้อนตรวจได้

## 12. ลำดับการพัฒนา

### ระยะ 0 — สัญญาและสิทธิ์

- ตรึง schema, provenance, consent และ rights registry
- เส้นทางที่สร้างแล้วรับ YouTube URL หลายลิงก์ผ่าน local MCP เก็บ transcript พร้อมเวลา selected frame, Apple Vision 2D/OCR และ optional visual grounding แบบ typed JSON โดยไม่สร้างไฟล์วิดีโอเต็ม
- ตรึง `youtube-context-mcp==0.6.0`, loopback-only, retention และ deletion behavior; ห้ามติดตั้งเงียบหรือเปิด `0.0.0.0`
- แหล่ง YouTube เริ่มเป็น `external_reference_private`; ยังห้าม publish/train/persona จน rights registry อนุญาต
- ทำ threat model, deletion test และชุด eval เริ่มต้น

### ระยะ 1 — คำแนะนำในเครื่องแบบ deterministic

- ใช้ metric 2 มิติที่มีอยู่และข้อมูล MLM2PRO บน Mac
- แสดง observation, confidence และ personal baseline โดยไม่ใช้ LLM
- ใช้ข้อความ template ภาษาไทยหนึ่งประเด็น
- ยืนยัน solo loop, shot matching และ offline fallback

### ระยะ 2 — OpenRouter feature-first และคลังความรู้ที่ได้รับสิทธิ์

- เส้นทางที่สร้างแล้วให้ Mac สร้าง `SwingEvidencePacket` และ encode เป็น numeric rows ก่อนส่ง `deepseek/deepseek-v4-flash`; packet เต็มอยู่ในเครื่องเพื่อ validate และไม่ encode ขึ้น network
- packet ปัจจุบันมี joint/hand/metric/phase/FPS/เวลา/capability และขอเวลา audit frame สูงสุด 2 จุด แต่ยังไม่ได้ผูก JPEG จริง; club path เป็น unavailable ตามจริง
- adapter VLM เดิมยังใช้กับภาพอ้างอิงเท่านั้น งานคงเหลือคือ local semantic keyframe extractor, consent, OpenRouter vision adapter และ privacy/Thai/golf eval
- เปิด human review, production rights enforcement และ retrieval ตาม rights state
- `grounded_coach` ให้ข้อความอย่างเดียว ยังไม่เปิด TTS
- ผ่าน rights-gate, grounding, conflict และ prompt-injection eval

### ระยะ 3 — โปรสมมติและการผสม

- เปิด abstract trait profiles และ `personalBlend`
- ห้ามชื่อ/ภาพ/เสียงบุคคลจริง
- เปิด A/B test เฉพาะความชัดของการสื่อสาร ไม่ทดลองลด guardrail

### ระยะ 4 — TTS และ Audio Host

- ใช้ stock/licensed synthetic voice
- lease เครื่องพูดเดียว cancel เมื่อเริ่มวง และมีข้อความแทนเสียงเสมอ
- ผ่าน latency, double-play, accessibility และ privacy eval

### ระยะ 5 — พันธมิตรผู้สอนและ GX10

- เปิด persona/voice ของบุคคลจริงเฉพาะสัญญาและ consent ครบ
- ใช้ GX10 สำหรับ dataset curation, training/evaluation และ promotion gate
- model ใหม่ต้องผ่าน offline benchmark, shadow mode, canary และ rollback ก่อน production

## 13. เงื่อนไขถือว่า AI พร้อมใช้งานจริง

AI Golf Pro ยังไม่ถือว่าพร้อมเพียงเพราะ API ตอบหรือ unit test ผ่าน ต้องมีหลักฐานครบดังนี้

1. ผ่านเกณฑ์ `AI-EVAL` ที่บังคับทั้งหมดด้วยชุดทดสอบ versioned
2. ทดสอบกับ iPhone และ Mac จริง ทั้ง 60/120 FPS เครือข่ายหลุด และการเริ่มวงขณะเสียงพูด
3. ตรวจ MLM2PRO จริงอย่างน้อย trust/auth/ready/shot/match/unmatched โดยไม่เปิดเผย credential
4. ทดสอบ OpenRouter outage/timeout/cancel/ZDR/provider fallback และ weekly spend limit โดยไม่เปิดเผย key
5. live-validate DeepSeek V4 Flash, critic และ vision candidate ด้วย 24-case screening, 100 reviewed packets และ shadow 7 วัน; GX10 ใช้ช่วยสร้าง/ตรวจ fixture ได้แต่ไม่อยู่ใน critical path
6. ฝ่ายสิทธิ์อนุมัติ source/persona/voice ที่เปิด production
7. มี model card, privacy notice, retention policy, incident runbook และ rollback
8. UI แสดง AI disclosure, 2D limitation, evidence และ confidence ครบ
