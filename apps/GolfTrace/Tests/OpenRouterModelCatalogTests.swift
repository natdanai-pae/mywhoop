import Foundation
import XCTest

@testable import GolfTrace

final class OpenRouterModelCatalogTests: XCTestCase {
  func testPrimaryCoachConsumesPacketButCannotReceivePlayerFrame() {
    let model = OpenRouterGolfModelCatalog.primaryCoach
    XCTAssertTrue(
      model.isEligible(
        for: .structuredSwingPacket,
        evaluationPassed: true,
        playerFrameConsent: false
      ))
    XCTAssertFalse(
      model.isEligible(
        for: .playerAuditFrame,
        evaluationPassed: true,
        playerFrameConsent: true
      ))
  }

  func testFreeVisionShadowNeverReceivesRealPlayerFrame() {
    let model = OpenRouterGolfModelCatalog.freeVisionShadow
    XCTAssertTrue(
      model.isEligible(
        for: .syntheticEvaluationFrame,
        evaluationPassed: false,
        playerFrameConsent: false
      ))
    XCTAssertFalse(
      model.isEligible(
        for: .playerAuditFrame,
        evaluationPassed: true,
        playerFrameConsent: true
      ))
  }

  func testPaidVisionRequiresEvaluationAndExplicitFrameConsent() {
    let model = OpenRouterGolfModelCatalog.paidVisionAudit
    XCTAssertFalse(
      model.isEligible(
        for: .playerAuditFrame,
        evaluationPassed: false,
        playerFrameConsent: true
      ))
    XCTAssertFalse(
      model.isEligible(
        for: .playerAuditFrame,
        evaluationPassed: true,
        playerFrameConsent: false
      ))
    XCTAssertTrue(
      model.isEligible(
        for: .playerAuditFrame,
        evaluationPassed: true,
        playerFrameConsent: true
      ))
  }

  func testTemporaryFreeHy3StopsAfterPublishedExpiry() throws {
    let before = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-20T23:59:59Z")
    )
    let after = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-21T00:00:00Z")
    )
    let model = OpenRouterGolfModelCatalog.temporaryHy3Free
    XCTAssertTrue(
      model.isEligible(
        for: .structuredSwingPacket,
        evaluationPassed: false,
        playerFrameConsent: false,
        now: before
      ))
    XCTAssertFalse(
      model.isEligible(
        for: .structuredSwingPacket,
        evaluationPassed: false,
        playerFrameConsent: false,
        now: after
      ))
  }
}
