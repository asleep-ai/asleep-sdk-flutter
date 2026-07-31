import 'dart:convert';

const androidQualificationScenarios = <String>{
  'cold_start_without_permissions',
  'permission_denial_and_regrant',
  'notification_denial_api_33_plus',
  'microphone_fgs_api_34_plus',
  'battery_settings_return_and_recheck',
  'process_kill_and_restore',
  'start_upload_analysis_stop_report',
  'full_night_session',
};

const iosQualificationScenarios = <String>{
  'cold_start_without_permissions',
  'permission_denial_and_recovery',
  'background_audio',
  'interruption_and_foreground_resume',
  'later_upload_recovery',
  'analysis_ack_and_event',
  'stop_and_report',
  'full_night_session',
};

class QualificationExpectations {
  const QualificationExpectations({
    this.commitSha,
    this.packageVersion,
    this.flutterVersion,
    this.dartVersion,
    this.androidNativeVersion,
    this.iosNativeVersion,
    this.operator,
  });

  final String? commitSha;
  final String? packageVersion;
  final String? flutterVersion;
  final String? dartVersion;
  final String? androidNativeVersion;
  final String? iosNativeVersion;
  final String? operator;
}

List<String> validateDeviceQualification(
  Object? input, {
  QualificationExpectations expectations = const QualificationExpectations(),
  bool allowIncomplete = false,
  DateTime? now,
}) {
  final errors = <String>[];
  if (input is! Map<String, Object?>) {
    return ['Evidence must be a JSON object.'];
  }
  _validateObject(input, '', {
    'schemaVersion',
    'candidate',
    'run',
    'privacy',
    'platforms',
  }, errors);
  final candidate = _requiredObject(input, 'candidate', 'candidate', errors);
  final run = _requiredObject(input, 'run', 'run', errors);
  final privacy = _requiredObject(input, 'privacy', 'privacy', errors);
  final platforms = _requiredObject(input, 'platforms', 'platforms', errors);
  if (candidate != null) {
    _validateObject(candidate, 'candidate', {
      'commitSha',
      'packageVersion',
      'flutterVersion',
      'dartVersion',
      'androidNativeVersion',
      'iosNativeVersion',
    }, errors);
    for (final field in [
      'commitSha',
      'packageVersion',
      'flutterVersion',
      'dartVersion',
      'androidNativeVersion',
      'iosNativeVersion',
    ]) {
      _requireString(candidate, field, 'candidate.$field', errors);
    }
  }
  if (run != null) {
    _validateObject(run, 'run', {
      'startedAt',
      'completedAt',
      'operator',
    }, errors);
    _requireNullableString(run, 'startedAt', 'run.startedAt', errors);
    _requireNullableString(run, 'completedAt', 'run.completedAt', errors);
    _requireString(run, 'operator', 'run.operator', errors);
  }
  if (privacy != null) {
    _validateObject(privacy, 'privacy', {
      'credentialsInjectedAtRuntime',
      'credentialsPersisted',
      'sleepDataRetained',
    }, errors);
    for (final field in [
      'credentialsInjectedAtRuntime',
      'credentialsPersisted',
      'sleepDataRetained',
    ]) {
      _requireBool(privacy, field, 'privacy.$field', errors);
    }
  }
  if (platforms != null) {
    _validateObject(platforms, 'platforms', {'android', 'ios'}, errors);
  }

  void exact(String path, String? expected) {
    if (expected == null) return;
    final actual = _at(input, path);
    if (actual != expected) {
      errors.add('$path must equal "$expected"; found ${jsonEncode(actual)}.');
    }
  }

  if (_at(input, 'schemaVersion') != 1) {
    errors.add('schemaVersion must equal 1.');
  }
  exact('candidate.commitSha', expectations.commitSha);
  exact('candidate.packageVersion', expectations.packageVersion);
  exact('candidate.flutterVersion', expectations.flutterVersion);
  exact('candidate.dartVersion', expectations.dartVersion);
  exact('candidate.androidNativeVersion', expectations.androidNativeVersion);
  exact('candidate.iosNativeVersion', expectations.iosNativeVersion);
  exact('run.operator', expectations.operator);

  final semanticVersion = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  );
  for (final field in [
    'packageVersion',
    'flutterVersion',
    'dartVersion',
    'androidNativeVersion',
    'iosNativeVersion',
  ]) {
    final version = _at(input, 'candidate.$field');
    if (version is! String || !semanticVersion.hasMatch(version)) {
      errors.add('candidate.$field must be a semantic version.');
    }
  }

  final commitSha = _at(input, 'candidate.commitSha');
  if (commitSha is! String || !RegExp(r'^[0-9a-f]{40}$').hasMatch(commitSha)) {
    errors.add('candidate.commitSha must be a lowercase 40-character SHA.');
  }

  final timestamps = <String, DateTime>{};
  _validateTimestamp(
    input,
    'run.startedAt',
    errors,
    allowIncomplete,
    timestamps,
  );
  _validateTimestamp(
    input,
    'run.completedAt',
    errors,
    allowIncomplete,
    timestamps,
  );
  if (!allowIncomplete) {
    if (_at(input, 'privacy.credentialsInjectedAtRuntime') != true) {
      errors.add('privacy.credentialsInjectedAtRuntime must be true.');
    }
    if (_at(input, 'privacy.credentialsPersisted') != false) {
      errors.add('privacy.credentialsPersisted must be false.');
    }
    if (_at(input, 'privacy.sleepDataRetained') != false) {
      errors.add('privacy.sleepDataRetained must be false.');
    }
    final operator = _nonEmpty(_at(input, 'run.operator'));
    if (operator == null) errors.add('run.operator must be non-empty.');
  }

  _validatePlatform(
    input,
    platform: 'android',
    requiredScenarios: androidQualificationScenarios,
    expectedArchitecture: 'arm64-v8a',
    errors: errors,
    allowIncomplete: allowIncomplete,
    timestamps: timestamps,
  );
  _validatePlatform(
    input,
    platform: 'ios',
    requiredScenarios: iosQualificationScenarios,
    expectedArchitecture: 'arm64',
    errors: errors,
    allowIncomplete: allowIncomplete,
    timestamps: timestamps,
  );
  _validateTimestampOrder(
    timestamps,
    errors,
    now: (now ?? DateTime.now()).toUtc(),
  );
  return errors;
}

void _validatePlatform(
  Map<String, Object?> input, {
  required String platform,
  required Set<String> requiredScenarios,
  required String expectedArchitecture,
  required List<String> errors,
  required bool allowIncomplete,
  required Map<String, DateTime> timestamps,
}) {
  final base = 'platforms.$platform';
  final platformObject = _at(input, base);
  if (platformObject is! Map<String, Object?>) {
    errors.add('$base must be an object.');
    return;
  }
  _validateObject(platformObject, base, {'devices', 'scenarios'}, errors);
  final devices = platformObject['devices'];
  final deviceRoles = <String, int>{};
  if (devices is! List<Object?>) {
    errors.add('$base.devices must be an array.');
  } else {
    for (var index = 0; index < devices.length; index++) {
      final device = devices[index];
      final devicePath = '$base.devices[$index]';
      if (device is! Map<String, Object?>) {
        errors.add('$devicePath must be an object.');
        continue;
      }
      final deviceFields = <String>{
        'role',
        'physical',
        'manufacturer',
        'model',
        'architecture',
        'osVersion',
        if (platform == 'android') 'apiLevel' else 'osMajor',
      };
      _validateObject(device, devicePath, deviceFields, errors);
      _requireString(device, 'role', '$devicePath.role', errors);
      _requireBool(device, 'physical', '$devicePath.physical', errors);
      for (final field in [
        'manufacturer',
        'model',
        'architecture',
        'osVersion',
      ]) {
        _requireString(device, field, '$devicePath.$field', errors);
      }
      final versionField = platform == 'android' ? 'apiLevel' : 'osMajor';
      _requireInt(device, versionField, '$devicePath.$versionField', errors);
      final role = device['role'];
      if (role is String) {
        if (!{'minimum', 'current'}.contains(role)) {
          errors.add('$devicePath.role is invalid.');
        } else if (deviceRoles.containsKey(role)) {
          errors.add('$base.devices must contain unique roles.');
        } else {
          deviceRoles[role] = device[versionField] is int
              ? device[versionField]! as int
              : -1;
        }
      }
      if (!allowIncomplete) {
        if (device['physical'] != true) {
          errors.add('$devicePath.physical must be true.');
        }
        for (final field in ['manufacturer', 'model', 'osVersion']) {
          if (_nonEmpty(device[field]) == null) {
            errors.add('$devicePath.$field must be non-empty.');
          }
        }
      }
      if (device['architecture'] != expectedArchitecture) {
        errors.add(
          '$devicePath.architecture must equal "$expectedArchitecture".',
        );
      }
    }
  }
  if (!allowIncomplete) {
    if (!deviceRoles.keys.toSet().containsAll({'minimum', 'current'})) {
      errors.add('$base.devices must contain minimum and current roles.');
    }
    final versionField = platform == 'android' ? 'apiLevel' : 'osMajor';
    final currentMinimum = platform == 'android' ? 34 : 16;
    if ((deviceRoles['current'] ?? -1) < currentMinimum) {
      errors.add(
        '$base current $versionField must be at least $currentMinimum.',
      );
    }
    final minimumVersion = platform == 'android' ? 24 : 15;
    if (deviceRoles['minimum'] != minimumVersion) {
      errors.add('$base minimum $versionField must equal $minimumVersion.');
    }
  }

  final scenarios = _at(input, '$base.scenarios');
  if (scenarios is! Map<String, Object?>) {
    errors.add('$base.scenarios must be an object.');
    return;
  }
  final missing = requiredScenarios.difference(scenarios.keys.toSet());
  final unknown = scenarios.keys.toSet().difference(requiredScenarios);
  if (missing.isNotEmpty) {
    errors.add('$base.scenarios is missing: ${missing.toList()..sort()}.');
  }
  if (unknown.isNotEmpty) {
    errors.add(
      '$base.scenarios has unknown entries: ${unknown.toList()..sort()}.',
    );
  }

  final usedDeviceRoles = <String>{};
  for (final id in requiredScenarios) {
    if (!scenarios.containsKey(id)) continue;
    final scenario = scenarios[id];
    if (scenario is! Map<String, Object?>) {
      errors.add('$base.scenarios.$id must be an object.');
      continue;
    }
    final scenarioPath = '$base.scenarios.$id';
    _validateObject(scenario, scenarioPath, {
      'status',
      'completedAt',
      'evidence',
      'notes',
      'deviceRoles',
    }, errors);
    _requireString(scenario, 'status', '$scenarioPath.status', errors);
    _requireNullableString(
      scenario,
      'completedAt',
      '$scenarioPath.completedAt',
      errors,
    );
    _requireString(scenario, 'notes', '$scenarioPath.notes', errors);
    final notes = scenario['notes'];
    if (notes is String &&
        RegExp(
          r'api[\s_-]?key|access[\s_-]?token|authorization|'
          r'bearer\s+[A-Za-z0-9._-]+|'
          r'(?:audio[\s_-]?(?:samples|data)|samples|sleep[\s_-]?stages|'
          r'raw[\s_-]?data)\s*[:=]',
          caseSensitive: false,
        ).hasMatch(notes)) {
      errors.add('$scenarioPath.notes must not contain sensitive data.');
    }
    final roles = scenario['deviceRoles'];
    if (roles is! List<Object?> ||
        roles.any(
          (role) => role is! String || !deviceRoles.containsKey(role),
        )) {
      errors.add(
        '$scenarioPath.deviceRoles must reference known device roles.',
      );
    } else if (!allowIncomplete && roles.isEmpty) {
      errors.add('$scenarioPath.deviceRoles must not be empty.');
    } else {
      usedDeviceRoles.addAll(roles.cast<String>());
    }
    final status = scenario['status'];
    if (!{'passed', 'failed', 'blocked', 'not_run'}.contains(status)) {
      errors.add('$scenarioPath.status is invalid.');
    } else if (!allowIncomplete && status != 'passed') {
      errors.add('$scenarioPath.status must be "passed".');
    }
    _validateTimestampMap(
      scenario,
      'completedAt',
      '$scenarioPath.completedAt',
      errors,
      allowIncomplete,
      timestamps,
    );
    final evidence = scenario['evidence'];
    if (!allowIncomplete && (evidence is! List<Object?> || evidence.isEmpty)) {
      errors.add('$scenarioPath.evidence must contain at least one URL.');
    } else if (evidence is List<Object?>) {
      final seen = <String>{};
      for (final url in evidence) {
        final parsed = url is String ? Uri.tryParse(url) : null;
        if (parsed == null ||
            parsed.scheme != 'https' ||
            parsed.host.isEmpty ||
            parsed.userInfo.isNotEmpty ||
            parsed.hasQuery ||
            parsed.hasFragment) {
          errors.add(
            '$scenarioPath.evidence must contain stable credential-free HTTPS URLs.',
          );
        } else if (!seen.add(url as String)) {
          errors.add('$scenarioPath.evidence must not contain duplicate URLs.');
        }
      }
    } else if (evidence != null) {
      errors.add('$scenarioPath.evidence must be an array.');
    }
  }
  if (!allowIncomplete &&
      !usedDeviceRoles.containsAll({'minimum', 'current'})) {
    errors.add('$base scenarios must cover minimum and current device roles.');
  }
}

void _validateTimestamp(
  Map<String, Object?> input,
  String path,
  List<String> errors,
  bool allowNull,
  Map<String, DateTime> timestamps,
) {
  final value = _at(input, path);
  _validateTimestampValue(value, path, errors, allowNull, timestamps);
}

void _validateTimestampMap(
  Map<String, Object?> input,
  String key,
  String path,
  List<String> errors,
  bool allowNull,
  Map<String, DateTime> timestamps,
) {
  _validateTimestampValue(input[key], path, errors, allowNull, timestamps);
}

void _validateTimestampValue(
  Object? value,
  String path,
  List<String> errors,
  bool allowNull,
  Map<String, DateTime> timestamps,
) {
  if (allowNull && value == null) return;
  final timestamp = value is String ? DateTime.tryParse(value) : null;
  if (timestamp == null || !timestamp.isUtc) {
    errors.add('$path must be an ISO-8601 UTC timestamp.');
  } else {
    timestamps[path] = timestamp;
  }
}

void _validateTimestampOrder(
  Map<String, DateTime> timestamps,
  List<String> errors, {
  required DateTime now,
}) {
  final started = timestamps['run.startedAt'];
  final completed = timestamps['run.completedAt'];
  for (final entry in timestamps.entries) {
    if (entry.value.isAfter(now.add(const Duration(minutes: 5)))) {
      errors.add('${entry.key} must not be in the future.');
    }
    if (entry.key.contains('.scenarios.') && started != null) {
      if (entry.value.isBefore(started)) {
        errors.add('${entry.key} must not precede run.startedAt.');
      }
      if (completed != null && entry.value.isAfter(completed)) {
        errors.add('${entry.key} must not follow run.completedAt.');
      }
    }
  }
  if (started != null && completed != null && completed.isBefore(started)) {
    errors.add('run.completedAt must not precede run.startedAt.');
  }
}

void _validateObject(
  Map<String, Object?> object,
  String path,
  Set<String> keys,
  List<String> errors,
) {
  for (final key in keys) {
    if (!object.containsKey(key)) {
      errors.add('${path.isEmpty ? '' : '$path.'}$key is required.');
    }
  }
  final unknown = object.keys.toSet().difference(keys);
  if (unknown.isNotEmpty) {
    errors.add(
      '${path.isEmpty ? 'Evidence' : path} has unknown fields: '
      '${unknown.toList()..sort()}.',
    );
  }
}

Map<String, Object?>? _requiredObject(
  Map<String, Object?> object,
  String key,
  String path,
  List<String> errors,
) {
  final value = object[key];
  if (value is Map<String, Object?>) return value;
  if (object.containsKey(key)) errors.add('$path must be an object.');
  return null;
}

void _requireString(
  Map<String, Object?> object,
  String key,
  String path,
  List<String> errors,
) {
  if (object.containsKey(key) && object[key] is! String) {
    errors.add('$path must be a string.');
  }
}

void _requireNullableString(
  Map<String, Object?> object,
  String key,
  String path,
  List<String> errors,
) {
  if (object.containsKey(key) &&
      object[key] != null &&
      object[key] is! String) {
    errors.add('$path must be a string or null.');
  }
}

void _requireBool(
  Map<String, Object?> object,
  String key,
  String path,
  List<String> errors,
) {
  if (object.containsKey(key) && object[key] is! bool) {
    errors.add('$path must be a boolean.');
  }
}

void _requireInt(
  Map<String, Object?> object,
  String key,
  String path,
  List<String> errors,
) {
  if (object.containsKey(key) && object[key] is! int) {
    errors.add('$path must be an integer.');
  }
}

Object? _at(Map<String, Object?> input, String path) {
  Object? current = input;
  for (final segment in path.split('.')) {
    if (current is! Map<String, Object?>) return null;
    current = current[segment];
  }
  return current;
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
