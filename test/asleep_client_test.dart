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

    test('serializes restore checks against restore and initialize', () async {
      platform.restoreCompleter = Completer<RestoreResult>();
      final restore = client.checkAndRestoreTracking();
      await pumpEventQueue();

      await expectLater(
        client.checkAndRestoreTracking(),
        throwsInvalidStateContaining('another restore'),
      );
      await expectLater(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
        throwsInvalidStateContaining('restore check'),
      );

      platform.restoreCompleter!.complete(
        const RestoreResult(hasActiveSession: true),
      );
      expect((await restore).hasActiveSession, isTrue);
      expect(platform.setupCount, 0);
    });

    test('releases the restore guard after native rejection', () async {
      platform.restoreCompleter = Completer<RestoreResult>();
      final restore = client.checkAndRestoreTracking();
      final failure = expectLater(restore, throwsNativeFailure);

      platform.restoreCompleter!.completeError(
        StateError('restore unavailable'),
      );
      await failure;
      platform.restoreCompleter = null;

      expect(
        (await client.checkAndRestoreTracking()).hasActiveSession,
        isFalse,
      );
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

    for (final event in <AsleepEvent>[
      const TrackingCreatedEvent(sessionId: 'restored-session'),
      const TrackingUploadedEvent(sequence: 1),
    ]) {
      test('preserves restored-session configure access after '
          '${event.runtimeType}', () async {
        platform.hasActiveSession = true;
        await client.checkAndRestoreTracking();

        platform.emit(event);
        await client.configure(
          const AsleepConfiguration(apiKey: 'test-api-key'),
        );

        expect(client.state.setupStatus, SetupStatus.complete);
        expect(platform.configureCount, 1);
      });
    }

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

      await expectLater(client.startTracking(), throwsNativeFailure);
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
      final startFailure = expectLater(start, throwsNativeFailure);

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
      final modes = <bool>[];
      final subscription = client.states.listen(
        (state) => modes.add(state.isOnDeviceAnalysisEnabled),
      );

      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );
      expect(client.state.isOnDeviceAnalysisEnabled, isTrue);
      expect(modes, contains(true));

      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();

      expect(platform.analysisRequestCount, 1);
      expect(client.state.isAnalyzing, isTrue);
      await subscription.cancel();
    });

    test('uses non-ODA cadence from the public snapshot', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      expect(client.state.isOnDeviceAnalysisEnabled, isFalse);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();
      expect(platform.analysisRequestCount, 0);

      platform.emit(const TrackingUploadedEvent(sequence: 11));
      await pumpEventQueue();
      expect(platform.analysisRequestCount, 1);
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
      expect(client.state.error?.code, AsleepErrorCode.invalidState.name);

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
      expect(client.state.isOnDeviceAnalysisEnabled, isTrue);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();

      expect(platform.analysisRequestCount, 1);
    });

    test('restoration and configure default to non-ODA mode', () async {
      platform.hasActiveSession = true;

      final restored = await client.checkAndRestoreTracking();
      expect(restored.hasActiveSession, isTrue);
      expect(client.state.isOnDeviceAnalysisEnabled, isFalse);

      await client.configure(
        const AsleepConfiguration(apiKey: 'replacement-api-key'),
      );
      expect(client.state.isOnDeviceAnalysisEnabled, isFalse);
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

    test(
      'recovers state while iOS quarantines timed-out initialization',
      () async {
        platform.setupCompleter = Completer<void>();
        final initialization = client.initialize(
          const AsleepSetupOptions(apiKey: 'test-api-key'),
        );
        await pumpEventQueue();

        await expectLater(
          client.initialize(
            const AsleepSetupOptions(apiKey: 'concurrent-api-key'),
          ),
          throwsInvalidStateContaining('already in progress'),
        );

        platform.setupCompleter!.completeError(
          const AsleepException(
            AsleepErrorCode.nativeFailure,
            'The native Asleep SDK did not complete setup within 30 seconds',
            nativeCode: 'INITIALIZATION_TIMEOUT',
            nativeDetails: <String, Object?>{
              'phase': 'setup',
              'timeoutSeconds': 30,
              'platform': 'ios',
            },
          ),
        );
        await expectLater(
          initialization,
          throwsA(
            isA<AsleepException>().having(
              (error) => error.nativeCode,
              'nativeCode',
              'INITIALIZATION_TIMEOUT',
            ),
          ),
        );

        expect(client.state.setupStatus, SetupStatus.idle);
        expect(client.state.error?.code, 'INITIALIZATION_TIMEOUT');
        expect(client.state.error?.platformDetails['phase'], 'setup');

        platform.setupCompleter = null;
        platform.setupError = const AsleepException(
          AsleepErrorCode.nativeFailure,
          'Wait for the timed-out iOS initialization attempt to finish before retrying',
          nativeCode: 'INITIALIZATION_RECOVERY_REQUIRED',
        );
        await expectLater(
          client.initialize(
            const AsleepSetupOptions(apiKey: 'quarantined-retry-api-key'),
          ),
          throwsA(
            isA<AsleepException>().having(
              (error) => error.nativeCode,
              'nativeCode',
              'INITIALIZATION_RECOVERY_REQUIRED',
            ),
          ),
        );

        platform.setupError = null;
        await client.initialize(
          const AsleepSetupOptions(apiKey: 'retry-api-key'),
        );

        expect(platform.setupCount, 3);
        expect(client.state.setupStatus, SetupStatus.complete);
        expect(client.state.error, isNull);
      },
    );

    test('permits configure retry after native join quarantine settles', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.configureCompleter = Completer<void>();
      final configuration = client.configure(
        const AsleepConfiguration(apiKey: 'replacement-api-key'),
      );
      await pumpEventQueue();

      platform.configureCompleter!.completeError(
        const AsleepException(
          AsleepErrorCode.nativeFailure,
          'The native Asleep SDK did not complete configuration within 30 seconds',
          nativeCode: 'INITIALIZATION_TIMEOUT',
          nativeDetails: <String, Object?>{
            'phase': 'configuration',
            'timeoutSeconds': 30,
            'platform': 'ios',
          },
        ),
      );
      await expectLater(configuration, throwsA(isA<AsleepException>()));

      expect(client.state.setupStatus, SetupStatus.idle);
      expect(client.state.error?.code, 'INITIALIZATION_TIMEOUT');

      platform.configureCompleter = null;
      platform.configureError = const AsleepException(
        AsleepErrorCode.nativeFailure,
        'Wait for the timed-out iOS initialization attempt to finish before retrying',
        nativeCode: 'INITIALIZATION_RECOVERY_REQUIRED',
      );
      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'quarantined-retry-api-key'),
        ),
        throwsA(
          isA<AsleepException>().having(
            (error) => error.nativeCode,
            'nativeCode',
            'INITIALIZATION_RECOVERY_REQUIRED',
          ),
        ),
      );

      platform.configureError = null;
      await client.configure(
        const AsleepConfiguration(apiKey: 'retry-api-key'),
      );

      expect(platform.configureCount, 3);
      expect(client.state.setupStatus, SetupStatus.complete);
      expect(client.state.error, isNull);
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
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );
      expect(client.state.isOnDeviceAnalysisEnabled, isTrue);
      platform.setupError = StateError('replacement setup failed');

      await expectLater(
        client.initialize(
          const AsleepSetupOptions(apiKey: 'replacement-api-key'),
        ),
        throwsNativeFailure,
      );

      expect(client.state.setupStatus, SetupStatus.idle);
      expect(client.state.isOnDeviceAnalysisEnabled, isFalse);
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

      final exception = await captureAsleepException(
        client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key')),
      );

      expect(client.state.error, same(nativeError));
      expect(exception.error, same(nativeError));
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
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );
      platform.configureError = StateError('replacement config failed');

      await expectLater(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
        throwsNativeFailure,
      );

      expect(client.state.setupStatus, SetupStatus.idle);
      expect(client.state.isOnDeviceAnalysisEnabled, isFalse);
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

      final exception = await captureAsleepException(
        client.configure(
          const AsleepConfiguration(apiKey: 'replacement-api-key'),
        ),
      );

      expect(client.state.error, same(nativeError));
      expect(exception.error, same(nativeError));
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

    test('validation failures publish the thrown structured error', () async {
      final exception = await captureAsleepException(
        client.initialize(const AsleepSetupOptions(apiKey: ' ')),
      );

      expect(exception.error, same(client.state.error));
      expect(exception.error?.code, AsleepErrorCode.invalidArgument.name);
      expect(exception.error?.message, contains('apiKey'));
    });

    test('native command details are shared with the snapshot error', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.loggingError = const AsleepException(
        AsleepErrorCode.nativeFailure,
        'Logging failed.',
        nativeCode: 'ASLEEP_SDK_ERROR',
        nativeDetails: <String, Object?>{
          'sdkCode': 23000,
          'caseName': 'networkOffline',
          'platform': 'ios',
        },
      );

      final exception = await captureAsleepException(
        client.setLoggingEnabled(true),
      );

      expect(exception.error, same(client.state.error));
      expect(exception.nativeCode, 'ASLEEP_SDK_ERROR');
      expect(exception.error?.code, 'NETWORK_OFFLINE');
      expect(exception.error?.category, AsleepErrorCategory.transient);
      expect(exception.error?.numericCode, 23000);
      expect(exception.error?.platformDetails['caseName'], 'networkOffline');
      expect(exception.error?.platformDetails['platform'], 'ios');
    });

    test('a richer concurrent event error wins a command failure', () async {
      await prepareClient(client);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.analysisCompleter = Completer<AnalysisRequest>();
      final analysis = client.requestAnalysis();
      await pumpEventQueue();
      final eventError = AsleepError(
        code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
        message: 'Resume in the foreground.',
        category: AsleepErrorCategory.recoveryRequired,
        numericCode: 21002,
      );
      platform.emit(TrackingFailedEvent(error: eventError));
      platform.analysisCompleter!.completeError(StateError('generic failure'));

      final exception = await captureAsleepException(analysis);

      expect(client.state.error, same(eventError));
      expect(exception.error, same(eventError));
      expect(client.state.isAnalyzing, isFalse);
    });

    test('overlapping command failures keep their own errors', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.permissionCompleter = Completer<bool>();
      final permission = client.hasRequiredPermissions();

      platform.loggingError = StateError('logging failed');
      final loggingException = await captureAsleepException(
        client.setLoggingEnabled(true),
      );
      platform.permissionCompleter!.completeError(
        StateError('permission failed'),
      );
      final permissionException = await captureAsleepException(permission);

      expect(loggingException.error?.message, contains('logging failed'));
      expect(permissionException.error?.message, contains('permission failed'));
      expect(permissionException.error, same(client.state.error));
      expect(permissionException.error, isNot(same(loggingException.error)));
    });

    test(
      'cleared event errors are not resurrected by command failures',
      () async {
        await client.initialize(
          const AsleepSetupOptions(apiKey: 'test-api-key'),
        );
        final eventError = AsleepError(
          code: 'NETWORK_OFFLINE',
          message: 'The native event failed.',
          category: AsleepErrorCategory.transient,
        );

        platform.permissionCompleter = Completer<bool>();
        var permission = client.hasRequiredPermissions();
        platform.emit(TrackingFailedEvent(error: eventError));
        client.clearError();
        platform.permissionCompleter!.completeError(
          StateError('permission failed after clear'),
        );

        var exception = await captureAsleepException(permission);
        expect(
          exception.error?.message,
          contains('permission failed after clear'),
        );
        expect(exception.error, same(client.state.error));
        expect(exception.error, isNot(same(eventError)));

        client.clearError();
        platform.permissionCompleter = Completer<bool>();
        permission = client.hasRequiredPermissions();
        platform.emit(TrackingFailedEvent(error: eventError));
        platform.emit(const UserJoinedEvent(userId: 'user-1'));
        platform.permissionCompleter!.completeError(
          StateError('permission failed after success event'),
        );

        exception = await captureAsleepException(permission);
        expect(
          exception.error?.message,
          contains('permission failed after success event'),
        );
        expect(exception.error, same(client.state.error));
        expect(exception.error, isNot(same(eventError)));
      },
    );

    test(
      'auxiliary command failures share one structured error instance',
      () async {
        await client.initialize(
          const AsleepSetupOptions(apiKey: 'test-api-key'),
        );
        final failure = StateError('native command failed');
        final cases =
            <
              ({
                void Function() arrange,
                Future<Object?> Function() invoke,
                void Function() reset,
              })
            >[
              (
                arrange: () => platform.restoreError = failure,
                invoke: client.checkAndRestoreTracking,
                reset: () => platform.restoreError = null,
              ),
              (
                arrange: () => platform.batteryCheckError = failure,
                invoke: client.checkBatteryOptimization,
                reset: () => platform.batteryCheckError = null,
              ),
              (
                arrange: () => platform.batteryRequestError = failure,
                invoke: client.requestBatteryOptimizationExemption,
                reset: () => platform.batteryRequestError = null,
              ),
              (
                arrange: () => platform.permissionCheckError = failure,
                invoke: client.hasRequiredPermissions,
                reset: () => platform.permissionCheckError = null,
              ),
              (
                arrange: () => platform.permissionRequestError = failure,
                invoke: client.requestRequiredPermissions,
                reset: () => platform.permissionRequestError = null,
              ),
              (
                arrange: () => platform.reportError = failure,
                invoke: () => client.getReport('session-1'),
                reset: () => platform.reportError = null,
              ),
              (
                arrange: () => platform.reportListError = failure,
                invoke: () => client.getReportList('2026-07-01', '2026-07-30'),
                reset: () => platform.reportListError = null,
              ),
              (
                arrange: () => platform.averageReportError = failure,
                invoke: () =>
                    client.getAverageReport('2026-07-01', '2026-07-30'),
                reset: () => platform.averageReportError = null,
              ),
              (
                arrange: () => platform.deleteError = failure,
                invoke: () => client.deleteSession('session-1'),
                reset: () => platform.deleteError = null,
              ),
              (
                arrange: () => platform.loggingError = failure,
                invoke: () => client.setLoggingEnabled(true),
                reset: () => platform.loggingError = null,
              ),
            ];

        for (final command in cases) {
          command.arrange();
          final exception = await captureAsleepException(command.invoke());
          expect(exception.error, same(client.state.error));
          expect(exception.error?.code, 'NATIVE_FAILURE');
          command.reset();
          client.clearError();
        }
      },
    );

    test('lifecycle failures share the snapshot error', () async {
      await prepareClient(client);
      platform.startError = StateError('start failed');
      var exception = await captureAsleepException(client.startTracking());
      expect(exception.error, same(client.state.error));

      platform.startError = null;
      client.clearError();
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(const TrackingInterruptedEvent());
      platform.resumeError = StateError('resume failed');
      exception = await captureAsleepException(client.resumeTracking());
      expect(exception.error, same(client.state.error));

      platform.resumeError = null;
      client.clearError();
      platform.stopError = StateError('stop failed');
      exception = await captureAsleepException(client.stopTracking());
      expect(exception.error, same(client.state.error));
    });

    test(
      'successful commands clear only the error they started with',
      () async {
        await client.initialize(
          const AsleepSetupOptions(apiKey: 'test-api-key'),
        );
        platform.loggingError = StateError('old failure');
        await captureAsleepException(client.setLoggingEnabled(true));
        final oldError = client.state.error;

        platform.loggingError = null;
        await client.setLoggingEnabled(true);
        expect(oldError, isNotNull);
        expect(client.state.error, isNull);

        platform.permissionCompleter = Completer<bool>();
        final permission = client.hasRequiredPermissions();
        final concurrentError = AsleepError(
          code: 'NETWORK_OFFLINE',
          message: 'The network went offline.',
          category: AsleepErrorCategory.transient,
        );
        platform.emit(TrackingFailedEvent(error: concurrentError));
        platform.permissionCompleter!.complete(true);

        expect(await permission, isTrue);
        expect(client.state.error, same(concurrentError));

        final reusedError = AsleepError(
          code: 'NETWORK_OFFLINE',
          message: 'The same native error was emitted again.',
          category: AsleepErrorCategory.transient,
        );
        platform.emit(TrackingFailedEvent(error: reusedError));
        platform.permissionCompleter = Completer<bool>();
        final repeatedPermission = client.hasRequiredPermissions();
        platform.emit(TrackingFailedEvent(error: reusedError));
        platform.permissionCompleter!.complete(true);

        expect(await repeatedPermission, isTrue);
        expect(client.state.error, same(reusedError));
      },
    );

    test('dispose detaches native events and closes streams', () async {
      var eventCount = 0;
      var stateDone = false;
      final modes = <bool>[];
      final eventSubscription = client.events.listen((_) => eventCount++);
      final stateSubscription = client.states.listen(
        (state) => modes.add(state.isOnDeviceAnalysisEnabled),
        onDone: () => stateDone = true,
      );

      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );
      await client.dispose();
      platform.emit(const TrackingCreatedEvent(sessionId: 'ignored'));
      await pumpEventQueue();

      expect(eventCount, 0);
      expect(stateDone, isTrue);
      expect(modes.sublist(modes.length - 2), <bool>[true, false]);
      expect(client.state.isOnDeviceAnalysisEnabled, isFalse);
      expect(client.clearError, returnsNormally);
      await eventSubscription.cancel();
      await stateSubscription.cancel();
    });

    test('clearError is a no-op from the terminal state listener', () async {
      Object? reentrantError;
      var observeTerminalState = false;
      final subscription = client.states.listen((state) {
        if (observeTerminalState && !state.isOnDeviceAnalysisEnabled) {
          try {
            client.clearError();
          } catch (error) {
            reentrantError = error;
          }
        }
      });
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );

      observeTerminalState = true;
      await client.dispose();

      expect(reentrantError, isNull);
      await subscription.cancel();
    });

    test('terminal state listener shares the active dispose', () async {
      platform.disposeCompleter = Completer<void>();
      Future<void>? reentrantDispose;
      var observeTerminalState = false;
      final subscription = client.states.listen((state) {
        if (observeTerminalState && !state.isOnDeviceAnalysisEnabled) {
          observeTerminalState = false;
          reentrantDispose = client.dispose();
        }
      });
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );

      observeTerminalState = true;
      final outerDispose = client.dispose();
      expect(reentrantDispose, same(outerDispose));
      await pumpEventQueue();
      expect(platform.eventCancelCount, 1);
      expect(platform.disposeCount, 1);

      platform.disposeCompleter!.complete();
      await Future.wait(<Future<void>>[outerDispose, reentrantDispose!]);
      expect(platform.eventCancelCount, 1);
      expect(platform.disposeCount, 1);
      await subscription.cancel();
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

      final exception = await captureAsleepException(client.dispose());
      await pumpEventQueue();

      expect(exception.code, AsleepErrorCode.nativeFailure);
      expect(exception.error, same(client.state.error));
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
  Object? restoreError;
  Object? batteryCheckError;
  Object? batteryRequestError;
  Object? permissionCheckError;
  Object? permissionRequestError;
  Object? resumeError;
  Object? stopError;
  Object? analysisError;
  Object? reportError;
  Object? reportListError;
  Object? averageReportError;
  Object? deleteError;
  Object? loggingError;
  Object? disposeError;
  Completer<void>? startCompleter;
  Completer<void>? setupCompleter;
  Completer<void>? configureCompleter;
  Completer<void>? stopCompleter;
  Completer<void>? resumeCompleter;
  Completer<RestoreResult>? restoreCompleter;
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
    await setupCompleter?.future;
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
    await configureCompleter?.future;
  }

  @override
  Future<RestoreResult> checkAndRestoreTracking() async {
    if (restoreError case final error?) {
      throw error;
    }
    if (restoreCompleter case final completer?) {
      return completer.future;
    }
    return RestoreResult(hasActiveSession: hasActiveSession);
  }

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    if (batteryCheckError case final error?) {
      throw error;
    }
    return BatteryOptimizationStatus(
      exempted: batteryExempted,
      platform: 'test',
    );
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async {
    if (batteryRequestError case final error?) {
      throw error;
    }
    return true;
  }

  @override
  Future<bool> hasRequiredPermissions() async {
    if (permissionCheckError case final error?) {
      throw error;
    }
    if (permissionCompleter case final completer?) {
      return completer.future;
    }
    return hasPermissions;
  }

  @override
  Future<bool> requestRequiredPermissions() async {
    permissionRequestCount++;
    if (permissionRequestError case final error?) {
      throw error;
    }
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
    if (resumeError case final error?) {
      throw error;
    }
    await resumeCompleter?.future;
  }

  @override
  Future<void> stopTracking() async {
    stopCount++;
    if (stopError case final error?) {
      throw error;
    }
    await stopCompleter?.future;
  }

  @override
  Future<AnalysisRequest> requestAnalysis() async {
    analysisRequestCount++;
    if (analysisError case final error?) {
      throw error;
    }
    if (analysisCompleter case final completer?) {
      return completer.future;
    }
    return const AnalysisRequest(status: AnalysisRequestStatus.requested);
  }

  @override
  Future<AsleepReport> getReport(String sessionId) {
    throw reportError ?? UnimplementedError();
  }

  @override
  Future<List<AsleepSession>> getReportList(
    String fromDate,
    String toDate,
  ) async {
    if (reportListError case final error?) {
      throw error;
    }
    return const <AsleepSession>[];
  }

  @override
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate) {
    throw averageReportError ?? UnimplementedError();
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    if (deleteError case final error?) {
      throw error;
    }
  }

  @override
  Future<void> setLoggingEnabled(bool enabled) async {
    if (loggingError case final error?) {
      throw error;
    }
  }

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

final Matcher throwsNativeFailure = throwsA(
  isA<AsleepException>().having(
    (error) => error.code,
    'code',
    AsleepErrorCode.nativeFailure,
  ),
);

Future<AsleepException> captureAsleepException(Future<Object?> future) async {
  try {
    await future;
  } on AsleepException catch (error) {
    return error;
  }
  throw TestFailure('Expected AsleepException.');
}

extension on AsleepError {
  TrackingFailedEvent get asTrackingFailure => TrackingFailedEvent(error: this);
}
