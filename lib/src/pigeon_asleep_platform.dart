import 'dart:async';

import 'package:flutter/services.dart';

import 'asleep_events.dart';
import 'asleep_models.dart';
import 'asleep_platform.dart';
import 'transport.g.dart' as transport;

class PigeonAsleepPlatform extends AsleepPlatform {
  PigeonAsleepPlatform({transport.AsleepHostApi? hostApi, this._eventStream})
    : _hostApi = hostApi ?? transport.AsleepHostApi();

  final transport.AsleepHostApi _hostApi;
  final Stream<transport.NativeEventMessage>? _eventStream;
  Stream<AsleepEvent>? _events;
  static Stream<AsleepEvent>? _sharedEvents;

  @override
  Stream<AsleepEvent> get events {
    final injected = _eventStream;
    if (injected != null) {
      return _events ??= injected.map(_decodeEvent);
    }
    return _events ??= _sharedEvents ??= transport.events().map(_decodeEvent);
  }

  @override
  Future<void> setup(AsleepSetupOptions options) {
    return _hostApi
        .setup(
          transport.SetupMessage(
            apiKey: options.apiKey,
            baseUrl: options.baseUrl,
            callbackUrl: options.callbackUrl,
            service: options.service,
            enableOnDeviceAnalysis: options.enableOnDeviceAnalysis,
          ),
        )
        .asAsleepFuture();
  }

  @override
  Future<void> configure(AsleepConfiguration configuration) {
    return _hostApi
        .configure(
          transport.ConfigurationMessage(
            apiKey: configuration.apiKey,
            userId: configuration.userId,
            baseUrl: configuration.baseUrl,
            callbackUrl: configuration.callbackUrl,
          ),
        )
        .asAsleepFuture();
  }

  @override
  Future<RestoreResult> checkAndRestoreTracking() async {
    final result = await _hostApi.checkAndRestoreTracking().asAsleepFuture();
    return RestoreResult(hasActiveSession: result.hasActiveSession);
  }

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    final result = await _hostApi.checkBatteryOptimization().asAsleepFuture();
    return BatteryOptimizationStatus(
      exempted: result.exempted,
      platform: result.platform,
      message: result.message,
    );
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() {
    return _hostApi.requestBatteryOptimizationExemption().asAsleepFuture();
  }

  @override
  Future<bool> hasRequiredPermissions() {
    return _hostApi.hasRequiredPermissions().asAsleepFuture();
  }

  @override
  Future<bool> requestRequiredPermissions() {
    return _hostApi.requestRequiredPermissions().asAsleepFuture();
  }

  @override
  Future<void> startTracking(AsleepTrackingOptions options) {
    final notification = options.androidNotification;
    return _hostApi
        .startTracking(
          transport.TrackingMessage(
            androidNotification: notification == null
                ? null
                : transport.NotificationMessage(
                    title: notification.title,
                    text: notification.text,
                    icon: notification.icon,
                  ),
            iosAudioSessionOptions: options.iosAudioSessionOptions
                .map(_audioOption)
                .toList(growable: false),
          ),
        )
        .asAsleepFuture();
  }

  @override
  Future<void> resumeTracking() => _hostApi.resumeTracking().asAsleepFuture();

  @override
  Future<void> stopTracking() => _hostApi.stopTracking().asAsleepFuture();

  @override
  Future<AnalysisRequest> requestAnalysis() async {
    final result = await _hostApi.requestAnalysis().asAsleepFuture();
    final immediateJson = result.resultJson;
    return AnalysisRequest(
      status: result.status == 'completed'
          ? AnalysisRequestStatus.completed
          : AnalysisRequestStatus.requested,
      timestamp: result.timestampMilliseconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              result.timestampMilliseconds!,
              isUtc: true,
            ),
      immediateResult: immediateJson == null
          ? null
          : AsleepAnalysisResult.fromJson(decodeJsonMap(immediateJson)),
    );
  }

  @override
  Future<AsleepReport> getReport(String sessionId) async {
    return AsleepReport.fromJsonString(
      await _hostApi.getReport(sessionId).asAsleepFuture(),
    );
  }

  @override
  Future<List<AsleepSession>> getReportList(
    String fromDate,
    String toDate,
  ) async {
    final sessions = await _hostApi
        .getReportList(fromDate, toDate)
        .asAsleepFuture();
    return sessions.map(AsleepSession.fromJsonString).toList(growable: false);
  }

  @override
  Future<AsleepAverageReport> getAverageReport(
    String fromDate,
    String toDate,
  ) async {
    return AsleepAverageReport.fromJsonString(
      await _hostApi.getAverageReport(fromDate, toDate).asAsleepFuture(),
    );
  }

  @override
  Future<void> deleteSession(String sessionId) {
    return _hostApi.deleteSession(sessionId).asAsleepFuture();
  }

  @override
  Future<void> setLoggingEnabled(bool enabled) {
    return _hostApi.setLoggingEnabled(enabled).asAsleepFuture();
  }

  transport.AudioSessionOptionMessage _audioOption(
    IosAudioSessionOption value,
  ) => switch (value) {
    IosAudioSessionOption.duckOthers =>
      transport.AudioSessionOptionMessage.duckOthers,
    IosAudioSessionOption.allowAirPlay =>
      transport.AudioSessionOptionMessage.allowAirPlay,
    IosAudioSessionOption.allowBluetooth =>
      transport.AudioSessionOptionMessage.allowBluetooth,
    IosAudioSessionOption.allowBluetoothA2DP =>
      transport.AudioSessionOptionMessage.allowBluetoothA2DP,
  };

  static AsleepEvent _decodeEvent(transport.NativeEventMessage message) {
    final payload = _eventPayload(message.payloadJson);
    switch (message.type) {
      case 'onTrackingCreated':
        return TrackingCreatedEvent(
          sessionId: _optionalNonEmptyString(payload, 'sessionId'),
        );
      case 'onTrackingUploaded':
        return TrackingUploadedEvent(
          sequence: _requiredInt(payload, 'sequence'),
        );
      case 'onTrackingClosed':
        return TrackingClosedEvent(
          sessionId: _optionalNonEmptyString(payload, 'sessionId'),
        );
      case 'onTrackingFailed':
        return TrackingFailedEvent(error: _error(payload));
      case 'onTrackingInterrupted':
        return const TrackingInterruptedEvent();
      case 'onTrackingResumed':
        return const TrackingResumedEvent();
      case 'onMicPermissionDenied':
        return const MicrophonePermissionDeniedEvent();
      case 'onUserJoined':
        return UserJoinedEvent(
          userId: _requiredNonEmptyString(payload, 'userId'),
        );
      case 'onUserJoinFailed':
        return UserJoinFailedEvent(error: _error(payload));
      case 'onUserDeleted':
        return UserDeletedEvent(
          userId: _requiredNonEmptyString(payload, 'userId'),
        );
      case 'onSetupDidComplete':
        return const SetupCompletedEvent();
      case 'onSetupDidFail':
        return SetupFailedEvent(error: _error(payload));
      case 'onSetupInProgress':
        return SetupProgressEvent(
          progress: _requiredNumber(payload, 'progress').toDouble(),
        );
      case 'onAnalysisResult':
        return AnalysisResultEvent(
          result: AsleepAnalysisResult.fromJson(payload),
        );
      case 'onDebugLog':
        return DebugLogEvent(message: _requiredString(payload, 'message'));
      default:
        return UnknownNativeEvent(type: message.type, payload: payload);
    }
  }

  static Map<String, Object?> _eventPayload(String value) {
    if (value.isEmpty || value == 'null') {
      return const <String, Object?>{};
    }
    return decodeJsonMap(value);
  }

  static String? _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw _malformedEvent('Field "$key" must be a string.');
    }
    return value;
  }

  static String _requiredString(Map<String, Object?> json, String key) =>
      _string(json, key) ??
      (throw _malformedEvent('Missing string field "$key".'));

  static String _requiredNonEmptyString(Map<String, Object?> json, String key) {
    final value = _requiredString(json, key);
    if (value.isEmpty) {
      throw _malformedEvent('Field "$key" must not be empty.');
    }
    return value;
  }

  static String? _optionalNonEmptyString(
    Map<String, Object?> json,
    String key,
  ) {
    final value = _string(json, key);
    return value == null || value.isEmpty ? null : value;
  }

  static int _requiredInt(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is int) {
      return value;
    }
    if (value is num && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt();
    }
    throw _malformedEvent('Field "$key" must be an integer.');
  }

  static num _requiredNumber(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! num || !value.isFinite) {
      throw _malformedEvent('Field "$key" must be a finite number.');
    }
    return value;
  }

  static AsleepError _error(Map<String, Object?> payload) {
    _requiredNonEmptyString(payload, 'code');
    final message = _string(payload, 'message') ?? _string(payload, 'error');
    if (message == null || message.isEmpty) {
      throw _malformedEvent(
        'An error event must contain a non-empty message or error field.',
      );
    }
    return AsleepError.fromJson(payload);
  }

  static AsleepException _malformedEvent(String message) => AsleepException(
    AsleepErrorCode.malformedPayload,
    'Malformed native event: $message',
  );
}

extension _NativeFuture<T> on Future<T> {
  Future<T> asAsleepFuture() async {
    try {
      return await this;
    } on PlatformException catch (error) {
      throw AsleepException(
        AsleepErrorCode.nativeFailure,
        error.message ?? 'The native Asleep SDK operation failed.',
        nativeCode: error.code,
        nativeDetails: error.details,
        cause: error,
      );
    }
  }
}
