import AsleepSDK
import AVFoundation
import Flutter
import Foundation

private enum NativeSdkOwnerRegistry {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var owner: ObjectIdentifier?

  static func claim(_ candidate: AnyObject) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let identifier = ObjectIdentifier(candidate)
    if owner == nil {
      owner = identifier
    }
    return owner == identifier
  }

  static func isOwner(_ candidate: AnyObject) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return owner == ObjectIdentifier(candidate)
  }

  static func release(_ candidate: AnyObject) {
    lock.lock()
    defer { lock.unlock() }
    if owner == ObjectIdentifier(candidate) {
      owner = nil
    }
  }
}

struct TrackingStartRecoveryGate {
  private(set) var isRecoveryRequired = false

  var canStart: Bool {
    !isRecoveryRequired
  }

  var acceptsCreatedSession: Bool {
    !isRecoveryRequired
  }

  mutating func requireRecovery() {
    isRecoveryRequired = true
  }

  mutating func didTerminate() {
    isRecoveryRequired = false
  }
}

func trackingFailureTerminatesSession(_ error: Asleep.AsleepError) -> Bool {
  switch error {
  case .stopTrackingNetworkFail, .uploadTrackingTerminated, .interruptionRecoveryFailed:
    return true
  default:
    return false
  }
}

func trackingStartRecoveryRequiredError() -> PigeonError {
  PigeonError(
    code: "TRACKING_START_RECOVERY_REQUIRED",
    message: "Wait for the timed-out or cancelled tracking start to close before retrying",
    details: nil
  )
}

public final class AsleepSdkFlutterPlugin: NSObject, FlutterPlugin {
  private let events = IosEventsStreamHandler()
  private lazy var hostApi = IosAsleepHostApi(events: events)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = AsleepSdkFlutterPlugin()
    AsleepHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance.hostApi)
    EventsStreamHandler.register(
      with: registrar.messenger(),
      streamHandler: instance.events
    )
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    hostApi.detach()
    events.detach()
  }

  deinit {
    hostApi.detach()
    events.detach()
  }
}

private final class IosEventsStreamHandler: EventsStreamHandler {
  private var sink: PigeonEventSink<NativeEventMessage>?

  override func onListen(
    withArguments arguments: Any?,
    sink: PigeonEventSink<NativeEventMessage>
  ) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(
    type: String,
    payloadJson: String,
    completion: (() -> Void)? = nil
  ) {
    let deliver = { [weak self] in
      self?.sink?.success(
        NativeEventMessage(type: type, payloadJson: payloadJson)
      )
      completion?()
    }
    if Thread.isMainThread {
      deliver()
    } else {
      DispatchQueue.main.async(execute: deliver)
    }
  }

  func detach() {
    DispatchQueue.main.async { [weak self] in
      self?.sink?.endOfStream()
      self?.sink = nil
    }
  }
}

private final class IosAsleepHostApi: NSObject, AsleepHostApi {
  private let events: IosEventsStreamHandler
  private var trackingManager: Asleep.SleepTrackingManager?
  private var reportManager: Asleep.Reports?
  private var config: Asleep.Config?
  private var setupCompletion: ((Result<Void, Error>) -> Void)?
  private var setupMessage: SetupMessage?
  private var setupBaseURL: URL?
  private var setupCallbackURL: URL?
  private var configuringFromSetup = false
  private var configureCompletion: ((Result<Void, Error>) -> Void)?
  private var loggingEnabled = false
  private var initializationInFlight = false
  private var trackingActive = false
  private var trackingStartCompletion: ((Result<Void, Error>) -> Void)?
  private var trackingStartTimeout: DispatchWorkItem?
  private var nextTrackingStartGeneration: UInt64 = 0
  private var activeTrackingStartGeneration: UInt64?
  private var trackingStartRecoveryGate = TrackingStartRecoveryGate()
  private var detached = false

  init(events: IosEventsStreamHandler) {
    self.events = events
  }

  func setup(
    message: SetupMessage,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let baseURL: URL?
    let callbackURL: URL?
    do {
      baseURL = try validatedURL(message.baseUrl, field: "baseUrl")
      callbackURL = try validatedURL(message.callbackUrl, field: "callbackUrl")
    } catch {
      completion(.failure(error))
      return
    }
    guard claimNativeSdk(completion) else { return }
    guard setupCompletion == nil, configureCompletion == nil else {
      completion(.failure(BridgeError.configurationInProgress))
      return
    }
    setupCompletion = completion
    setupMessage = message
    setupBaseURL = baseURL
    setupCallbackURL = callbackURL
    initializationInFlight = true
    Asleep.setLogger(self)
    Asleep.setup(
      apiKey: message.apiKey,
      baseUrl: baseURL,
      callbackUrl: callbackURL,
      service: message.service,
      enableODA: message.enableOnDeviceAnalysis,
      delegate: self
    )
  }

  func configure(
    message: ConfigurationMessage,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let baseURL: URL?
    let callbackURL: URL?
    do {
      baseURL = try validatedURL(message.baseUrl, field: "baseUrl")
      callbackURL = try validatedURL(message.callbackUrl, field: "callbackUrl")
    } catch {
      completion(.failure(error))
      return
    }
    guard claimNativeSdk(completion) else { return }
    guard setupCompletion == nil, configureCompletion == nil else {
      completion(.failure(BridgeError.configurationInProgress))
      return
    }
    configureCompletion = completion
    initializationInFlight = true
    Asleep.setLogger(self)
    Asleep.initAsleepConfig(
      apiKey: message.apiKey,
      userId: message.userId,
      baseUrl: baseURL,
      callbackUrl: callbackURL,
      delegate: self
    )
  }

  func checkAndRestoreTracking(
    completion: @escaping (Result<RestoreMessage, Error>) -> Void
  ) {
    // Match the React Native contract: iOS has no persistent foreground
    // service to reconnect after process death. A session identifier is not an
    // active-state signal because AsleepSDK also retains it after close.
    completion(.success(RestoreMessage(hasActiveSession: false)))
  }

  func checkBatteryOptimization(
    completion: @escaping (Result<BatteryOptimizationMessage, Error>) -> Void
  ) {
    completion(
      .success(
        BatteryOptimizationMessage(
          exempted: true,
          platform: "ios",
          message: "Battery optimization exemptions are not applicable on iOS"
        )
      )
    )
  }

  func requestBatteryOptimizationExemption(
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    completion(.success(true))
  }

  func hasRequiredPermissions(
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    completion(
      .success(AVAudioSession.sharedInstance().recordPermission == .granted)
    )
  }

  func requestRequiredPermissions(
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      DispatchQueue.main.async {
        completion(.success(granted))
      }
    }
  }

  func startTracking(
    message: TrackingMessage,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let trackingManager else {
      completion(.failure(BridgeError.trackingManagerUnavailable))
      return
    }
    guard trackingStartCompletion == nil else {
      completion(.failure(BridgeError.trackingStartInProgress))
      return
    }
    guard trackingStartRecoveryGate.canStart else {
      completion(.failure(trackingStartRecoveryRequiredError()))
      return
    }
    var options: AVAudioSession.CategoryOptions = []
    for option in message.iosAudioSessionOptions {
      switch option {
      case .duckOthers:
        options.insert(.duckOthers)
      case .allowAirPlay:
        options.insert(.allowAirPlay)
      case .allowBluetooth:
        options.insert(.allowBluetoothHFP)
      case .allowBluetoothA2DP:
        options.insert(.allowBluetoothA2DP)
      }
    }
    trackingStartCompletion = completion
    nextTrackingStartGeneration &+= 1
    let generation = nextTrackingStartGeneration
    activeTrackingStartGeneration = generation
    let timeout = DispatchWorkItem { [weak self] in
      guard self?.activeTrackingStartGeneration == generation else { return }
      self?.trackingStartRecoveryGate.requireRecovery()
      self?.finishTrackingStart(
        .failure(BridgeError.trackingStartTimeout),
        generation: generation
      )
      self?.trackingManager?.stopTracking()
    }
    trackingStartTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    trackingManager.startTracking(additionalAudioSessionOptions: options)
  }

  func resumeTracking(completion: @escaping (Result<Void, Error>) -> Void) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let trackingManager else {
      completion(.failure(BridgeError.trackingManagerUnavailable))
      return
    }
    trackingManager.resumeTracking()
    completion(.success(()))
  }

  func stopTracking(completion: @escaping (Result<Void, Error>) -> Void) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let trackingManager else {
      completion(.failure(BridgeError.trackingManagerUnavailable))
      return
    }
    if activeTrackingStartGeneration != nil {
      trackingStartRecoveryGate.requireRecovery()
    }
    finishTrackingStart(.failure(BridgeError.trackingStartCancelled))
    trackingManager.stopTracking()
    completion(.success(()))
  }

  func requestAnalysis(
    completion: @escaping (Result<AnalysisRequestMessage, Error>) -> Void
  ) {
    guard requireNativeSdkOwner(completion) else { return }
    guard trackingActive else {
      completion(.failure(BridgeError.trackingNotActive))
      return
    }
    guard let trackingManager else {
      completion(.failure(BridgeError.trackingManagerUnavailable))
      return
    }
    trackingManager.requestAnalysis()
    completion(
      .success(
        AnalysisRequestMessage(
          status: "requested",
          timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
          resultJson: nil
        )
      )
    )
  }

  func getReport(
    sessionId: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let reportManager else {
      completion(.failure(BridgeError.reportManagerUnavailable))
      return
    }
    Task {
      do {
        let report = try await reportManager.report(sessionId: sessionId)
        completion(.success(try encodeJSON(report)))
      } catch {
        completion(.failure(transportError(error)))
      }
    }
  }

  func getReportList(
    fromDate: String,
    toDate: String,
    completion: @escaping (Result<[String], Error>) -> Void
  ) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let reportManager else {
      completion(.failure(BridgeError.reportManagerUnavailable))
      return
    }
    Task {
      do {
        let pageSize = 100
        var offset = 0
        var sessions: [Asleep.Model.SleepSession] = []
        while true {
          let page = try await reportManager.reports(
            fromDate: fromDate,
            toDate: toDate,
            offset: offset,
            limit: pageSize
          )
          sessions.append(contentsOf: page)
          guard page.count == pageSize else { break }
          offset += page.count
        }
        completion(.success(try sessions.map(encodeSleepSession)))
      } catch {
        completion(.failure(transportError(error)))
      }
    }
  }

  func getAverageReport(
    fromDate: String,
    toDate: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let reportManager else {
      completion(.failure(BridgeError.reportManagerUnavailable))
      return
    }
    Task {
      do {
        let report = try await reportManager.getAverageReport(
          fromDate: fromDate,
          toDate: toDate
        )
        completion(.success(try encodeJSON(report)))
      } catch {
        completion(.failure(transportError(error)))
      }
    }
  }

  func deleteSession(
    sessionId: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard requireNativeSdkOwner(completion) else { return }
    guard let reportManager else {
      completion(.failure(BridgeError.reportManagerUnavailable))
      return
    }
    Task {
      do {
        try await reportManager.deleteReport(sessionId: sessionId)
        completion(.success(()))
      } catch {
        completion(.failure(transportError(error)))
      }
    }
  }

  func setLoggingEnabled(
    enabled: Bool,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    loggingEnabled = enabled
    completion(.success(()))
  }

  func detach() {
    detached = true
    setupCompletion?(.failure(BridgeError.engineDetached))
    setupCompletion = nil
    setupMessage = nil
    setupBaseURL = nil
    setupCallbackURL = nil
    configuringFromSetup = false
    configureCompletion?(.failure(BridgeError.engineDetached))
    configureCompletion = nil
    finishTrackingStart(.failure(BridgeError.engineDetached))
    trackingStartRecoveryGate.didTerminate()
    trackingManager = nil
    reportManager = nil
    config = nil
    trackingActive = false
    initializationInFlight = false
    releaseNativeSdkIfIdle()
  }

  private func finishConfiguration(_ result: Result<Void, Error>) {
    configureCompletion?(result)
    configureCompletion = nil
    initializationInFlight = false
    releaseNativeSdkIfIdle()
  }

  private func finishTrackingStart(_ result: Result<Void, Error>) {
    finishTrackingStart(result, generation: nil)
  }

  private func finishTrackingStart(
    _ result: Result<Void, Error>,
    generation: UInt64?
  ) {
    if let generation, activeTrackingStartGeneration != generation {
      return
    }
    activeTrackingStartGeneration = nil
    guard let completion = trackingStartCompletion else { return }
    trackingStartCompletion = nil
    trackingStartTimeout?.cancel()
    trackingStartTimeout = nil
    completion(result)
  }

  private func claimNativeSdk<T>(
    _ completion: (Result<T, Error>) -> Void
  ) -> Bool {
    guard NativeSdkOwnerRegistry.claim(self) else {
      completion(.failure(BridgeError.anotherEngineOwnsNativeSdk))
      return false
    }
    return true
  }

  private func requireNativeSdkOwner<T>(
    _ completion: (Result<T, Error>) -> Void
  ) -> Bool {
    guard NativeSdkOwnerRegistry.isOwner(self) else {
      completion(.failure(BridgeError.nativeSdkNotOwned))
      return false
    }
    return true
  }

  private func releaseNativeSdkIfIdle() {
    if detached, !initializationInFlight {
      NativeSdkOwnerRegistry.release(self)
    }
  }

  private func emit(
    _ type: String,
    _ payload: [String: Any] = [:],
    completion: (() -> Void)? = nil
  ) {
    do {
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      events.emit(
        type: type,
        payloadJson: String(decoding: data, as: UTF8.self),
        completion: completion
      )
    } catch {
      let fallback = #"{"message":"Failed to encode native event"}"#
      events.emit(type: "onDebugLog", payloadJson: fallback, completion: completion)
    }
  }

  private func emitJSON(_ type: String, _ payloadJson: String) {
    events.emit(type: type, payloadJson: payloadJson)
  }

  private func errorPayload(
    _ error: Asleep.AsleepError,
    fallbackCode: String
  ) -> [String: Any] {
    let code: String
    let message: String
    var payload: [String: Any]

    switch error {
    case .ODAIntegrityFail:
      code = "ODA_INTEGRITY_FAIL"
      message = "The model has been updated or the file is corrupted"
    case .networkOffline:
      code = "NETWORK_OFFLINE"
      message = "The Internet connection appears to be offline"
    case .unableODA:
      code = "UNABLE_ODA"
      message = "On-device analysis is not available"
    case .uploadTrackingTerminated(let detail):
      code = "UPLOAD_TRACKING_TERMINATED"
      message = detail ?? error.description
    case .interruptionRecoveryFailed(let attemptsCount):
      code = "INTERRUPTION_RECOVERY_FAILED"
      message = "Failed to recover from audio interruption after \(attemptsCount) attempts"
    case .audioInitializationFailed:
      code = "AUDIO_INITIALIZATION_FAILED"
      message = "Audio recording could not be initialized"
    case .cannotActivateInBackground:
      code = "CANNOT_ACTIVATE_IN_BACKGROUND"
      message = "Recording could not resume in the background"
    default:
      code = fallbackCode
      message = error.description
    }

    payload = [
      "code": code,
      "message": message,
      "error": error.description,
      "sdkCode": error.errorCode.code,
      "platformDetails": [
        "platform": "ios",
        "numericCodeSource": "Asleep.AsleepError.errorCode.code",
      ],
    ]
    if case .interruptionRecoveryFailed(let attemptsCount) = error {
      payload["attemptsCount"] = attemptsCount
    }
    return payload
  }
}

extension IosAsleepHostApi: AsleepSetupDelegate {
  func setupDidComplete() {
    guard !detached else { return }
    guard
      let message = setupMessage,
      let completion = setupCompletion
    else {
      initializationInFlight = false
      releaseNativeSdkIfIdle()
      return
    }
    setupMessage = nil
    setupCompletion = nil
    configuringFromSetup = true
    configureCompletion = completion
    let baseURL = setupBaseURL
    let callbackURL = setupCallbackURL
    setupBaseURL = nil
    setupCallbackURL = nil
    Asleep.initAsleepConfig(
      apiKey: message.apiKey,
      userId: nil,
      baseUrl: baseURL,
      callbackUrl: callbackURL,
      delegate: self
    )
  }

  func setupDidFail(error: Asleep.AsleepError) {
    guard !detached else { return }
    emit("onSetupDidFail", errorPayload(error, fallbackCode: "SETUP_FAILED"))
    setupCompletion?(.failure(transportError(error)))
    setupCompletion = nil
    setupMessage = nil
    setupBaseURL = nil
    setupCallbackURL = nil
    initializationInFlight = false
    releaseNativeSdkIfIdle()
  }

  func setupInProgress(progress: Int) {
    guard !detached else { return }
    emit("onSetupInProgress", ["progress": progress])
  }
}

extension IosAsleepHostApi: AsleepConfigDelegate {
  func userDidJoin(userId: String, config: Asleep.Config) {
    guard !detached else { return }
    self.config = config
    trackingManager = Asleep.createSleepTrackingManager(config: config, delegate: self)
    reportManager = Asleep.createReports(config: config)
    emit("onUserJoined", ["userId": userId])
    if configuringFromSetup {
      configuringFromSetup = false
      emit("onSetupDidComplete")
    }
    finishConfiguration(.success(()))
  }

  func didFailUserJoin(error: Asleep.AsleepError) {
    guard !detached else { return }
    emit(
      "onUserJoinFailed",
      errorPayload(error, fallbackCode: "INITIALIZATION_FAILED")
    )
    if configuringFromSetup {
      configuringFromSetup = false
      emit("onSetupDidFail", errorPayload(error, fallbackCode: "INIT_CONFIG_FAILED"))
    }
    finishConfiguration(.failure(transportError(error)))
  }

  func userDidDelete(userId: String) {
    guard !detached else { return }
    emit("onUserDeleted", ["userId": userId])
  }
}

extension IosAsleepHostApi: AsleepSleepTrackingManagerDelegate {
  func didCreate() {
    guard !detached else { return }
    guard trackingStartRecoveryGate.acceptsCreatedSession else {
      trackingManager?.stopTracking()
      return
    }
    guard let generation = activeTrackingStartGeneration else {
      trackingManager?.stopTracking()
      return
    }
    trackingActive = true
    resolveSessionId(retriesRemaining: 5, generation: generation) { [weak self] in
      self?.finishTrackingStart(.success(()), generation: generation)
    }
  }

  func didUpload(sequence: Int) {
    guard !detached else { return }
    emit("onTrackingUploaded", ["sequence": sequence])
  }

  func didClose(sessionId: String) {
    guard !detached else { return }
    trackingStartRecoveryGate.didTerminate()
    trackingActive = false
    finishTrackingStart(.failure(BridgeError.trackingClosedBeforeStart))
    emit("onTrackingClosed", ["sessionId": sessionId])
  }

  func didFail(error: Asleep.AsleepError) {
    guard !detached else { return }
    activeTrackingStartGeneration = nil
    if trackingFailureTerminatesSession(error) {
      trackingStartRecoveryGate.didTerminate()
      trackingActive = false
    }
    emit(
      "onTrackingFailed",
      errorPayload(error, fallbackCode: "TRACKING_FAILED")
    ) { [weak self] in
      self?.finishTrackingStart(.failure(transportError(error)))
    }
  }

  func didInterrupt() {
    guard !detached else { return }
    emit("onTrackingInterrupted")
  }

  func didResume() {
    guard !detached else { return }
    emit("onTrackingResumed")
  }

  func micPermissionWasDenied() {
    guard !detached else { return }
    trackingStartRecoveryGate.didTerminate()
    activeTrackingStartGeneration = nil
    emit("onMicPermissionDenied") { [weak self] in
      self?.finishTrackingStart(.failure(BridgeError.microphonePermissionDenied))
    }
  }

  func analysing(session: Asleep.Model.Session) {
    guard !detached else { return }
    do {
      emitJSON("onAnalysisResult", try encodeJSON(session))
    } catch {
      emit("onDebugLog", ["message": "Failed to encode analysis result: \(error)"])
    }
  }

  private func resolveSessionId(
    retriesRemaining: Int,
    generation: UInt64,
    completion: @escaping () -> Void
  ) {
    guard
      activeTrackingStartGeneration == generation,
      trackingActive
    else {
      return
    }
    if let sessionId = trackingManager?.getTrackingStatus().sessionId {
      emit("onTrackingCreated", ["sessionId": sessionId], completion: completion)
      return
    }
    guard retriesRemaining > 0 else {
      emit("onTrackingCreated", completion: completion)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      self?.resolveSessionId(
        retriesRemaining: retriesRemaining - 1,
        generation: generation,
        completion: completion
      )
    }
  }
}

extension IosAsleepHostApi: AsleepLogger {
  func d(tag: LogTag, msg: String, error: Error?) {
    log(level: "D", tag: tag, message: msg, error: error)
  }

  func e(tag: LogTag, msg: String, error: Error?) {
    log(level: "E", tag: tag, message: msg, error: error)
  }

  func i(tag: LogTag, msg: String, error: Error?) {
    log(level: "I", tag: tag, message: msg, error: error)
  }

  func w(tag: LogTag, msg: String, error: Error?) {
    log(level: "W", tag: tag, message: msg, error: error)
  }

  private func log(level: String, tag: LogTag, message: String, error: Error?) {
    guard loggingEnabled else { return }
    let suffix = error.map { " | \($0.localizedDescription)" } ?? ""
    emit("onDebugLog", ["message": "[\(level)][\(tag.value)] \(message)\(suffix)"])
  }
}

private enum BridgeError: LocalizedError {
  case configurationInProgress
  case anotherEngineOwnsNativeSdk
  case nativeSdkNotOwned
  case trackingManagerUnavailable
  case trackingNotActive
  case trackingStartInProgress
  case trackingStartTimeout
  case trackingStartCancelled
  case trackingClosedBeforeStart
  case microphonePermissionDenied
  case reportManagerUnavailable
  case engineDetached
  case invalidURL(field: String, value: String)

  var errorDescription: String? {
    switch self {
    case .configurationInProgress:
      return "Configuration is already in progress"
    case .anotherEngineOwnsNativeSdk:
      return "The Asleep native SDK is already owned by another Flutter engine"
    case .nativeSdkNotOwned:
      return "This Flutter engine does not own the Asleep native SDK; initialize it first"
    case .trackingManagerUnavailable:
      return "Tracking manager is not initialized"
    case .trackingNotActive:
      return "Sleep tracking is not active"
    case .trackingStartInProgress:
      return "Tracking start is already in progress"
    case .trackingStartTimeout:
      return "The native Asleep SDK did not acknowledge tracking start"
    case .trackingStartCancelled:
      return "Tracking start was cancelled by stopTracking"
    case .trackingClosedBeforeStart:
      return "Tracking closed before the native SDK acknowledged its start"
    case .microphonePermissionDenied:
      return "Microphone permission was denied"
    case .reportManagerUnavailable:
      return "Report manager is not initialized"
    case .engineDetached:
      return "Flutter engine detached"
    case .invalidURL(let field, let value):
      return "\(field) must be an absolute HTTP or HTTPS URL: \(value)"
    }
  }
}

private func validatedURL(_ value: String?, field: String) throws -> URL? {
  guard let value, !value.isEmpty else { return nil }
  guard
    let components = URLComponents(string: value),
    let scheme = components.scheme?.lowercased(),
    scheme == "http" || scheme == "https",
    components.host?.isEmpty == false,
    let url = components.url
  else {
    throw BridgeError.invalidURL(field: field, value: value)
  }
  return url
}

private func transportError(_ error: Error) -> Error {
  guard let asleepError = error as? Asleep.AsleepError else { return error }
  let details: [String: any Sendable] = [
    "sdkCode": asleepError.errorCode.code,
    "caseName": String(describing: asleepError),
    "platform": "ios",
  ]
  return PigeonError(
    code: "ASLEEP_SDK_ERROR",
    message: asleepError.description,
    details: details
  )
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func encodeSleepSession(_ session: Asleep.Model.SleepSession) throws -> String {
  var payload: [String: Any] = [
    "sessionId": session.sessionId,
    "state": session.state.rawValue,
    "sessionStartTime": ISO8601DateFormatter().string(from: session.sessionStartTime),
    "createdTimezone": session.createdTimezone,
  ]
  if let value = session.sessionEndTime {
    payload["sessionEndTime"] = ISO8601DateFormatter().string(from: value)
  }
  if let value = session.unexpectedEndTime {
    payload["unexpectedEndTime"] = ISO8601DateFormatter().string(from: value)
  }
  if let value = session.lastReceivedSeqNum {
    payload["lastReceivedSeqNum"] = value
  }
  if let value = session.timeInBed {
    payload["timeInBed"] = value
  }
  let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  return String(decoding: data, as: UTF8.self)
}
