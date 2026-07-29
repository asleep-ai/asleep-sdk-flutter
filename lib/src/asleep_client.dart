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
  AsleepClient({AsleepPlatform? platform})
    : _platform = platform ?? PigeonAsleepPlatform();

  final AsleepPlatform _platform;
  final StreamController<AsleepSnapshot> _states =
      StreamController<AsleepSnapshot>.broadcast(sync: true);
  final StreamController<AsleepEvent> _events =
      StreamController<AsleepEvent>.broadcast(sync: true);

  AsleepSnapshot _state = const AsleepSnapshot();
  StreamSubscription<AsleepEvent>? _nativeEvents;
  bool _initialized = false;
  bool _onDeviceAnalysisEnabled = false;
  bool _disposed = false;

  /// The most recently reduced SDK state.
  AsleepSnapshot get state => _state;

  /// Emits each state snapshot after it changes.
  Stream<AsleepSnapshot> get states => _states.stream;

  /// Emits native SDK events without reducing or filtering them.
  Stream<AsleepEvent> get events => _events.stream;

  /// Sets up the native SDK with the supplied API and service options.
  Future<void> initialize(AsleepSetupOptions options) async {
    _ensureOpen();
    _attachEvents();
    _setState(
      _state.copyWith(setupStatus: SetupStatus.inProgress, clearError: true),
    );
    try {
      await _platform.setup(options);
      _onDeviceAnalysisEnabled = options.enableOnDeviceAnalysis;
      _initialized = true;
    } catch (error) {
      _setState(
        _state.copyWith(
          setupStatus: SetupStatus.idle,
          error: _asleepError(error),
        ),
      );
      rethrow;
    }
  }

  /// Applies credentials and endpoints without running the setup flow.
  Future<void> configure(AsleepConfiguration configuration) async {
    _ensureOpen();
    _attachEvents();
    await _platform.configure(configuration);
    _initialized = true;
  }

  /// Checks for a native tracking session that can be restored.
  Future<RestoreResult> checkAndRestoreTracking() async {
    _ensureReady();
    final result = await _platform.checkAndRestoreTracking();
    if (result.hasActiveSession) {
      _setState(
        _state.copyWith(
          trackingStatus: TrackingStatus.tracking,
          didClose: false,
        ),
      );
    }
    return result;
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
    if (_state.isTracking) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'A tracking session is already active.',
      );
    }
    if (!await _platform.hasRequiredPermissions()) {
      throw const AsleepException(
        AsleepErrorCode.permissionRequired,
        'Required microphone permissions have not been granted.',
      );
    }
    await _platform.startTracking(options);
  }

  /// Resumes a paused session or one awaiting foreground recovery.
  Future<void> resumeTracking() {
    _ensureReady();
    if (_state.trackingStatus != TrackingStatus.recoveryRequired &&
        _state.trackingStatus != TrackingStatus.paused) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'Tracking is not paused or awaiting foreground recovery.',
      );
    }
    return _platform.resumeTracking();
  }

  /// Stops the active tracking session.
  Future<void> stopTracking() async {
    _ensureReady();
    if (!_state.isTracking) {
      throw const AsleepException(
        AsleepErrorCode.invalidState,
        'No tracking session is active.',
      );
    }
    await _platform.stopTracking();
  }

  /// Requests an analysis update for the active session.
  Future<AnalysisRequest> requestAnalysis() async {
    _ensureReady();
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
    return _platform.getReport(sessionId);
  }

  /// Fetches sessions whose report dates fall within the requested range.
  Future<List<AsleepSession>> getReportList(String fromDate, String toDate) {
    _ensureReady();
    return _platform.getReportList(fromDate, toDate);
  }

  /// Fetches an aggregate report for the requested date range.
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate) {
    _ensureReady();
    return _platform.getAverageReport(fromDate, toDate);
  }

  /// Deletes the session identified by [sessionId].
  Future<void> deleteSession(String sessionId) {
    _ensureReady();
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
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _nativeEvents?.cancel();
    _nativeEvents = null;
    await _platform.dispose();
    await _events.close();
    await _states.close();
  }

  void _attachEvents() {
    _nativeEvents ??= _platform.events.listen(
      _handleEvent,
      onError: (Object error, StackTrace stackTrace) {
        final mapped = _asleepError(error);
        _setState(_state.copyWith(error: mapped));
      },
    );
  }

  void _handleEvent(AsleepEvent event) {
    if (_disposed) {
      return;
    }
    _events.add(event);
    switch (event) {
      case TrackingCreatedEvent():
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.tracking,
            sessionId: event.sessionId,
            didClose: false,
            clearError: true,
          ),
        );
      case TrackingUploadedEvent():
        if (_onDeviceAnalysisEnabled ||
            (event.sequence >= 10 && event.sequence % 10 == 1)) {
          unawaited(_requestAnalysisFromUpload());
        }
      case TrackingClosedEvent():
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.idle,
            sessionId: event.sessionId,
            didClose: true,
            isAnalyzing: false,
            clearError: true,
          ),
        );
      case TrackingFailedEvent():
        final category = event.error.category;
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
            isAnalyzing: false,
            didClose: category == AsleepErrorCategory.terminal,
          ),
        );
      case TrackingInterruptedEvent():
        _setState(_state.copyWith(trackingStatus: TrackingStatus.paused));
      case TrackingResumedEvent():
        _setState(
          _state.copyWith(
            trackingStatus: TrackingStatus.tracking,
            clearError: true,
          ),
        );
      case MicrophonePermissionDeniedEvent():
        _setState(
          _state.copyWith(
            error: const AsleepError(
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
        _setState(
          _state.copyWith(setupStatus: SetupStatus.idle, error: event.error),
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
  }

  void _setState(AsleepSnapshot value) {
    if (_disposed) {
      return;
    }
    _state = value;
    _states.add(value);
  }

  Future<void> _requestAnalysisFromUpload() async {
    if (_disposed || !_initialized || _state.isAnalyzing) {
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
      return AsleepError(code: error.code.name, message: error.message);
    }
    return AsleepError(
      code: 'NATIVE_FAILURE',
      message: error.toString(),
      platformDetails: <String, Object?>{'cause': error},
    );
  }
}
