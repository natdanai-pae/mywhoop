import CoreMedia
import Vision
import XCTest

@testable import GolfTrace

final class SwingMotionAnalyzerTests: XCTestCase {
  func testReconstructsCenterWhenOneWristBrieflyDisappears() throws {
    let analyzer = SwingMotionAnalyzer(positionSmoothingTimeConstant: 0)

    let bothWrists = try XCTUnwrap(
      analyzer.consume(pose(at: 0, leftX: 0.4, rightX: 0.6)).handCenter)
    let leftOnly = try XCTUnwrap(
      analyzer.consume(pose(at: 0.02, leftX: 0.4, rightX: nil)).handCenter)
    let rightOnly = try XCTUnwrap(
      analyzer.consume(pose(at: 0.04, leftX: nil, rightX: 0.6)).handCenter)

    XCTAssertEqual(bothWrists.x, 0.5, accuracy: 0.000_001)
    XCTAssertEqual(leftOnly.x, 0.5, accuracy: 0.000_001)
    XCTAssertEqual(rightOnly.x, 0.5, accuracy: 0.000_001)
  }

  func testTimeFilterReducesFrameToFrameJitter() throws {
    let analyzer = SwingMotionAnalyzer(positionSmoothingTimeConstant: 0.03)
    let rawX: [CGFloat] = [0.50, 0.51, 0.49, 0.51, 0.49, 0.51, 0.49]
    var filteredX: [CGFloat] = []

    for (index, x) in rawX.enumerated() {
      let frame = analyzer.consume(
        pose(at: Double(index) / 60, leftX: x - 0.01, rightX: x + 0.01)
      )
      filteredX.append(try XCTUnwrap(frame.handCenter).x)
    }

    let rawRange = try XCTUnwrap(rawX.max()) - (try XCTUnwrap(rawX.min()))
    let filteredRange =
      try XCTUnwrap(filteredX.dropFirst().max())
      - (try XCTUnwrap(filteredX.dropFirst().min()))
    XCTAssertLessThan(filteredRange, rawRange * 0.6)
  }

  func testResetDoesNotDragPreviousTraceIntoNewPosition() throws {
    let analyzer = SwingMotionAnalyzer(positionSmoothingTimeConstant: 0.03)
    _ = analyzer.consume(pose(at: 0, leftX: 0.19, rightX: 0.21))
    _ = analyzer.consume(pose(at: 0.02, leftX: 0.19, rightX: 0.21))

    analyzer.reset()
    let newCenter = try XCTUnwrap(
      analyzer.consume(pose(at: 0, leftX: 0.79, rightX: 0.81)).handCenter
    )

    XCTAssertEqual(newCenter.x, 0.8, accuracy: 0.000_001)
  }

  func testLeanAnalysisFramesMaterializeHistoryOnlyForUISnapshot() {
    let analyzer = SwingMotionAnalyzer(positionSmoothingTimeConstant: 0)
    for index in 0..<12 {
      let frame = analyzer.consume(
        pose(
          at: Double(index) / 120,
          leftX: 0.4 + CGFloat(index) * 0.001,
          rightX: 0.6 + CGFloat(index) * 0.001
        ),
        materializePointHistory: false
      )
      XCTAssertTrue(frame.pointHistory.isEmpty)
    }

    let snapshot = analyzer.uiSnapshot()
    XCTAssertEqual(snapshot.pointHistory.count, 12)
    XCTAssertEqual(snapshot.handCenter, analyzer.latestFrame.handCenter)
    XCTAssertEqual(snapshot.normalizedHandSpeed, analyzer.latestFrame.normalizedHandSpeed)
  }

  func testLongRunningLeanHistoryRemainsPointBounded() {
    let analyzer = SwingMotionAnalyzer(
      maximumHistoryDuration: 10,
      maximumPointCount: 20,
      positionSmoothingTimeConstant: 0
    )
    for index in 0..<5_000 {
      _ = analyzer.consume(
        pose(
          at: Double(index) / 120,
          leftX: 0.4,
          rightX: 0.6
        ),
        materializePointHistory: false
      )
    }

    XCTAssertEqual(analyzer.uiSnapshot().pointHistory.count, 20)
  }

  private func pose(
    at seconds: Double,
    leftX: CGFloat?,
    rightX: CGFloat?
  ) -> PoseFrame {
    var joints: [VNHumanBodyPoseObservation.JointName: PoseJoint] = [:]
    if let leftX {
      joints[.leftWrist] = PoseJoint(
        id: "left",
        location: CGPoint(x: leftX, y: 0.5),
        confidence: 0.9
      )
    }
    if let rightX {
      joints[.rightWrist] = PoseJoint(
        id: "right",
        location: CGPoint(x: rightX, y: 0.5),
        confidence: 0.9
      )
    }
    return PoseFrame(
      joints: joints,
      timestamp: CMTime(seconds: seconds, preferredTimescale: 60_000)
    )
  }
}
