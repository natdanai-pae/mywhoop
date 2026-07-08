# IPhoneMirror

Mac app สำหรับ mirror หน้าจอ iPhone ผ่านสาย USB โดยใช้ iPhone screen feed แบบเดียวกับ QuickTime Player.

## วิธีใช้

1. เสียบ iPhone กับ Mac ด้วยสาย USB
2. ปลดล็อก iPhone แล้วกด Trust This Computer
3. รัน:

   ```sh
   cd /Users/maripae/Documents/PaeWhoop/tools/IPhoneMirror
   ./run.sh
   ```

4. ถ้า macOS ถามสิทธิ์ Camera ให้กด Allow เพราะ macOS จัด iPhone screen feed ไว้ใต้ capture permission เดียวกัน
5. เลือก iPhone ใน Device แล้วกด Start Mirror

ถ้าไม่เจอ iPhone ให้เปิด QuickTime Player > File > New Movie Recording แล้วดูว่า dropdown ข้างปุ่ม record มี iPhone หรือไม่ จากนั้นกลับมากด Refresh ในแอปนี้อีกครั้ง

## Control mode ทดลอง

แอปมีปุ่ม `Control Off/On` สำหรับส่ง mouse click/drag เป็น tap/swipe ไปที่ iPhone ผ่าน WebDriverAgent.

ต้องมี WebDriverAgent ฟังอยู่ที่ `http://127.0.0.1:8100` ก่อน:

```sh
iproxy 8100:8100 -u 00008150-000251E9349A401C
```

แล้วรัน WebDriverAgentRunner ลง iPhone:

```sh
xcodebuild \
  -project /Users/maripae/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'id=00008150-000251E9349A401C' \
  DEVELOPMENT_TEAM=YG7X8EC59V \
  CODE_SIGN_STYLE=Automatic \
  test
```

ถ้า Xcode ขึ้นว่า `The developer disk image could not be mounted on this device` ให้เปิด Xcode > Window > Devices and Simulators แล้วรอให้ Xcode prepare iPhone หรืออัปเดต Xcode/iOS platform support ให้ตรงกับ iOS ในเครื่องก่อน.
