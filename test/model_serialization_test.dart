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
}
