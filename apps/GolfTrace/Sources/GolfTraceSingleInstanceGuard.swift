import Darwin
import Foundation

/// เก็บสิทธิ์การทำงานของ GolfTrace เพียงหนึ่งสำเนาในเครื่องเดียวกัน
///
/// ใช้ advisory file lock ซึ่งระบบปฏิบัติการจะปลดให้เองหากแอปปิดหรือค้าง
/// จึงไม่ทิ้งสถานะล็อกค้างไว้เหมือนการเขียน flag ลง UserDefaults
final class GolfTraceSingleInstanceGuard {
  enum AcquisitionResult: Equatable {
    case acquired
    case anotherInstanceRunning
    case unavailable
  }

  private let lockURL: URL
  private var fileDescriptor: Int32?

  init(lockURL: URL? = nil) {
    self.lockURL = lockURL ?? Self.defaultLockURL()
  }

  deinit {
    release()
  }

  /// ขอสิทธิ์เป็น GolfTrace สำเนาที่ควบคุมอุปกรณ์ได้
  /// - Returns: `.anotherInstanceRunning` เมื่อมีสำเนาอื่นถือ lock อยู่แล้ว
  func acquire() -> AcquisitionResult {
    if fileDescriptor != nil {
      return .acquired
    }

    do {
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      return .unavailable
    }

    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      return .unavailable
    }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      close(descriptor)
      return lockError == EWOULDBLOCK ? .anotherInstanceRunning : .unavailable
    }

    fileDescriptor = descriptor
    return .acquired
  }

  /// ปลดสิทธิ์เมื่อกำลังปิดแอป เพื่อให้การเปิดครั้งถัดไปเริ่มได้ทันที
  func release() {
    guard let fileDescriptor else { return }
    flock(fileDescriptor, LOCK_UN)
    close(fileDescriptor)
    self.fileDescriptor = nil
  }

  private static func defaultLockURL() -> URL {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory

    return
      base
      .appendingPathComponent("GolfTrace", isDirectory: true)
      .appendingPathComponent("single-instance.lock", isDirectory: false)
  }
}
