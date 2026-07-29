# GolfTraceCamera

แอปกล้องคู่กับ GolfTrace บน Mac สำหรับ iOS 18 ขึ้นไป แอปขอสิทธิ์ใช้กล้อง แสดงภาพจากกล้องหลัง และตรวจโหมดที่อุปกรณ์รองรับจริง ถ้ามีโหมด 1080p 120 FPS จะเลือกให้อัตโนมัติ ส่วน 1080p 60/240 FPS และ 4K 120 FPS จะแสดงเฉพาะเมื่อกล้องรองรับตรงตามค่านั้น

เมื่อกล้องพร้อม แอปจะค้นหา GolfTrace บน Mac เชื่อมต่อ และส่งภาพให้อัตโนมัติ ภาพถูกบีบอัดเป็น H.264 ด้วยชิปของ iPhone แล้วส่งผ่าน TCP แบบหน่วงต่ำ หาก Mac หรือเครือข่ายหลุด แอปจะค้นหาและเชื่อมต่อใหม่เอง หน้าจอจะไม่ดับขณะแอปอยู่ด้านหน้า และแอปไม่บันทึกรูปหรือวิดีโอลง iPhone

ให้ใช้ **1080p 120 FPS** เป็นค่าหลักสำหรับภาพสด การถอดรหัส การหาตำแหน่งร่างกาย การวาดเส้น และการวิเคราะห์ทั้งหมดทำบน Mac แอป iPhone มีหน้าที่รับและบีบอัดภาพเท่านั้น ส่วน 240 FPS ควรถือว่าเป็นโหมดทดลอง จนกว่าจะทดสอบครบทั้งการบีบอัด การส่ง และการถอดรหัสบนเครื่องจริง

ภาพสดส่งผ่านเครือข่ายระหว่างสองเครื่อง จึงไม่ต้องต่อสาย USB-C สายยังมีประโยชน์สำหรับชาร์จไฟ ติดตั้งรุ่นพัฒนา และอ่านบันทึกเหตุการณ์ของอุปกรณ์ การอัปเดตแบบใช้งานทั่วไปควรส่งผ่าน TestFlight หรือ App Store

> ความปลอดภัย: การค้นหาใช้ Bonjour (`_golftrace._tcp`) และ transport ปัจจุบันเป็น TCP ที่ยังไม่มี TLS หรือการยืนยันตัวตนของ Mac ใช้เฉพาะ LAN ที่เชื่อถือได้ และอย่าส่งภาพผ่าน Wi‑Fi สาธารณะ

## Clone และเตรียมเครื่อง

โปรเจกต์นี้ใช้ Swift 5, iOS 18 SDK และ XcodeGen 2.42.0 ขึ้นไป ต้องใช้ Xcode 16 ขึ้นไปสำหรับ iOS 18:

```sh
git clone git@github.com:natdanai-pae/mywhoop.git
cd mywhoop
brew install xcodegen
(cd apps/GolfTraceCamera && xcodegen generate)
```

`apps/GolfTraceCamera/project.yml` เป็น source of truth ของโปรเจกต์ ส่วน wire protocol และ settings ที่ใช้ร่วมกับ Mac อยู่ใน `apps/Shared/` ไฟล์ `.xcodeproj`, `.build/`, DerivedData และ provisioning ของเครื่องพัฒนาเป็นไฟล์ generated/local และไม่ควร commit

repository ไม่เก็บ development team หรือ signing material เมื่อต้องการติดตั้งบน iPhone ให้เปิด `apps/GolfTraceCamera/GolfTraceCamera.xcodeproj` ใน Xcode เลือก target `GolfTraceCamera` แล้วเลือก Team ของตนเองใน **Signing & Capabilities** อย่าเพิ่ม `DEVELOPMENT_TEAM`, provisioning profile, certificate หรือ device identifier ลงใน `project.yml`

แอป iPhone ไม่มี environment variable หรือ `.env` ที่ต้องตั้งค่า และไม่มี runtime secret การอนุญาตกล้องกับ Local Network ทำผ่าน iOS เมื่อระบบถาม

## Build, test และ run

```sh
# รันจาก root ของ repository
xcodebuild -project apps/GolfTraceCamera/GolfTraceCamera.xcodeproj \
  -scheme GolfTraceCamera \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build

xcrun simctl list devices available
xcodebuild -project apps/GolfTraceCamera/GolfTraceCamera.xcodeproj \
  -scheme GolfTraceCamera \
  -destination 'platform=iOS Simulator,name=<SIMULATOR_NAME>' \
  test
```

สำหรับ run แบบครบเส้นทาง ให้เปิดโปรเจกต์ใน Xcode เลือก iPhone ที่ลงทะเบียนกับ Team ของตนเองแล้วกด Run จากนั้นเปิด GolfTrace บน Mac ก่อนเปิดแอปนี้ ทั้งสองเครื่องต้องอยู่ LAN เดียวกันและ iPhone ต้องปลดล็อกพร้อมเปิดแอปไว้ด้านหน้า

ต้องใช้ iPhone หรือ iPad จริงเพื่อตรวจสิทธิ์กล้อง ภาพสด, FPS จริง, hardware H.264 และการ reconnect ตัวจำลอง iOS ใช้ยืนยันได้เฉพาะ build และ unit tests ดู checklist เครื่องจริงใน [`../GolfTrace/TOMORROW-DEBUG.md`](../GolfTrace/TOMORROW-DEBUG.md)
