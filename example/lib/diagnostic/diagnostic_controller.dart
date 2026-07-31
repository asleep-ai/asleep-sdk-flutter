import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Native host behavior that the diagnostic app must keep platform-specific.
enum DiagnosticHostPlatform { android, ios }

/// Owns the diagnostic app's single client, subscriptions, and lifecycle.
class DiagnosticController extends ChangeNotifier {
  DiagnosticController({
    required AsleepClient client,
    required this.hostPlatform,
  }) : _client = client,
       _snapshot = client.state,
       _sdkPrepared =
           client.state.setupStatus == SetupStatus.complete &&
           client.state.batteryOptimizationChecked,
       _sdkPreparationAllowed =
           client.state.setupStatus == SetupStatus.idle &&
           client.state.trackingStatus == TrackingStatus.idle &&
           !client.state.batteryOptimizationChecked &&
           client.state.error == null &&
           client.state.sessionId == null &&
           !client.state.didClose,
       _recordingDeadCleanupRequired =
           client.state.error?.category == AsleepErrorCategory.recordingDead &&
           !client.state.didClose {
    final initialSessionId = client.state.sessionId?.trim();
    if (initialSessionId != null && initialSessionId.isNotEmpty) {
      _lastTrackedSessionId = initialSessionId;
    }
    _stateSubscription = _client.states.listen(_onSnapshot);
    _eventSubscription = _client.events.listen(
      _onEvent,
      onError: _onEventError,
    );
  }

  factory DiagnosticController.forCurrentPlatform() {
    final hostPlatform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => DiagnosticHostPlatform.ios,
      _ => DiagnosticHostPlatform.android,
    };
    return DiagnosticController(
      client: AsleepClient(),
      hostPlatform: hostPlatform,
    );
  }

  final AsleepClient _client;
  final DiagnosticHostPlatform hostPlatform;

  late final StreamSubscription<AsleepSnapshot> _stateSubscription;
  late final StreamSubscription<AsleepEvent> _eventSubscription;
  AsleepSnapshot _snapshot;
  BatteryOptimizationStatus? _batteryStatus;
  AsleepReport? _report;
  List<AsleepSession> _reportList = const <AsleepSession>[];
  AsleepAverageReport? _averageReport;
  final Set<String> _deletedSessionIds = <String>{};
  int _detailedReportGeneration = 0;
  int _reportListGeneration = 0;
  int _averageReportRequestGeneration = 0;
  int _averageReportCacheGeneration = 0;
  AsleepAnalysisResult? _analysisResult;
  String? _lastTrackedSessionId;
  bool? _permissionsGranted;
  AsleepError? _operationError;
  String? _operationMessage;
  String _lastEvent = 'No public events yet';
  bool _loggingEnabled = false;
  bool _deletionInFlight = false;
  bool _sdkPrepared;
  bool _sdkPreparationAllowed;
  bool _sdkPreparationInFlight = false;
  bool _analysisRequestInFlight = false;
  bool _startInFlight = false;
  int _startOutcomeGeneration = 0;
  bool _trackingRestorationRequired = false;
  bool _trackingReconciliationInFlight = false;
  bool _trackingClosePending = false;
  bool _stopAwaitingEndEvent = false;
  bool _recordingDeadCleanupRequired;
  bool _recoveryAwaitingUpload = false;
  bool _resumeInFlight = false;
  bool _closed = false;
  int _activeOperationCount = 0;
  Completer<void>? _operationsDrained;
  Future<void>? _closeFuture;
  Future<void>? _analysisRequestFuture;
  Future<void> _loggingTransition = Future<void>.value();

  AsleepSnapshot get snapshot => _snapshot;
  BatteryOptimizationStatus? get batteryStatus => _batteryStatus;
  AsleepReport? get report => _report;
  List<AsleepSession> get reportList => _reportList;
  AsleepAverageReport? get averageReport => _averageReport;
  AsleepAnalysisResult? get analysisResult => _analysisResult;
  String? get lastTrackedSessionId => _lastTrackedSessionId;
  bool? get permissionsGranted => _permissionsGranted;
  AsleepError? get operationError => _operationError;
  String? get operationMessage => _operationMessage;
  String get lastEvent => _lastEvent;
  bool get loggingEnabled => _loggingEnabled;
  bool get deletionInFlight => _deletionInFlight;
  bool get sdkPrepared => _sdkPrepared;
  bool get sdkPreparationInFlight => _sdkPreparationInFlight;
  bool get analysisRequestInFlight => _analysisRequestInFlight;
  bool get recoveryAwaitingUpload => _recoveryAwaitingUpload;
  bool get trackingRestorationRequired => _trackingRestorationRequired;
  bool get stopAwaitingEndEvent => _stopAwaitingEndEvent;
  bool get canPrepareSdk =>
      _sdkPreparationAllowed &&
      !_sdkPrepared &&
      !_sdkPreparationInFlight &&
      !canStopTracking &&
      !_stopAwaitingEndEvent &&
      !_trackingRestorationRequired &&
      !_closed;
  bool get canReconcileTracking =>
      _trackingRestorationRequired &&
      !_trackingReconciliationInFlight &&
      !_trackingClosePending;
  bool get canStopTracking =>
      !_stopAwaitingEndEvent &&
      (_snapshot.isTracking || _startInFlight || _recordingDeadCleanupRequired);
  bool get canStartTracking =>
      !canStopTracking &&
      _sdkPrepared &&
      (hostPlatform != DiagnosticHostPlatform.android ||
          _batteryStatus?.exempted == true) &&
      !_sdkPreparationInFlight &&
      !_stopAwaitingEndEvent &&
      !_trackingRestorationRequired &&
      !_trackingReconciliationInFlight;
  bool get canRequestAnalysis =>
      _sdkPrepared &&
      _snapshot.trackingStatus == TrackingStatus.tracking &&
      !_snapshot.isAnalyzing &&
      !_analysisRequestInFlight &&
      !_stopAwaitingEndEvent;
  bool get canResumeTracking =>
      (_snapshot.trackingStatus == TrackingStatus.paused ||
          _snapshot.trackingStatus == TrackingStatus.recoveryRequired) &&
      !_resumeInFlight &&
      !_recoveryAwaitingUpload &&
      !_stopAwaitingEndEvent &&
      !_closed;

  String? get operationErrorText => _safeErrorText(_operationError);
  String? get snapshotErrorText => _safeErrorText(_snapshot.error);

  String? _safeErrorText(AsleepError? error) =>
      error == null ? null : '${error.code} (${error.category.name})';

  /// Restores first, then configures that session or initializes a new one.
  ///
  /// [apiKey] remains a method-local value. This controller never persists it,
  /// places it in diagnostic state, or includes it in logs and error text.
  Future<void> initializeOrRestore(String apiKey) async {
    if (!canPrepareSdk) {
      return;
    }
    _sdkPrepared = false;
    final runtimeApiKey = apiKey.trim();
    if (runtimeApiKey.isEmpty) {
      _recordLocalError(
        AsleepError(
          code: 'API_KEY_REQUIRED',
          message: 'Enter an API key before initialization.',
        ),
      );
      return;
    }
    _sdkPreparationInFlight = true;
    _sdkPreparationAllowed = false;
    _notify();
    var prepared = false;
    try {
      prepared = await _runWithOutcome('SDK ready', () async {
        final restore = await _client.checkAndRestoreTracking();
        _trackingRestorationRequired = false;
        _trackingClosePending = false;
        if (restore.hasActiveSession) {
          await _client.configure(AsleepConfiguration(apiKey: runtimeApiKey));
        } else {
          await _client.initialize(
            AsleepSetupOptions(
              apiKey: runtimeApiKey,
              enableOnDeviceAnalysis: true,
            ),
          );
        }
        _batteryStatus = await _client.checkBatteryOptimization();
        _sdkPrepared = true;
      });
    } finally {
      _sdkPreparationAllowed = !prepared;
      _sdkPreparationInFlight = false;
      _notify();
    }
  }

  Future<bool?> checkPermissions() async {
    bool? result;
    await _run('Permission status checked', () async {
      result = await _client.hasRequiredPermissions();
      _permissionsGranted = result;
    });
    return result;
  }

  Future<bool?> requestPermissions() async {
    bool? result;
    await _run('Permission request complete', () async {
      result = await _client.requestRequiredPermissions();
      _permissionsGranted = result;
    });
    return result;
  }

  Future<void> recheckBatteryOptimization() async {
    await _run('Battery status refreshed', () async {
      _batteryStatus = await _client.checkBatteryOptimization();
    });
  }

  /// Opens Android-owned battery settings. Recheck in a separate user action.
  Future<bool?> openBatterySettings() =>
      _runValue(_client.requestBatteryOptimizationExemption);

  Future<void> startTracking() async {
    if (!canStartTracking || _closed) {
      return;
    }
    _startInFlight = true;
    final outcomeGeneration = ++_startOutcomeGeneration;
    _notify();
    try {
      await _runWithOutcome(
        'Tracking start requested',
        () async {
          final options = switch (hostPlatform) {
            DiagnosticHostPlatform.android => const AsleepTrackingOptions(
              androidNotification: AndroidNotificationOptions(
                title: 'Sleep tracking',
                text: 'Asleep diagnostic session is recording',
              ),
            ),
            DiagnosticHostPlatform.ios => const AsleepTrackingOptions(
              iosAudioSessionOptions: <IosAudioSessionOption>[
                IosAudioSessionOption.allowBluetoothA2DP,
              ],
            ),
          };
          try {
            await _client.startTracking(options);
            _permissionsGranted = true;
          } on AsleepException catch (error) {
            if (error.code == AsleepErrorCode.permissionRequired) {
              _permissionsGranted = false;
            }
            if (error.nativeCode == 'TRACKING_START_TIMEOUT') {
              _trackingRestorationRequired = true;
              _trackingClosePending = false;
            }
            rethrow;
          }
        },
        shouldCommitOutcome: () => _startOutcomeGeneration == outcomeGeneration,
      );
    } finally {
      _startInFlight = false;
      _releaseStopAwaitingWithoutEndEventIfSettled();
      _notify();
    }
  }

  Future<void> resumeTracking() => _resumeForForeground();

  Future<void> stopTracking() async {
    if (_stopAwaitingEndEvent || _closed) {
      return;
    }
    final mustReconcile = _startInFlight;
    _startOutcomeGeneration++;
    _stopAwaitingEndEvent = true;
    if (mustReconcile) {
      _trackingRestorationRequired = true;
      _trackingReconciliationInFlight = true;
    }
    _notify();
    var stopSucceeded = false;
    try {
      await _runWithOutcome(null, () async {
        await _client.stopTracking();
        stopSucceeded = true;
        if (mustReconcile) {
          if (_client.state.trackingStatus == TrackingStatus.idle) {
            await _restoreTrackingState();
          } else {
            _trackingClosePending = true;
            _operationMessage = 'Tracking stop requested; waiting for close';
          }
        } else if (_stopAwaitingEndEvent) {
          _operationMessage = 'Tracking stop requested; waiting for close';
        } else {
          _operationMessage = 'Tracking stopped';
        }
      });
    } finally {
      if (!stopSucceeded) {
        _stopAwaitingEndEvent = false;
      }
      if (mustReconcile) {
        _trackingReconciliationInFlight = false;
      }
      _notify();
    }
  }

  Future<void> reconcileTrackingState() async {
    if (!_trackingRestorationRequired ||
        _trackingReconciliationInFlight ||
        _closed) {
      return;
    }
    _trackingReconciliationInFlight = true;
    _notify();
    try {
      await _runWithOutcome(null, _restoreTrackingState);
    } finally {
      _trackingReconciliationInFlight = false;
      _notify();
    }
  }

  Future<void> requestAnalysis() {
    final activeRequest = _analysisRequestFuture;
    if (activeRequest != null) {
      return activeRequest;
    }
    if (!canRequestAnalysis || _closed) {
      return Future<void>.value();
    }
    final completion = Completer<void>();
    _analysisRequestInFlight = true;
    _analysisRequestFuture = completion.future;
    _notify();
    unawaited(_requestAnalysis(completion));
    return completion.future;
  }

  Future<void> _requestAnalysis(Completer<void> completion) async {
    try {
      await _run('Analysis requested', () async {
        final request = await _client.requestAnalysis();
        if (request.immediateResult case final result?) {
          _analysisResult = result;
        }
      });
    } finally {
      _analysisRequestInFlight = false;
      _analysisRequestFuture = null;
      _notify();
      completion.complete();
    }
  }

  Future<void> _restoreTrackingState() async {
    final restore = await _client.checkAndRestoreTracking();
    _trackingRestorationRequired = false;
    _trackingClosePending = false;
    _operationMessage = restore.hasActiveSession
        ? 'Active tracking restored'
        : 'Tracking stopped';
    _releaseStopAwaitingWithoutEndEventIfSettled();
  }

  Future<void> loadReport(String sessionId) async {
    final normalized = sessionId.trim();
    final generation = ++_detailedReportGeneration;
    await _runWithOutcome(null, () async {
      final report = await _client.getReport(normalized);
      if (_detailedReportGeneration != generation) {
        return;
      }
      if (!_deletedSessionIds.contains(report.session.id)) {
        _report = report;
        _operationMessage = 'Detailed report loaded';
      } else {
        _operationMessage = 'Deleted session report ignored';
      }
    }, shouldCommitOutcome: () => _detailedReportGeneration == generation);
  }

  Future<void> loadReportList(String fromDate, String toDate) async {
    final generation = ++_reportListGeneration;
    await _runWithOutcome(
      'Report list loaded',
      () async {
        final reports = await _client.getReportList(
          fromDate.trim(),
          toDate.trim(),
        );
        if (_reportListGeneration != generation) {
          return;
        }
        _reportList = reports
            .where((session) => !_deletedSessionIds.contains(session.id))
            .toList(growable: false);
      },
      shouldCommitOutcome: () => _reportListGeneration == generation,
    );
  }

  Future<void> loadAverageReport(String fromDate, String toDate) async {
    final requestGeneration = ++_averageReportRequestGeneration;
    final cacheGeneration = _averageReportCacheGeneration;
    await _runWithOutcome(
      null,
      () async {
        final report = await _client.getAverageReport(
          fromDate.trim(),
          toDate.trim(),
        );
        if (_averageReportRequestGeneration != requestGeneration) {
          return;
        }
        if (_averageReportCacheGeneration == cacheGeneration) {
          _averageReport = report;
          _operationMessage = 'Average report loaded';
        } else {
          _operationMessage = 'Stale average report ignored';
        }
      },
      shouldCommitOutcome: () =>
          _averageReportRequestGeneration == requestGeneration,
    );
  }

  /// Deletes only after the app's irreversible-action UI has confirmed.
  Future<bool> deleteSession(
    String sessionId, {
    required bool confirmed,
  }) async {
    if (_deletionInFlight) {
      return false;
    }
    if (!confirmed) {
      _operationError = null;
      _operationMessage = 'Deletion cancelled';
      _notify();
      return false;
    }
    final normalized = sessionId.trim();
    _deletionInFlight = true;
    _notify();
    var deleted = false;
    try {
      await _run('Session deleted', () async {
        await _client.deleteSession(normalized);
        _deletedSessionIds.add(normalized);
        _averageReportCacheGeneration++;
        if (_report?.session.id == normalized) {
          _report = null;
        }
        _reportList = _reportList
            .where((session) => session.id != normalized)
            .toList(growable: false);
        _averageReport = null;
        deleted = true;
      });
      return deleted;
    } finally {
      _deletionInFlight = false;
      _notify();
    }
  }

  Future<void> setLoggingEnabled(bool enabled) {
    if (_closed) {
      return Future<void>.value();
    }
    final transition = _loggingTransition.then((_) async {
      if (_closed) {
        return;
      }
      await _run(
        enabled ? 'Diagnostic logging enabled' : 'Diagnostic logging disabled',
        () async {
          await _client.setLoggingEnabled(enabled);
          _loggingEnabled = enabled;
        },
      );
    });
    _loggingTransition = transition;
    return transition;
  }

  /// Handles only iOS foreground recovery and deduplicates resumed callbacks.
  Future<void> handleLifecycleState(AppLifecycleState state) async {
    if (state != AppLifecycleState.resumed ||
        hostPlatform != DiagnosticHostPlatform.ios ||
        _closed) {
      return;
    }
    final trackingStatus = _snapshot.trackingStatus;
    if (trackingStatus != TrackingStatus.paused &&
        trackingStatus != TrackingStatus.recoveryRequired) {
      return;
    }
    await _resumeForForeground();
  }

  Future<void> _resumeForForeground() async {
    if (!canResumeTracking) {
      return;
    }
    _resumeInFlight = true;
    _recoveryAwaitingUpload = true;
    _notify();
    try {
      final resumed = await _runWithOutcome(
        'Foreground recovery requested',
        _client.resumeTracking,
      );
      if (!resumed) {
        _recoveryAwaitingUpload = false;
      }
    } finally {
      _resumeInFlight = false;
      _notify();
    }
  }

  Future<void> _run(
    String successMessage,
    FutureOr<void> Function() action,
  ) async {
    await _runWithOutcome(successMessage, action);
  }

  Future<bool> _runWithOutcome(
    String? successMessage,
    FutureOr<void> Function() action, {
    bool Function()? shouldCommitOutcome,
  }) async {
    if (_closed) {
      return false;
    }
    _beginOperation();
    try {
      _operationError = null;
      _operationMessage = null;
      _notify();
      try {
        await action();
        if (!(shouldCommitOutcome?.call() ?? true)) {
          return true;
        }
        if (successMessage != null) {
          _operationMessage = successMessage;
        }
        _notify();
        return true;
      } on AsleepException catch (error) {
        if (!(shouldCommitOutcome?.call() ?? true)) {
          return false;
        }
        _operationError = error.error ?? _client.state.error;
        _operationMessage = 'Operation failed';
      } catch (_) {
        if (!(shouldCommitOutcome?.call() ?? true)) {
          return false;
        }
        _operationError =
            _client.state.error ??
            AsleepError(
              code: 'UNEXPECTED_FAILURE',
              message: 'The operation failed without diagnostic details.',
            );
        _operationMessage = 'Operation failed';
      }
      _notify();
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<T?> _runValue<T>(Future<T> Function() action) async {
    T? result;
    await _run('Operation complete', () async {
      result = await action();
    });
    return result;
  }

  void _recordLocalError(AsleepError error) {
    _operationError = error;
    _operationMessage = 'Operation failed';
    _notify();
  }

  void _onSnapshot(AsleepSnapshot snapshot) {
    _snapshot = snapshot;
    if (snapshot.setupStatus != SetupStatus.complete) {
      _sdkPrepared = false;
    }
    final sessionId = snapshot.sessionId?.trim();
    if (sessionId != null && sessionId.isNotEmpty) {
      _lastTrackedSessionId = sessionId;
    }
    _notify();
  }

  void _onEvent(AsleepEvent event) {
    if (event is DebugLogEvent) {
      return;
    }
    if (event is TrackingCreatedEvent) {
      _recordingDeadCleanupRequired = false;
    }
    if (event is TrackingUploadedEvent && _recoveryAwaitingUpload) {
      _recoveryAwaitingUpload = false;
    }
    if (event is TrackingInterruptedEvent && _recoveryAwaitingUpload) {
      _recoveryAwaitingUpload = false;
    }
    if (event is MicrophonePermissionDeniedEvent) {
      _permissionsGranted = false;
    }
    if (event is TrackingClosedEvent) {
      _recordingDeadCleanupRequired = false;
      if (_recoveryAwaitingUpload) {
        _recoveryAwaitingUpload = false;
      }
      _handleTrackingEnded();
    }
    if (event case AnalysisResultEvent(:final result)) {
      _analysisResult = result;
    }
    if (event case TrackingFailedEvent(:final error)
        when _recoveryAwaitingUpload &&
            (error.category == AsleepErrorCategory.terminal ||
                error.category == AsleepErrorCategory.recordingDead)) {
      _recoveryAwaitingUpload = false;
    }
    if (event case TrackingFailedEvent(:final error)
        when _recoveryAwaitingUpload &&
            error.category == AsleepErrorCategory.recoveryRequired) {
      _recoveryAwaitingUpload = false;
    }
    if (event case TrackingFailedEvent(:final error)) {
      if (error.category == AsleepErrorCategory.recordingDead) {
        _recordingDeadCleanupRequired = true;
      } else if (error.category == AsleepErrorCategory.terminal) {
        _recordingDeadCleanupRequired = false;
      }
      if (error.category == AsleepErrorCategory.terminal ||
          error.category == AsleepErrorCategory.recordingDead) {
        _handleTrackingEnded();
      }
    }
    _lastEvent = _safeEventLabel(event);
    _notify();
  }

  void _handleTrackingEnded() {
    final completedPendingStop = _stopAwaitingEndEvent;
    _stopAwaitingEndEvent = false;
    if (!_trackingRestorationRequired || !_trackingClosePending) {
      if (completedPendingStop) {
        _operationMessage = 'Tracking stopped';
      }
      return;
    }
    _trackingClosePending = false;
    unawaited(reconcileTrackingState());
  }

  void _releaseStopAwaitingWithoutEndEventIfSettled() {
    if (_stopAwaitingEndEvent &&
        !_trackingRestorationRequired &&
        !_trackingClosePending &&
        !_startInFlight) {
      _stopAwaitingEndEvent = false;
    }
  }

  void _onEventError(Object streamError, StackTrace _) {
    if (_closed) {
      return;
    }
    final structuredError = switch (streamError) {
      AsleepException(:final error?) => error,
      _ => _client.state.error,
    };
    _operationError = structuredError == null
        ? AsleepError(
            code: 'EVENT_STREAM_FAILURE',
            message: 'The native event stream failed.',
          )
        : AsleepError(
            code: structuredError.code,
            message: 'The native event stream failed.',
            category: structuredError.category,
            numericCode: structuredError.numericCode,
          );
    _operationMessage = 'Native event stream failed';
    _lastEvent = 'Native event stream failed';
    _notify();
  }

  String _safeEventLabel(AsleepEvent event) => switch (event) {
    TrackingCreatedEvent() => 'Tracking created',
    TrackingUploadedEvent() => 'Tracking upload received',
    TrackingClosedEvent() => 'Tracking closed',
    TrackingFailedEvent() => 'Tracking failed',
    TrackingInterruptedEvent() => 'Tracking interrupted',
    TrackingResumedEvent() => 'Tracking resumed callback received',
    MicrophonePermissionDeniedEvent() => 'Microphone permission denied',
    UserJoinedEvent() => 'User associated',
    UserJoinFailedEvent() => 'User association failed',
    UserDeletedEvent() => 'User association deleted',
    SetupCompletedEvent() => 'Setup completed',
    SetupFailedEvent() => 'Setup failed',
    SetupProgressEvent() => 'Setup progress received',
    AnalysisResultEvent() => 'Analysis result received',
    UnknownNativeEvent() => 'Unknown native event received',
    DebugLogEvent() => 'Diagnostic log suppressed',
  };

  void _notify() {
    if (!_closed) {
      notifyListeners();
    }
  }

  void _beginOperation() {
    if (_activeOperationCount == 0) {
      _operationsDrained = Completer<void>();
    }
    _activeOperationCount++;
  }

  void _endOperation() {
    _activeOperationCount--;
    if (_activeOperationCount == 0) {
      _operationsDrained!.complete();
      _operationsDrained = null;
    }
  }

  Future<void> _waitForActiveOperations() => _activeOperationCount == 0
      ? Future<void>.value()
      : _operationsDrained!.future;

  /// Turns logging off, cancels app subscriptions, then disposes the client.
  Future<void> close() {
    final activeClose = _closeFuture;
    if (activeClose != null) {
      return activeClose;
    }
    final future = _close();
    _closeFuture = future;
    return future;
  }

  Future<void> _close() async {
    _closed = true;
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

    await cleanUp(_waitForActiveOperations);
    await cleanUp(() => _loggingTransition);
    await cleanUp(() => _client.setLoggingEnabled(false));
    await cleanUp(_stateSubscription.cancel);
    await cleanUp(_eventSubscription.cancel);
    await cleanUp(_client.dispose);
    super.dispose();

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}
