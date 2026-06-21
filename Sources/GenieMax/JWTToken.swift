import Foundation

/// Minimal read-only JWT helper for the E2EE sync client (the E2EE sync design). The CLIENT only needs to know WHEN an
/// OAuth id-token expires so it can refresh before a sync (the SERVER verifies the signature — we never trust this
/// client-side read for auth). Pure + deterministic (caller passes `now`), so it's fully testable.
public enum JWTToken {
  /// The decoded payload claims, or nil if the token is malformed. No signature check (the SERVER verifies).
  public static func claims(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let payload = base64urlDecode(String(parts[1])) else { return nil }
    return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
  }

  /// The `exp` (expiry, unix seconds) claim, or nil if the token is malformed / has no numeric exp.
  public static func expiry(_ jwt: String) -> Double? { claims(jwt)?["exp"] as? Double }

  /// The `sub` (subject = the provider's stable user id) claim, or nil.
  public static func subject(_ jwt: String) -> String? { claims(jwt)?["sub"] as? String }

  /// The `email` claim, or nil. Present in Google id-tokens when the "email" scope is granted.
  public static func email(_ jwt: String) -> String? { claims(jwt)?["email"] as? String }

  /// Is the token still valid `skew` seconds from `now`? An unknown/unparseable expiry is treated as EXPIRED (safe —
  /// triggers a refresh rather than sending a dead token).
  public static func isFresh(_ jwt: String, now: Double, skew: Double = 60) -> Bool {
    guard let exp = expiry(jwt) else { return false }
    return now + skew < exp
  }

  static func base64urlDecode(_ s: String) -> Data? {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    return Data(base64Encoded: b)
  }
}
