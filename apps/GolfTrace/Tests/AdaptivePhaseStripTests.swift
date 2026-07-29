import Foundation
import XCTest

@testable import GolfTrace

final class AdaptivePhaseStripTests: XCTestCase {
  func testResolverAlwaysBuildsEightSlotsInStoryboardOrder() {
    let slots = AdaptivePhaseStripResolver.slots(from: [])

    XCTAssertEqual(slots.count, 8)
    XCTAssertEqual(
      slots.map(\.id),
      [
        "address", "takeaway", "backswing", "top", "downswing", "impact",
        "followThrough", "finish",
      ]
    )
    XCTAssertTrue(slots.allSatisfy { !$0.isAvailable })
    XCTAssertTrue(slots.allSatisfy { $0.statusText == "ยังไม่มั่นใจ" })
  }

  func testResolverMapsAnalyzerAliasesWithoutChangingFixedSlots() {
    let slots = AdaptivePhaseStripResolver.slots(
      from: [
        evidence(phaseID: "Half Backswing", replayTimestampMs: 1_200),
        evidence(phaseID: "Delivery", replayTimestampMs: 1_800),
        evidence(phaseID: "Impact Window", replayTimestampMs: 2_100),
        evidence(phaseID: "Extension", replayTimestampMs: 2_600),
      ]
    )

    XCTAssertEqual(
      slots.filter(\.isAvailable).map(\.id),
      [
        "backswing", "downswing", "impact", "followThrough",
      ])
  }

  func testResolverPrefersSeekableMarkerOverHigherConfidenceUnmappedMarker() throws {
    let slots = AdaptivePhaseStripResolver.slots(
      from: [
        evidence(
          phaseID: "top",
          replayTimestampMs: nil,
          confidence: 0.99,
          provenance: "หลักฐานเดิม"
        ),
        evidence(
          phaseID: "top",
          replayTimestampMs: 2_180,
          confidence: 0.75,
          provenance: "เวลารีเพลย์ที่จับคู่แล้ว"
        ),
      ]
    )

    let top = try XCTUnwrap(slots.first(where: { $0.id == "top" }))
    XCTAssertEqual(top.evidence?.replayTimestampMs, 2_180)
    XCTAssertEqual(top.statusText, "เวลารีเพลย์ที่จับคู่แล้ว")
    XCTAssertEqual(top.canSeek, true)
    XCTAssertEqual(try XCTUnwrap(top.replayTimeSeconds), 2.18, accuracy: 0.000_1)
  }

  func testMarkerWithoutReplayTimestampIsVisibleButCannotSeek() throws {
    let slots = AdaptivePhaseStripResolver.slots(
      from: [evidence(phaseID: "finish", replayTimestampMs: nil)]
    )

    let finish = try XCTUnwrap(slots.first(where: { $0.id == "finish" }))
    XCTAssertTrue(finish.isAvailable)
    XCTAssertTrue(finish.canSelect)
    XCTAssertFalse(finish.canSeek)
    XCTAssertNil(finish.replayTimeSeconds)
  }

  func testResolverDropsUnknownPhaseRatherThanInventingAStoryboardSlot() {
    let slots = AdaptivePhaseStripResolver.slots(
      from: [evidence(phaseID: "mystery transition", replayTimestampMs: 900)]
    )

    XCTAssertTrue(slots.allSatisfy { !$0.isAvailable })
  }

  private func evidence(
    phaseID: String,
    replayTimestampMs: Int?,
    confidence: Double = 0.82,
    provenance: String = "หลักฐานทดสอบ"
  ) -> AdaptivePhaseStripEvidence {
    AdaptivePhaseStripEvidence(
      phaseID: phaseID,
      sourceTimestampMs: 800,
      replayTimestampMs: replayTimestampMs,
      confidence: confidence,
      provenanceText: provenance,
      limitation: nil,
      thumbnailURL: nil
    )
  }
}
