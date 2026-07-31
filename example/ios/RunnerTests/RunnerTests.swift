import AsleepSDK
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

  func testTrackingStartRecoveryErrorPreservesCodeAndMessage() {
    let error = trackingStartRecoveryRequiredError()

    XCTAssertEqual(error.code, "TRACKING_START_RECOVERY_REQUIRED")
    XCTAssertEqual(
      error.message,
      "Wait for the timed-out or cancelled tracking start to close before retrying"
    )
  }

  func testTrackingFailuresClassifyOnlyDefinitiveTerminationPaths() {
    XCTAssertTrue(
      trackingFailureTerminatesSession(
        .stopTrackingNetworkFail(code: -9999, message: nil)
      )
    )
    XCTAssertTrue(
      trackingFailureTerminatesSession(
        .uploadTrackingTerminated(message: nil)
      )
    )
    XCTAssertTrue(
      trackingFailureTerminatesSession(
        .interruptionRecoveryFailed(attemptsCount: 3)
      )
    )
    XCTAssertFalse(trackingFailureTerminatesSession(.audioInitializationFailed))
    XCTAssertFalse(trackingFailureTerminatesSession(.cannotActivateInBackground))
  }

  func testInitializationCoordinatorCompletesExactlyOnce() {
    let scheduler = TestInitializationScheduler()
    let coordinator = InitializationAttemptCoordinator(
      scheduler: scheduler,
      timeout: 30
    )
    var results: [Result<Void, Error>] = []
    let attempt = coordinator.begin(phase: .configuration) { _, result in
      results.append(result)
    }

    XCTAssertNotNil(attempt)
    XCTAssertTrue(coordinator.succeed(attempt!))
    XCTAssertFalse(coordinator.succeed(attempt!))
    scheduler.runAll()

    XCTAssertEqual(results.count, 1)
    XCTAssertNoThrow(try results[0].get())
  }

  func testInitializationCoordinatorTimesOutAndQuarantinesLateCompletion() {
    let scheduler = TestInitializationScheduler()
    let coordinator = InitializationAttemptCoordinator(
      scheduler: scheduler,
      timeout: 30
    )
    var firstResults: [Result<Void, Error>] = []
    let first = coordinator.begin(phase: .setup) { _, result in
      firstResults.append(result)
    }!

    scheduler.runNext()

    XCTAssertEqual(firstResults.count, 1)
    XCTAssertFalse(coordinator.succeed(first))
    XCTAssertEqual(
      (try? firstResults[0].getFailure() as? PigeonError)?.code,
      "INITIALIZATION_TIMEOUT"
    )

    var secondResults: [Result<Void, Error>] = []
    let second = coordinator.begin(phase: .configuration) { _, result in
      secondResults.append(result)
    }!

    XCTAssertNotEqual(first, second)
    XCTAssertFalse(coordinator.fail(first, error: TestError.failure))
    XCTAssertTrue(coordinator.succeed(second))
    XCTAssertEqual(secondResults.count, 1)
    XCTAssertNoThrow(try secondResults[0].get())
  }

  func testInitializationCoordinatorUsesASeparateBoundForJoin() {
    let scheduler = TestInitializationScheduler()
    let coordinator = InitializationAttemptCoordinator(
      scheduler: scheduler,
      timeout: 30
    )
    var results: [Result<Void, Error>] = []
    let attempt = coordinator.begin(phase: .setup) { _, result in
      results.append(result)
    }!
    let setupTimeout = scheduler.tasks[0]

    XCTAssertTrue(coordinator.advance(attempt, to: .configuration))
    XCTAssertTrue(setupTimeout.cancelled)
    XCTAssertEqual(scheduler.tasks.count, 2)

    scheduler.run(setupTimeout)
    XCTAssertTrue(results.isEmpty)
    scheduler.run(scheduler.tasks[1])

    let details =
      (try? results[0].getFailure() as? PigeonError)?.details as? [String: Any]
    XCTAssertEqual(details?["phase"] as? String, "configuration")
    XCTAssertEqual(details?["timeoutSeconds"] as? Int, 30)
    XCTAssertEqual(details?["platform"] as? String, "ios")
  }

  func testInitializationCoordinatorRejectsPendingAttemptOnDetach() {
    let scheduler = TestInitializationScheduler()
    let coordinator = InitializationAttemptCoordinator(
      scheduler: scheduler,
      timeout: 30
    )
    var results: [Result<Void, Error>] = []
    _ = coordinator.begin(phase: .configuration) { _, result in
      results.append(result)
    }

    coordinator.detach(error: TestError.detached)
    coordinator.detach(error: TestError.detached)
    scheduler.runAll()

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(try? results[0].getFailure() as? TestError, .detached)
  }

  func testHostQuarantinesTimedOutSetupDelegateFromRetry() {
    let scheduler = TestInitializationScheduler()
    let events = TestEventEmitter()
    var setupDelegates: [AsleepSetupDelegate] = []
    var configureDelegates: [AsleepConfigDelegate] = []
    let nativeSdk = IosNativeSdkActions(
      setLogger: { _ in },
      setup: { _, _, _, _, _, delegate in setupDelegates.append(delegate) },
      configure: { _, _, _, _, _, delegate in configureDelegates.append(delegate) }
    )
    let host = IosAsleepHostApi(
      events: events,
      nativeSdk: nativeSdk,
      initializationScheduler: scheduler,
      initializationTimeout: 30
    )
    var firstResults: [Result<Void, Error>] = []
    host.setup(
      message: SetupMessage(
        apiKey: "test-key",
        baseUrl: nil,
        callbackUrl: nil,
        service: nil,
        enableOnDeviceAnalysis: false
      )
    ) {
      firstResults.append($0)
    }

    scheduler.runNext()

    XCTAssertEqual(firstResults.count, 1)
    XCTAssertEqual(events.types, ["onSetupDidFail"])
    XCTAssertEqual(events.payloads[0]["code"] as? String, "INITIALIZATION_TIMEOUT")

    var secondResults: [Result<Void, Error>] = []
    host.setup(
      message: SetupMessage(
        apiKey: "retry-key",
        baseUrl: nil,
        callbackUrl: nil,
        service: nil,
        enableOnDeviceAnalysis: false
      )
    ) {
      secondResults.append($0)
    }
    XCTAssertEqual(setupDelegates.count, 2)

    setupDelegates[0].setupDidComplete()
    XCTAssertTrue(configureDelegates.isEmpty)
    XCTAssertTrue(secondResults.isEmpty)

    setupDelegates[1].setupDidComplete()
    XCTAssertEqual(configureDelegates.count, 1)
    configureDelegates[0].didFailUserJoin(error: .networkOffline)
    configureDelegates[0].didFailUserJoin(error: .networkOffline)

    XCTAssertEqual(secondResults.count, 1)
    XCTAssertEqual(events.types.suffix(2), ["onUserJoinFailed", "onSetupDidFail"])
    host.detach()
  }

  func testHostDetachRejectsPendingSetupAndReleasesNativeOwnership() {
    let scheduler = TestInitializationScheduler()
    let events = TestEventEmitter()
    var firstDelegate: AsleepSetupDelegate?
    let firstHost = IosAsleepHostApi(
      events: events,
      nativeSdk: IosNativeSdkActions(
        setLogger: { _ in },
        setup: { _, _, _, _, _, delegate in firstDelegate = delegate },
        configure: { _, _, _, _, _, _ in }
      ),
      initializationScheduler: scheduler,
      initializationTimeout: 30
    )
    var firstResults: [Result<Void, Error>] = []
    firstHost.setup(
      message: SetupMessage(
        apiKey: "test-key",
        baseUrl: nil,
        callbackUrl: nil,
        service: nil,
        enableOnDeviceAnalysis: false
      )
    ) {
      firstResults.append($0)
    }

    firstHost.detach()
    firstDelegate?.setupDidComplete()
    scheduler.runAll()

    XCTAssertEqual(firstResults.count, 1)
    XCTAssertTrue(events.types.isEmpty)

    var secondSetupCount = 0
    let secondHost = IosAsleepHostApi(
      events: TestEventEmitter(),
      nativeSdk: IosNativeSdkActions(
        setLogger: { _ in },
        setup: { _, _, _, _, _, _ in secondSetupCount += 1 },
        configure: { _, _, _, _, _, _ in }
      ),
      initializationScheduler: TestInitializationScheduler(),
      initializationTimeout: 30
    )
    secondHost.setup(
      message: SetupMessage(
        apiKey: "replacement-key",
        baseUrl: nil,
        callbackUrl: nil,
        service: nil,
        enableOnDeviceAnalysis: false
      )
    ) { _ in }

    XCTAssertEqual(secondSetupCount, 1)
    secondHost.detach()
  }

  func testHostQuarantinesTimedOutJoinDelegateFromNewConfiguration() {
    let scheduler = TestInitializationScheduler()
    let events = TestEventEmitter()
    var setupDelegate: AsleepSetupDelegate?
    var configureDelegates: [AsleepConfigDelegate] = []
    let host = IosAsleepHostApi(
      events: events,
      nativeSdk: IosNativeSdkActions(
        setLogger: { _ in },
        setup: { _, _, _, _, _, delegate in setupDelegate = delegate },
        configure: { _, _, _, _, _, delegate in configureDelegates.append(delegate) }
      ),
      initializationScheduler: scheduler,
      initializationTimeout: 30
    )
    var setupResults: [Result<Void, Error>] = []
    host.setup(
      message: SetupMessage(
        apiKey: "test-key",
        baseUrl: nil,
        callbackUrl: nil,
        service: nil,
        enableOnDeviceAnalysis: false
      )
    ) {
      setupResults.append($0)
    }
    setupDelegate?.setupDidComplete()

    scheduler.runNext()

    XCTAssertEqual(setupResults.count, 1)
    XCTAssertEqual(events.types, ["onUserJoinFailed", "onSetupDidFail"])
    XCTAssertEqual(
      events.payloads.map { $0["code"] as? String },
      ["INITIALIZATION_TIMEOUT", "INITIALIZATION_TIMEOUT"]
    )

    var retryResults: [Result<Void, Error>] = []
    host.configure(
      message: ConfigurationMessage(
        apiKey: "retry-key",
        userId: nil,
        baseUrl: nil,
        callbackUrl: nil
      )
    ) {
      retryResults.append($0)
    }
    XCTAssertEqual(configureDelegates.count, 2)

    configureDelegates[0].didFailUserJoin(error: .networkOffline)
    XCTAssertTrue(retryResults.isEmpty)
    XCTAssertEqual(events.types.count, 2)

    configureDelegates[1].didFailUserJoin(error: .networkOffline)
    XCTAssertEqual(retryResults.count, 1)
    XCTAssertEqual(events.types.last, "onUserJoinFailed")
    host.detach()
  }

  func testTrackingEventsPreserveInterruptResumeUploadOrder() {
    let events = TestEventEmitter()
    let host = IosAsleepHostApi(events: events)

    host.didInterrupt()
    host.didResume()
    host.didUpload(sequence: 7)

    XCTAssertEqual(
      events.types,
      ["onTrackingInterrupted", "onTrackingResumed", "onTrackingUploaded"]
    )
    host.detach()
  }

  func testRecoveryErrorsUseSemanticCodesAndOfficialSdkNumbers() {
    let events = TestEventEmitter()
    let host = IosAsleepHostApi(events: events)

    host.didFail(error: .audioInitializationFailed)
    host.didFail(error: .cannotActivateInBackground)

    XCTAssertEqual(
      events.payloads.map { $0["code"] as? String },
      ["AUDIO_INITIALIZATION_FAILED", "CANNOT_ACTIVATE_IN_BACKGROUND"]
    )
    XCTAssertEqual(
      events.payloads.map { $0["sdkCode"] as? Int },
      [
        Asleep.AsleepError.audioInitializationFailed.errorCode.code,
        Asleep.AsleepError.cannotActivateInBackground.errorCode.code,
      ]
    )
    XCTAssertNotEqual(events.payloads[0]["sdkCode"] as? Int, 38)
    XCTAssertNotEqual(events.payloads[1]["sdkCode"] as? Int, 39)
    host.detach()
  }
}

private enum TestError: Error {
  case failure
  case detached
}

extension Result where Success == Void, Failure == Error {
  fileprivate func getFailure() throws -> Error {
    switch self {
    case .success:
      throw TestError.failure
    case .failure(let error):
      return error
    }
  }
}

private final class TestInitializationTask: InitializationScheduledTask {
  let action: () -> Void
  private(set) var cancelled = false

  init(action: @escaping () -> Void) {
    self.action = action
  }

  func cancel() {
    cancelled = true
  }
}

private final class TestInitializationScheduler: InitializationScheduling {
  private(set) var tasks: [TestInitializationTask] = []

  func schedule(
    after delay: TimeInterval,
    _ action: @escaping () -> Void
  ) -> InitializationScheduledTask {
    let task = TestInitializationTask(action: action)
    tasks.append(task)
    return task
  }

  func runNext() {
    guard let task = tasks.first(where: { !$0.cancelled }) else {
      XCTFail("Expected a scheduled task")
      return
    }
    run(task)
  }

  func run(_ task: TestInitializationTask) {
    guard !task.cancelled else { return }
    task.action()
  }

  func runAll() {
    for task in tasks where !task.cancelled {
      task.action()
    }
  }
}

private final class TestEventEmitter: IosEventEmitting {
  private(set) var types: [String] = []
  private(set) var payloads: [[String: Any]] = []

  func emit(
    type: String,
    payloadJson: String,
    completion: (() -> Void)?
  ) {
    types.append(type)
    let data = Data(payloadJson.utf8)
    let payload =
      (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    payloads.append(payload)
    completion?()
  }
}
