import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'asleep_events.dart';
import 'asleep_models.dart';
import 'asleep_platform.dart';
import 'transport.g.dart' as transport;

class PigeonAsleepPlatform extends AsleepPlatform {
  PigeonAsleepPlatform({transport.AsleepHostApi? hostApi})
    : _hostApi = hostApi ?? transport.AsleepHostApi();

  final transport.AsleepHostApi _hostApi;
  Stream<AsleepEvent>? _events;

  @override
  Stream<AsleepEvent> get events =>
      _events ??= transport.events().map(_decodeEvent).asBroadcastStream();

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

  AsleepEvent _decodeEvent(transport.NativeEventMessage message) {
    final payload = _eventPayload(message.payloadJson);
    switch (message.type) {
      case 'onTrackingCreated':
        return TrackingCreatedEvent(sessionId: _string(payload, 'sessionId'));
      case 'onTrackingUploaded':
        return TrackingUploadedEvent(sequence: _int(payload, 'sequence') ?? 0);
      case 'onTrackingClosed':
        return TrackingClosedEvent(
          sessionId: _string(payload, 'sessionId') ?? '',
        );
      case 'onTrackingFailed':
        return TrackingFailedEvent(error: AsleepError.fromJson(payload));
      case 'onTrackingInterrupted':
        return const TrackingInterruptedEvent();
      case 'onTrackingResumed':
        return const TrackingResumedEvent();
      case 'onMicPermissionDenied':
        return const MicrophonePermissionDeniedEvent();
      case 'onUserJoined':
        return UserJoinedEvent(userId: _string(payload, 'userId') ?? '');
      case 'onUserJoinFailed':
        return UserJoinFailedEvent(error: AsleepError.fromJson(payload));
      case 'onUserDeleted':
        return UserDeletedEvent(userId: _string(payload, 'userId') ?? '');
      case 'onSetupDidComplete':
        return const SetupCompletedEvent();
      case 'onSetupDidFail':
        return SetupFailedEvent(error: AsleepError.fromJson(payload));
      case 'onSetupInProgress':
        return SetupProgressEvent(
          progress: (_number(payload, 'progress') ?? 0).toDouble(),
        );
      case 'onAnalysisResult':
        return AnalysisResultEvent(
          result: AsleepAnalysisResult.fromJson(payload),
        );
      case 'onDebugLog':
        return DebugLogEvent(message: _string(payload, 'message') ?? '');
      default:
        return UnknownNativeEvent(type: message.type, payload: payload);
    }
  }

  Map<String, Object?> _eventPayload(String value) {
    if (value.isEmpty || value == 'null') {
      return const <String, Object?>{};
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      return <String, Object?>{'value': decoded};
    }
    return decoded.map((key, child) => MapEntry(key.toString(), child));
  }

  String? _string(Map<String, Object?> json, String key) =>
      json[key] is String ? json[key] as String : null;
  int? _int(Map<String, Object?> json, String key) =>
      json[key] is num ? (json[key] as num).toInt() : null;
  num? _number(Map<String, Object?> json, String key) =>
      json[key] is num ? json[key] as num : null;
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
