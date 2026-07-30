import 'dart:convert';

/// Lifecycle state of native SDK setup.
enum SetupStatus { idle, inProgress, complete }

/// Lifecycle state of a tracking session.
enum TrackingStatus { idle, tracking, paused, recoveryRequired }

/// Recovery behavior associated with an SDK error.
enum AsleepErrorCategory {
  terminal,
  recordingDead,
  recoveryRequired,
  transient,
  unknown,
}

/// Errors produced by the Flutter client boundary.
enum AsleepErrorCode {
  disposed,
  invalidArgument,
  invalidState,
  permissionRequired,
  unsupportedPlatform,
  nativeFailure,
  malformedPayload,
}

/// iOS audio-session options accepted while tracking.
enum IosAudioSessionOption {
  duckOthers,
  allowAirPlay,
  allowBluetooth,
  allowBluetoothA2DP,
}

/// Current state of an analysis request.
enum AnalysisRequestStatus { requested, completed }

/// Options used to initialize the native Asleep SDK.
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

/// Credentials and endpoints used to configure the native SDK.
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

/// Android foreground-service notification overrides.
class AndroidNotificationOptions {
  const AndroidNotificationOptions({this.title, this.text, this.icon});

  final String? title;
  final String? text;
  final String? icon;
}

/// Platform-specific options for a new tracking session.
class AsleepTrackingOptions {
  const AsleepTrackingOptions({
    this.androidNotification,
    this.iosAudioSessionOptions = const <IosAudioSessionOption>[],
  });

  final AndroidNotificationOptions? androidNotification;
  final List<IosAudioSessionOption> iosAudioSessionOptions;
}

/// Result of checking for a restorable tracking session.
class RestoreResult {
  const RestoreResult({required this.hasActiveSession});

  final bool hasActiveSession;
}

/// Android battery-optimization status reported by the native SDK.
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

/// Acknowledgement and optional immediate result of an analysis request.
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

/// Structured error received from a native Asleep SDK.
class AsleepError {
  AsleepError({
    required this.code,
    required this.message,
    this.category = AsleepErrorCategory.unknown,
    this.numericCode,
    Map<String, Object?> platformDetails = const <String, Object?>{},
  }) : platformDetails = _immutableMap(platformDetails);

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
          _string(json, 'detail') ??
          'Unknown native error',
      category: category,
      numericCode: numericCode,
      platformDetails: json,
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
        if (_terminalNumericCodes.contains(numericCode)) {
          return AsleepErrorCategory.terminal;
        }
        if (_transientNumericCodes.contains(numericCode)) {
          return AsleepErrorCategory.transient;
        }
        return AsleepErrorCategory.unknown;
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

  static const Set<int> _transientNumericCodes = <int>{23000, 23500};
}

/// Exception thrown by the Flutter SDK boundary.
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

/// Incremental analysis data for an active or completed session.
class AsleepAnalysisResult {
  AsleepAnalysisResult({
    this.id,
    this.state,
    this.startTime,
    this.endTime,
    List<int>? sleepStages,
    List<int>? breathStages,
    List<int>? snoringStages,
  }) : sleepStages = _immutableListOrNull(sleepStages),
       breathStages = _immutableListOrNull(breathStages),
       snoringStages = _immutableListOrNull(snoringStages);

  factory AsleepAnalysisResult.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepAnalysisResult(
      id: _optionalNonEmptyString(json, 'id'),
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

/// Session metadata and stage data embedded in a detailed report.
class AsleepReportSession {
  AsleepReportSession({
    required this.id,
    required this.createdTimezone,
    required this.startTime,
    this.endTime,
    this.unexpectedEndTime,
    required this.state,
    List<int>? sleepStages,
    List<int>? breathStages,
    List<int>? snoringStages,
  }) : sleepStages = _immutableListOrNull(sleepStages),
       breathStages = _immutableListOrNull(breathStages),
       snoringStages = _immutableListOrNull(snoringStages);

  factory AsleepReportSession.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    return AsleepReportSession(
      id: _requiredNonEmptyString(json, 'id'),
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

/// Sleep and breathing statistics returned by report APIs.
class AsleepStat {
  AsleepStat._(this.values);

  factory AsleepStat.fromJson(Map<String, Object?> json) {
    return AsleepStat._(_camelized(json));
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

/// Detailed sleep report for one session.
class AsleepReport {
  AsleepReport({
    required this.timezone,
    required this.session,
    required this.missingDataRatio,
    required List<String> peculiarities,
    this.stat,
  }) : peculiarities = List<String>.unmodifiable(peculiarities);

  factory AsleepReport.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    final stat = _map(json, 'stat');
    return AsleepReport(
      timezone: _requiredString(json, 'timezone'),
      session: AsleepReportSession.fromJson(_requiredMap(json, 'session')),
      missingDataRatio: _requiredDouble(json, 'missingDataRatio'),
      peculiarities: _requiredStringList(json, 'peculiarities'),
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

/// Summary metadata for a report-list session.
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
    final id =
        _optionalNonEmptyString(json, 'id') ??
        _optionalNonEmptyString(json, 'sessionId');
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

/// Date range and timezone covered by an aggregate report.
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

/// Aggregate-report entry for a session in which sleep was detected.
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
      id: _requiredNonEmptyString(json, 'id'),
      startTime: _requiredDate(json, 'startTime'),
      endTime: _requiredDate(json, 'endTime'),
      createdTimezone: _requiredString(json, 'createdTimezone'),
      stats: AsleepStat.fromJson(json),
      raw: json,
    );
  }

  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final String createdTimezone;
  final AsleepStat stats;
  final Map<String, Object?> raw;
}

/// Aggregate-report entry for a session in which sleep was not detected.
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
      id: _requiredNonEmptyString(json, 'id'),
      startTime: _requiredDate(json, 'startTime'),
      endTime: _requiredDate(json, 'endTime'),
      completedTime: _date(json, 'completedTime'),
      raw: json,
    );
  }

  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final DateTime? completedTime;
  final Map<String, Object?> raw;
}

/// Aggregate sleep report over a date range.
class AsleepAverageReport {
  AsleepAverageReport._({
    required this.period,
    required List<String> peculiarities,
    this.averageStats,
    required List<AsleepSleptSession> sleptSessions,
    required List<AsleepNeverSleptSession> neverSleptSessions,
    required Map<String, Object?> raw,
  }) : peculiarities = List<String>.unmodifiable(peculiarities),
       sleptSessions = List<AsleepSleptSession>.unmodifiable(sleptSessions),
       neverSleptSessions = List<AsleepNeverSleptSession>.unmodifiable(
         neverSleptSessions,
       ),
       raw = _immutableMap(raw);

  factory AsleepAverageReport.fromJson(Map<String, Object?> source) {
    final json = _camelized(source);
    final averageStats = _map(json, 'averageStats');
    return AsleepAverageReport._(
      period: AsleepReportPeriod.fromJson(_requiredMap(json, 'period')),
      peculiarities: _requiredStringList(json, 'peculiarities'),
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
      raw: json,
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

/// Immutable client state reduced from native SDK events.
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
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException catch (error) {
    throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'The native SDK returned invalid JSON.',
      cause: error,
    );
  }
  if (decoded is! Map) {
    throw const AsleepException(
      AsleepErrorCode.malformedPayload,
      'Expected a JSON object from the native SDK.',
    );
  }
  return _stringKeyedMap(decoded);
}

Map<String, Object?> _camelized(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable(
    source.map((key, value) {
      final normalized = key.replaceAllMapped(
        RegExp(r'_([a-z])'),
        (match) => match.group(1)!.toUpperCase(),
      );
      return MapEntry(normalized, _camelizeValue(value));
    }),
  );
}

Object? _camelizeValue(Object? value) {
  if (value is Map) {
    return _camelized(_stringKeyedMap(value));
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_camelizeValue));
  }
  return value;
}

String? _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw _malformed('Field "$key" must be a string.');
  }
  return value;
}

String _requiredString(Map<String, Object?> json, String key) =>
    _string(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing string field "$key".',
    ));

String? _optionalNonEmptyString(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  return value == null || value.isEmpty ? null : value;
}

String _requiredNonEmptyString(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  if (value.isEmpty) {
    throw _malformed('Field "$key" must not be empty.');
  }
  return value;
}

int? _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  if (value is num && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  throw _malformed('Field "$key" must be an integer.');
}

double? _double(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! num || !value.isFinite) {
    throw _malformed('Field "$key" must be a finite number.');
  }
  return value.toDouble();
}

double _requiredDouble(Map<String, Object?> json, String key) =>
    _double(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing number field "$key".',
    ));

DateTime? _date(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (value == null) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw _malformed('Field "$key" must be an ISO-8601 date.');
  }
  return parsed.toUtc();
}

DateTime _requiredDate(Map<String, Object?> json, String key) =>
    _date(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing date field "$key".',
    ));
Map<String, Object?>? _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    throw _malformed('Field "$key" must be an object.');
  }
  return _stringKeyedMap(value);
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) =>
    _map(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing object field "$key".',
    ));
List<int>? _intList(Map<String, Object?> json, String key) {
  final values = _list(json, key);
  if (values == null) {
    return null;
  }
  return List<int>.unmodifiable(
    values.indexed.map((entry) {
      final (index, value) = entry;
      if (value is int) {
        return value;
      }
      if (value is num && value.isFinite && value == value.truncateToDouble()) {
        return value.toInt();
      }
      throw _malformed('Field "$key[$index]" must be an integer.');
    }),
  );
}

List<String>? _stringList(Map<String, Object?> json, String key) {
  final values = _list(json, key);
  if (values == null) {
    return null;
  }
  return List<String>.unmodifiable(
    values.indexed.map((entry) {
      final (index, value) = entry;
      if (value is! String) {
        throw _malformed('Field "$key[$index]" must be a string.');
      }
      return value;
    }),
  );
}

List<String> _requiredStringList(Map<String, Object?> json, String key) =>
    _stringList(json, key) ??
    (throw AsleepException(
      AsleepErrorCode.malformedPayload,
      'Missing list field "$key".',
    ));

List<Map<String, Object?>>? _mapList(Map<String, Object?> json, String key) {
  final values = _list(json, key);
  if (values == null) {
    return null;
  }
  return List<Map<String, Object?>>.unmodifiable(
    values.indexed.map((entry) {
      final (index, value) = entry;
      if (value is! Map) {
        throw _malformed('Field "$key[$index]" must be an object.');
      }
      return _stringKeyedMap(value);
    }),
  );
}

List<Object?>? _list(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! List) {
    throw _malformed('Field "$key" must be a list.');
  }
  return value;
}

Map<String, Object?> _stringKeyedMap(Map<Object?, Object?> source) {
  final result = <String, Object?>{};
  for (final entry in source.entries) {
    if (entry.key is! String) {
      throw _malformed('JSON object keys must be strings.');
    }
    result[entry.key! as String] = entry.value;
  }
  return _immutableMap(result);
}

Map<String, Object?> _immutableMap(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable(
    source.map((key, value) => MapEntry(key, _immutableValue(value))),
  );
}

Object? _immutableValue(Object? value) {
  if (value is Map) {
    return _stringKeyedMap(value);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableValue));
  }
  return value;
}

List<T>? _immutableListOrNull<T>(List<T>? values) =>
    values == null ? null : List<T>.unmodifiable(values);

AsleepException _malformed(String message) =>
    AsleepException(AsleepErrorCode.malformedPayload, message);
