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

  test('unsupported OS capabilities block release', () {
    final evidence = _completeEvidence();
    final androidDevice = _device(evidence, 'android', 'current');
    androidDevice['apiLevel'] = 33;
    final iosDevice = _device(evidence, 'ios', 'minimum');
    iosDevice['osMajor'] = 14;

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      containsAll(<dynamic>[
        'platforms.android current apiLevel must be at least 34.',
        'platforms.ios minimum osMajor must equal 15.',
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

  test('credentials and raw samples in notes block release', () {
    final evidence = _completeEvidence();
    (_scenarios(evidence, 'android')['full_night_session']!
            as Map<String, Object?>)['notes'] =
        'apiKey=SECRET; samples: [0.1]';

    expect(
      validateDeviceQualification(
        evidence,
        expectations: _expectations,
        now: DateTime.utc(2026, 8),
      ),
      contains(contains('notes must not contain sensitive data')),
    );
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
    'notes': 'Redacted diagnostic log.',
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
  final ios = platform('Apple', 'iPhone', 'arm64', 'osMajor', 15, 18);
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
