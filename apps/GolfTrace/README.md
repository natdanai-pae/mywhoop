# วิเคราะห์วงสวิง (GolfTrace)

แอป Mac สำหรับรับภาพสดจาก iPhone แล้วประมวลผลวงสวิงบน MacBook Pro โดยตรง เส้นทางหลักใช้แอป `กล้องวงสวิง` บน iPhone ส่งภาพ 1080p 120 FPS ผ่านเครือข่าย ส่วนระบบ Continuity Camera ของ Apple เป็นทางสำรอง 60 FPS

```text
iPhone 1080p120 → บีบอัด H.264 → ส่งผ่านเครือข่าย → Mac ถอดภาพและวิเคราะห์
Continuity Camera 1080p60                    → ทางสำรอง
MLM2PRO → Bluetooth → Mac → จับคู่ค่าลูกกับวงสวิงตามเวลาและบันทึกไว้ด้วยกัน
คลิปที่คัดเลือก → ชุดข้อมูล → เทรนบน GX10 → นำโมเดลกลับมารันบน Mac ในอนาคต
YouTube MCP → เฟรมที่เลือกใน cache → Apple Vision/OCR → Qwen3-VL บน GX10 (เลือกเปิด) → typed JSON → DeepSeek
```

เส้นทางภาพจาก iPhone ใช้ Bonjour เพื่อค้นหา Mac แล้วส่ง H.264 ผ่าน TCP โดยตรง ปัจจุบันยังไม่มี TLS หรือการยืนยันตัวตนของเครื่องปลายทาง จึงควรใช้เฉพาะเครือข่ายภายในที่เชื่อถือได้ ไม่ควรใช้ Wi‑Fi สาธารณะหรือเครือข่ายที่มีผู้ใช้ไม่รู้จัก

## สถานะที่ยืนยันได้

- ฟีเจอร์ที่ระบุว่า “มีในโค้ด” ด้านล่างมี implementation และชุดทดสอบอยู่ใน repository
- เคยตรวจเส้นทาง 1920×1080 ที่ 120 FPS ด้วย iPhone 17 Pro Max หนึ่งรอบ แต่ผลเดิมไม่ใช่การรับรอง build ปัจจุบันหรือฮาร์ดแวร์ทุกชุด
- การรับภาพต่อเนื่อง การ reconnect การสร้างคลิป คุณภาพ Vision และการติดตั้งบน iPhone ยังต้องทดสอบตาม [TOMORROW-DEBUG.md](TOMORROW-DEBUG.md) บนเครื่องจริง
- ตัวเชื่อม MLM2PRO, OpenRouter, MCP และ GX10 มีขอบเขตบางส่วนที่ยังต้องยืนยันกับบริการหรืออุปกรณ์จริง ดูรายละเอียดใน [MVP-STATUS.md](MVP-STATUS.md)

## โครงสร้างที่ควรรู้

```text
apps/
├── GolfTrace/
│   ├── Sources/
│   │   ├── AICoach/             # การตั้งค่า AI, OpenRouter และ Whisper
│   │   ├── Analysis/            # evidence packet และ storyboard
│   │   ├── HighSpeedTransport/  # รับ H.264 จาก iPhone
│   │   ├── Knowledge/           # YouTube MCP, Vision/OCR และ optional VLM
│   │   ├── LaunchMonitor/       # MLM2PRO และการจับคู่ค่าลูก
│   │   ├── Records/             # ประวัติและ retention
│   │   └── Replay/              # buffer, เขียนคลิป และเล่นย้อนหลัง
│   ├── Tests/                   # unit/integration tests ฝั่ง macOS
│   └── project.yml              # source of truth สำหรับ XcodeGen
├── GolfTraceCamera/
│   ├── Sources/                 # กล้อง iOS, H.264 encoder และ TCP sender
│   ├── Tests/                   # tests ที่รันบน iOS Simulator
│   └── project.yml
└── Shared/                      # wire protocol, settings และ assets ที่ใช้ร่วมกัน
```

ไฟล์ `.xcodeproj` และ `.build/` เป็นไฟล์ที่สร้างใหม่ได้และไม่ใช่ source of truth ให้แก้ `project.yml` หรือ source ที่เกี่ยวข้องแล้วรัน XcodeGen ใหม่

## เริ่มต้นสำหรับนักพัฒนา

ต้องมี Mac ที่ติดตั้ง Xcode ซึ่งรองรับ Swift 6 และ iOS 18 SDK (Xcode 16 ขึ้นไป), Command Line Tools และ XcodeGen 2.42.0 ขึ้นไป ตัวแอป Mac ตั้ง deployment target เป็น macOS 14 และแอปกล้องตั้งเป็น iOS 18

```sh
git clone git@github.com:natdanai-pae/mywhoop.git
cd mywhoop

brew install xcodegen
xcodegen --version

(cd apps/GolfTrace && xcodegen generate)
(cd apps/GolfTraceCamera && xcodegen generate)
```

### ตั้งค่า signing ในเครื่อง

repository ไม่เก็บ Apple development team, provisioning profile หรือ certificate ของผู้พัฒนา หลัง generate โปรเจกต์แล้วให้เปิดแต่ละ `.xcodeproj` ใน Xcode เลือก target ของแอป ไปที่ **Signing & Capabilities** แล้วเลือก Team ของตนเอง การตั้งค่านี้เป็นข้อมูลเฉพาะเครื่องและไม่ควรเพิ่ม `DEVELOPMENT_TEAM` ลงใน `project.yml` หรือ commit ไฟล์ provisioning/certificate

### Build และ test

รันจาก root ของ repository:

```sh
# macOS app
xcodebuild \
  -project apps/GolfTrace/GolfTrace.xcodeproj \
  -scheme GolfTrace \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project apps/GolfTrace/GolfTrace.xcodeproj \
  -scheme GolfTrace \
  -destination 'platform=macOS' \
  test

# iOS app: compile โดยไม่ต้องใช้กล้องจริง
xcodebuild \
  -project apps/GolfTraceCamera/GolfTraceCamera.xcodeproj \
  -scheme GolfTraceCamera \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build

# เลือกชื่อ simulator ที่มีอยู่ แล้วใช้ชื่อนั้นแทน <SIMULATOR_NAME>
xcrun simctl list devices available
xcodebuild \
  -project apps/GolfTraceCamera/GolfTraceCamera.xcodeproj \
  -scheme GolfTraceCamera \
  -destination 'platform=iOS Simulator,name=<SIMULATOR_NAME>' \
  test
```

การ build/test บน Simulator ไม่ยืนยันสิทธิ์กล้อง FPS จริง VideoToolbox บนอุปกรณ์ หรือการเชื่อมต่อเครือข่าย สำหรับการ run แบบครบเส้นทาง ให้เปิดสองโปรเจกต์ใน Xcode เลือก Mac และ iPhone ที่ลงทะเบียนกับ Team ของตนเอง แล้วกด Run โดยเปิดแอป Mac ก่อน

### Environment variables และ credential

การ run แอปตามปกติ **ไม่ต้องใช้ environment variable และไม่ใช้ไฟล์ `.env`** ค่า endpoint/model ที่เลือกได้ตั้งผ่าน UI ส่วน secret ไม่ถูกเก็บใน repository:

- OpenRouter API key และ Rapsodo Simulator connector secret กรอกผ่าน `SecureField` ในแอปและเก็บใน macOS Keychain
- endpoint ของ YouTube MCP, GX10 Whisper และ GX10 VLM ตั้งในหน้า AI Golf Pro; อย่าใส่ secret ลง source, shell history, log หรือ `.env`
- `GOLFTRACE_LIVE_MCP_URL` เป็นตัวเลือกสำหรับเปิด live MCP test
- `GOLFTRACE_VALIDATION_VIDEO_DIR` เป็นตัวเลือกสำหรับ external-video canary tests; directory นี้อาจมีภาพบุคคลและต้องอยู่นอก Git
- `DEVELOPMENT_TEAM` เป็น Xcode build setting สำหรับ signing ในเครื่อง ไม่ใช่ runtime secret และไม่ควร commit ค่า

ไม่มี frontend web หรือ backend service ใน repository ที่ต้องเปิดเพื่อใช้กล้อง การวิเคราะห์ในเครื่อง ประวัติ และ replay บริการ AI/อุปกรณ์ต่อไปนี้เป็น optional:

- OpenRouter/DeepSeek เป็นบริการภายนอก ตั้ง HTTPS endpoint, model และ API key ในหน้า AI Golf Pro; ไม่มี local server ใน repository
- YouTube MCP เป็น local process ที่ต้องเปิดเฉพาะเมื่อใช้คลัง YouTube ดูคำสั่งในหัวข้อ [ตั้งค่า YouTube คำพูด + ภาพอ้างอิง](#ตั้งค่า-youtube-คำพูด--ภาพอ้างอิง)
- GX10 Whisper และ Qwen3-VL ต้องมี endpoint ที่ผู้ดูแล deploy แยกต่างหาก repository นี้มี client เท่านั้น และยังไม่มีผล live validation ของ deployment ปัจจุบัน
- MLM2PRO เป็น hardware integration ที่ไม่จำเป็นต่อเส้นทางกล้อง และยังต้องยืนยันอุปกรณ์จริงด้วย credential ที่ได้รับอนุญาต

## สิ่งที่ทำได้ในรุ่นนี้

- เปิดรอ iPhone และเชื่อมต่อกันอัตโนมัติ ไม่มีปุ่มเชื่อมซ้ำในทางใช้งานปกติ
- รับและถอด H.264 ด้วยชิปของ Mac พร้อมแยกตัวเลข FPS ของกล้อง การส่ง การรับ การถอด และการวิเคราะห์
- ตรวจตำแหน่งร่างกายด้วย Vision บน Mac และวาดโครงกระดูกทับภาพสด
- ตรวจการเริ่มและจบวงสวิงอัตโนมัติหลังผู้เล่นวางมือนิ่ง
- วาดเส้นทางกึ่งกลางมือแบบลดความสั่น และชดเชยเมื่อข้อมือข้างหนึ่งหายชั่วคราว
- สรุปค่าที่วัดได้อย่างปลอดภัยจากภาพ 2 มิติ เช่น ทางมือเทียบความยาวลำตัว จังหวะมือ และการเปลี่ยนแนวลำตัวในภาพ
- เก็บ H.264 ย้อนหลังแบบจำกัดหน่วยความจำ แล้วสร้างคลิป `.mov` โดยไม่บีบอัดซ้ำ
- เล่นย้อนหลังที่ 0.25×, 0.5×, 1× ลากเวลา และดูทีละเฟรม
- เก็บประวัติพร้อมคลิปใน Mac อัตโนมัติ สูงสุด 20 วงหรือ 4 GiB แล้วตัดวงเก่าสุดก่อน
- เข้าคิวคลิปของวงที่ตีติดกันตามลำดับ และรอเขียนคลิป/ประวัติให้เสร็จก่อนปิดแอป
- หมุนภาพ 180° พร้อมกันทั้งภาพ การตรวจท่า และเส้นทับภาพ
- ตรวจภาพหยุดและพยายามเชื่อมต่อใหม่เอง
- ค้นหา MLM2PRO จาก Mac และให้ยืนยันเครื่องจริงครั้งแรกก่อนส่งข้อมูลยืนยันสิทธิ์
- รับ Club Speed, Ball Speed, มุมยิงแนวนอน/แนวตั้ง, Spin Axis และ Total Spin แล้วคำนวณ Smash Factor
- จับคู่ค่าจาก MLM2PRO กับวงสวิงภายในช่วงเวลา 8 วินาที และเก็บค่าที่ยังไม่มีคู่ลงดิสก์ทันทีเพื่อไม่ให้ข้อมูลหาย
- เก็บ Secret สำหรับตัวเชื่อม Rapsodo ไว้ใน Keychain ที่ผูกกับ Mac เครื่องนี้ โดยไม่ฝังค่าไว้ในซอร์สหรือเขียนลง log
- รับ YouTube ได้หลายลิงก์ในครั้งเดียว แล้วสร้างรายการงานแยกสถานะคำถอดเสียง การจัดความรู้ และภาพอ้างอิงของแต่ละวิดีโอ
- ใช้ MCP ใน Mac อ่าน transcript พร้อมเวลาและดึง JPEG/PNG เฉพาะช่วงที่โปรกำลังอธิบาย โดยไม่เก็บไฟล์วิดีโอเต็มเรื่อง
- ใช้ Apple Vision อ่านจุดร่างกาย ค่าท่าทาง 2 มิติ และ OCR ข้อความสั้นบนเฟรมที่เลือก แล้วผูกกับข้อความหลักจากแหล่ง, URL, เวลาอ้างอิง, รหัสตรวจสอบภาพ และรุ่นของ Vision
- มี adapter แบบเลือกเปิดสำหรับส่งเฉพาะเฟรม YouTube ที่เลือกและ cache แล้วให้ Qwen3-VL บน GX10 ตีความ จากนั้นตรวจคำตอบเป็น typed JSON ก่อนเก็บเป็นหลักฐานประเภท AI inferred
- ส่งให้ DeepSeek-V4-Flash เฉพาะข้อความ แหล่งอ้างอิง ผล Apple Vision/OCR และ typed JSON จาก VLM ไม่ส่งพิกเซลภาพอ้างอิงหรือภาพสด 120 FPS ให้ DeepSeek

เคยตรวจเส้นทางจริงด้วย iPhone 17 Pro Max แล้วที่ **1920×1080, 120 FPS** ตั้งแต่จับภาพ บีบอัด ส่ง รับ จนถึงถอดภาพบน Mac โดยไม่พบการถอดภาพล้มเหลวในรอบนั้น ผลนี้เป็นประวัติการทดสอบ ไม่ใช่ผล UAT ของ build ปัจจุบัน

## วิธีเปิดใช้งาน

หลัง generate และตั้งค่า signing แล้ว สามารถสร้างและเปิด build แยกจาก source ได้ดังนี้:

```sh
xcodebuild \
  -project apps/GolfTrace/GolfTrace.xcodeproj \
  -scheme GolfTrace \
  -configuration Debug \
  -derivedDataPath /tmp/GolfTrace-DerivedData \
  build
open /tmp/GolfTrace-DerivedData/Build/Products/Debug/GolfTrace.app
```

เปิดแอป Mac ก่อน แล้วเปิดแอป `กล้องวงสวิง` บน iPhone ที่ปลดล็อกอยู่ ทั้งสองแอปจะค้นหาและเชื่อมต่อกันเอง ควรให้ iPhone กับ Mac อยู่เครือข่ายเดียวกันและเปิดแอป iPhone ไว้ด้านหน้า

การส่งภาพสด **ไม่ต้องเสียบ USB-C** เพราะภาพเดินทางผ่านเครือข่าย สายยังมีประโยชน์สำหรับชาร์จไฟ ติดตั้งแอปรุ่นพัฒนา และเก็บข้อความตรวจสอบจาก Xcode

## ตั้งค่า YouTube คำพูด + ภาพอ้างอิง

GolfTrace ใช้ [youtube-context-mcp](https://github.com/realiti4/youtube-context-mcp) เพียงตัวเดียวสำหรับคำถอดเสียงพร้อมเวลาและเฟรมที่เลือก แอปไม่ติดตั้งบริการนี้เองแบบเงียบ และไม่ส่ง BDA API key ให้ MCP

ติดตั้ง Python 3.12, FFmpeg และ MCP เวอร์ชันที่ตรึงไว้บน Mac:

```sh
brew install python@3.12 ffmpeg

PYTHON="$(brew --prefix python@3.12)/bin/python3.12"
TOOLS="$HOME/Library/Application Support/GolfTrace/Tools/youtube-context"

"$PYTHON" -m venv "$TOOLS/venv"
"$TOOLS/venv/bin/python" -m pip install "youtube-context-mcp==0.6.0"
"$TOOLS/venv/bin/python" -c \
  "import importlib.metadata as m; assert m.version('youtube-context-mcp') == '0.6.0'; print('พร้อม: youtube-context-mcp 0.6.0')"
```

เริ่มบริการใน Terminal หนึ่งหน้าต่างก่อนเปิด/ใช้งานคลัง YouTube:

```sh
TOOLS="$HOME/Library/Application Support/GolfTrace/Tools/youtube-context"
"$TOOLS/venv/bin/youtube-context-mcp" \
  --transport http \
  --host 127.0.0.1 \
  --port 8765
```

ถ้าต้องการให้บริการเปิดเองตอน login สามารถสร้าง LaunchAgent ชื่อ
`com.bda.golftrace.youtube-context-mcp` ในเครื่องของผู้พัฒนาได้ โดย repository
นี้ไม่ได้ติดตั้ง LaunchAgent ให้อัตโนมัติ หลังตั้งค่าแล้วตรวจสถานะได้ด้วย:

```sh
launchctl print gui/$(id -u)/com.bda.golftrace.youtube-context-mcp
lsof -nP -iTCP:8765 -sTCP:LISTEN
```

คำสั่งเริ่มแบบ Terminal ด้านบนใช้ได้เสมอโดยไม่ต้องสร้าง LaunchAgent แอปไม่ดาวน์โหลดหรือติดตั้ง package เอง

ที่อยู่เชื่อมต่อ (endpoint) ในแอปต้องเป็น `http://127.0.0.1:8765/mcp` จากนั้นทำตามนี้:

1. เปิด `AI Golf Pro` แล้วไปที่ `แหล่งสอนจาก YouTube · คำพูด + ภาพอ้างอิง`
2. เปิด `ตั้งค่า MCP ขั้นสูง` แล้วกด `ทดสอบคำพูด + ภาพ`; สถานะพร้อมต้องยืนยันว่ามีทั้ง `get_transcript` และ `get_video_frame`
3. วางหลาย URL ได้โดยแยกด้วยช่องว่างหรือขึ้นบรรทัดใหม่ แล้วกด `เพิ่มลิงก์ทั้งหมด` แต่ละลิงก์เป็นงานอิสระ จึงอาจเสร็จไม่เรียงตามลำดับ
4. แอปอ่านคำถอดเสียงและดึงภาพตัวอย่างตามเวลาได้แม้ยังไม่ได้ตั้ง DSV4; เมื่อ DeepSeek-V4-Flash พร้อม ระบบจะสกัดข้อความหลักแล้วดึงภาพรอบ claim ให้ละเอียดขึ้นอัตโนมัติ
5. ตรวจภาพตัวอย่าง จำนวน `Vision ใช้ได้`, `OCR` และ `VLM ผูกภาพได้`; ตัวเลข VLM นับผล grounding เป็นหัวข้อ ไม่ใช่จำนวนเฟรม กรอบส้มหมายถึงหลักฐาน pose ยังไม่พอ ส่วนกรอบเขียวหมายถึง Apple Vision พบจุดร่างกายที่ใช้ได้
6. หากต้องการทำใหม่ กด `ให้ DeepSeek อ่านใหม่` หรือ `อ่านภาพใหม่` ที่แหล่งนั้นได้ โดยไม่ต้องมีคนเฝ้าหน้า Mac ระหว่างตี

### Qwen3-VL บน GX10 แบบเลือกเปิด

ใน `AI Golf Pro · GX10 + DSV4` เปิด `ให้ GX10 อ่านความหมายภาพ` แล้วช่อง `ที่อยู่ VLM` และ `โมเดล VLM` จึงจะปรากฏ ค่า model เริ่มต้นคือ `Qwen/Qwen3-VL-8B-Instruct` ส่วน endpoint ตั้งใจปล่อยว่างไว้จนกว่าจะมีบริการ OpenAI-compatible ที่ยืนยันแล้วบน GX10

เส้นทางนี้อ่านเฉพาะ JPEG/PNG ของ YouTube ที่แอปเลือกและ cache ไว้แล้ว ไม่อ่านภาพสดจาก iPhone และไม่อยู่ในเส้นทางรับ 120 FPS ตัว adapter และ schema typed JSON มีอยู่ในซอร์สแล้ว แต่การ deploy endpoint/model และการตอบจริงของ Qwen3-VL บน GX10 **ยังไม่ได้ตรวจด้วยเครื่องจริง** จึงยังห้ามตีความว่าการ build ผ่านหรือการเปิด toggle แปลว่า hardware พร้อมใช้งาน

VLM ไม่ใช้ API key ของ DSV4 และแอปไม่ส่ง key นั้นไป endpoint ของ VLM ผลที่ผ่านการตรวจ schema เท่านั้นจึงถูกส่งต่อเป็น structured evidence ให้ DeepSeek; พิกเซลภาพไม่ถูกส่งให้ DeepSeek-V4-Flash

ห้ามเปลี่ยน `--host` เป็น `0.0.0.0` เพราะบริการนี้ไม่มีระบบยืนยันตัวตนของ GolfTrace ค่า loopback `127.0.0.1` ทำให้รับคำขอจาก Mac เครื่องนี้เท่านั้น หากปิด Terminal หรือบริการหยุด กล้องสด การเล่นย้อนหลัง และประวัติยังทำงาน แต่การเพิ่มแหล่ง YouTube ใหม่จะหยุดจนเปิด MCP อีกครั้ง

### ข้อมูลที่บันทึกและลบ

- เส้นทางที่แอปเรียกไม่สร้างไฟล์หรือ cache วิดีโอเต็มเรื่อง ภายใน MCP ใช้ `yt-dlp` แบบ `skip_download` หา stream แล้วให้ FFmpeg อ่านข้อมูลชั่วคราวเท่าที่จำเป็นเพื่อสร้างเฟรม จึงยังรับ byte ของสื่อจาก YouTube แต่ไม่เขียน full-video file ลงดิสก์
- เก็บเฉพาะ JPEG/PNG ที่เลือกไว้ใต้ `~/Library/Application Support/GolfTrace/youtube-frames/<videoID>/` โดยชื่อไฟล์มาจาก SHA-256
- เก็บ URL, transcript hash, transcript chunk, claim, timecode, path ของภาพ, ผล Vision/OCR และผล VLM แบบ typed JSON ใน `~/Library/Application Support/GolfTrace/youtube-knowledge.json`
- กด `ลบ` ที่แหล่งนั้นเพื่อลบรายการใน JSON และโฟลเดอร์เฟรมที่เลือกของ video ID นั้น
- รุ่นปัจจุบันยังไม่มีการลบตามอายุอัตโนมัติ ภาพและข้อมูลจึงอยู่จนผู้ใช้ลบแหล่ง
- URL สาธารณะไม่ใช่ใบอนุญาตให้เผยแพร่ ทำ dataset ฝึกโมเดล เลียนเสียง/บุคลิก หรืออ้างว่าโปรรับรองแอป งานเหล่านี้ต้องมีสิทธิ์และ consent แยกต่างหาก

## ทำไม Continuity Camera เห็นเพียง 60 FPS

Continuity Camera คือระบบที่ macOS มอง iPhone เป็นกล้องภายนอก ระบบนี้เหมาะเป็นทางสำรอง แต่เส้นทางที่ตรวจแล้วส่งได้สูงสุด 60 FPS ในงานนี้ การรับ 120 FPS จึงใช้แอป iPhone จับภาพจากเซนเซอร์โดยตรง แล้วส่ง H.264 ให้ Mac

คำว่า H.264 คือรูปแบบบีบอัดวิดีโอเพื่อลดปริมาณข้อมูล ส่วนการตรวจร่างกาย การจับวง การสรุปผล และการเล่นย้อนหลังยังทำบน Mac ไม่ได้ย้ายการประมวลผลไป iPhone

## ข้อจำกัดที่ต้องเข้าใจ

- เส้นปัจจุบันคือกึ่งกลางข้อมือ ยังไม่ใช่เส้นทางหัวไม้
- ค่าจากไหล่และสะโพกเป็นภาพฉาย 2 มิติ ไม่ใช่องศาหมุน 3 มิติจริง
- ภาพ YouTube ที่เลือกเป็นเฟรมเดี่ยวหลายจุดรอบคำพูด ไม่ใช่การวิเคราะห์การเคลื่อนไหวต่อเนื่อง และเวลาอาจคลาดจาก keyframe ราว 1–2 วินาที
- Apple Vision ในเส้นทางภาพอ้างอิงยังไม่เห็น clubhead, shaft หรือลูก ส่วน OCR อ่านได้เพียงข้อความสั้นและอาจผิด การเปิด Qwen3-VL เพิ่มข้อสังเคราะห์จากภาพ แต่ไม่เปลี่ยนให้เป็นค่าที่วัดจริงหรือข้อมูล 3 มิติ
- adapter Qwen3-VL และ typed schema มีในโค้ดแล้ว แต่ deployment ของ endpoint/model บน GX10 ยังต้องตรวจด้วยเครื่องจริง เมื่อปิด VLM หรือ endpoint ใช้ไม่ได้ ระบบยังใช้ Apple Vision/OCR ได้ตามเดิม
- DeepSeek-V4-Flash เป็นโมเดลสร้างข้อความและไม่ได้รับพิกเซลภาพโดยตรง โดยรับเฉพาะ typed JSON ที่ผ่านการตรวจจาก Qwen3-VL พร้อม confidence และ limitations
- ถ้าภาพมีหลายคน จุดร่างกายไม่พอ หรือ claim กับภาพไม่สอดคล้อง ต้องถือว่าใช้ยืนยันไม่ได้ ไม่ให้ AI เดาเติม
- ค่า Ball Speed, Club Speed, มุมยิง และสปินมาจาก MLM2PRO ไม่ได้คำนวณจากกล้อง ส่วนระยะ Carry ยังไม่มีใน packet ชุดที่ยืนยันแล้ว
- ทาง Bluetooth และตัวอ่านข้อมูลผ่านการทดสอบด้วยข้อมูลจำลองแล้ว แต่ยังต้องยืนยันการ authenticate และรับหนึ่งช็อตกับ MLM2PRO เครื่องจริง
- การเชื่อมตรงต้องใช้ Secret สำหรับ Simulator connector ที่ Rapsodo อนุญาตโดยเฉพาะ การกด Third-party ในแอป Rapsodo อย่างเดียวไม่สร้าง Secret นี้ และแอปไม่ฝังหรือดึง credential ของผู้อื่นมาใช้
- GX10 ไม่อยู่ในเส้นทางสด 120 FPS งาน Qwen3-VL ที่เลือกเปิดใช้เฉพาะเฟรม YouTube ใน cache แบบ asynchronous ส่วนการเทรน/ประเมินยังใช้คลิปที่คัดเลือกแยกต่างหาก
- 240 FPS ยังเป็นโหมดทดลอง เป้าหมายหลักที่รองรับตอนนี้คือ 1080p120
- iPhone ต้องเปิดเครื่อง ปลดล็อก และเปิดแอปกล้องไว้ด้านหน้า จึงจะส่งภาพได้

ขั้นตอนตรวจเครื่องจริงอยู่ใน [TOMORROW-DEBUG.md](TOMORROW-DEBUG.md) และขอบเขตความพร้อมอยู่ใน [MVP-STATUS.md](MVP-STATUS.md)
