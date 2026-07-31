import 'dart:async';

import 'asleep_events.dart';
import 'asleep_models.dart';
import 'asleep_platform.dart';
import 'pigeon_asleep_platform.dart';

/// Coordinates Asleep setup, tracking, reports, events, and observable state.
class AsleepClient {
  /// Creates a client backed by [platform] or the default native implementation.
  ///
  /// Supply an [AsleepPlatform] fake to test SDK-consuming code without native
  /// platform channels.
  factory AsleepClient({AsleepPlatform? platform}) {
    if (platform != null) {
      return AsleepClient._(platform, ownsNativeLease: false);
    }
    if (_nativeClientClaimed) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Only one native AsleepClient may be active in a Flutter engine.',
      );
    }
    _nativeClientClaimed = true;
    try {
      return AsleepClient._(PigeonAsleepPlatform(), ownsNativeLease: true);
    } catch (_) {
      _nativeClientClaimed = false;
      rethrow;
    }
  }

  AsleepClient._(this._platform, {required this._ownsNativeLease});

  static bool _nativeClientClaimed = false;

  final AsleepPlatform _platform;
  final bool _ownsNativeLease;
  final StreamController<AsleepSnapshot> _states =
      StreamController<AsleepSnapshot>.broadcast(sync: true);
  final StreamController<AsleepEvent> _events =
      StreamController<AsleepEvent>.broadcast(sync: true);

  AsleepSnapshot _state = const AsleepSnapshot();
  StreamSubscription<AsleepEvent>? _nativeEvents;
  bool _initialized = false;
  bool _initializationInFlight = false;
  bool _restoreInFlight = false;
  bool _trackingStatusChecked = false;
  bool _preflightRestoreDetected = false;
  bool _preflightConfigureAllowed = false;
  bool _recordingDeadSession = false;
  int _nextStartAttempt = 0;
  int? _activeStartAttempt;
  bool _startPending = false;
  bool _stopPending = false;
  bool _resumePending = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// The most recently reduced SDK state.
  AsleepSnapshot get state => _state;

  /// Emits each state snapshot after it changes.
  Stream<AsleepSnapshot> get states => _states.stream;

  /// Emits native SDK events without reducing or filtering them.
  Stream<AsleepEvent> get events => _events.stream;

  /// Sets up the native SDK with the supplied API and service options.
  Future<void> initialize(AsleepSetupOptions options) async {
    _ensureOpen();
    _ensureInitializationAvailable();
    if (_state.isTracking ||
        _recordingDeadSession ||
        _hasPendingLifecycleCommand) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Cannot initialize while a tracking session is active.',
      );
    }
    _validateRequiredString(options.apiKey, 'apiKey');
    _validateOptionalUrl(options.baseUrl, 'baseUrl');
    _validateOptionalUrl(options.callbackUrl, 'callbackUrl');
    _validateOptionalNonEmptyString(options.service, 'service');
    final errorBefore = _state.error;
    _initializationInFlight = true;
    _initialized = false;
    _attachEvents();
    _setState(
      _state.copyWith(setupStatus: SetupStatus.inProgress, clearError: true),
    );
    try {
      await _restorePreflight();
      if (_state.isTracking) {
        _preflightConfigureAllowed = true;
        throw const AsleepException(
          AsleepErrorCode.invalidState,
          'Cannot initialize while a tracking session is active. '
          'Call configure() to reconnect it or stopTracking() first.',
        );
      }
      await _platform.setup(options);
      _initialized = true;
      _setState(
        _state.copyWith(
          setupStatus: SetupStatus.complete,
          isOnDeviceAnalysisEnabled: options.enableOnDeviceAnalysis,
          clearError: true,
        ),
      );
    } catch (error) {
      _initialized = false;
      _setState(
        _state.copyWith(
          setupStatus: SetupStatus.idle,
          isOnDeviceAnalysisEnabled: false,
          error: _errorAfterFailure(errorBefore, error),
        ),
      );
      rethrow;
    } finally {
      _initializationInFlight = false;
    }
  }

  /// Applies credentials and endpoints without running the setup flow.
  Future<void> configure(AsleepConfiguration configuration) async {
    _ensureOpen();
    _ensureInitializationAvailable();
    if ((_state.isTracking && !_preflightConfigureAllowed) ||
        _recordingDeadSession ||
        _hasPendingLifecycleCommand) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Cannot configure while a tracking session is active.',
      );
    }
    _validateRequiredString(configuration.apiKey, 'apiKey');
    _validateOptionalNonEmptyString(configuration.userId, 'userId');
    _validateOptionalUrl(configuration.baseUrl, 'baseUrl');
    _validateOptionalUrl(configuration.callbackUrl, 'callbackUrl');
    _preflightConfigureAllowed = false;
    final errorBefore = _state.error;
    _initializationInFlight = true;
    _initialized = false;
    _attachEvents();
    _setState(
      _state.copyWith(setupStatus: SetupStatus.inProgress, clearError: true),
    );
    try {
      await _restorePreflight();
      await _platform.configure(configuration);
      _initialized = true;
      _setState(
        _state.copyWith(setupStatus: SetupStatus.complete, clearError: true),
      );
    } catch (error) {
      _initialized = false;
      _preflightConfigureAllowed =
          _preflightRestoreDetected && _state.isTracking;
      _setState(
        _state.copyWith(
          setupStatus: SetupStatus.idle,
          error: _errorAfterFailure(errorBefore, error),
        ),
      );
      rethrow;
    } finally {
      _initializationInFlight = false;
    }
  }

  /// Checks for a native tracking session that can be restored.
  Future<RestoreResult> checkAndRestoreTracking() async {
    _ensureOpen();
    if (_restoreInFlight ||
        _initializationInFlight ||
        _hasPendingLifecycleCommand) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Cannot restore tracking while another restore, initialization, or a '
        'lifecycle command is in progress.',
      );
    }
    _restoreInFlight = true;
    try {
      _attachEvents();
      final result = await _platform.checkAndRestoreTracking();
      final stalePreflight = _preflightRestoreDetected;
      _preflightRestoreDetected = result.hasActiveSession;
      _preflightConfigureAllowed = result.hasActiveSession && !_initialized;
      _trackingStatusChecked = true;
      if (result.hasActiveSession) {
        _recordingDeadSession = false;
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.tracking,
            didClose: false,
          ),
        );
      } else if (stalePreflight &&
          _state.trackingStatus == TrackingStatus.tracking) {
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.idle,
            clearSessionId: true,
          ),
        );
      }
      return result;
    } finally {
      _restoreInFlight = false;
    }
  }

  /// Returns the Android battery-optimization status.
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    _ensureReady();
    final status = await _platform.checkBatteryOptimization();
    _setState(_state.copyWith(batteryOptimizationChecked: true));
    return status;
  }

  /// Requests an Android battery-optimization exemption when supported.
  Future<bool> requestBatteryOptimizationExemption() {
    _ensureReady();
    return _platform.requestBatteryOptimizationExemption();
  }

  /// Whether all platform permissions required for tracking are granted.
  Future<bool> hasRequiredPermissions() {
    _ensureOpen();
    return _platform.hasRequiredPermissions();
  }

  /// Requests the platform permissions required for tracking.
  Future<bool> requestRequiredPermissions() {
    _ensureOpen();
    return _platform.requestRequiredPermissions();
  }

  /// Starts a new tracking session with optional platform-specific settings.
  Future<void> startTracking([
    AsleepTrackingOptions options = const AsleepTrackingOptions(),
  ]) async {
    _ensureReady();
    if (!_trackingStatusChecked) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Call checkAndRestoreTracking() before startTracking().',
      );
    }
    if (!_state.batteryOptimizationChecked) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Call checkBatteryOptimization() before startTracking().',
      );
    }
    if (_state.setupStatus == SetupStatus.inProgress) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Cannot start tracking while setup is in progress.',
      );
    }
    if (_recordingDeadSession) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'The previous recording failed. Call stopTracking() before starting again.',
      );
    }
    if (_state.isTracking || _hasPendingLifecycleCommand) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'A tracking lifecycle command is already in progress.',
      );
    }
    final startAttempt = ++_nextStartAttempt;
    _activeStartAttempt = startAttempt;
    _startPending = true;
    try {
      if (!await _platform.hasRequiredPermissions()) {
        throw const AsleepException(
          AsleepErrorCode.permissionRequired,
          'Required microphone permissions have not been granted.',
        );
      }
      _ensureStartAttemptActive(startAttempt);
      final batteryStatus = await _platform.checkBatteryOptimization();
      _ensureStartAttemptActive(startAttempt);
      if (!batteryStatus.exempted) {
        throw const AsleepException(
          AsleepErrorCode.invalidState,
          'Battery optimization exemption is required before tracking. '
          'Call requestBatteryOptimizationExemption() and check again.',
        );
      }
      await _platform.startTracking(options);
      _ensureStartAttemptActive(startAttempt);
      _activeStartAttempt = null;
      _startPending = false;
      if (_state.trackingStatus == TrackingStatus.idle) {
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.tracking,
            didClose: false,
            clearError: true,
          ),
        );
      }
    } catch (error) {
      if (_activeStartAttempt == startAttempt) {
        _activeStartAttempt = null;
        _startPending = false;
        if (error is AsleepException &&
            error.nativeCode == 'TRACKING_START_TIMEOUT') {
          _trackingStatusChecked = false;
        }
      }
      rethrow;
    }
  }

  /// Resumes a paused session or one awaiting foreground recovery.
  Future<void> resumeTracking() async {
    _ensureReady();
    if (_state.trackingStatus != TrackingStatus.recoveryRequired &&
        _state.trackingStatus != TrackingStatus.paused) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Tracking is not paused or awaiting foreground recovery.',
      );
    }
    if (_hasPendingLifecycleCommand) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'A tracking lifecycle command is already in progress.',
      );
    }
    _resumePending = true;
    try {
      await _platform.resumeTracking();
    } catch (_) {
      _resumePending = false;
      rethrow;
    }
  }

  /// Stops the active tracking session.
  Future<void> stopTracking() async {
    _ensureOpen();
    final cancellingPendingStart =
        _activeStartAttempt != null &&
        _state.trackingStatus == TrackingStatus.idle;
    if (!_state.isTracking &&
        !_recordingDeadSession &&
        _activeStartAttempt == null &&
        !_resumePending) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'No tracking session is active.',
      );
    }
    if (_stopPending) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'A stopTracking command is already in progress.',
      );
    }
    _activeStartAttempt = null;
    _startPending = false;
    _stopPending = true;
    try {
      await _platform.stopTracking();
      if (cancellingPendingStart &&
          _state.trackingStatus == TrackingStatus.idle) {
        _clearPendingLifecycleCommands();
        _trackingStatusChecked = false;
        _recordingDeadSession = false;
      }
    } catch (_) {
      _stopPending = false;
      rethrow;
    }
  }

  /// Requests an analysis update for the active session.
  Future<AnalysisRequest> requestAnalysis() async {
    _ensureReady();
    if (_stopPending) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Cannot request analysis while tracking is stopping.',
      );
    }
    if (_state.trackingStatus != TrackingStatus.tracking) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'No tracking session is active.',
      );
    }
    if (_state.isAnalyzing) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'An analysis request is already pending.',
      );
    }
    _setState(_state.copyWith(isAnalyzing: true));
    try {
      return await _platform.requestAnalysis();
    } catch (_) {
      _setState(_state.copyWith(isAnalyzing: false));
      rethrow;
    }
  }

  /// Fetches the detailed report for [sessionId].
  Future<AsleepReport> getReport(String sessionId) {
    _ensureReady();
    _validateRequiredString(sessionId, 'sessionId');
    return _platform.getReport(sessionId);
  }

  /// Fetches sessions whose report dates fall within the requested range.
  Future<List<AsleepSession>> getReportList(String fromDate, String toDate) {
    _ensureReady();
    _validateRequiredString(fromDate, 'fromDate');
    _validateRequiredString(toDate, 'toDate');
    return _platform.getReportList(fromDate, toDate);
  }

  /// Fetches an aggregate report for the requested date range.
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate) {
    _ensureReady();
    _validateRequiredString(fromDate, 'fromDate');
    _validateRequiredString(toDate, 'toDate');
    return _platform.getAverageReport(fromDate, toDate);
  }

  /// Deletes the session identified by [sessionId].
  Future<void> deleteSession(String sessionId) {
    _ensureReady();
    _validateRequiredString(sessionId, 'sessionId');
    return _platform.deleteSession(sessionId);
  }

  /// Enables or disables native SDK diagnostic logging.
  Future<void> setLoggingEnabled(bool enabled) {
    _ensureOpen();
    return _platform.setLoggingEnabled(enabled);
  }

  /// Removes the current error from [state].
  void clearError() {
    _ensureOpen();
    if (_state.error != null) {
      _setState(_state.copyWith(clearError: true));
    }
  }

  /// Releases native resources and closes the client's streams.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _setState(_state.copyWith(isOnDeviceAnalysisEnabled: false));
    _disposed = true;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> cleanUp(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await cleanUp(() async {
      await _nativeEvents?.cancel();
      _nativeEvents = null;
    });
    await cleanUp(_platform.dispose);
    await cleanUp(_events.close);
    await cleanUp(_states.close);
    if (_ownsNativeLease) {
      _nativeClientClaimed = false;
    }

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  void _attachEvents() {
    _nativeEvents ??= _platform.events.listen(
      _handleEvent,
      onError: (Object error, StackTrace stackTrace) {
        final mapped = _asleepError(error);
        _setState(_state.copyWith(error: mapped));
        _events.addError(error, stackTrace);
      },
    );
  }

  void _handleEvent(AsleepEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case TrackingCreatedEvent():
        final sessionId = _nonEmpty(event.sessionId);
        _startPending = false;
        _recordingDeadSession = false;
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.tracking,
            sessionId: sessionId,
            clearSessionId: sessionId == null,
            didClose: false,
            clearError: true,
          ),
        );
      case TrackingUploadedEvent():
        final wasRecovering =
            _state.trackingStatus == TrackingStatus.recoveryRequired;
        _startPending = false;
        _resumePending = false;
        if (wasRecovering) {
          _setState(
            _state.copyWith(
              trackingStatus: TrackingStatus.tracking,
              clearError: true,
            ),
          );
        }
        if (_state.trackingStatus == TrackingStatus.tracking &&
            !_stopPending &&
            (_state.isOnDeviceAnalysisEnabled ||
                (event.sequence >= 10 && event.sequence % 10 == 1))) {
          unawaited(_requestAnalysisFromUpload());
        }
      case TrackingClosedEvent():
        final sessionId = _nonEmpty(event.sessionId);
        _preflightRestoreDetected = false;
        _preflightConfigureAllowed = false;
        _clearPendingLifecycleCommands();
        _recordingDeadSession = false;
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.idle,
            sessionId: sessionId,
            didClose: true,
            isAnalyzing: false,
            clearError: true,
          ),
        );
      case TrackingFailedEvent():
        final category = event.error.category;
        final ended =
            category == AsleepErrorCategory.terminal ||
            category == AsleepErrorCategory.recordingDead;
        if (ended) {
          _preflightRestoreDetected = false;
          _preflightConfigureAllowed = false;
          _clearPendingLifecycleCommands();
        } else if (category == AsleepErrorCategory.recoveryRequired) {
          _resumePending = false;
          _startPending = false;
        }
        if (category == AsleepErrorCategory.recordingDead) {
          _recordingDeadSession = true;
        } else if (category == AsleepErrorCategory.terminal) {
          _recordingDeadSession = false;
        }
        final status = switch (category) {
          AsleepErrorCategory.terminal => TrackingStatus.idle,
          AsleepErrorCategory.recordingDead => TrackingStatus.idle,
          AsleepErrorCategory.recoveryRequired =>
            TrackingStatus.recoveryRequired,
          _ => _state.trackingStatus,
        };
        _setState(
          _state.copyWith(
            trackingStatus: status,
            error: event.error,
            isAnalyzing: ended ? false : _state.isAnalyzing,
            didClose: category == AsleepErrorCategory.terminal,
          ),
        );
      case TrackingInterruptedEvent():
        _resumePending = false;
        _setState(_state.copyWith(trackingStatus: TrackingStatus.paused));
      case TrackingResumedEvent():
        _resumePending = false;
        _setState(
          _state.copyWith(
            trackingStatus: _state.trackingStatus == TrackingStatus.paused
                ? TrackingStatus.tracking
                : _state.trackingStatus,
            clearError: true,
          ),
        );
      case MicrophonePermissionDeniedEvent():
        _setState(
          _state.copyWith(
            error: AsleepError(
              code: 'MICROPHONE_PERMISSION_DENIED',
              message: 'Microphone permission was denied.',
            ),
          ),
        );
      case UserJoinedEvent():
        _setState(_state.copyWith(userId: event.userId, clearError: true));
      case UserJoinFailedEvent():
        _setState(_state.copyWith(error: event.error));
      case UserDeletedEvent():
        _setState(_state.copyWith(clearUserId: true));
      case SetupCompletedEvent():
        _setState(
          _state.copyWith(setupStatus: SetupStatus.complete, clearError: true),
        );
      case SetupFailedEvent():
        _initialized = false;
        _setState(
          _state.copyWith(
            setupStatus: SetupStatus.idle,
            isOnDeviceAnalysisEnabled: false,
            error: event.error,
          ),
        );
      case SetupProgressEvent():
        _setState(_state.copyWith(setupStatus: SetupStatus.inProgress));
      case AnalysisResultEvent():
        _setState(
          _state.copyWith(analysisResult: event.result, isAnalyzing: false),
        );
      case DebugLogEvent():
      case UnknownNativeEvent():
        break;
    }
    _events.add(event);
  }

  void _setState(AsleepSnapshot value) {
    if (_disposed) {
      return;
    }
    if (_sameSnapshot(_state, value)) {
      return;
    }
    _state = value;
    _states.add(value);
  }

  bool _sameSnapshot(AsleepSnapshot left, AsleepSnapshot right) =>
      left.setupStatus == right.setupStatus &&
      left.trackingStatus == right.trackingStatus &&
      left.userId == right.userId &&
      left.sessionId == right.sessionId &&
      identical(left.analysisResult, right.analysisResult) &&
      left.isAnalyzing == right.isAnalyzing &&
      left.isOnDeviceAnalysisEnabled == right.isOnDeviceAnalysisEnabled &&
      identical(left.error, right.error) &&
      left.didClose == right.didClose &&
      left.batteryOptimizationChecked == right.batteryOptimizationChecked;

  Future<void> _requestAnalysisFromUpload() async {
    if (_disposed || !_initialized || _stopPending || _state.isAnalyzing) {
      return;
    }
    try {
      await requestAnalysis();
    } catch (error) {
      if (!_disposed) {
        _setState(
          _state.copyWith(isAnalyzing: false, error: _asleepError(error)),
        );
      }
    }
  }

  Future<void> _restorePreflight() async {
    final stalePreflight = _preflightRestoreDetected;
    final result = await _platform.checkAndRestoreTracking();
    if (!result.hasActiveSession) {
      if (stalePreflight &&
          _preflightRestoreDetected &&
          _state.trackingStatus == TrackingStatus.tracking) {
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.idle,
            clearSessionId: true,
          ),
        );
      }
      _preflightRestoreDetected = false;
      return;
    }
    _preflightRestoreDetected = true;
    _recordingDeadSession = false;
    _setState(
      _state.copyWith(trackingStatus: TrackingStatus.tracking, didClose: false),
    );
  }

  bool get _hasPendingLifecycleCommand =>
      _activeStartAttempt != null ||
      _startPending ||
      _stopPending ||
      _resumePending;

  void _clearPendingLifecycleCommands() {
    _startPending = false;
    _stopPending = false;
    _resumePending = false;
  }

  void _ensureStartAttemptActive(int attempt) {
    if (_activeStartAttempt != attempt || _disposed) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'The startTracking command was cancelled.',
      );
    }
  }

  void _ensureInitializationAvailable() {
    if (_initializationInFlight) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'SDK initialization is already in progress.',
      );
    }
    if (_restoreInFlight) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Cannot initialize while a restore check is in progress.',
      );
    }
  }

  void _validateOptionalUrl(String? value, String field) {
    if (value == null) {
      return;
    }
    final uri = Uri.tryParse(value);
    if (value.isEmpty ||
        uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw AsleepException(
        AsleepErrorCode.invalidArgument,
        '$field must be an absolute HTTP or HTTPS URL with a host.',
      );
    }
  }

  void _validateRequiredString(String value, String field) {
    if (value.trim().isEmpty) {
      throw AsleepException(
        AsleepErrorCode.invalidArgument,
        '$field must not be empty.',
      );
    }
  }

  void _validateOptionalNonEmptyString(String? value, String field) {
    if (value != null) {
      _validateRequiredString(value, field);
    }
  }

  String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  void _ensureReady() {
    _ensureOpen();
    if (!_initialized) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Call initialize() or configure() first.',
      );
    }
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const AsleepException(
        AsleepErrorCode.disposed,
        'This AsleepClient has been disposed.',
      );
    }
  }

  AsleepError _asleepError(Object error) {
    if (error is AsleepException) {
      final details = error.nativeDetails;
      if (details is Map) {
        final payload = details.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        payload.putIfAbsent('code', () => error.nativeCode ?? error.code.name);
        payload.putIfAbsent('message', () => error.message);
        return AsleepError.fromJson(payload);
      }
      return AsleepError(
        code: error.nativeCode ?? error.code.name,
        message: error.message,
        platformDetails: <String, Object?>{
          'details': ?details,
          'cause': ?error.cause,
        },
      );
    }
    return AsleepError(
      code: 'NATIVE_FAILURE',
      message: error.toString(),
      platformDetails: <String, Object?>{'cause': error},
    );
  }

  AsleepError _errorAfterFailure(
    AsleepError? errorBefore,
    Object commandError,
  ) {
    final eventError = _state.error;
    if (eventError != null && !identical(eventError, errorBefore)) {
      return eventError;
    }
    return _asleepError(commandError);
  }
}
