import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/src/device_qualification.dart';

void main() {
  test('complete exact evidence passes', () {
    expect(
      validateDeviceQualification(
        _completeEvidence(),
        expectations: _expectations,
      ),
      isEmpty,
    );
  });

  test('missing and failed scenarios block release', () {
    final evidence = _completeEvidence();
    final scenarios = _scenarios(evidence, 'android');
    scenarios.remove('full_night_session');
    (scenarios['process_kill_and_restore']! as Map<String, Object?>)['status'] =
        'failed';

    expect(
      validateDeviceQualification(evidence, expectations: _expectations),
      containsAll(<dynamic>[
        contains('full_night_session'),
        contains('process_kill_and_restore.status must be "passed"'),
      ]),
    );
  });

  test('candidate version mismatch blocks release', () {
    final evidence = _completeEvidence();
    _candidate(evidence)['androidNativeVersion'] = '3.3.0';

    expect(
      validateDeviceQualification(evidence, expectations: _expectations),
      contains(contains('candidate.androidNativeVersion must equal "3.2.1"')),
    );
  });

  test('empty or malformed extracted versions block release', () {
    final evidence = _completeEvidence();
    _candidate(evidence)['packageVersion'] = '';
    _candidate(evidence)['dartVersion'] = 'Dart SDK version unavailable';

    expect(
      validateDeviceQualification(evidence, now: DateTime.utc(2026, 8)),
      containsAll(<dynamic>[
        'candidate.packageVersion must be a semantic version.',
        'candidate.dartVersion must be a semantic version.',
      ]),
    );
  });

  test('nonphysical device and missing evidence block release', () {
    final evidence = _completeEvidence();
    _device(evidence, 'android', 'current')['physical'] = false;
    (_scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>)['evidence'] =
        <Object?>[];

    expect(
      validateDeviceQualification(evidence, expectations: _expectations),
      containsAll(<dynamic>[
        contains('platforms.android.devices[1].physical must be true'),
        contains('full_night_session.evidence must contain'),
      ]),
    );
  });

  test('credential retention and untrusted operator block release', () {
    final evidence = _completeEvidence();
    final privacy = evidence['privacy']! as Map<String, Object?>;
    privacy['credentialsPersisted'] = true;

    expect(
      validateDeviceQualification(
        evidence,
        expectations: const QualificationExpectations(
          operator: 'trusted-github-actor',
        ),
      ),
      containsAll(<dynamic>[
        contains('privacy.credentialsPersisted must be false'),
        contains('run.operator must equal "trusted-github-actor"'),
      ]),
    );
  });

  test('bound operator names bypass only sensitive vocabulary scanning', () {
    for (final operator in ['reporter', 'samples-team']) {
      final evidence = _completeEvidence();
      (evidence['run']! as Map<String, Object?>)['operator'] = operator;

      expect(
        validateDeviceQualification(
          evidence,
          expectations: QualificationExpectations(operator: operator),
        ),
        isEmpty,
      );

      _device(evidence, 'android', 'current')['model'] = operator;
      expect(
        validateDeviceQualification(
          evidence,
          expectations: QualificationExpectations(operator: operator),
        ),
        contains(
          'platforms.android.devices[1].model contains prohibited sensitive data.',
        ),
      );
    }
  });

  test('unsupported OS capabilities block release', () {
    final evidence = _completeEvidence();
    final androidDevice = _device(evidence, 'android', 'current');
    androidDevice['apiLevel'] = 35;
    final iosCurrentDevice = _device(evidence, 'ios', 'current');
    iosCurrentDevice['osMajor'] = 25;
    final iosMinimumDevice = _device(evidence, 'ios', 'minimum');
    iosMinimumDevice['osMajor'] = 14;

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      containsAll(<dynamic>[
        'platforms.android current apiLevel must be at least 36.',
        'platforms.ios current osMajor must be at least 26.',
        'platforms.ios minimum osMajor must equal 15.',
      ]),
    );
  });

  test('API-specific scenarios require a capable Android device role', () {
    final evidence = _completeEvidence();
    for (final id in [
      'notification_denial_api_33_plus',
      'microphone_fgs_api_34_plus',
    ]) {
      (_scenarios(evidence, 'android')[id]!
          as Map<String, Object?>)['deviceRoles'] = <Object?>[
        'minimum',
      ];
    }

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      containsAll(<dynamic>[
        contains(
          'notification_denial_api_33_plus.deviceRoles must include '
          'a device at API 33 or newer',
        ),
        contains(
          'microphone_fgs_api_34_plus.deviceRoles must include '
          'a device at API 34 or newer',
        ),
      ]),
    );
  });

  test('unknown fields and malformed types block release', () {
    final evidence = _completeEvidence();
    evidence['unexpected'] = true;
    _candidate(evidence)['packageVersion'] = 1;
    _device(evidence, 'android', 'current')['serial'] = 'not-allowed';
    (_scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>)['notes'] =
        <Object?>[];
    _scenarios(evidence, 'ios')['background_audio'] = null;

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      containsAll(<dynamic>[
        contains('Evidence has unknown fields'),
        contains('candidate.packageVersion must be a string'),
        contains('platforms.android.devices[1] has unknown fields'),
        contains('full_night_session.notes must be a string'),
        contains('platforms.ios.scenarios.background_audio must be an object'),
      ]),
    );
  });

  test('invalid, duplicate, and credential-bearing URLs block release', () {
    final evidence = _completeEvidence();
    final scenario =
        _scenarios(evidence, 'ios')['full_night_session']!
            as Map<String, Object?>;
    scenario['evidence'] = <Object?>[
      'https://github.com/asleep-ai/evidence/1',
      'https://github.com/asleep-ai/evidence/1',
      'http://example.com/insecure',
      'https://user:password@example.com/private',
      'https://example.com/evidence?token=secret',
      'https://example.com/evidence#token',
      42,
    ];

    final errors = validateDeviceQualification(
      evidence,
      expectations: _expectations,
      now: DateTime.utc(2026, 8),
    );
    expect(errors, contains(contains('must not contain duplicate URLs')));
    expect(
      errors
          .where((error) => error.contains('credential-free HTTPS URLs'))
          .length,
      5,
    );
  });

  test('sensitive data classes in notes block release', () {
    for (final notes in <String>[
      'apiKey=SECRET; samples: [0.1]',
      'userId=patient-123',
      'sessionId=session-123',
      'report={"sleepScore":82}',
    ]) {
      final evidence = _completeEvidence();
      (_scenarios(evidence, 'android')['full_night_session']!
              as Map<String, Object?>)['notes'] =
          notes;

      expect(
        validateDeviceQualification(
          evidence,
          expectations: _expectations,
          now: DateTime.utc(2026, 8),
        ),
        contains(
          contains(
            'full_night_session.notes contains prohibited sensitive data',
          ),
        ),
        reason: notes,
      );
    }
  });

  test('free-form notes fail closed while canonical redacted prose passes', () {
    final evidence = _completeEvidence();
    final scenario =
        _scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>;
    scenario['notes'] = 'Microphone recovery passed.';
    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      contains(contains('notes must be empty or the canonical redacted')),
    );

    scenario['notes'] = 'Passed with redacted evidence.';
    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      isEmpty,
    );
  });

  test('sensitive values and field names cannot move to sibling fields', () {
    final evidence = _completeEvidence();
    _device(evidence, 'android', 'current')['model'] = 'userId=patient-123';
    (_scenarios(evidence, 'ios')['full_night_session']!
        as Map<String, Object?>)['evidence'] = <Object?>[
      'https://example.com/report/sleepScore',
    ];
    (evidence['privacy']! as Map<String, Object?>)['sessionId'] = 'hidden';

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      containsAll(<dynamic>[
        contains('platforms.android.devices[1].model contains prohibited'),
        contains(
          'platforms.ios.scenarios.full_night_session.evidence[0] '
          'contains prohibited',
        ),
        contains('privacy contains a prohibited sensitive-data field'),
      ]),
    );
  });

  test('duplicate JSON members are rejected before evidence decoding', () {
    const duplicateSources = <String>[
      '{"operator":"api_key=secret","operator":"safe"}',
      '{"operator":"api_key=secret","oper\\u0061tor":"safe"}',
      '{"outer":{"value":1,"value":2}}',
    ];

    for (final source in duplicateSources) {
      expect(
        () => decodeDeviceQualificationJson(source),
        throwsA(
          isA<FormatException>()
              .having(
                (error) => error.message,
                'message',
                'Evidence JSON must not contain duplicate object members.',
              )
              .having(
                (error) => error.toString(),
                'safe error',
                isNot(contains('secret')),
              ),
        ),
      );
    }
  });

  test('equal member names in separate JSON objects remain valid', () {
    expect(
      decodeDeviceQualificationJson(
        '{"first":{"value":1},"second":{"value":2}}',
      ),
      <String, Object?>{
        'first': <String, Object?>{'value': 1},
        'second': <String, Object?>{'value': 2},
      },
    );
  });

  test('validation errors never echo rejected evidence values', () {
    final evidence = _completeEvidence();
    const sensitiveValue = 'userId=patient-123';
    _candidate(evidence)['packageVersion'] = sensitiveValue;
    (evidence['privacy']! as Map<String, Object?>)[sensitiveValue] =
        'report={"sleepScore":82}';

    final output = validateDeviceQualification(
      evidence,
      expectations: _expectations,
      now: DateTime.utc(2026, 8),
    ).join('\n');

    expect(output, isNot(contains('patient-123')));
    expect(output, isNot(contains('sleepScore')));
    expect(output, isNot(contains('82')));
  });

  test('out-of-order and future timestamps block release', () {
    final evidence = _completeEvidence();
    final androidScenario =
        _scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>;
    androidScenario['completedAt'] = '2026-07-30T22:00:00Z';
    final iosScenario =
        _scenarios(evidence, 'ios')['full_night_session']!
            as Map<String, Object?>;
    iosScenario['completedAt'] = '2026-08-02T01:00:00Z';

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      containsAll(<dynamic>[
        contains('must not precede run.startedAt'),
        contains('must not follow run.completedAt'),
        contains('must not be in the future'),
      ]),
    );
  });

  test('timestamp spellings must use canonical uppercase-Z UTC', () {
    for (final timestampPath in _timestampPaths.entries) {
      for (final invalidTimestamp in _invalidTimestampSpellings) {
        final evidence = _completeEvidence();
        timestampPath.value(evidence, invalidTimestamp);

        expect(
          validateDeviceQualification(
            evidence,
            expectations: _expectations,
            now: DateTime.utc(2026, 8),
          ),
          contains('${timestampPath.key} must be an ISO-8601 UTC timestamp.'),
          reason: '${timestampPath.key} accepted $invalidTimestamp',
        );
      }
    }
  });

  test('calendar overflow timestamps are rejected without normalization', () {
    for (final timestampPath in _timestampPaths.entries) {
      for (final invalidTimestamp in _invalidCalendarTimestamps) {
        final evidence = _completeEvidence();
        timestampPath.value(evidence, invalidTimestamp);

        expect(
          validateDeviceQualification(
            evidence,
            expectations: _expectations,
            now: DateTime.utc(2027),
          ),
          contains('${timestampPath.key} must be an ISO-8601 UTC timestamp.'),
          reason: '${timestampPath.key} accepted $invalidTimestamp',
        );
      }
    }
  });

  test('canonical uppercase-Z timestamps accept optional fractions', () {
    final evidence = _completeEvidence();
    final run = evidence['run']! as Map<String, Object?>;
    run['startedAt'] = '2026-07-30T23:00:00Z';
    run['completedAt'] = '2026-07-31T02:00:00.123456Z';
    (_scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>)['completedAt'] =
        '2026-07-31T01:00:00.5Z';
    (_scenarios(evidence, 'ios')['full_night_session']!
            as Map<String, Object?>)['completedAt'] =
        '2026-07-31T01:00:00Z';

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      isEmpty,
    );
  });

  test('strict timestamps accept leap day and component boundaries', () {
    final evidence = _completeEvidence();
    final run = evidence['run']! as Map<String, Object?>;
    run['startedAt'] = '2024-02-29T00:00:00Z';
    run['completedAt'] = '2024-12-31T23:59:59.999999Z';
    for (final platform in ['android', 'ios']) {
      for (final scenario in _scenarios(evidence, platform).values) {
        (scenario as Map<String, Object?>)['completedAt'] =
            '2024-06-01T12:00:00Z';
      }
    }
    (_scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>)['completedAt'] =
        '2024-04-30T23:59:59Z';
    (_scenarios(evidence, 'ios')['full_night_session']!
            as Map<String, Object?>)['completedAt'] =
        '2024-02-29T00:00:00.1Z';

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2025),
      ),
      isEmpty,
    );
  });

  test('JSON Schema enforces the canonical timestamp spelling', () {
    final schema =
        jsonDecode(
              File('qualification/evidence.schema.json').readAsStringSync(),
            )
            as Map<String, Object?>;
    final properties = schema['properties']! as Map<String, Object?>;
    final run =
        (properties['run']! as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    final definitions = schema[r'$defs']! as Map<String, Object?>;
    final scenario =
        (definitions['scenario']! as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    final timestampSchemas = <Map<String, Object?>>[
      run['startedAt']! as Map<String, Object?>,
      run['completedAt']! as Map<String, Object?>,
      scenario['completedAt']! as Map<String, Object?>,
    ];

    for (final timestampSchema in timestampSchemas) {
      final pattern = RegExp(timestampSchema['pattern']! as String);
      for (final invalidTimestamp in _invalidTimestampSpellings) {
        expect(pattern.hasMatch(invalidTimestamp), isFalse);
      }
      expect(pattern.hasMatch('2026-07-31T01:00:00Z'), isTrue);
      expect(pattern.hasMatch('2026-07-31T01:00:00.123456Z'), isTrue);
    }
  });

  test('qualification workflow receives evidence only from a secret', () {
    final workflow = File(
      '.github/workflows/device-qualification.yml',
    ).readAsStringSync();

    expect(workflow, isNot(contains('evidence_base64')));
    expect(workflow, isNot(contains('inputs.evidence')));
    expect(
      workflow,
      contains(
        r'EVIDENCE_JSON: ${{ secrets.DEVICE_QUALIFICATION_EVIDENCE_JSON }}',
      ),
    );
    expect(workflow, contains(r'[[ -z "${EVIDENCE_JSON:-}" ]]'));
    expect(workflow, contains('umask 077'));
    expect(
      workflow,
      contains(
        r'''printf '%s' "$EVIDENCE_JSON" > "$RUNNER_TEMP/evidence.json"''',
      ),
    );
    expect(workflow, contains('retention-days: 90'));

    final operatorGuide = File(
      'doc/DEVICE_QUALIFICATION.md',
    ).readAsStringSync();
    expect(operatorGuide, isNot(contains('evidence_base64')));
    expect(
      operatorGuide,
      contains('gh secret set DEVICE_QUALIFICATION_EVIDENCE_JSON'),
    );
    expect(operatorGuide, contains('< "\$secret_input"'));
    expect(
      operatorGuide,
      contains('gh secret delete DEVICE_QUALIFICATION_EVIDENCE_JSON'),
    );
    expect(operatorGuide, contains('gh run watch "\$qualification_run_id"'));
  });

  test('incomplete template shape can be checked without credentials', () {
    final evidence = _completeEvidence();
    evidence['privacy'] = <String, Object?>{
      'credentialsInjectedAtRuntime': false,
      'credentialsPersisted': false,
      'sleepDataRetained': false,
    };
    final run = evidence['run']! as Map<String, Object?>;
    run['startedAt'] = null;
    run['completedAt'] = null;
    run['operator'] = '';
    for (final platform in ['android', 'ios']) {
      for (final scenario in _scenarios(evidence, platform).values) {
        final entry = scenario as Map<String, Object?>;
        entry['status'] = 'not_run';
        entry['completedAt'] = null;
        entry['evidence'] = <Object?>[];
        entry['notes'] = '';
      }
    }

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        allowIncomplete: true,
        now: DateTime.utc(2026, 8),
      ),
      isEmpty,
    );
  });
}

const _invalidTimestampSpellings = <String>[
  '2026-07-31T01:00:00+02:00',
  '2026-07-31T01:00:00+00:00',
  '2026-07-31T01:00:00z',
  '2026-07-31 01:00:00Z',
];

const _invalidCalendarTimestamps = <String>[
  '2026-00-01T01:00:00Z',
  '2026-13-01T01:00:00Z',
  '2026-02-31T01:00:00Z',
  '2025-02-29T01:00:00Z',
  '2026-04-31T01:00:00Z',
  '2026-07-31T24:00:00Z',
  '2026-07-31T01:60:00Z',
  '2026-07-31T01:00:60Z',
];

final _timestampPaths = <String, void Function(Map<String, Object?>, String)>{
  'run.startedAt': (evidence, value) {
    (evidence['run']! as Map<String, Object?>)['startedAt'] = value;
  },
  'run.completedAt': (evidence, value) {
    (evidence['run']! as Map<String, Object?>)['completedAt'] = value;
  },
  'platforms.android.scenarios.full_night_session.completedAt':
      (evidence, value) {
        (_scenarios(evidence, 'android')['full_night_session']!
                as Map<String, Object?>)['completedAt'] =
            value;
      },
  'platforms.ios.scenarios.full_night_session.completedAt': (evidence, value) {
    (_scenarios(evidence, 'ios')['full_night_session']!
            as Map<String, Object?>)['completedAt'] =
        value;
  },
};

const _expectations = QualificationExpectations(
  commitSha: '49fa33ca0d184d7c1954ad79a3077a5e67c78aa9',
  packageVersion: '0.1.0',
  flutterVersion: '3.44.8',
  dartVersion: '3.12.2',
  androidNativeVersion: '3.2.1',
  iosNativeVersion: '3.2.0',
);

Map<String, Object?> _completeEvidence() {
  Map<String, Object?> scenario() => <String, Object?>{
    'status': 'passed',
    'completedAt': '2026-07-31T01:00:00Z',
    'evidence': <Object?>['https://github.com/asleep-ai/evidence/1'],
    'notes': 'Passed with redacted evidence.',
    'deviceRoles': <Object?>['current'],
  };

  Map<String, Object?> platform(
    String manufacturer,
    String model,
    String architecture,
    String versionField,
    int minimumVersion,
    int currentVersion,
  ) => <String, Object?>{
    'devices': <Object?>[
      <String, Object?>{
        'role': 'minimum',
        'physical': true,
        'manufacturer': manufacturer,
        'model': '$model minimum',
        'architecture': architecture,
        'osVersion': 'minimum',
        versionField: minimumVersion,
      },
      <String, Object?>{
        'role': 'current',
        'physical': true,
        'manufacturer': manufacturer,
        'model': '$model current',
        'architecture': architecture,
        'osVersion': 'current',
        versionField: currentVersion,
      },
    ],
    'scenarios': <String, Object?>{},
  };

  final android = platform(
    'Samsung',
    'SM-X236N',
    'arm64-v8a',
    'apiLevel',
    24,
    36,
  );
  final ios = platform('Apple', 'iPhone', 'arm64', 'osMajor', 15, 26);
  final androidScenarios = android['scenarios']! as Map<String, Object?>;
  final iosScenarios = ios['scenarios']! as Map<String, Object?>;
  for (final id in androidQualificationScenarios) {
    androidScenarios[id] = scenario();
  }
  for (final id in iosQualificationScenarios) {
    iosScenarios[id] = scenario();
  }
  (androidScenarios['cold_start_without_permissions']!
      as Map<String, Object?>)['deviceRoles'] = <Object?>[
    'minimum',
    'current',
  ];
  (iosScenarios['cold_start_without_permissions']!
      as Map<String, Object?>)['deviceRoles'] = <Object?>[
    'minimum',
    'current',
  ];

  return <String, Object?>{
    'schemaVersion': 1,
    'candidate': <String, Object?>{
      'commitSha': _expectations.commitSha,
      'packageVersion': _expectations.packageVersion,
      'flutterVersion': _expectations.flutterVersion,
      'dartVersion': _expectations.dartVersion,
      'androidNativeVersion': _expectations.androidNativeVersion,
      'iosNativeVersion': _expectations.iosNativeVersion,
    },
    'run': <String, Object?>{
      'startedAt': '2026-07-30T23:00:00Z',
      'completedAt': '2026-07-31T02:00:00Z',
      'operator': 'operator@example.com',
    },
    'privacy': <String, Object?>{
      'credentialsInjectedAtRuntime': true,
      'credentialsPersisted': false,
      'sleepDataRetained': false,
    },
    'platforms': <String, Object?>{'android': android, 'ios': ios},
  };
}

Map<String, Object?> _candidate(Map<String, Object?> evidence) =>
    evidence['candidate']! as Map<String, Object?>;

Map<String, Object?> _platform(
  Map<String, Object?> evidence,
  String platform,
) =>
    (evidence['platforms']! as Map<String, Object?>)[platform]!
        as Map<String, Object?>;

Map<String, Object?> _scenarios(
  Map<String, Object?> evidence,
  String platform,
) => _platform(evidence, platform)['scenarios']! as Map<String, Object?>;

Map<String, Object?> _device(
  Map<String, Object?> evidence,
  String platform,
  String role,
) => (_platform(evidence, platform)['devices']! as List<Object?>)
    .cast<Map<String, Object?>>()
    .singleWhere((device) => device['role'] == role);
