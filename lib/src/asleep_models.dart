import 'dart:convert';

enum SetupStatus { idle, inProgress, complete }

enum TrackingStatus { idle, tracking, paused, recoveryRequired }

enum AsleepErrorCategory {
  terminal,
  recordingDead,
  recoveryRequired,
  transient,
  unknown,
}

enum AsleepErrorCode {
  disposed,
  invalidState,
  permissionRequired,
  unsupportedPlatform,
  nativeFailure,
  malformedPayload,
}

enum IosAudioSessionOption {
  duckOthers,
  allowAirPlay,
  allowBluetooth,
  allowBluetoothA2DP,
}

enum AnalysisRequestStatus { requested, completed }

class AsleepSetupOptions {
  const AsleepSetupOptions({
    required this.apiKey,
    this.baseUrl,
    this.callbackUrl,
    this.service,
    this.enableOnDeviceAnalysis = false,
  });

  final String apiKey;
  final String? baseUrl;
  final String? callbackUrl;
  final String? service;
  final bool enableOnDeviceAnalysis;
}

class AsleepConfiguration {
  const AsleepConfiguration({
    required this.apiKey,
    this.userId,
    this.baseUrl,
    this.callbackUrl,
  });

  final String apiKey;
  final String? userId;
  final String? baseUrl;
  final String? callbackUrl;
}

class AndroidNotificationOptions {
  const AndroidNotificationOptions({this.title, this.text, this.icon});

  final String? title;
  final String? text;
  final String? icon;
}

class AsleepTrackingOptions {
  const AsleepTrackingOptions({
    this.androidNotification,
    this.iosAudioSessionOptions = const <IosAudioSessionOption>[],
  });

  final AndroidNotificationOptions? androidNotification;
  final List<IosAudioSessionOption> iosAudioSessionOptions;
}

class RestoreResult {
  const RestoreResult({required this.hasActiveSession});

  final bool hasActiveSession;
}

class BatteryOptimizationStatus {
  const BatteryOptimizationStatus({
    required this.exempted,
    required this.platform,
    this.message,
  });

  final bool exempted;
  final String platform;
  final String? message;
}

class AnalysisRequest {
  const AnalysisRequest({
    required this.status,
    this.timestamp,
    this.immediateResult,
  });

  final AnalysisRequestStatus status;
  final DateTime? timestamp;
  final AsleepAnalysisResult? immediateResult;
}

class AsleepError {
  const AsleepError({
    required this.code,
    required this.message,
    this.category = AsleepErrorCategory.unknown,
    this.numericCode,
    this.platformDetails = const <String, Object?>{},
  });

  factory AsleepError.fromJson(Map<String, Object?> json) {
    final categoryName = _string(json, 'category');
    final numericCode =
        _int(json, 'sdkCode') ??
        _int(json, 'numericCode') ??
        _int(json, 'error_code');
    final category = AsleepErrorCategory.values.firstWhere(
      (value) => value.name == categoryName,
      orElse: () => _categoryForCode(_string(json, 'code'), numericCode),
    );
    return AsleepError(
      code: _string(json, 'code') ?? 'UNKNOWN_ERROR',
      message:
          _string(json, 'message') ??
          _string(json, 'error') ??
          'Unknown native error',
      category: category,
      numericCode: numericCode,
      platformDetails: Map<String, Object?>.unmodifiable(json),
    );
  }

  final String code;
  final String message;
  final AsleepErrorCategory category;
  final int? numericCode;
  final Map<String, Object?> platformDetails;

  static AsleepErrorCategory _categoryForCode(String? code, int? numericCode) {
    switch (code) {
      case 'UPLOAD_TRACKING_TERMINATED':
        return AsleepErrorCategory.terminal;
      case 'AUDIO_INITIALIZATION_FAILED':
        return AsleepErrorCategory.recordingDead;
      case 'CANNOT_ACTIVATE_IN_BACKGROUND':
        return AsleepErrorCategory.recoveryRequired;
      case 'INTERRUPTION_RECOVERY_FAILED':
        return AsleepErrorCategory.terminal;
      case 'NETWORK_OFFLINE':
        return AsleepErrorCategory.transient;
      default:
        return _terminalNumericCodes.contains(numericCode)
            ? AsleepErrorCategory.terminal
            : AsleepErrorCategory.unknown;
    }
  }

  static const Set<int> _terminalNumericCodes = <int>{
    11003,
    22000,
    22401,
    22409,
    22422,
    22500,
    23499,
    24000,
    24400,
    24401,
    24403,
    24404,
    24500,
  };
}

class AsleepException implements Exception {
  const AsleepException(
    this.code,
    this.message, {
    this.nativeCode,
    this.nativeDetails,
    this.cause,
  });

  final AsleepErrorCode code;
  final String message;
  final String? nativeCode;
  final Object? nativeDetails;
  final Object? cause;

  @override
  String toString() => 'AsleepException(${code.name}): $message';
}

class AsleepAnalysisResult {
  const AsleepAnalysisResult({
    this.id,
    this.state,
    this.startTime,
    this.endTime,
    this.sleepStages,
    this.breathStages,
    this.snoringStages,
  });

  factory AsleepAnalysisResult.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepAnalysisResult(
      id: _string(json, 'id'),
      state: _string(json, 'state'),
      startTime: _date(json, 'startTime'),
      endTime: _date(json, 'endTime'),
      sleepStages: _intList(json, 'sleepStages'),
      breathStages: _intList(json, 'breathStages'),
      snoringStages: _intList(json, 'snoringStages'),
    );
  }

  final String? id;
  final String? state;
  final DateTime? startTime;
  final DateTime? endTime;
  final List<int>? sleepStages;
  final List<int>? breathStages;
  final List<int>? snoringStages;
}

class AsleepReportSession {
  const AsleepReportSession({
    required this.id,
    required this.createdTimezone,
    required this.startTime,
    this.endTime,
    this.unexpectedEndTime,
    required this.state,
    this.sleepStages,
    this.breathStages,
    this.snoringStages,
  });

  factory AsleepReportSession.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepReportSession(
      id: _requiredString(json, 'id'),
      createdTimezone: _requiredString(json, 'createdTimezone'),
      startTime: _requiredDate(json, 'startTime'),
      endTime: _date(json, 'endTime'),
      unexpectedEndTime: _date(json, 'unexpectedEndTime'),
      state: _requiredString(json, 'state'),
      sleepStages: _intList(json, 'sleepStages'),
      breathStages: _intList(json, 'breathStages'),
      snoringStages: _intList(json, 'snoringStages'),
    );
  }

  final String id;
  final String createdTimezone;
  final DateTime startTime;
  final DateTime? endTime;
  final DateTime? unexpectedEndTime;
  final String state;
  final List<int>? sleepStages;
  final List<int>? breathStages;
  final List<int>? snoringStages;
}

class AsleepStat {
  AsleepStat._(this.values);

  factory AsleepStat.fromJson(Map<String, Object?> json) {
    return AsleepStat._(Map<String, Object?>.unmodifiable(_camelized(json)));
  }

  final Map<String, Object?> values;

  int? get timeInBed => _int(values, 'timeInBed');
  int? get timeInSleep => _int(values, 'timeInSleep');
  int? get timeInWake => _int(values, 'timeInWake');
  int? get timeInRem => _int(values, 'timeInRem');
  int? get timeInLight => _int(values, 'timeInLight');
  int? get timeInDeep => _int(values, 'timeInDeep');
  int? get sleepLatency => _int(values, 'sleepLatency');
  int? get wakeupLatency => _int(values, 'wakeupLatency');
  int? get wasoCount => _int(values, 'wasoCount');
  int? get longestWaso => _int(values, 'longestWaso');
  double? get sleepEfficiency => _double(values, 'sleepEfficiency');
  double? get breathingIndex => _double(values, 'breathingIndex');
}

class AsleepReport {
  const AsleepReport({
    required this.timezone,
    required this.session,
    required this.missingDataRatio,
    required this.peculiarities,
    this.stat,
  });

  factory AsleepReport.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    final stat = _map(json, 'stat');
    return AsleepReport(
      timezone: _requiredString(json, 'timezone'),
      session: AsleepReportSession.fromJson(_requiredMap(json, 'session')),
      missingDataRatio: _double(json, 'missingDataRatio') ?? 0,
      peculiarities: _stringList(json, 'peculiarities') ?? const <String>[],
      stat: stat == null ? null : AsleepStat.fromJson(stat),
    );
  }

  factory AsleepReport.fromJsonString(String value) {
    return AsleepReport.fromJson(_decodeMap(value));
  }

  final String timezone;
  final AsleepReportSession session;
  final double missingDataRatio;
  final List<String> peculiarities;
  final AsleepStat? stat;
}

class AsleepSession {
  const AsleepSession({
    required this.id,
    required this.state,
    required this.startTime,
    required this.createdTimezone,
    this.endTime,
    this.unexpectedEndTime,
    this.lastReceivedSequence,
    this.timeInBed,
  });

  factory AsleepSession.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    final id = _string(json, 'id') ?? _string(json, 'sessionId');
    final start = _date(json, 'startTime') ?? _date(json, 'sessionStartTime');
    if (id == null || start == null) {
      throw const AsleepException(
        AsleepErrorCode.malformedPayload,
        'A session payload is missing its id or start time.',
      );
    }
    return AsleepSession(
      id: id,
      state: _requiredString(json, 'state'),
      startTime: start,
      endTime: _date(json, 'endTime') ?? _date(json, 'sessionEndTime'),
      createdTimezone: _requiredString(json, 'createdTimezone'),
      unexpectedEndTime: _date(json, 'unexpectedEndTime'),
      lastReceivedSequence: _int(json, 'lastReceivedSeqNum'),
      timeInBed: _int(json, 'timeInBed'),
    );
  }

  factory AsleepSession.fromJsonString(String value) {
    return AsleepSession.fromJson(_decodeMap(value));
  }

  final String id;
  final String state;
  final DateTime startTime;
  final DateTime? endTime;
  final String createdTimezone;
  final DateTime? unexpectedEndTime;
  final int? lastReceivedSequence;
  final int? timeInBed;
}

class AsleepReportPeriod {
  const AsleepReportPeriod({
    required this.timezone,
    required this.startDate,
    required this.endDate,
  });

  factory AsleepReportPeriod.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepReportPeriod(
      timezone: _requiredString(json, 'timezone'),
      startDate: _requiredString(json, 'startDate'),
      endDate: _requiredString(json, 'endDate'),
    );
  }

  final String timezone;
  final String startDate;
  final String endDate;
}

class AsleepSleptSession {
  AsleepSleptSession._({
    required this.id,
    required this.startTime,
    required this.endTime,
    required this.createdTimezone,
    required this.stats,
    required this.raw,
  });

  factory AsleepSleptSession.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepSleptSession._(
      id: _requiredString(json, 'id'),
      startTime: _requiredDate(json, 'startTime'),
      endTime: _requiredDate(json, 'endTime'),
      createdTimezone: _requiredString(json, 'createdTimezone'),
      stats: AsleepStat.fromJson(json),
      raw: Map<String, Object?>.unmodifiable(json),
    );
  }

  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final String createdTimezone;
  final AsleepStat stats;
  final Map<String, Object?> raw;
}

class AsleepNeverSleptSession {
  AsleepNeverSleptSession._({
    required this.id,
    required this.startTime,
    required this.endTime,
    this.completedTime,
    required this.raw,
  });

  factory AsleepNeverSleptSession.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepNeverSleptSession._(
      id: _requiredString(json, 'id'),
      startTime: _requiredDate(json, 'startTime'),
      endTime: _requiredDate(json, 'endTime'),
      completedTime: _date(json, 'completedTime'),
      raw: Map<String, Object?>.unmodifiable(json),
    );
  }

  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final DateTime? completedTime;
  final Map<String, Object?> raw;
}

class AsleepAverageReport {
  AsleepAverageReport._({
    required this.period,
    required this.peculiarities,
    this.averageStats,
    required this.sleptSessions,
    required this.neverSleptSessions,
    required this.raw,
  });

  factory AsleepAverageReport.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    final averageStats = _map(json, 'averageStats');
    return AsleepAverageReport._(
      period: AsleepReportPeriod.fromJson(_requiredMap(json, 'period')),
      peculiarities: _stringList(json, 'peculiarities') ?? const <String>[],
      averageStats: averageStats == null
          ? null
          : AsleepStat.fromJson(averageStats),
      sleptSessions:
          (_mapList(json, 'sleptSessions') ?? const <Map<String, Object?>>[])
              .map(AsleepSleptSession.fromJson)
              .toList(growable: false),
      neverSleptSessions:
          (_mapList(json, 'neverSleptSessions') ??
                  const <Map<String, Object?>>[])
              .map(AsleepNeverSleptSession.fromJson)
              .toList(growable: false),
      raw: Map<String, Object?>.unmodifiable(json),
    );
  }

  factory AsleepAverageReport.fromJsonString(String value) {
    return AsleepAverageReport.fromJson(_decodeMap(value));
  }

  final AsleepReportPeriod period;
  final List<String> peculiarities;
  final AsleepStat? averageStats;
  final List<AsleepSleptSession> sleptSessions;
  final List<AsleepNeverSleptSession> neverSleptSessions;
  final Map<String, Object?> raw;
}

class AsleepSnapshot {
  const AsleepSnapshot({
    this.setupStatus = SetupStatus.idle,
    this.trackingStatus = TrackingStatus.idle,
    this.userId,
    this.sessionId,
    this.analysisResult,
    this.isAnalyzing = false,
    this.error,
    this.didClose = false,
    this.batteryOptimizationChecked = false,
  });

  final SetupStatus setupStatus;
  final TrackingStatus trackingStatus;
  final String? userId;
  final String? sessionId;
  final AsleepAnalysisResult? analysisResult;
  final bool isAnalyzing;
  final AsleepError? error;
  final bool didClose;
  final bool batteryOptimizationChecked;

  bool get isTracking => trackingStatus != TrackingStatus.idle;
  bool get isPaused => trackingStatus == TrackingStatus.paused;

  AsleepSnapshot copyWith({
    SetupStatus? setupStatus,
    TrackingStatus? trackingStatus,
    String? userId,
    bool clearUserId = false,
    String? sessionId,
    bool clearSessionId = false,
    AsleepAnalysisResult? analysisResult,
    bool clearAnalysisResult = false,
    bool? isAnalyzing,
    AsleepError? error,
    bool clearError = false,
    bool? didClose,
    bool? batteryOptimizationChecked,
  }) {
    return AsleepSnapshot(
      setupStatus: setupStatus ?? this.setupStatus,
      trackingStatus: trackingStatus ?? this.trackingStatus,
      userId: clearUserId ? null : userId ?? this.userId,
      sessionId: clearSessionId ? null : sessionId ?? this.sessionId,
      analysisResult: clearAnalysisResult
          ? null
          : analysisResult ?? this.analysisResult,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      error: clearError ? null : error ?? this.error,
      didClose: didClose ?? this.didClose,
      batteryOptimizationChecked:
          batteryOptimizationChecked ?? this.batteryOptimizationChecked,
    );
  }
}

Map<String, Object?> decodeJsonMap(String value) => _decodeMap(value);

Map<String, Object?> _decodeMap(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) {
    throw const AsleepException(
      AsleepErrorCode.malformedPayload,
      'Expected a JSON object from the native SDK.',
    );
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

Map<String, Object?> _camelized(Map<String, Object?> source) {
  return source.map((key, value) {
    final normalized = key.replaceAllMapped(
      RegExp(r'_([a-z])'),
      (match) => match.group(1)!.toUpperCase(),
    );
    return MapEntry(normalized, _camelizeValue(value));
  });
}

Object? _camelizeValue(Object? value) {
  if (value is Map) {
    return _camelized(
      value.map((key, child) => MapEntry(key.toString(), child)),
    );
  }
  if (value is List) {
    return value.map(_camelizeValue).toList(growable: false);
  }
  return value;
}

String? _string(Map<String, Object?> json, String key) =>
    json[key] is String ? json[key] as String : null;
String _requiredString(Map<String, Object?> json, String key) =>
    _string(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing string field "$key".',
    ));
int? _int(Map<String, Object?> json, String key) =>
    json[key] is num ? (json[key] as num).toInt() : null;
double? _double(Map<String, Object?> json, String key) =>
    json[key] is num ? (json[key] as num).toDouble() : null;
DateTime? _date(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  return value == null ? null : DateTime.tryParse(value)?.toUtc();
}

DateTime _requiredDate(Map<String, Object?> json, String key) =>
    _date(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing date field "$key".',
    ));
Map<String, Object?>? _map(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is Map
      ? value.map((childKey, child) => MapEntry(childKey.toString(), child))
      : null;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) =>
    _map(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing object field "$key".',
    ));
List<int>? _intList(Map<String, Object?> json, String key) => json[key] is List
    ? (json[key] as List)
          .whereType<num>()
          .map((value) => value.toInt())
          .toList(growable: false)
    : null;
List<String>? _stringList(Map<String, Object?> json, String key) =>
    json[key] is List
    ? (json[key] as List).whereType<String>().toList(growable: false)
    : null;
List<Map<String, Object?>>? _mapList(Map<String, Object?> json, String key) =>
    json[key] is List
    ? (json[key] as List)
          .whereType<Map>()
          .map(
            (value) => value.map(
              (childKey, child) => MapEntry(childKey.toString(), child),
            ),
          )
          .toList(growable: false)
    : null;
