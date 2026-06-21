import Foundation
import CryptoKit

/// PKCE (RFC 7636) for the Google OAuth flow on a public (no-secret) installed app — `ASWebAuthenticationSession`
/// gets an authorization code, then the token endpoint is called with the `code_verifier` to prove possession,
/// so no client secret is needed. Pure + deterministic given the verifier, so the challenge is unit-testable.
public enum PKCE {
  /// A high-entropy code verifier: base64url of 32 random bytes (43 chars, within the RFC's 43–128 unreserved range).
  public static func verifier() -> String {
    base64url(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
  }
  /// The S256 challenge = base64url(SHA-256(verifier)).
  public static func challenge(_ verifier: String) -> String {
    base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
  }
  /// URL-safe, unpadded Base64 (the only encoding PKCE + JWT use).
  public static func base64url(_ d: Data) -> String {
    d.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
