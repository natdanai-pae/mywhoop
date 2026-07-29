import Combine
import Foundation

/// เก็บเฉพาะสถานะว่ามีรหัสเชื่อมต่อหรือไม่ โดยไม่เผยค่า Secret กลับเข้า UI
@MainActor
final class RapsodoCredentialSettings: ObservableObject {
  @Published private(set) var hasStoredSecret = false
  @Published private(set) var statusText = "ยังไม่ได้บันทึกรหัสเชื่อมต่อจาก Rapsodo"

  let tokenProvider: RapsodoSimulatorTokenProvider

  private let store: RapsodoSimulatorKeychainStore

  init(store: RapsodoSimulatorKeychainStore = RapsodoSimulatorKeychainStore()) {
    self.store = store
    tokenProvider = RapsodoSimulatorTokenProvider(secretStore: store)
    refreshStatus()
  }

  @discardableResult
  func saveSecret(_ secret: String) -> Bool {
    do {
      try store.saveSecret(secret)
      hasStoredSecret = true
      statusText = "เก็บรหัสเชื่อมต่อไว้ใน Keychain แล้ว"
      return true
    } catch {
      hasStoredSecret = false
      statusText = error.localizedDescription
      return false
    }
  }

  func deleteSecret() {
    do {
      try store.deleteSecret()
      hasStoredSecret = false
      statusText = "ลบรหัสเชื่อมต่อจากเครื่องแล้ว"
    } catch {
      statusText = error.localizedDescription
    }
  }

  private func refreshStatus() {
    do {
      hasStoredSecret = try store.hasSecret()
      statusText =
        hasStoredSecret
        ? "มีรหัสเชื่อมต่อใน Keychain แล้ว"
        : "ยังไม่ได้บันทึกรหัสเชื่อมต่อจาก Rapsodo"
    } catch {
      hasStoredSecret = false
      statusText = error.localizedDescription
    }
  }
}
