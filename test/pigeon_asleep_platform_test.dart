import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asleep_sdk_flutter/src/pigeon_asleep_platform.dart';
import 'package:asleep_sdk_flutter/src/transport.g.dart' as transport;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects unknown native analysis request statuses', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channelName =
        'dev.flutter.pigeon.asleep_sdk_flutter.AsleepHostApi.requestAnalysis';
    final channel = BasicMessageChannel<Object?>(
      channelName,
      transport.AsleepHostApi.pigeonChannelCodec,
      binaryMessenger: messenger,
    );
    messenger.setMockDecodedMessageHandler<Object?>(
      channel,
      (_) async => <Object?>[
        transport.AnalysisRequestMessage(
          status: 'compeleted',
          timestampMilliseconds: null,
          resultJson: null,
        ),
      ],
    );
    addTearDown(
      () => messenger.setMockDecodedMessageHandler<Object?>(channel, null),
    );
    final platform = PigeonAsleepPlatform(
      hostApi: transport.AsleepHostApi(binaryMessenger: messenger),
    );

    await expectLater(
      platform.requestAnalysis(),
      throwsA(malformedPayloadException),
    );
  });

  test('preserves structured native failure details', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channelName =
        'dev.flutter.pigeon.asleep_sdk_flutter.AsleepHostApi.setLoggingEnabled';
    final channel = BasicMessageChannel<Object?>(
      channelName,
      transport.AsleepHostApi.pigeonChannelCodec,
      binaryMessenger: messenger,
    );
    messenger.setMockDecodedMessageHandler<Object?>(
      channel,
      (_) async => <Object?>[
        'ASLEEP_SDK_ERROR',
        'The native SDK failed.',
        <String, Object?>{
          'sdkCode': 23000,
          'caseName': 'networkOffline',
          'platform': 'ios',
        },
      ],
    );
    addTearDown(
      () => messenger.setMockDecodedMessageHandler<Object?>(channel, null),
    );
    final platform = PigeonAsleepPlatform(
      hostApi: transport.AsleepHostApi(binaryMessenger: messenger),
    );

    final exception = await captureAsleepException(
      platform.setLoggingEnabled(true),
    );

    expect(exception.nativeCode, 'ASLEEP_SDK_ERROR');
    expect(exception.nativeDetails, isA<Map<Object?, Object?>>());
    final details = exception.nativeDetails! as Map<Object?, Object?>;
    expect(details['sdkCode'], 23000);
    expect(details['caseName'], 'networkOffline');
    expect(details, isNot(contains('category')));
    expect(details['platform'], 'ios');
  });

  group('PigeonAsleepPlatform event transport', () {
    test(
      'cancelling the mapped stream cancels the native event stream',
      () async {
        var listens = 0;
        var cancels = 0;
        final nativeEvents =
            StreamController<transport.NativeEventMessage>.broadcast(
              onListen: () => listens++,
              onCancel: () => cancels++,
            );
        final platform = PigeonAsleepPlatform(eventStream: nativeEvents.stream);

        final first = platform.events.listen((_) {});
        final second = platform.events.listen((_) {});
        expect(listens, 1);

        await first.cancel();
        expect(cancels, 0);
        await second.cancel();
        expect(cancels, 1);
        await nativeEvents.close();
      },
    );

    test('rejects malformed event JSON with a typed error', () async {
      final nativeEvents =
          StreamController<transport.NativeEventMessage>.broadcast();
      final platform = PigeonAsleepPlatform(eventStream: nativeEvents.stream);
      final error = expectLater(
        platform.events,
        emitsError(malformedPayloadException),
      );

      nativeEvents.add(
        transport.NativeEventMessage(
          type: 'onTrackingCreated',
          payloadJson: '[',
        ),
      );

      await error;
      await nativeEvents.close();
    });

    test('rejects non-object event payloads', () async {
      final nativeEvents =
          StreamController<transport.NativeEventMessage>.broadcast();
      final platform = PigeonAsleepPlatform(eventStream: nativeEvents.stream);
      final error = expectLater(
        platform.events,
        emitsError(malformedPayloadException),
      );

      nativeEvents.add(
        transport.NativeEventMessage(
          type: 'onTrackingCreated',
          payloadJson: '[1,2]',
        ),
      );

      await error;
      await nativeEvents.close();
    });

    test(
      'rejects missing required event fields instead of inventing values',
      () async {
        final cases = <transport.NativeEventMessage>[
          transport.NativeEventMessage(
            type: 'onTrackingUploaded',
            payloadJson: '{}',
          ),
          transport.NativeEventMessage(type: 'onUserJoined', payloadJson: '{}'),
          transport.NativeEventMessage(
            type: 'onSetupInProgress',
            payloadJson: '{"progress":"half"}',
          ),
          transport.NativeEventMessage(
            type: 'onTrackingFailed',
            payloadJson: '{}',
          ),
        ];

        for (final message in cases) {
          final nativeEvents =
              StreamController<transport.NativeEventMessage>.broadcast();
          final platform = PigeonAsleepPlatform(
            eventStream: nativeEvents.stream,
          );
          final error = expectLater(
            platform.events,
            emitsError(malformedPayloadException),
          );
          nativeEvents.add(message);
          await error;
          await nativeEvents.close();
        }
      },
    );

    test('normalizes an absent close ID to a nullable event field', () async {
      final nativeEvents =
          StreamController<transport.NativeEventMessage>.broadcast();
      final platform = PigeonAsleepPlatform(eventStream: nativeEvents.stream);
      final event = platform.events.first;

      nativeEvents.add(
        transport.NativeEventMessage(
          type: 'onTrackingClosed',
          payloadJson: '{}',
        ),
      );

      expect((await event as TrackingClosedEvent).sessionId, isNull);
      await nativeEvents.close();
    });

    test('normalizes empty native session IDs to null', () async {
      final nativeEvents =
          StreamController<transport.NativeEventMessage>.broadcast();
      final platform = PigeonAsleepPlatform(eventStream: nativeEvents.stream);
      final events = platform.events.take(2).toList();

      nativeEvents
        ..add(
          transport.NativeEventMessage(
            type: 'onTrackingCreated',
            payloadJson: '{"sessionId":""}',
          ),
        )
        ..add(
          transport.NativeEventMessage(
            type: 'onTrackingClosed',
            payloadJson: '{"sessionId":""}',
          ),
        );

      final decoded = await events;
      expect((decoded[0] as TrackingCreatedEvent).sessionId, isNull);
      expect((decoded[1] as TrackingClosedEvent).sessionId, isNull);
      await nativeEvents.close();
    });

    test('preserves only genuinely unknown event types', () async {
      final nativeEvents =
          StreamController<transport.NativeEventMessage>.broadcast();
      final platform = PigeonAsleepPlatform(eventStream: nativeEvents.stream);
      final event = platform.events.first;

      nativeEvents.add(
        transport.NativeEventMessage(
          type: 'onFutureEvent',
          payloadJson: '{"nested":{"value":1}}',
        ),
      );

      final unknown = await event as UnknownNativeEvent;
      expect(unknown.type, 'onFutureEvent');
      expect(unknown.payload['nested'], <String, Object?>{'value': 1});
      await nativeEvents.close();
    });
  });
}

final Matcher malformedPayloadException = isA<AsleepException>().having(
  (error) => error.code,
  'code',
  AsleepErrorCode.malformedPayload,
);

Future<AsleepException> captureAsleepException(Future<Object?> future) async {
  try {
    await future;
  } on AsleepException catch (error) {
    return error;
  }
  throw TestFailure('Expected AsleepException.');
}
