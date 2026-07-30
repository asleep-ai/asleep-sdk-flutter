import XCTest

@testable import asleep_sdk_flutter

class RunnerTests: XCTestCase {
  func testPluginCanBeConstructed() {
    let plugin = AsleepSdkFlutterPlugin()
    XCTAssertNotNil(plugin)
  }

  func testTrackingStartRetryWaitsForTimedOutAttemptToTerminate() {
    var gate = TrackingStartRecoveryGate()

    XCTAssertTrue(gate.canStart)
    gate.requireRecovery()

    XCTAssertFalse(gate.canStart)
    XCTAssertFalse(gate.acceptsCreatedSession)

    gate.didTerminate()

    XCTAssertTrue(gate.canStart)
    XCTAssertTrue(gate.acceptsCreatedSession)
  }
}
