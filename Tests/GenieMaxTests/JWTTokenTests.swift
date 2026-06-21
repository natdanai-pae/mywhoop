import Testing
import Foundation
@testable import GenieMax

// JWT expiry parsing for OAuth token refresh (the E2EE sync design).

private func jwt(exp: Int) -> String {
  // A real-shaped JWT: header.payload.sig with a base64url payload carrying `exp`.
  let payload = Data(#"{"sub":"abc","exp":\#(exp)}"#.utf8).base64EncodedString()
    .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
  return "eyJhbGciOiJSUzI1NiJ9.\(payload).sigbytes"
}

@Test func jwtExpiryParsed() {
  #expect(JWTToken.expiry(jwt(exp: 2_000_000_000)) == 2_000_000_000)
}

@Test func jwtFreshBeforeExpiryStaleAfter() {
  let t = jwt(exp: 2_000_000_000)
  #expect(JWTToken.isFresh(t, now: 1_000_000_000))                 // far before expiry
  #expect(!JWTToken.isFresh(t, now: 2_000_000_000))                // exactly at expiry → stale
  #expect(!JWTToken.isFresh(t, now: 1_999_999_999, skew: 60))      // inside the skew window → stale (refresh early)
  #expect(JWTToken.isFresh(t, now: 1_999_999_000, skew: 60))       // just outside the skew window → fresh
}

@Test func jwtMalformedIsStale() {
  #expect(JWTToken.expiry("not-a-jwt") == nil)
  #expect(JWTToken.expiry("only.two") == nil)
  #expect(!JWTToken.isFresh("garbage", now: 0))                    // unparseable → treated as expired (safe)
}
