import Foundation

public enum HealthExportPolicy {
  public static func canWriteHeartRate(source: String?) -> Bool { source == "standard_hr" }
  public static func canWriteHRV(source: String?) -> Bool { source == "rr" }
  public static func canWriteRestingHR(source: String?) -> Bool { source == "standard_hr" }
  public static func canWriteRespiratoryRate(source: String?) -> Bool { source == "rsa" }
  public static func canWriteBodyTemperature(source: String?) -> Bool { source == "body_temperature" }
  public static func canWriteActiveEnergy(hrSource: String?) -> Bool { hrSource == "standard_hr" }
  public static var canWriteEstimatedVO2max: Bool { false }

  public static func healthKitSDNNSource(liveHRVSource: String?, hasSDNN: Bool) -> String? {
    guard hasSDNN, liveHRVSource == "rr" else { return nil }
    return "rr"
  }
}
