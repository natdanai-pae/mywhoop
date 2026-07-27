import Foundation

enum VideoHalfTurn: String, Equatable {
  case normal
  case rotated180

  var degrees: Double { isEnabled ? 180 : 0 }
  var isEnabled: Bool { self == .rotated180 }

  var toggled: Self {
    isEnabled ? .normal : .rotated180
  }
}

enum VideoHalfTurnSource: String, Equatable {
  case directIPhone
  case appleFallback
}

/// Stores only the explicit mount correction selected by the user. The raw
/// orientation from the iPhone remains authoritative and is never rewritten.
struct VideoHalfTurnPreference {
  /// Kept as a compatibility key so build 20 and earlier retain the direct
  /// iPhone correction if the user temporarily rolls back.
  static let storageKey = "GolfTrace.camera.videoHalfTurn.v1"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  static func storageKey(for source: VideoHalfTurnSource) -> String {
    "GolfTrace.camera.videoHalfTurn.v2.\(source.rawValue)"
  }

  func load(for source: VideoHalfTurnSource) -> VideoHalfTurn {
    let sourceKey = Self.storageKey(for: source)
    let sourceRawValue = defaults.string(forKey: sourceKey)
    let legacyRawValue =
      source == .directIPhone
      ? defaults.string(forKey: Self.storageKey) : nil

    guard let rawValue = sourceRawValue ?? legacyRawValue,
      let value = VideoHalfTurn(rawValue: rawValue)
    else {
      return .normal
    }
    return value
  }

  func save(_ value: VideoHalfTurn, for source: VideoHalfTurnSource) {
    defaults.set(value.rawValue, forKey: Self.storageKey(for: source))
    if source == .directIPhone {
      defaults.set(value.rawValue, forKey: Self.storageKey)
    }
  }
}
