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

หมายเหตุ: วิธีนี้เป็น mirror/preview หน้าจอ ไม่ใช่ remote control iPhone. การ control iPhone จาก Mac ผ่าน USB ยังถูกจำกัดโดย Apple.
