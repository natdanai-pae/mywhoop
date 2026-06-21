import Testing
import Foundation
import CryptoKit
@testable import GenieMax

// PKCE (RFC 7636) for the Google OAuth flow.

@Test func pkceVerifierIsHighEntropyAndUnique() {
  let a = PKCE.verifier(), b = PKCE.verifier()
  #expect(a != b)
  #expect(a.count >= 43)                                  // RFC minimum
  #expect(a.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) })
}

@Test func pkceChallengeIsS256OfVerifier() {
  let v = "test-verifier-123"
  let expected = PKCE.base64url(Data(SHA256.hash(data: Data(v.utf8))))
  #expect(PKCE.challenge(v) == expected)
  #expect(!PKCE.challenge(v).contains("="))              // unpadded
  #expect(PKCE.challenge(v) != v)
}

@Test func pkceBase64urlIsUrlSafeUnpadded() {
  // bytes that would produce + / = in standard base64
  let s = PKCE.base64url(Data([0xfb, 0xff, 0xbf]))
  #expect(!s.contains("+") && !s.contains("/") && !s.contains("="))
}

// JWT subject extraction (used to derive the account id from a Google/Apple id-token).
@Test func jwtSubjectParsed() {
  let payload = Data(#"{"sub":"google-user-9","exp":2000000000}"#.utf8).base64EncodedString()
    .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
  let jwt = "h.\(payload).s"
  #expect(JWTToken.subject(jwt) == "google-user-9")
  #expect(JWTToken.expiry(jwt) == 2_000_000_000)
  #expect(JWTToken.subject("garbage") == nil)
}
