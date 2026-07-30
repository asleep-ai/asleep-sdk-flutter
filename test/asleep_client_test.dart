import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsleepClient', () {
    late FakeAsleepPlatform platform;
    late AsleepClient client;
    late bool disposeFailureExpected;

    setUp(() {
      platform = FakeAsleepPlatform();
      client = AsleepClient(platform: platform);
      disposeFailureExpected = false;
    });

    tearDown(() async {
      try {
        await client.dispose();
      } catch (_) {
        if (!disposeFailureExpected) {
          rethrow;
        }
      }
      await platform.close();
    });

    test('projects tracking events into one immutable state stream', () async {
      final states = <AsleepSnapshot>[];
      final subscription = client.states.listen(states.add);

      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(const TrackingInterruptedEvent());
      platform.emit(const TrackingResumedEvent());
      platform.emit(const TrackingClosedEvent(sessionId: 'session-1'));
      await pumpEventQueue();

      expect(
        states.map((state) => state.trackingStatus),
        containsAllInOrder(<TrackingStatus>[
          TrackingStatus.tracking,
          TrackingStatus.paused,
          TrackingStatus.tracking,
          TrackingStatus.idle,
        ]),
      );
      expect(client.state.sessionId, 'session-1');
      expect(client.state.didClose, isTrue);

      await subscription.cancel();
    });

    test('reduces state before publishing each native event', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      TrackingStatus? statusSeenByEventListener;
      final subscription = client.events
          .where((event) => event is TrackingCreatedEvent)
          .listen((_) {
            statusSeenByEventListener = client.state.trackingStatus;
          });

      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      expect(statusSeenByEventListener, TrackingStatus.tracking);
      await subscription.cancel();
    });

    test('does not request permission when startTracking is called', () async {
      platform.hasPermissions = false;
      await prepareClient(client);

      await expectLater(
        client.startTracking(),
        throwsA(
          isA<AsleepException>().having(
            (error) => error.code,
            'code',
            AsleepErrorCode.permissionRequired,
          ),
        ),
      );

      expect(platform.permissionRequestCount, 0);
      expect(platform.startCount, 0);
    });

    test('rejects start when battery optimization is not exempted', () async {
      await prepareClient(client);
      platform.batteryExempted = false;

      await expectLater(
        client.startTracking(),
        throwsInvalidStateContaining('Battery optimization'),
      );

      expect(platform.startCount, 0);
    });

    test('keeps recovery-required sessions active', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        TrackingFailedEvent(
          error: AsleepError(
            code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
            message: 'Foreground recovery is required.',
            category: AsleepErrorCategory.recoveryRequired,
            numericCode: 21002,
          ),
        ),
      );
      await pumpEventQueue();

      expect(client.state.trackingStatus, TrackingStatus.recoveryRequired);
      expect(client.state.isTracking, isTrue);
      expect(client.state.error?.numericCode, 21002);
    });

    test(
      'explicit restore check invalidates a stale preflight result',
      () async {
        platform.hasActiveSession = true;
        await client.configure(
          const AsleepConfiguration(apiKey: 'test-api-key'),
        );
        expect(client.state.trackingStatus, TrackingStatus.tracking);

        platform.hasActiveSession = false;
        final result = await client.checkAndRestoreTracking();

        expect(result.hasActiveSession, isFalse);
        expect(client.state.trackingStatus, TrackingStatus.idle);
        expect(client.state.sessionId, isNull);
      },
    );

    test('restore check does not clear a live in-process session', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      final result = await client.checkAndRestoreTracking();

      expect(result.hasActiveSession, isFalse);
      expect(client.state.trackingStatus, TrackingStatus.tracking);
      expect(client.state.sessionId, 'session-1');
    });

    test('restores before initialization and then permits configure', () async {
      platform.hasActiveSession = true;

      final result = await client.checkAndRestoreTracking();

      expect(result.hasActiveSession, isTrue);
      expect(client.state.trackingStatus, TrackingStatus.tracking);
      expect(client.state.didClose, isFalse);

      await client.configure(const AsleepConfiguration(apiKey: 'test-api-key'));

      expect(client.state.setupStatus, SetupStatus.complete);
      expect(platform.configureCount, 1);
    });

    test('requires restore and battery checks before startTracking', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));

      await expectLater(
        client.startTracking(),
        throwsInvalidStateContaining('checkAndRestoreTracking'),
      );

      await client.checkAndRestoreTracking();
      await expectLater(
        client.startTracking(),
        throwsInvalidStateContaining('checkBatteryOptimization'),
      );

      await client.checkBatteryOptimization();
      await client.startTracking();
      expect(platform.startCount, 1);
    });

    test(
      'successful start is immediately stoppable before its event',
      () async {
        await prepareClient(client);

        await client.startTracking();
        await client.stopTracking();

        expect(client.state.trackingStatus, TrackingStatus.tracking);
        expect(platform.stopCount, 1);
      },
    );

    test('allows only one startTracking command in flight', () async {
      await prepareClient(client);
      platform.startCompleter = Completer<void>();

      final first = client.startTracking();
      await pumpEventQueue();
      await expectLater(
        client.startTracking(),
        throwsInvalidStateContaining('already in progress'),
      );
      expect(platform.startCount, 1);

      platform.startCompleter!.complete();
      await first;
    });

    test('rejects restore while a start command is pending', () async {
      await prepareClient(client);
      platform.startCompleter = Completer<void>();
      final start = client.startTracking();
      await pumpEventQueue();

      await expectLater(
        client.checkAndRestoreTracking(),
        throwsInvalidStateContaining('lifecycle command'),
      );

      platform.startCompleter!.complete();
      await start;
    });

    test('releases the start guard after native rejection', () async {
      await prepareClient(client);
      platform.startError = StateError('first start failed');

      await expectLater(client.startTracking(), throwsStateError);
      platform.startError = null;
      await client.startTracking();

      expect(platform.startCount, 2);
    });

    test('allows only one stopTracking command in flight', () async {
      await prepareClient(client);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.stopCompleter = Completer<void>();

      final first = client.stopTracking();
      await expectLater(
        client.stopTracking(),
        throwsInvalidStateContaining('already in progress'),
      );
      expect(platform.stopCount, 1);

      platform.stopCompleter!.complete();
      await first;
    });

    test('stopTracking can cancel a pending start', () async {
      await prepareClient(client);
      platform.startCompleter = Completer<void>();

      final start = client.startTracking();
      await pumpEventQueue();
      final startFailure = expectLater(start, throwsStateError);

      await client.stopTracking();
      platform.startCompleter!.completeError(StateError('start cancelled'));

      await startFailure;
      expect(platform.stopCount, 1);

      platform.startCompleter = null;
      await expectLater(
        client.startTracking(),
        throwsInvalidStateContaining('checkAndRestoreTracking'),
      );
      await client.checkAndRestoreTracking();
      await client.startTracking();
      expect(platform.startCount, 2);
    });

    test('stopTracking cancels start before native start is invoked', () async {
      await prepareClient(client);
      platform.permissionCompleter = Completer<bool>();
      final start = client.startTracking();
      await pumpEventQueue();
      final startFailure = expectLater(
        start,
        throwsInvalidStateContaining('cancelled'),
      );

      await client.stopTracking();
      platform.permissionCompleter!.complete(true);

      await startFailure;
      expect(platform.startCount, 0);
      expect(platform.stopCount, 1);
    });

    test('allows only one resumeTracking command in flight', () async {
      await prepareClient(client);
      platform.emit(const TrackingInterruptedEvent());
      platform.resumeCompleter = Completer<void>();

      final first = client.resumeTracking();
      await expectLater(
        client.resumeTracking(),
        throwsInvalidStateContaining('already in progress'),
      );
      expect(platform.resumeCount, 1);

      platform.resumeCompleter!.complete();
      await first;
    });

    test('requests analysis on every ODA upload', () async {
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();

      expect(platform.analysisRequestCount, 1);
      expect(client.state.isAnalyzing, isTrue);
    });

    test(
      'requestAnalysis requires a live session and rejects duplicates',
      () async {
        await prepareClient(client);
        await expectLater(
          client.requestAnalysis(),
          throwsInvalidStateContaining('No tracking session'),
        );

        platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
        platform.analysisCompleter = Completer<AnalysisRequest>();
        final first = client.requestAnalysis();

        await expectLater(
          client.requestAnalysis(),
          throwsInvalidStateContaining('already pending'),
        );
        expect(platform.analysisRequestCount, 1);

        platform.analysisCompleter!.complete(
          const AnalysisRequest(status: AnalysisRequestStatus.requested),
        );
        await first;
        expect(client.state.isAnalyzing, isTrue);

        platform.emit(
          AnalysisResultEvent(
            result: AsleepAnalysisResult(
              id: 'session-1',
              sleepStages: <int>[1],
            ),
          ),
        );
        expect(client.state.isAnalyzing, isFalse);
      },
    );

    test(
      'requestAnalysis rejects paused and recovery-required sessions',
      () async {
        await prepareClient(client);
        platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
        platform.emit(const TrackingInterruptedEvent());
        await expectLater(
          client.requestAnalysis(),
          throwsInvalidStateContaining('No tracking session'),
        );

        platform.emit(
          AsleepError(
            code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
            message: 'Foreground recovery is required.',
            category: AsleepErrorCategory.recoveryRequired,
          ).asTrackingFailure,
        );
        await expectLater(
          client.requestAnalysis(),
          throwsInvalidStateContaining('No tracking session'),
        );
        expect(platform.analysisRequestCount, 0);
      },
    );

    test('blocks manual and automatic analysis while stopping', () async {
      await prepareClient(client);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.stopCompleter = Completer<void>();
      final stop = client.stopTracking();

      await expectLater(
        client.requestAnalysis(),
        throwsInvalidStateContaining('stopping'),
      );
      platform.emit(const TrackingUploadedEvent(sequence: 11));
      await pumpEventQueue();
      expect(platform.analysisRequestCount, 0);
      expect(client.state.error, isNull);

      platform.stopCompleter!.complete();
      await stop;
    });

    test('configure preserves the ODA cadence selected at setup', () async {
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );
      await client.configure(
        const AsleepConfiguration(apiKey: 'replacement-api-key'),
      );
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();

      expect(platform.analysisRequestCount, 1);
    });

    test('recording-dead failure does not report a clean close', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        TrackingFailedEvent(
          error: AsleepError(
            code: 'AUDIO_INITIALIZATION_FAILED',
            message: 'Audio recording cannot continue.',
            category: AsleepErrorCategory.recordingDead,
            numericCode: 11003,
          ),
        ),
      );
      await pumpEventQueue();

      expect(client.state.trackingStatus, TrackingStatus.idle);
      expect(client.state.isTracking, isFalse);
      expect(client.state.didClose, isFalse);
    });

    test('only an upload clears recovery-required tracking state', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        AsleepError(
          code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
          message: 'Foreground recovery is required.',
          category: AsleepErrorCategory.recoveryRequired,
        ).asTrackingFailure,
      );

      platform.emit(const TrackingResumedEvent());
      expect(client.state.trackingStatus, TrackingStatus.recoveryRequired);
      expect(client.state.error, isNull);

      platform.emit(const TrackingUploadedEvent(sequence: 2));
      expect(client.state.trackingStatus, TrackingStatus.tracking);
    });

    test('only terminal tracking failures clear pending analysis', () async {
      await prepareClient(client);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      await client.requestAnalysis();
      expect(client.state.isAnalyzing, isTrue);

      platform.emit(
        AsleepError(
          code: 'TRACKING_FAILED',
          message: 'Upload retry exhausted.',
          category: AsleepErrorCategory.transient,
          numericCode: 23000,
        ).asTrackingFailure,
      );
      expect(client.state.trackingStatus, TrackingStatus.tracking);
      expect(client.state.isAnalyzing, isTrue);

      platform.emit(
        AsleepError(
          code: 'UPLOAD_TRACKING_TERMINATED',
          message: 'Tracking terminated.',
          category: AsleepErrorCategory.terminal,
        ).asTrackingFailure,
      );
      expect(client.state.trackingStatus, TrackingStatus.idle);
      expect(client.state.isAnalyzing, isFalse);
    });

    test('clears a stale session ID when a new session has no ID', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(const TrackingCreatedEvent(sessionId: ''));

      expect(client.state.sessionId, isNull);
    });

    test('keeps the current session ID when close has no ID', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(const TrackingClosedEvent());

      expect(client.state.sessionId, 'session-1');
    });

    test('recording-dead sessions must be stopped before a restart', () async {
      await prepareClient(client);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        AsleepError(
          code: 'AUDIO_INITIALIZATION_FAILED',
          message: 'Recorder stopped.',
          category: AsleepErrorCategory.recordingDead,
        ).asTrackingFailure,
      );

      await expectLater(
        client.startTracking(),
        throwsInvalidStateContaining('stopTracking'),
      );
      await client.stopTracking();
      expect(platform.stopCount, 1);
    });

    test('successful initialize completes setup state', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));

      expect(client.state.setupStatus, SetupStatus.complete);
    });

    test('suppresses duplicate setup-complete snapshots', () async {
      platform.emitSetupCompletedBeforeReturn = true;
      var completedSnapshots = 0;
      final subscription = client.states.listen((state) {
        if (state.setupStatus == SetupStatus.complete) {
          completedSnapshots++;
        }
      });

      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));

      expect(completedSnapshots, 1);
      await subscription.cancel();
    });

    test('rejects setup while tracking is active', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      await expectLater(
        client.initialize(
          const AsleepSetupOptions(apiKey: 'replacement-api-key'),
        ),
        throwsInvalidStateContaining('tracking'),
      );

      expect(platform.setupCount, 1);
      expect(client.state.trackingStatus, TrackingStatus.tracking);
    });

    test('failed reinitialize invalidates prior readiness', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.setupError = StateError('replacement setup failed');

      await expectLater(
        client.initialize(
          const AsleepSetupOptions(apiKey: 'replacement-api-key'),
        ),
        throwsStateError,
      );

      expect(client.state.setupStatus, SetupStatus.idle);
      expect(
        (await client.checkAndRestoreTracking()).hasActiveSession,
        isFalse,
      );
      await expectLater(
        client.checkBatteryOptimization(),
        throwsInvalidStateContaining('initialize'),
      );
    });

    test('setup rejection preserves a richer failure event', () async {
      final nativeError = AsleepError(
        code: 'SETUP_FAILED',
        message: 'Native setup failed.',
        numericCode: 22401,
      );
      platform
        ..setupFailureEvent = nativeError
        ..setupError = StateError('generic host rejection');

      await expectLater(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
        throwsStateError,
      );

      expect(client.state.error, same(nativeError));
    });

    test('blocks setup but can stop a restored session', () async {
      platform.hasActiveSession = true;

      await expectLater(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
        throwsInvalidStateContaining('configure'),
      );
      expect(client.state.trackingStatus, TrackingStatus.tracking);
      expect(platform.setupCount, 0);

      await client.stopTracking();
      expect(platform.stopCount, 1);
    });

    test('configures a session found by initialize preflight', () async {
      platform.hasActiveSession = true;
      await expectLater(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
        throwsInvalidStateContaining('configure'),
      );

      await client.configure(const AsleepConfiguration(apiKey: 'test-api-key'));

      expect(client.state.setupStatus, SetupStatus.complete);
      expect(client.state.trackingStatus, TrackingStatus.tracking);
      expect(platform.configureCount, 1);
    });

    test('does not allow repeated configure on a restored session', () async {
      platform.hasActiveSession = true;
      await expectLater(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
        throwsInvalidStateContaining('configure'),
      );
      await client.configure(const AsleepConfiguration(apiKey: 'test-api-key'));

      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
        throwsInvalidStateContaining('tracking'),
      );
      expect(platform.configureCount, 1);
    });

    test('clears a stale initialize preflight before configure', () async {
      platform.hasActiveSession = true;
      await expectLater(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
        throwsInvalidStateContaining('configure'),
      );
      platform.hasActiveSession = false;

      await client.configure(const AsleepConfiguration(apiKey: 'test-api-key'));

      expect(client.state.trackingStatus, TrackingStatus.idle);
      expect(client.state.sessionId, isNull);
    });

    test('failed configure invalidates prior readiness', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.configureError = StateError('replacement config failed');

      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
        throwsStateError,
      );

      expect(client.state.setupStatus, SetupStatus.idle);
      expect(
        (await client.checkAndRestoreTracking()).hasActiveSession,
        isFalse,
      );
      await expectLater(
        client.checkBatteryOptimization(),
        throwsInvalidStateContaining('initialize'),
      );
    });

    test('rejects configure while a start command is pending', () async {
      await prepareClient(client);
      platform.startCompleter = Completer<void>();
      final start = client.startTracking();
      await pumpEventQueue();

      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
        throwsInvalidStateContaining('tracking'),
      );

      platform.startCompleter!.complete();
      await start;
    });

    test('rejects configure while a recording-dead session remains', () async {
      await prepareClient(client);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        AsleepError(
          code: 'AUDIO_INITIALIZATION_FAILED',
          message: 'Recorder stopped.',
          category: AsleepErrorCategory.recordingDead,
        ).asTrackingFailure,
      );

      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
        throwsInvalidStateContaining('tracking'),
      );
    });

    test('configure rejection preserves a richer failure event', () async {
      final nativeError = AsleepError(
        code: 'INITIALIZATION_FAILED',
        message: 'Native user join failed.',
        numericCode: 22401,
      );
      platform
        ..configureFailureEvent = nativeError
        ..configureError = StateError('generic host rejection');

      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
        throwsStateError,
      );

      expect(client.state.error, same(nativeError));
    });

    test('rejects invalid custom URLs before invoking native setup', () async {
      for (final value in <String>[
        '',
        'relative/path',
        'ftp://example.com',
        'https:///missing-host',
      ]) {
        await expectLater(
          client.initialize(
            AsleepSetupOptions(apiKey: 'test-api-key', baseUrl: value),
          ),
          throwsA(
            isA<AsleepException>().having(
              (error) => error.code,
              'code',
              AsleepErrorCode.invalidArgument,
            ),
          ),
        );
      }
      expect(platform.setupCount, 0);
    });

    test('accepts absolute HTTP and HTTPS custom URLs', () async {
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          baseUrl: 'https://api.example.com/v1',
          callbackUrl: 'http://callback.example.com/asleep',
        ),
      );

      expect(platform.setupCount, 1);
    });

    test(
      'rejects empty identifiers and credentials at the Dart boundary',
      () async {
        await expectLater(
          client.initialize(const AsleepSetupOptions(apiKey: ' ')),
          throwsInvalidArgument,
        );
        await expectLater(
          client.configure(
            const AsleepConfiguration(apiKey: 'test-api-key', userId: ''),
          ),
          throwsInvalidArgument,
        );
        await expectLater(
          client.initialize(
            const AsleepSetupOptions(apiKey: 'test-api-key', service: ''),
          ),
          throwsInvalidArgument,
        );

        await client.initialize(
          const AsleepSetupOptions(apiKey: 'test-api-key'),
        );
        expect(() => client.getReport(''), throwsInvalidArgument);
        expect(() => client.deleteSession(' '), throwsInvalidArgument);
        expect(
          () => client.getReportList('', '2026-07-30'),
          throwsInvalidArgument,
        );
      },
    );

    test('dispose detaches native events and closes streams', () async {
      var eventCount = 0;
      var stateDone = false;
      final eventSubscription = client.events.listen((_) => eventCount++);
      final stateSubscription = client.states.listen(
        (_) {},
        onDone: () => stateDone = true,
      );

      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      await client.dispose();
      platform.emit(const TrackingCreatedEvent(sessionId: 'ignored'));
      await pumpEventQueue();

      expect(eventCount, 0);
      expect(stateDone, isTrue);
      await eventSubscription.cancel();
      await stateSubscription.cancel();
    });

    test('native stream failures surface on the public event stream', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      final expected = AsleepException(
        AsleepErrorCode.malformedPayload,
        'Malformed native event.',
      );
      final stateSeenByErrorListener = Completer<AsleepError?>();
      final subscription = client.events.listen(
        (_) {},
        onError: (Object _, StackTrace stackTrace) {
          stateSeenByErrorListener.complete(client.state.error);
        },
      );

      platform.emitError(expected);

      expect(
        (await stateSeenByErrorListener.future)?.code,
        AsleepErrorCode.malformedPayload.name,
      );
      await subscription.cancel();
    });

    test('dispose closes streams even when platform cleanup fails', () async {
      var eventsDone = false;
      var statesDone = false;
      final eventSubscription = client.events.listen(
        (_) {},
        onDone: () => eventsDone = true,
      );
      final stateSubscription = client.states.listen(
        (_) {},
        onDone: () => statesDone = true,
      );
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.disposeError = StateError('native cleanup failed');
      disposeFailureExpected = true;

      await expectLater(client.dispose(), throwsStateError);
      await pumpEventQueue();

      expect(platform.eventCancelCount, 1);
      expect(platform.disposeCount, 1);
      expect(eventsDone, isTrue);
      expect(statesDone, isTrue);
      expect(
        client.hasRequiredPermissions,
        throwsA(
          isA<AsleepException>().having(
            (error) => error.code,
            'code',
            AsleepErrorCode.disposed,
          ),
        ),
      );

      await eventSubscription.cancel();
      await stateSubscription.cancel();
    });

    test('concurrent dispose calls share cleanup completion', () async {
      platform.disposeCompleter = Completer<void>();
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));

      final first = client.dispose();
      final second = client.dispose();
      var secondCompleted = false;
      unawaited(second.then((_) => secondCompleted = true));
      await pumpEventQueue();

      expect(identical(first, second), isTrue);
      expect(secondCompleted, isFalse);

      platform.disposeCompleter!.complete();
      await Future.wait(<Future<void>>[first, second]);
      expect(secondCompleted, isTrue);
    });
  });

  test('only one default native client can hold the engine lease', () async {
    final first = AsleepClient();
    expect(
      () => AsleepClient(),
      throwsA(
        isA<AsleepException>().having(
          (error) => error.code,
          'code',
          AsleepErrorCode.invalidState,
        ),
      ),
    );

    await first.dispose();
    final replacement = AsleepClient();
    await replacement.dispose();
  });
}

class FakeAsleepPlatform extends AsleepPlatform {
  FakeAsleepPlatform() {
    _events = StreamController<AsleepEvent>.broadcast(
      onListen: () => eventListenCount++,
      onCancel: () => eventCancelCount++,
      sync: true,
    );
  }

  late final StreamController<AsleepEvent> _events;

  bool hasPermissions = true;
  bool hasActiveSession = false;
  bool batteryExempted = true;
  bool emitSetupCompletedBeforeReturn = false;
  Object? setupError;
  Object? configureError;
  AsleepError? setupFailureEvent;
  AsleepError? configureFailureEvent;
  Object? startError;
  Object? disposeError;
  Completer<void>? startCompleter;
  Completer<void>? stopCompleter;
  Completer<void>? resumeCompleter;
  Completer<AnalysisRequest>? analysisCompleter;
  Completer<void>? disposeCompleter;
  Completer<bool>? permissionCompleter;
  int permissionRequestCount = 0;
  int setupCount = 0;
  int configureCount = 0;
  int startCount = 0;
  int stopCount = 0;
  int resumeCount = 0;
  int analysisRequestCount = 0;
  int eventListenCount = 0;
  int eventCancelCount = 0;
  int disposeCount = 0;

  @override
  Stream<AsleepEvent> get events => _events.stream;

  void emit(AsleepEvent event) => _events.add(event);

  void emitError(Object error) => _events.addError(error);

  Future<void> close() => _events.close();

  @override
  Future<void> setup(AsleepSetupOptions options) async {
    setupCount++;
    if (emitSetupCompletedBeforeReturn) {
      emit(const SetupCompletedEvent());
    }
    if (setupFailureEvent case final error?) {
      emit(SetupFailedEvent(error: error));
    }
    if (setupError case final error?) {
      throw error;
    }
  }

  @override
  Future<void> configure(AsleepConfiguration configuration) async {
    configureCount++;
    if (configureFailureEvent case final error?) {
      emit(UserJoinFailedEvent(error: error));
    }
    if (configureError case final error?) {
      throw error;
    }
  }

  @override
  Future<RestoreResult> checkAndRestoreTracking() async {
    return RestoreResult(hasActiveSession: hasActiveSession);
  }

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    return BatteryOptimizationStatus(
      exempted: batteryExempted,
      platform: 'test',
    );
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;

  @override
  Future<bool> hasRequiredPermissions() async {
    if (permissionCompleter case final completer?) {
      return completer.future;
    }
    return hasPermissions;
  }

  @override
  Future<bool> requestRequiredPermissions() async {
    permissionRequestCount++;
    return hasPermissions;
  }

  @override
  Future<void> startTracking(AsleepTrackingOptions options) async {
    startCount++;
    if (startError case final error?) {
      throw error;
    }
    await startCompleter?.future;
  }

  @override
  Future<void> resumeTracking() async {
    resumeCount++;
    await resumeCompleter?.future;
  }

  @override
  Future<void> stopTracking() async {
    stopCount++;
    await stopCompleter?.future;
  }

  @override
  Future<AnalysisRequest> requestAnalysis() async {
    analysisRequestCount++;
    if (analysisCompleter case final completer?) {
      return completer.future;
    }
    return const AnalysisRequest(status: AnalysisRequestStatus.requested);
  }

  @override
  Future<AsleepReport> getReport(String sessionId) {
    throw UnimplementedError();
  }

  @override
  Future<List<AsleepSession>> getReportList(
    String fromDate,
    String toDate,
  ) async {
    return const <AsleepSession>[];
  }

  @override
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> setLoggingEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {
    disposeCount++;
    await disposeCompleter?.future;
    if (disposeError case final error?) {
      throw error;
    }
  }
}

Future<void> prepareClient(AsleepClient client) async {
  await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
  await client.checkAndRestoreTracking();
  await client.checkBatteryOptimization();
}

Matcher throwsInvalidStateContaining(String text) {
  return throwsA(
    isA<AsleepException>()
        .having((error) => error.code, 'code', AsleepErrorCode.invalidState)
        .having((error) => error.message, 'message', contains(text)),
  );
}

final Matcher throwsInvalidArgument = throwsA(
  isA<AsleepException>().having(
    (error) => error.code,
    'code',
    AsleepErrorCode.invalidArgument,
  ),
);

extension on AsleepError {
  TrackingFailedEvent get asTrackingFailure => TrackingFailedEvent(error: this);
}
