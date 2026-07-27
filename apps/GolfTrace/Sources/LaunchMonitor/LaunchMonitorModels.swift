import Foundation

/// A single launch-monitor measurement received by the Mac.
///
/// Speed is stored in SI units so persisted data is unambiguous. The MPH
/// accessors are presentation helpers for the units golfers commonly use.
struct LaunchMonitorShot: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let receivedAt: Date
  /// ลำดับช็อตภายในรอบที่แอปเปิดอยู่ ไม่ใช่รหัสถาวรจากอุปกรณ์
  /// งานบันทึกและกันข้อมูลซ้ำข้ามการเปิดแอปต้องใช้ `id` ซึ่งเป็น UUID
  let deviceShotID: UInt64
  let clubHeadSpeedMetersPerSecond: Double
  let ballSpeedMetersPerSecond: Double
  let horizontalLaunchAngleDegrees: Double
  let verticalLaunchAngleDegrees: Double
  let spinAxisDegrees: Double
  let totalSpinRPM: UInt16
  let source: String
  let rawMeasurement: Data

  init(
    id: UUID = UUID(),
    receivedAt: Date,
    deviceShotID: UInt64,
    clubHeadSpeedMetersPerSecond: Double,
    ballSpeedMetersPerSecond: Double,
    horizontalLaunchAngleDegrees: Double,
    verticalLaunchAngleDegrees: Double,
    spinAxisDegrees: Double,
    totalSpinRPM: UInt16,
    source: String = "MLM2PRO-BLE",
    rawMeasurement: Data
  ) {
    self.id = id
    self.receivedAt = receivedAt
    self.deviceShotID = deviceShotID
    self.clubHeadSpeedMetersPerSecond = clubHeadSpeedMetersPerSecond
    self.ballSpeedMetersPerSecond = ballSpeedMetersPerSecond
    self.horizontalLaunchAngleDegrees = horizontalLaunchAngleDegrees
    self.verticalLaunchAngleDegrees = verticalLaunchAngleDegrees
    self.spinAxisDegrees = spinAxisDegrees
    self.totalSpinRPM = totalSpinRPM
    self.source = source
    self.rawMeasurement = rawMeasurement
  }

  var clubHeadSpeedMPH: Double {
    clubHeadSpeedMetersPerSecond * 2.236_936_292_054_4
  }

  var ballSpeedMPH: Double {
    ballSpeedMetersPerSecond * 2.236_936_292_054_4
  }

  /// A derived value, not an additional metric supplied by the device.
  var smashFactor: Double? {
    guard clubHeadSpeedMetersPerSecond > 0 else { return nil }
    return ballSpeedMetersPerSecond / clubHeadSpeedMetersPerSecond
  }
}

enum LaunchMonitorBluetoothAvailability: Equatable, Sendable {
  case poweredOff
  case unauthorized
  case unsupported
  case resetting
  case unknown

  var statusText: String {
    switch self {
    case .poweredOff:
      "Bluetooth ปิดอยู่ กรุณาเปิด Bluetooth บน Mac"
    case .unauthorized:
      "แอปยังไม่ได้รับอนุญาตให้ใช้ Bluetooth"
    case .unsupported:
      "Mac เครื่องนี้ไม่รองรับ Bluetooth ที่ MLM2PRO ต้องใช้"
    case .resetting:
      "Bluetooth กำลังเริ่มระบบใหม่"
    case .unknown:
      "กำลังตรวจสอบ Bluetooth"
    }
  }
}

enum LaunchMonitorConnectionState: Equatable, Sendable {
  case idle
  case bluetoothUnavailable(LaunchMonitorBluetoothAvailability)
  case scanning
  case awaitingDeviceTrust(id: UUID, deviceName: String)
  case connecting(deviceName: String)
  case discoveringServices(deviceName: String)
  case awaitingAuthorization(deviceName: String, userID: UInt32?)
  case arming(deviceName: String)
  case ready(deviceName: String)
  case stopping
  case failed(message: String)

  var statusText: String {
    switch self {
    case .idle:
      "ยังไม่ได้เชื่อม MLM2PRO"
    case .bluetoothUnavailable(let availability):
      availability.statusText
    case .scanning:
      "กำลังค้นหา MLM2PRO ใกล้เคียง"
    case .awaitingDeviceTrust(_, let deviceName):
      "พบ \(deviceName) รอคุณยืนยันว่าเป็นอุปกรณ์ที่ไว้ใจ"
    case .connecting(let deviceName):
      "กำลังเชื่อมต่อ \(deviceName)"
    case .discoveringServices(let deviceName):
      "เชื่อมต่อ \(deviceName) แล้ว กำลังเตรียมช่องข้อมูล"
    case .awaitingAuthorization(_, let userID):
      if let userID {
        "พบ MLM2PRO แล้ว รอสิทธิ์ Third-party สำหรับผู้ใช้ \(userID)"
      } else {
        "พบ MLM2PRO แล้ว กำลังขอสิทธิ์ Third-party"
      }
    case .arming(let deviceName):
      "\(deviceName) กำลังเตรียมพร้อมรับค่าการตี"
    case .ready(let deviceName):
      "\(deviceName) พร้อมรับค่าการตี"
    case .stopping:
      "กำลังหยุดการเชื่อมต่อ MLM2PRO"
    case .failed(let message):
      message
    }
  }
}

struct MLM2PROAuthorizationChallenge: Equatable, Sendable {
  let userID: UInt32
  let deviceName: String
}

enum LaunchMonitorEvent: Equatable, Sendable {
  case stateChanged(LaunchMonitorConnectionState)
  case discoveredDevice(id: UUID, name: String, rssi: Int)
  case deviceTrustRequired(id: UUID, name: String)
  case authorizationRequired(MLM2PROAuthorizationChallenge)
  case shot(LaunchMonitorShot)
  case batteryLevel(percent: Int)
  case error(message: String)
}
