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
