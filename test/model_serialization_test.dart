import 'dart:convert';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes snake_case analysis payloads', () {
    final result = AsleepAnalysisResult.fromJson(
      jsonDecode(
            '{"id":"s1","start_time":"2026-07-29T00:00:00Z",'
            '"sleep_stages":[1,2],"unknown_future_field":true}',
          )
          as Map<String, Object?>,
    );

    expect(result.id, 's1');
    expect(result.startTime, DateTime.utc(2026, 7, 29));
    expect(result.sleepStages, <int>[1, 2]);
  });

  test('unknown error categories remain representable', () {
    final error = AsleepError.fromJson(<String, Object?>{
      'code': 'FUTURE_NATIVE_ERROR',
      'message': 'New native error',
      'sdkCode': 99999,
      'category': 'future-category',
      'caseName': 'futureCase',
    });

    expect(error.code, 'FUTURE_NATIVE_ERROR');
    expect(error.numericCode, 99999);
    expect(error.category, AsleepErrorCategory.unknown);
    expect(error.platformDetails['caseName'], 'futureCase');
  });

  test('semantic error category outranks a colliding numeric code', () {
    final iosError = AsleepError.fromJson(<String, Object?>{
      'code': 'AUDIO_INITIALIZATION_FAILED',
      'message': 'Audio initialization failed',
      'sdkCode': 11003,
    });
    final androidError = AsleepError.fromJson(<String, Object?>{
      'code': 'TRACKING_FAILED',
      'message': 'Audio failed terminally',
      'sdkCode': 11003,
    });

    expect(iosError.category, AsleepErrorCategory.recordingDead);
    expect(androidError.category, AsleepErrorCategory.terminal);
  });

  test('interruption recovery failure is terminal', () {
    final error = AsleepError.fromJson(<String, Object?>{
      'code': 'INTERRUPTION_RECOVERY_FAILED',
      'message': 'Audio interruption recovery failed',
    });

    expect(error.category, AsleepErrorCategory.terminal);
  });

  test('Android upload exhaustion codes are transient', () {
    for (final code in <int>[23000, 23500]) {
      final error = AsleepError.fromJson(<String, Object?>{
        'code': 'TRACKING_FAILED',
        'message': 'Upload retry exhausted',
        'sdkCode': code,
      });

      expect(error.category, AsleepErrorCategory.transient);
    }
  });

  test('tracking numeric codes do not classify setup failures', () {
    final error = AsleepError.fromJson(<String, Object?>{
      'code': 'SETUP_FAILED',
      'message': 'Setup failed before tracking.',
      'sdkCode': 22401,
    });

    expect(error.category, AsleepErrorCategory.unknown);
  });

  test('report list aliases native session keys', () {
    final session = AsleepSession.fromJson(<String, Object?>{
      'session_id': 's1',
      'session_start_time': '2026-07-29T00:00:00Z',
      'created_timezone': 'Asia/Seoul',
      'state': 'COMPLETE',
    });

    expect(session.id, 's1');
    expect(session.startTime, DateTime.utc(2026, 7, 29));
    expect(session.createdTimezone, 'Asia/Seoul');
  });

  test('exposes the complete typed report statistics contract', () {
    final report = AsleepReport.fromJson(<String, Object?>{
      'timezone': 'UTC',
      'session': <String, Object?>{
        'id': 's1',
        'created_timezone': 'UTC',
        'start_time': '2026-07-29T00:00:00Z',
        'state': 'COMPLETE',
      },
      'missing_data_ratio': 0,
      'peculiarities': <String>[],
      'stat': <String, Object?>{
        'sleep_cycle_time': <String>['2026-07-29T01:00:00Z'],
        'time_in_stable_breath': 1,
        'time_in_bed': 2,
        'unstable_breath_ratio': 3.5,
        'sleep_cycle': 4,
        'time_in_sleep': 5,
        'breathing_index': 6.5,
        'deep_latency': 7,
        'rem_latency': 8,
        'time_in_snoring': 9,
        'wake_time': '2026-07-29T08:00:00Z',
        'longest_waso': 10,
        'light_ratio': 11.5,
        'no_snoring_ratio': 12.5,
        'snoring_count': 13,
        'unstable_breath_count': 14,
        'time_in_deep': 15,
        'sleep_time': '2026-07-29T00:30:00Z',
        'sleep_cycle_count': 16,
        'wakeup_latency': 17,
        'breathing_pattern': 'STABLE',
        'time_in_rem': 18,
        'snoring_ratio': 19.5,
        'stable_breath_ratio': 20.5,
        'time_in_sleep_period': 21,
        'light_latency': 22,
        'rem_ratio': 23.5,
        'sleep_efficiency': 24.5,
        'time_in_no_snoring': 25,
        'sleep_latency': 26,
        'time_in_light': 27,
        'sleep_index': 28,
        'sleep_ratio': 29.5,
        'time_in_unstable_breath': 30,
        'waso_count': 31,
        'wake_ratio': 32.5,
        'deep_ratio': 33.5,
        'time_in_wake': 34,
      },
    });
    final stat = report.stat!;

    expect(stat.sleepCycleTime, <String>['2026-07-29T01:00:00Z']);
    expect(stat.timeInStableBreath, 1);
    expect(stat.timeInBed, 2);
    expect(stat.unstableBreathRatio, 3.5);
    expect(stat.sleepCycle, 4);
    expect(stat.timeInSleep, 5);
    expect(stat.breathingIndex, 6.5);
    expect(stat.deepLatency, 7);
    expect(stat.remLatency, 8);
    expect(stat.timeInSnoring, 9);
    expect(stat.wakeTime, '2026-07-29T08:00:00Z');
    expect(stat.longestWaso, 10);
    expect(stat.lightRatio, 11.5);
    expect(stat.noSnoringRatio, 12.5);
    expect(stat.snoringCount, 13);
    expect(stat.unstableBreathCount, 14);
    expect(stat.timeInDeep, 15);
    expect(stat.sleepTime, '2026-07-29T00:30:00Z');
    expect(stat.sleepCycleCount, 16);
    expect(stat.wakeupLatency, 17);
    expect(stat.breathingPattern, 'STABLE');
    expect(stat.timeInRem, 18);
    expect(stat.snoringRatio, 19.5);
    expect(stat.stableBreathRatio, 20.5);
    expect(stat.timeInSleepPeriod, 21);
    expect(stat.lightLatency, 22);
    expect(stat.remRatio, 23.5);
    expect(stat.sleepEfficiency, 24.5);
    expect(stat.timeInNoSnoring, 25);
    expect(stat.sleepLatency, 26);
    expect(stat.timeInLight, 27);
    expect(stat.sleepIndex, 28);
    expect(stat.sleepRatio, 29.5);
    expect(stat.timeInUnstableBreath, 30);
    expect(stat.wasoCount, 31);
    expect(stat.wakeRatio, 32.5);
    expect(stat.deepRatio, 33.5);
    expect(stat.timeInWake, 34);
  });

  test('average-report sessions require and expose completion times', () {
    final report = AsleepAverageReport.fromJson(<String, Object?>{
      'period': <String, Object?>{
        'timezone': 'UTC',
        'start_date': '2026-07-29',
        'end_date': '2026-07-30',
      },
      'peculiarities': <String>[],
      'average_stats': <String, Object?>{
        'sleep_time': '11:41:59',
        'wake_time': '17:38:03',
      },
      'slept_sessions': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'slept',
          'created_timezone': 'UTC',
          'start_time': '2026-07-29T00:00:00Z',
          'end_time': '2026-07-29T08:00:00Z',
          'completed_time': '2026-07-29T08:01:00Z',
          'sleep_efficiency': 90.5,
          'time_in_wake': 10,
          'time_in_sleep_period': 470,
          'time_in_sleep': 450,
          'time_in_bed': 480,
          'wake_ratio': 0.02,
          'sleep_ratio': 0.94,
        },
      ],
      'never_slept_sessions': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'awake',
          'start_time': '2026-07-30T00:00:00Z',
          'end_time': '2026-07-30T01:00:00Z',
          'completed_time': '2026-07-30T01:01:00Z',
        },
      ],
    });

    expect(
      report.sleptSessions.single.completedTime,
      DateTime.utc(2026, 7, 29, 8, 1),
    );
    expect(report.sleptSessions.single.sleepEfficiency, 90.5);
    expect(report.sleptSessions.single.timeInBed, 480);
    expect(report.sleptSessions.single.sleepRatio, 0.94);
    expect(
      report.neverSleptSessions.single.completedTime,
      DateTime.utc(2026, 7, 30, 1, 1),
    );
    expect(report.averageStats!.sleepTime, '11:41:59');
    expect(report.averageStats!.wakeTime, '17:38:03');
  });

  test('average-report session completion times are required', () {
    expect(
      () => AsleepAverageReport.fromJson(<String, Object?>{
        'period': <String, Object?>{
          'timezone': 'UTC',
          'start_date': '2026-07-29',
          'end_date': '2026-07-30',
        },
        'peculiarities': <String>[],
        'slept_sessions': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'slept',
            'created_timezone': 'UTC',
            'start_time': '2026-07-29T00:00:00Z',
            'end_time': '2026-07-29T08:00:00Z',
          },
        ],
      }),
      throwsA(malformedPayloadException),
    );
  });

  test('session identifiers are never exposed as empty strings', () {
    expect(
      AsleepAnalysisResult.fromJson(<String, Object?>{'id': ''}).id,
      isNull,
    );
    expect(
      () => AsleepSession.fromJson(<String, Object?>{
        'sessionId': '',
        'sessionStartTime': '2026-07-29T00:00:00Z',
        'createdTimezone': 'Asia/Seoul',
        'state': 'COMPLETE',
      }),
      throwsA(malformedPayloadException),
    );
  });

  test('invalid JSON syntax throws a typed malformed-payload error', () {
    expect(
      () => AsleepReport.fromJsonString('{'),
      throwsA(malformedPayloadException),
    );
  });

  test('wrong optional collection element types are rejected', () {
    expect(
      () => AsleepAnalysisResult.fromJson(<String, Object?>{
        'sleepStages': <Object?>[1, 'two', 3],
      }),
      throwsA(malformedPayloadException),
    );
    expect(
      () => AsleepAnalysisResult.fromJson(<String, Object?>{
        'sleepStages': <Object?>[1.5],
      }),
      throwsA(malformedPayloadException),
    );
  });

  test('invalid optional dates are rejected instead of treated as absent', () {
    expect(
      () => AsleepAnalysisResult.fromJson(<String, Object?>{
        'startTime': 'not-a-date',
      }),
      throwsA(malformedPayloadException),
    );
  });

  test('required report fields are never synthesized', () {
    expect(
      () => AsleepReport.fromJson(<String, Object?>{
        'timezone': 'UTC',
        'session': <String, Object?>{
          'id': 'session-1',
          'createdTimezone': 'UTC',
          'startTime': '2026-07-29T00:00:00Z',
          'state': 'COMPLETE',
        },
      }),
      throwsA(malformedPayloadException),
    );
  });

  test('decoded nested collections are immutable', () {
    final result = AsleepAnalysisResult.fromJson(<String, Object?>{
      'sleepStages': <int>[1, 2],
    });
    final error = AsleepError.fromJson(<String, Object?>{
      'code': 'FUTURE_NATIVE_ERROR',
      'message': 'New native error',
      'nested': <String, Object?>{
        'values': <Object?>[
          1,
          <String, Object?>{'name': 'value'},
        ],
      },
    });

    expect(() => result.sleepStages!.add(3), throwsUnsupportedError);
    final nested = error.platformDetails['nested']! as Map<String, Object?>;
    final values = nested['values']! as List<Object?>;
    expect(() => nested['new'] = true, throwsUnsupportedError);
    expect(() => values.add(2), throwsUnsupportedError);
    expect(
      () => (values[1]! as Map<String, Object?>)['name'] = 'changed',
      throwsUnsupportedError,
    );
  });

  test('public model constructors defensively copy list inputs', () {
    final stages = <int>[1, 2];
    final result = AsleepAnalysisResult(sleepStages: stages);
    stages.add(3);

    expect(result.sleepStages, <int>[1, 2]);
    expect(() => result.sleepStages!.add(4), throwsUnsupportedError);
  });
}

final Matcher malformedPayloadException = isA<AsleepException>().having(
  (error) => error.code,
  'code',
  AsleepErrorCode.malformedPayload,
);
