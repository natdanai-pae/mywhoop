import UIKit
import XCTest
@testable import GolfTraceCamera

final class PhysicalOrientationControllerTests: XCTestCase {
  func testMapsPhysicalOrientationsToMatchingInterfaceMasks() {
    XCTAssertEqual(
      PhysicalOrientationRequestPolicy.interfaceMask(for: .portrait),
      .portrait
    )
    XCTAssertEqual(
      PhysicalOrientationRequestPolicy.interfaceMask(for: .portraitUpsideDown),
      .portraitUpsideDown
    )
    XCTAssertEqual(
      PhysicalOrientationRequestPolicy.interfaceMask(for: .landscapeLeft),
      .landscapeRight
    )
    XCTAssertEqual(
      PhysicalOrientationRequestPolicy.interfaceMask(for: .landscapeRight),
      .landscapeLeft
    )
  }

  func testIgnoresFlatAndUnknownPhysicalOrientations() {
    XCTAssertNil(PhysicalOrientationRequestPolicy.interfaceMask(for: .faceUp))
    XCTAssertNil(PhysicalOrientationRequestPolicy.interfaceMask(for: .faceDown))
    XCTAssertNil(PhysicalOrientationRequestPolicy.interfaceMask(for: .unknown))
  }

  func testDoesNotRequestWhenInterfaceAlreadyMatches() {
    var policy = PhysicalOrientationRequestPolicy()

    XCTAssertNil(
      policy.requestMask(
        for: .landscapeLeft,
        currentInterfaceOrientation: .landscapeRight
      )
    )
  }

  func testDoesNotRepeatTheSamePendingRequest() {
    var policy = PhysicalOrientationRequestPolicy()

    XCTAssertEqual(
      policy.requestMask(
        for: .landscapeLeft,
        currentInterfaceOrientation: .portrait
      ),
      .landscapeRight
    )
    XCTAssertNil(
      policy.requestMask(
        for: .landscapeLeft,
        currentInterfaceOrientation: .portrait
      )
    )
  }

  func testResetAllowsARequestToBeIssuedAgain() {
    var policy = PhysicalOrientationRequestPolicy()
    _ = policy.requestMask(
      for: .landscapeRight,
      currentInterfaceOrientation: .portrait
    )

    policy.reset()

    XCTAssertEqual(
      policy.requestMask(
        for: .landscapeRight,
        currentInterfaceOrientation: .portrait
      ),
      .landscapeLeft
    )
  }
}
