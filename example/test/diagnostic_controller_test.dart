import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:asleep_sdk_flutter_example/diagnostic/diagnostic_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagnosticController', () {
    test('keeps Start disabled until SDK preparation fully succeeds', () async {
      final platform = _FakePlatform()
        ..batteryCheckCompleter = Completer<BatteryOptimizationStatus>();
      final controller = _controller(platform);

      expect(controller.sdkPrepared, isFalse);
      expect(controller.canStartTracking, isFalse);
      await controller.startTracking();
      expect(platform.calls, isNot(contains('start')));
      expect(controller.operationError, isNull);

      final preparation = controller.initializeOrRestore('runtime-secret');
      while (!platform.calls.contains('battery-check')) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(controller.sdkPreparationInFlight, isTrue);
      expect(controller.sdkPrepared, isFalse);
      expect(controller.canStartTracking, isFalse);

      platform.batteryCheckCompleter!.complete(
        const BatteryOptimizationStatus(exempted: true, platform: 'android'),
      );
      await preparation;

      expect(controller.sdkPreparationInFlight, isFalse);
      expect(controller.sdkPrepared, isTrue);
      expect(controller.canStartTracking, isTrue);

      await controller.close();
    });

    test('failed SDK preparation stays gated and can be retried', () async {
      final platform = _FakePlatform()..setupError = StateError('setup failed');
      final controller = _controller(platform);

      await controller.initializeOrRestore('runtime-secret');

      expect(controller.sdkPreparationInFlight, isFalse);
      expect(controller.sdkPrepared, isFalse);
      expect(controller.canPrepareSdk, isTrue);
      expect(controller.canStartTracking, isFalse);
      expect(controller.operationMessage, 'Operation failed');

      platform.setupError = null;
      await controller.initializeOrRestore('runtime-secret');

      expect(controller.sdkPrepared, isTrue);
      expect(controller.canStartTracking, isTrue);
      expect(controller.operationMessage, 'SDK ready');

      await controller.close();
    });

    test('completed SDK preparation ignores repeated preparation', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      final callsAfterPreparation = List<String>.of(platform.calls);

      expect(controller.canPrepareSdk, isFalse);
      await controller.initializeOrRestore('replacement-secret');

      expect(platform.calls, callsAfterPreparation);
      expect(platform.configuredApiKey, isNull);
      expect(platform.setupApiKey, 'runtime-secret');
      expect(controller.sdkPrepared, isTrue);
      expect(controller.operationMessage, 'SDK ready');
      expect(controller.operationError, isNull);

      await controller.close();
    });

    test('unprepared live session cannot start SDK preparation', () async {
      final platform = _FakePlatform()
        ..restoreResult = const RestoreResult(hasActiveSession: true);
      final client = AsleepClient(platform: platform);
      await client.checkAndRestoreTracking();
      final controller = DiagnosticController(
        client: client,
        hostPlatform: DiagnosticHostPlatform.android,
      );
      final callsBefore = List<String>.of(platform.calls);

      expect(controller.sdkPrepared, isFalse);
      expect(controller.canStopTracking, isTrue);
      expect(controller.canPrepareSdk, isFalse);
      await controller.initializeOrRestore('runtime-secret');

      expect(platform.calls, callsBefore);
      expect(platform.configuredApiKey, isNull);
      expect(controller.sdkPrepared, isFalse);

      await controller.close();
    });

    test('derives readiness from a fully prepared existing client', () async {
      final platform = _FakePlatform();
      final client = AsleepClient(platform: platform);
      await client.initialize(
        const AsleepSetupOptions(apiKey: 'runtime-secret'),
      );
      await client.checkBatteryOptimization();

      final controller = DiagnosticController(
        client: client,
        hostPlatform: DiagnosticHostPlatform.android,
      );

      expect(controller.sdkPrepared, isTrue);
      expect(controller.canStartTracking, isFalse);

      await controller.recheckBatteryOptimization();
      expect(controller.canStartTracking, isTrue);

      await controller.close();
    });

    test('existing client without battery preparation remains gated', () async {
      final platform = _FakePlatform();
      final client = AsleepClient(platform: platform);
      await client.initialize(
        const AsleepSetupOptions(apiKey: 'runtime-secret'),
      );

      final controller = DiagnosticController(
        client: client,
        hostPlatform: DiagnosticHostPlatform.android,
      );
      final callsBefore = List<String>.of(platform.calls);

      expect(controller.snapshot.setupStatus, SetupStatus.complete);
      expect(controller.sdkPrepared, isFalse);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canPrepareSdk, isFalse);
      await controller.initializeOrRestore('replacement-secret');
      expect(platform.calls, callsBefore);
      expect(platform.setupApiKey, 'runtime-secret');
      expect(platform.configuredApiKey, isNull);
      expect(controller.sdkPrepared, isFalse);

      await controller.close();
    });

    test('recognizes a fully prepared restored client', () async {
      final platform = _FakePlatform()
        ..restoreResult = const RestoreResult(hasActiveSession: true);
      final client = AsleepClient(platform: platform);
      await client.checkAndRestoreTracking();
      await client.configure(
        const AsleepConfiguration(apiKey: 'runtime-secret'),
      );
      await client.checkBatteryOptimization();

      final controller = DiagnosticController(
        client: client,
        hostPlatform: DiagnosticHostPlatform.android,
      );

      expect(controller.sdkPrepared, isTrue);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canStopTracking, isTrue);

      platform.emit(const TrackingClosedEvent(sessionId: 'restored-session'));
      expect(controller.sdkPrepared, isTrue);
      expect(controller.canStartTracking, isFalse);

      await controller.recheckBatteryOptimization();
      expect(controller.canStartTracking, isTrue);

      await controller.close();
    });

    test(
      'subscribes before restore and configures an active session',
      () async {
        final platform = _FakePlatform()
          ..restoreResult = const RestoreResult(hasActiveSession: true);
        final controller = _controller(platform);

        await controller.initializeOrRestore('runtime-secret');

        expect(platform.calls, <String>[
          'restore',
          'restore',
          'configure',
          'battery-check',
        ]);
        expect(platform.configuredApiKey, 'runtime-secret');
        expect(platform.setupApiKey, isNull);
        expect(controller.snapshot.setupStatus, SetupStatus.complete);

        await controller.close();
      },
    );

    test('initializes a new session and checks battery status', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);

      await controller.initializeOrRestore('runtime-secret');

      expect(platform.calls, <String>[
        'restore',
        'restore',
        'setup',
        'battery-check',
      ]);
      expect(platform.setupApiKey, 'runtime-secret');
      expect(platform.configuredApiKey, isNull);
      expect(controller.batteryStatus?.exempted, isTrue);

      await controller.close();
    });

    test('retains the latest non-empty tracked session ID', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      expect(controller.lastTrackedSessionId, isNull);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));
      expect(controller.lastTrackedSessionId, 'session-created');
      platform.emit(const TrackingClosedEvent(sessionId: 'session-closed'));
      expect(controller.lastTrackedSessionId, 'session-closed');
      platform.emit(const TrackingCreatedEvent());
      expect(controller.snapshot.sessionId, isNull);
      expect(controller.lastTrackedSessionId, 'session-closed');

      await controller.close();
    });

    test('keeps permission and Android battery actions separate', () async {
      final platform = _FakePlatform()
        ..permissionsGranted = false
        ..permissionRequestResult = true
        ..batteryStatus = const BatteryOptimizationStatus(
          exempted: false,
          platform: 'android',
        );
      final controller = _controller(platform);

      await controller.initializeOrRestore('runtime-secret');
      expect(await controller.checkPermissions(), isFalse);
      expect(controller.permissionsGranted, isFalse);
      expect(await controller.requestPermissions(), isTrue);
      expect(controller.permissionsGranted, isTrue);
      platform.emit(const MicrophonePermissionDeniedEvent());
      expect(controller.permissionsGranted, isFalse);
      expect(await controller.openBatterySettings(), isTrue);
      await controller.recheckBatteryOptimization();

      expect(
        platform.calls,
        containsAllInOrder(<String>[
          'permissions-check',
          'permissions-request',
          'battery-request',
          'battery-check',
        ]),
      );

      await controller.close();
    });

    test(
      'Android Start requires an exemption and recheck updates eligibility',
      () async {
        final platform = _FakePlatform()
          ..batteryStatus = const BatteryOptimizationStatus(
            exempted: false,
            platform: 'android',
          );
        final controller = _controller(platform);

        await controller.initializeOrRestore('runtime-secret');

        expect(controller.sdkPrepared, isTrue);
        expect(controller.batteryStatus?.exempted, isFalse);
        expect(controller.canStartTracking, isFalse);
        await controller.startTracking();
        expect(platform.calls.where((call) => call == 'start'), isEmpty);

        platform.batteryStatus = const BatteryOptimizationStatus(
          exempted: true,
          platform: 'android',
        );
        await controller.recheckBatteryOptimization();

        expect(controller.batteryStatus?.exempted, isTrue);
        expect(controller.canStartTracking, isTrue);
        await controller.startTracking();
        expect(platform.calls.where((call) => call == 'start').length, 1);

        await controller.close();
      },
    );

    test('iOS Start does not require an Android battery exemption', () async {
      final platform = _FakePlatform()
        ..batteryStatus = const BatteryOptimizationStatus(
          exempted: false,
          platform: 'ios',
        );
      final controller = _controller(
        platform,
        hostPlatform: DiagnosticHostPlatform.ios,
      );

      await controller.initializeOrRestore('runtime-secret');

      expect(controller.sdkPrepared, isTrue);
      expect(controller.batteryStatus?.exempted, isFalse);
      expect(controller.canStartTracking, isTrue);

      await controller.close();
    });

    test('updates Android permission state from tracking preflight', () async {
      final platform = _FakePlatform()..permissionsGranted = false;
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      await controller.startTracking();
      expect(controller.permissionsGranted, isFalse);
      expect(
        controller.operationError?.code,
        AsleepErrorCode.permissionRequired.name,
      );

      platform.permissionsGranted = true;
      expect(await controller.checkPermissions(), isTrue);
      platform.batteryStatus = const BatteryOptimizationStatus(
        exempted: false,
        platform: 'android',
      );
      await controller.recheckBatteryOptimization();
      expect(controller.canStartTracking, isFalse);
      final startsBeforeBatteryExemption = platform.calls
          .where((call) => call == 'start')
          .length;
      await controller.startTracking();
      expect(controller.permissionsGranted, isTrue);
      expect(
        platform.calls.where((call) => call == 'start').length,
        startsBeforeBatteryExemption,
      );

      platform.batteryStatus = const BatteryOptimizationStatus(
        exempted: true,
        platform: 'android',
      );
      await controller.recheckBatteryOptimization();
      expect(controller.canStartTracking, isTrue);
      await controller.startTracking();
      expect(controller.permissionsGranted, isTrue);

      await controller.close();
    });

    test('successful iOS start records granted permissions', () async {
      final platform = _FakePlatform();
      final controller = _controller(
        platform,
        hostPlatform: DiagnosticHostPlatform.ios,
      );
      await controller.initializeOrRestore('runtime-secret');

      expect(controller.permissionsGranted, isNull);
      await controller.startTracking();
      expect(controller.permissionsGranted, isTrue);

      await controller.close();
    });

    test('start timeout requires reconciliation before retry', () async {
      final platform = _FakePlatform()
        ..startError = const AsleepException(
          AsleepErrorCode.nativeFailure,
          'Native start timed out',
          nativeCode: 'TRACKING_START_TIMEOUT',
        );
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      await controller.startTracking();

      expect(controller.snapshot.trackingStatus, TrackingStatus.idle);
      expect(controller.trackingRestorationRequired, isTrue);
      expect(controller.canReconcileTracking, isTrue);
      expect(controller.canStartTracking, isFalse);
      expect(controller.operationMessage, 'Operation failed');
      expect(platform.calls.where((call) => call == 'start').length, 1);

      await controller.startTracking();
      expect(platform.calls.where((call) => call == 'start').length, 1);
      expect(controller.operationMessage, 'Operation failed');

      platform.startError = null;
      platform.restoreCompleter = Completer<RestoreResult>();
      final reconciliation = controller.reconcileTrackingState();
      expect(controller.canReconcileTracking, isFalse);
      expect(controller.canStartTracking, isFalse);
      platform.restoreCompleter!.complete(
        const RestoreResult(hasActiveSession: false),
      );
      await reconciliation;

      expect(controller.trackingRestorationRequired, isFalse);
      expect(controller.canReconcileTracking, isFalse);
      expect(controller.canStartTracking, isTrue);
      expect(controller.operationMessage, 'Tracking stopped');
      expect(controller.operationError, isNull);

      await controller.close();
    });

    test('Stop cancels a pending start and restores eligibility', () async {
      final platform = _FakePlatform()..startCompleter = Completer<void>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      platform.restoreCompleter = Completer<RestoreResult>();

      final start = controller.startTracking();
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.trackingStatus, TrackingStatus.idle);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canStopTracking, isTrue);

      final stop = controller.stopTracking();
      await Future<void>.delayed(Duration.zero);
      expect(platform.calls, contains('stop'));
      expect(controller.stopAwaitingEndEvent, isTrue);
      expect(controller.canStopTracking, isFalse);
      platform.startCompleter!.completeError(StateError('start cancelled'));
      await start;

      expect(controller.canStartTracking, isFalse);
      expect(controller.canReconcileTracking, isFalse);
      expect(controller.stopAwaitingEndEvent, isTrue);
      platform.restoreCompleter!.complete(
        const RestoreResult(hasActiveSession: false),
      );
      await stop;

      expect(controller.stopAwaitingEndEvent, isFalse);
      expect(controller.canStartTracking, isTrue);
      expect(controller.canStopTracking, isFalse);
      expect(controller.trackingRestorationRequired, isFalse);
      expect(controller.permissionsGranted, isNull);
      expect(controller.operationMessage, 'Tracking stopped');
      expect(controller.operationError, isNull);

      await controller.close();
    });

    test(
      'normal Stop waits for a lifecycle end before allowing actions',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));

        await controller.stopTracking();

        expect(controller.stopAwaitingEndEvent, isTrue);
        expect(controller.canStopTracking, isFalse);
        expect(controller.canStartTracking, isFalse);
        expect(
          controller.operationMessage,
          'Tracking stop requested; waiting for close',
        );
        expect(controller.operationError, isNull);
        final stopCalls = platform.calls.where((call) => call == 'stop').length;

        await controller.stopTracking();

        expect(
          platform.calls.where((call) => call == 'stop').length,
          stopCalls,
        );
        expect(
          controller.operationMessage,
          'Tracking stop requested; waiting for close',
        );
        expect(controller.operationError, isNull);

        platform.emit(const TrackingClosedEvent(sessionId: 'session-created'));

        expect(controller.stopAwaitingEndEvent, isFalse);
        expect(controller.canStopTracking, isFalse);
        expect(controller.canStartTracking, isTrue);
        expect(controller.operationMessage, 'Tracking stopped');

        await controller.close();
      },
    );

    for (final category in <AsleepErrorCategory>[
      AsleepErrorCategory.terminal,
      AsleepErrorCategory.recordingDead,
    ]) {
      test(
        '${category.name} lifecycle failure completes a pending Stop',
        () async {
          final platform = _FakePlatform();
          final controller = _controller(platform);
          await controller.initializeOrRestore('runtime-secret');
          platform.emit(
            const TrackingCreatedEvent(sessionId: 'session-created'),
          );

          await controller.stopTracking();

          expect(controller.stopAwaitingEndEvent, isTrue);
          expect(
            controller.operationMessage,
            'Tracking stop requested; waiting for close',
          );

          platform.emit(
            TrackingFailedEvent(
              error: AsleepError(
                code: 'TRACKING_ENDED',
                message: 'Tracking ended',
                category: category,
              ),
            ),
          );

          expect(controller.stopAwaitingEndEvent, isFalse);
          expect(controller.operationMessage, 'Tracking stopped');
          expect(controller.operationError, isNull);

          await controller.close();
        },
      );
    }

    test(
      'pending Stop blocks analysis without replacing its outcome',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));

        await controller.stopTracking();

        expect(controller.stopAwaitingEndEvent, isTrue);
        expect(controller.snapshot.trackingStatus, TrackingStatus.tracking);
        expect(controller.canRequestAnalysis, isFalse);
        expect(
          controller.operationMessage,
          'Tracking stop requested; waiting for close',
        );
        await controller.requestAnalysis();

        expect(platform.calls.where((call) => call == 'analysis').length, 0);
        expect(
          controller.operationMessage,
          'Tracking stop requested; waiting for close',
        );
        expect(controller.operationError, isNull);

        platform.emit(const TrackingClosedEvent(sessionId: 'session-created'));
        expect(controller.stopAwaitingEndEvent, isFalse);
        expect(controller.canRequestAnalysis, isFalse);
        expect(controller.operationMessage, 'Tracking stopped');

        await controller.close();
      },
    );

    for (final recoveryRequired in <bool>[false, true]) {
      test(
        'pending Stop blocks resume from '
        '${recoveryRequired ? 'recovery-required' : 'paused'} state',
        () async {
          final platform = _FakePlatform();
          final controller = _controller(platform);
          await controller.initializeOrRestore('runtime-secret');
          platform.emit(
            const TrackingCreatedEvent(sessionId: 'session-created'),
          );
          if (recoveryRequired) {
            platform.emit(
              TrackingFailedEvent(
                error: AsleepError(
                  code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
                  message: 'Foreground recovery required',
                  category: AsleepErrorCategory.recoveryRequired,
                ),
              ),
            );
          } else {
            platform.emit(const TrackingInterruptedEvent());
          }
          expect(controller.canResumeTracking, isTrue);

          await controller.stopTracking();

          expect(controller.stopAwaitingEndEvent, isTrue);
          expect(controller.canResumeTracking, isFalse);
          expect(
            controller.operationMessage,
            'Tracking stop requested; waiting for close',
          );
          await controller.resumeTracking();

          expect(platform.resumeCount, 0);
          expect(
            controller.operationMessage,
            'Tracking stop requested; waiting for close',
          );
          expect(controller.operationError, isNull);

          platform.emit(
            const TrackingClosedEvent(sessionId: 'session-created'),
          );
          expect(controller.stopAwaitingEndEvent, isFalse);
          expect(controller.canResumeTracking, isFalse);
          expect(controller.operationMessage, 'Tracking stopped');

          await controller.close();
        },
      );
    }

    test(
      'recording-dead cleanup Stop waits for a later lifecycle end',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        final recordingDead = TrackingFailedEvent(
          error: AsleepError(
            code: 'AUDIO_INITIALIZATION_FAILED',
            message: 'Recording stopped',
            category: AsleepErrorCategory.recordingDead,
          ),
        );
        platform.emit(recordingDead);

        expect(controller.stopAwaitingEndEvent, isFalse);
        expect(controller.canStopTracking, isTrue);
        await controller.stopTracking();

        expect(controller.stopAwaitingEndEvent, isTrue);
        expect(controller.canStopTracking, isFalse);
        expect(controller.canStartTracking, isFalse);
        final stopCalls = platform.calls.where((call) => call == 'stop').length;
        await controller.stopTracking();
        expect(
          platform.calls.where((call) => call == 'stop').length,
          stopCalls,
        );

        platform.emit(recordingDead);

        expect(controller.stopAwaitingEndEvent, isFalse);
        expect(controller.canStopTracking, isTrue);
        expect(controller.canStartTracking, isFalse);

        await controller.stopTracking();
        expect(controller.stopAwaitingEndEvent, isTrue);
        platform.emit(const TrackingClosedEvent(sessionId: 'session-created'));
        expect(controller.stopAwaitingEndEvent, isFalse);
        expect(controller.canStopTracking, isFalse);
        expect(controller.canStartTracking, isTrue);

        await controller.close();
      },
    );

    test('failed Stop immediately permits retry', () async {
      final platform = _FakePlatform()..stopError = StateError('stop failed');
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));

      await controller.stopTracking();

      expect(controller.stopAwaitingEndEvent, isFalse);
      expect(controller.canStopTracking, isTrue);
      expect(controller.canStartTracking, isFalse);
      expect(controller.operationMessage, 'Operation failed');
      expect(controller.operationError, isNotNull);

      platform.stopError = null;
      await controller.stopTracking();

      expect(platform.calls.where((call) => call == 'stop').length, 2);
      expect(controller.stopAwaitingEndEvent, isTrue);
      expect(controller.canStopTracking, isFalse);
      expect(
        controller.operationMessage,
        'Tracking stop requested; waiting for close',
      );
      expect(controller.operationError, isNull);

      platform.emit(const TrackingClosedEvent(sessionId: 'session-created'));
      expect(controller.stopAwaitingEndEvent, isFalse);
      expect(controller.canStartTracking, isTrue);
      expect(controller.operationMessage, 'Tracking stopped');

      await controller.close();
    });

    test('pending start reconciliation preserves a restored session', () async {
      final platform = _FakePlatform()..startCompleter = Completer<void>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      platform.restoreCompleter = Completer<RestoreResult>();

      final start = controller.startTracking();
      await Future<void>.delayed(Duration.zero);
      final stop = controller.stopTracking();
      await Future<void>.delayed(Duration.zero);
      platform.startCompleter!.completeError(StateError('start cancelled'));
      await start;
      platform.restoreCompleter!.complete(
        const RestoreResult(hasActiveSession: true),
      );
      await stop;

      expect(controller.snapshot.trackingStatus, TrackingStatus.tracking);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canStopTracking, isTrue);
      expect(controller.operationMessage, 'Active tracking restored');
      expect(controller.operationError, isNull);

      await controller.close();
    });

    test('failed reconciliation keeps Start disabled until retry', () async {
      final platform = _FakePlatform()..startCompleter = Completer<void>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      platform.restoreCompleter = Completer<RestoreResult>();

      final start = controller.startTracking();
      await Future<void>.delayed(Duration.zero);
      final stop = controller.stopTracking();
      await Future<void>.delayed(Duration.zero);
      platform.startCompleter!.completeError(StateError('start cancelled'));
      await start;
      platform.restoreCompleter!.completeError(
        StateError('restore unavailable'),
      );
      await stop;

      expect(controller.trackingRestorationRequired, isTrue);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canReconcileTracking, isTrue);
      expect(controller.operationMessage, 'Operation failed');
      expect(controller.operationError, isNotNull);

      platform.restoreCompleter = Completer<RestoreResult>();
      final retry = controller.reconcileTrackingState();
      await Future<void>.delayed(Duration.zero);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canReconcileTracking, isFalse);
      platform.restoreCompleter!.complete(
        const RestoreResult(hasActiveSession: false),
      );
      await retry;

      expect(controller.trackingRestorationRequired, isFalse);
      expect(controller.canStartTracking, isTrue);
      expect(controller.operationMessage, 'Tracking stopped');
      expect(controller.operationError, isNull);

      await controller.close();
    });

    for (final hasActiveSession in <bool>[false, true]) {
      test('tracked pending start waits for close before restoring '
          '${hasActiveSession ? 'active' : 'idle'} state', () async {
        final platform = _FakePlatform()..startCompleter = Completer<void>();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        platform.restoreCompleter = Completer<RestoreResult>();
        final restoreCallsBefore = platform.calls
            .where((call) => call == 'restore')
            .length;

        final start = controller.startTracking();
        await Future<void>.delayed(Duration.zero);
        platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));
        final stop = controller.stopTracking();
        await stop;

        expect(
          platform.calls.where((call) => call == 'restore').length,
          restoreCallsBefore,
        );
        expect(controller.trackingRestorationRequired, isTrue);
        expect(controller.canStartTracking, isFalse);
        expect(controller.canReconcileTracking, isFalse);
        expect(
          controller.operationMessage,
          'Tracking stop requested; waiting for close',
        );

        platform.startCompleter!.complete();
        await start;
        platform.emit(const TrackingClosedEvent(sessionId: 'session-created'));
        await Future<void>.delayed(Duration.zero);
        expect(
          platform.calls.where((call) => call == 'restore').length,
          restoreCallsBefore + 1,
        );
        platform.restoreCompleter!.complete(
          RestoreResult(hasActiveSession: hasActiveSession),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.trackingRestorationRequired, isFalse);
        expect(
          controller.snapshot.trackingStatus,
          hasActiveSession ? TrackingStatus.tracking : TrackingStatus.idle,
        );
        expect(controller.canStartTracking, !hasActiveSession);
        expect(controller.canStopTracking, hasActiveSession);

        await controller.close();
      });
    }

    for (final category in <AsleepErrorCategory>[
      AsleepErrorCategory.terminal,
      AsleepErrorCategory.recordingDead,
    ]) {
      test(
        'tracked pending start reconciles after ${category.name} failure',
        () async {
          final platform = _FakePlatform()..startCompleter = Completer<void>();
          final controller = _controller(platform);
          await controller.initializeOrRestore('runtime-secret');
          platform.restoreCompleter = Completer<RestoreResult>();
          final restoreCallsBefore = platform.calls
              .where((call) => call == 'restore')
              .length;

          final start = controller.startTracking();
          await Future<void>.delayed(Duration.zero);
          platform.emit(
            const TrackingCreatedEvent(sessionId: 'session-created'),
          );
          await controller.stopTracking();

          final failure = TrackingFailedEvent(
            error: AsleepError(
              code: 'TRACKING_ENDED',
              message: 'Tracking ended',
              category: category,
            ),
          );
          platform.emit(failure);
          await Future<void>.delayed(Duration.zero);

          expect(
            platform.calls.where((call) => call == 'restore').length,
            restoreCallsBefore + 1,
          );
          expect(controller.trackingRestorationRequired, isTrue);
          expect(controller.canStartTracking, isFalse);

          platform.emit(
            const TrackingClosedEvent(sessionId: 'session-created'),
          );
          platform.emit(failure);
          await Future<void>.delayed(Duration.zero);
          expect(
            platform.calls.where((call) => call == 'restore').length,
            restoreCallsBefore + 1,
          );

          platform.startCompleter!.complete();
          await start;
          expect(
            platform.calls.where((call) => call == 'restore').length,
            restoreCallsBefore + 1,
          );

          platform.restoreCompleter!.complete(
            const RestoreResult(hasActiveSession: false),
          );
          await Future<void>.delayed(Duration.zero);

          expect(controller.trackingRestorationRequired, isFalse);
          if (category == AsleepErrorCategory.recordingDead) {
            expect(controller.canStartTracking, isFalse);
            expect(controller.canStopTracking, isTrue);
          } else {
            expect(controller.canStartTracking, isTrue);
            expect(controller.canStopTracking, isFalse);
          }

          await controller.close();
        },
      );
    }

    for (final category in <AsleepErrorCategory>[
      AsleepErrorCategory.transient,
      AsleepErrorCategory.unknown,
      AsleepErrorCategory.recoveryRequired,
    ]) {
      test(
        '${category.name} failure does not release a pending tracked stop',
        () async {
          final platform = _FakePlatform()..startCompleter = Completer<void>();
          final controller = _controller(platform);
          await controller.initializeOrRestore('runtime-secret');
          platform.restoreCompleter = Completer<RestoreResult>();
          final restoreCallsBefore = platform.calls
              .where((call) => call == 'restore')
              .length;

          final start = controller.startTracking();
          await Future<void>.delayed(Duration.zero);
          platform.emit(
            const TrackingCreatedEvent(sessionId: 'session-created'),
          );
          await controller.stopTracking();
          platform.emit(
            TrackingFailedEvent(
              error: AsleepError(
                code: 'TRACKING_NOT_ENDED',
                message: 'Tracking may still be active',
                category: category,
              ),
            ),
          );
          await Future<void>.delayed(Duration.zero);

          expect(
            platform.calls.where((call) => call == 'restore').length,
            restoreCallsBefore,
          );
          expect(controller.trackingRestorationRequired, isTrue);
          expect(controller.canStartTracking, isFalse);
          expect(controller.canReconcileTracking, isFalse);

          platform.startCompleter!.complete();
          await start;
          expect(
            platform.calls.where((call) => call == 'restore').length,
            restoreCallsBefore,
          );

          platform.emit(
            const TrackingClosedEvent(sessionId: 'session-created'),
          );
          await Future<void>.delayed(Duration.zero);
          expect(
            platform.calls.where((call) => call == 'restore').length,
            restoreCallsBefore + 1,
          );
          platform.restoreCompleter!.complete(
            const RestoreResult(hasActiveSession: false),
          );
          await Future<void>.delayed(Duration.zero);
          expect(controller.trackingRestorationRequired, isFalse);
          expect(controller.canStartTracking, isTrue);

          await controller.close();
        },
      );
    }

    test('failed tracked Stop permits manual reconciliation', () async {
      final platform = _FakePlatform()
        ..startCompleter = Completer<void>()
        ..stopError = StateError('stop unavailable');
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final start = controller.startTracking();
      await Future<void>.delayed(Duration.zero);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));
      await controller.stopTracking();

      expect(controller.trackingRestorationRequired, isTrue);
      expect(controller.canStartTracking, isFalse);
      expect(controller.canReconcileTracking, isTrue);
      expect(controller.operationMessage, 'Operation failed');

      platform.startCompleter!.complete();
      await start;
      platform.restoreCompleter = Completer<RestoreResult>();
      final retry = controller.reconcileTrackingState();
      await Future<void>.delayed(Duration.zero);
      platform.restoreCompleter!.complete(
        const RestoreResult(hasActiveSession: true),
      );
      await retry;

      expect(controller.trackingRestorationRequired, isFalse);
      expect(controller.snapshot.trackingStatus, TrackingStatus.tracking);
      expect(controller.operationMessage, 'Active tracking restored');

      await controller.close();
    });

    test('close does not wait for a missing close event', () async {
      final platform = _FakePlatform()..startCompleter = Completer<void>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final start = controller.startTracking();
      await Future<void>.delayed(Duration.zero);
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-created'));
      await controller.stopTracking();
      platform.startCompleter!.complete();
      await start;

      expect(controller.trackingRestorationRequired, isTrue);
      await controller.close();
      expect(platform.disposeCount, 1);
    });

    test('keeps recording-dead sessions stoppable and not startable', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      platform.emit(
        TrackingFailedEvent(
          error: AsleepError(
            code: 'AUDIO_INITIALIZATION_FAILED',
            message: 'Recording stopped',
            category: AsleepErrorCategory.recordingDead,
          ),
        ),
      );

      expect(controller.canStopTracking, isTrue);
      expect(controller.canStartTracking, isFalse);

      expect(await controller.checkPermissions(), isTrue);
      expect(controller.snapshot.error, isNull);
      expect(controller.canStopTracking, isTrue);
      expect(controller.canStartTracking, isFalse);

      await controller.stopTracking();
      expect(controller.stopAwaitingEndEvent, isTrue);
      expect(controller.canStopTracking, isFalse);
      expect(controller.canStartTracking, isFalse);

      platform.emit(const TrackingClosedEvent(sessionId: 'session-1'));
      expect(controller.stopAwaitingEndEvent, isFalse);
      expect(controller.canStopTracking, isFalse);
      expect(controller.canStartTracking, isTrue);

      await controller.close();
    });

    test(
      'redacts native event stream failures without uncaught errors',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');

        platform.emitError(
          AsleepException(
            AsleepErrorCode.malformedPayload,
            'secret-native-event-payload',
            nativeCode: 'EVENT_DECODE_FAILED',
            nativeDetails: const <String, Object?>{
              'credential': 'runtime-secret',
            },
          ),
        );

        expect(controller.operationErrorText, 'EVENT_DECODE_FAILED (unknown)');
        expect(controller.operationMessage, 'Native event stream failed');
        expect(controller.lastEvent, 'Native event stream failed');
        expect(
          controller.operationErrorText,
          isNot(contains('runtime-secret')),
        );
        expect(
          controller.operationErrorText,
          isNot(contains('secret-native-event-payload')),
        );

        await controller.close();
      },
    );

    test(
      'shares an in-flight analysis request and preserves its outcome',
      () async {
        final platform = _FakePlatform()
          ..analysisCompleter = Completer<AnalysisRequest>();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

        expect(controller.canRequestAnalysis, isTrue);
        final first = controller.requestAnalysis();
        final repeated = controller.requestAnalysis();

        expect(identical(first, repeated), isTrue);
        expect(controller.analysisRequestInFlight, isTrue);
        expect(controller.canRequestAnalysis, isFalse);
        expect(platform.calls.where((call) => call == 'analysis').length, 1);

        platform.analysisCompleter!.complete(
          const AnalysisRequest(status: AnalysisRequestStatus.requested),
        );
        await Future.wait(<Future<void>>[first, repeated]);

        expect(controller.analysisRequestInFlight, isFalse);
        expect(controller.snapshot.isAnalyzing, isTrue);
        expect(controller.canRequestAnalysis, isFalse);
        expect(controller.operationMessage, 'Analysis requested');
        expect(controller.operationError, isNull);

        final whilePending = controller.requestAnalysis();
        await whilePending;
        expect(platform.calls.where((call) => call == 'analysis').length, 1);
        expect(controller.operationMessage, 'Analysis requested');
        expect(controller.operationError, isNull);

        platform.emit(
          AnalysisResultEvent(result: AsleepAnalysisResult(id: 'event')),
        );
        expect(controller.canRequestAnalysis, isTrue);

        await controller.close();
      },
    );

    test('analysis failure releases the guard for retry', () async {
      final platform = _FakePlatform()
        ..analysisCompleter = Completer<AnalysisRequest>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));

      final failed = controller.requestAnalysis();
      platform.analysisCompleter!.completeError(StateError('analysis failed'));
      await failed;

      expect(controller.analysisRequestInFlight, isFalse);
      expect(controller.snapshot.isAnalyzing, isFalse);
      expect(controller.canRequestAnalysis, isTrue);
      expect(controller.operationMessage, 'Operation failed');
      expect(controller.operationError, isNotNull);

      platform.analysisCompleter = Completer<AnalysisRequest>();
      final retry = controller.requestAnalysis();
      expect(controller.analysisRequestInFlight, isTrue);
      expect(platform.calls.where((call) => call == 'analysis').length, 2);
      platform.analysisCompleter!.complete(
        const AnalysisRequest(status: AnalysisRequestStatus.requested),
      );
      await retry;

      expect(controller.operationMessage, 'Analysis requested');
      expect(controller.operationError, isNull);

      await controller.close();
    });

    test(
      'synchronous analysis event shares the actual command future',
      () async {
        final platform = _FakePlatform()
          ..analysisCompleter = Completer<AnalysisRequest>();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
        platform.onAnalysisRequest = () {
          platform.emit(
            AnalysisResultEvent(
              result: AsleepAnalysisResult(id: 'synchronous-event'),
            ),
          );
        };
        Future<void>? reentrant;
        var reentrantCompleted = false;
        controller.addListener(() {
          if (controller.analysisResult?.id == 'synchronous-event' &&
              reentrant == null) {
            reentrant = controller.requestAnalysis();
            unawaited(
              reentrant!.then((_) {
                reentrantCompleted = true;
              }),
            );
          }
        });

        final request = controller.requestAnalysis();

        expect(reentrant, isNotNull);
        expect(identical(request, reentrant), isTrue);
        expect(controller.snapshot.isAnalyzing, isFalse);
        expect(controller.analysisRequestInFlight, isTrue);
        expect(controller.canRequestAnalysis, isFalse);
        expect(platform.calls.where((call) => call == 'analysis').length, 1);
        await Future<void>.delayed(Duration.zero);
        expect(reentrantCompleted, isFalse);

        platform.analysisCompleter!.complete(
          const AnalysisRequest(status: AnalysisRequestStatus.requested),
        );
        await Future.wait(<Future<void>>[request, reentrant!]);

        expect(controller.analysisRequestInFlight, isFalse);
        expect(controller.canRequestAnalysis, isTrue);
        expect(controller.analysisResult?.id, 'synchronous-event');
        expect(reentrantCompleted, isTrue);

        await controller.close();
      },
    );

    test('exercises tracking, analysis, and every report form', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      await controller.startTracking();
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.analysisResult = AsleepAnalysisResult(id: 'immediate');
      await controller.requestAnalysis();
      expect(controller.analysisResult?.id, 'immediate');
      platform.emit(
        AnalysisResultEvent(result: AsleepAnalysisResult(id: 'event')),
      );
      expect(controller.analysisResult?.id, 'event');
      await controller.loadReport('session-1');
      await controller.loadReportList('2026-07-01', '2026-07-31');
      await controller.loadAverageReport('2026-07-01', '2026-07-31');
      await controller.stopTracking();

      expect(
        platform.calls,
        containsAllInOrder(<String>[
          'start',
          'analysis',
          'report:session-1',
          'report-list:2026-07-01:2026-07-31',
          'average-report:2026-07-01:2026-07-31',
          'stop',
        ]),
      );
      expect(controller.report?.session.id, 'session-1');
      expect(controller.reportList.single.id, 'session-1');
      expect(controller.averageReport?.period.startDate, '2026-07-01');

      await controller.close();
    });

    test(
      'guards iOS foreground resume until a later upload proves recovery',
      () async {
        final platform = _FakePlatform()
          ..restoreResult = const RestoreResult(hasActiveSession: true);
        final controller = _controller(
          platform,
          hostPlatform: DiagnosticHostPlatform.ios,
        );
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(
          TrackingFailedEvent(
            error: AsleepError(
              code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
              message: 'Foreground required',
              category: AsleepErrorCategory.recoveryRequired,
            ),
          ),
        );

        final first = controller.handleLifecycleState(
          AppLifecycleState.resumed,
        );
        final duplicate = controller.handleLifecycleState(
          AppLifecycleState.resumed,
        );
        await Future.wait(<Future<void>>[first, duplicate]);

        expect(platform.resumeCount, 1);
        expect(controller.recoveryAwaitingUpload, isTrue);

        await controller.handleLifecycleState(AppLifecycleState.resumed);
        expect(platform.resumeCount, 1);
        expect(controller.recoveryAwaitingUpload, isTrue);

        platform.emit(const TrackingResumedEvent());
        expect(controller.recoveryAwaitingUpload, isTrue);

        platform.emit(const TrackingUploadedEvent(sequence: 1));
        expect(controller.recoveryAwaitingUpload, isFalse);

        await controller.close();
      },
    );

    test(
      'transient failures keep the recovery latch until an upload',
      () async {
        final platform = _FakePlatform()
          ..restoreResult = const RestoreResult(hasActiveSession: true);
        final controller = _controller(
          platform,
          hostPlatform: DiagnosticHostPlatform.ios,
        );
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(
          TrackingFailedEvent(
            error: AsleepError(
              code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
              message: 'Foreground required',
              category: AsleepErrorCategory.recoveryRequired,
            ),
          ),
        );
        await controller.handleLifecycleState(AppLifecycleState.resumed);

        platform.emit(
          TrackingFailedEvent(
            error: AsleepError(
              code: 'NETWORK_OFFLINE',
              message: 'Retry later',
              category: AsleepErrorCategory.transient,
            ),
          ),
        );
        expect(controller.recoveryAwaitingUpload, isTrue);

        await controller.handleLifecycleState(AppLifecycleState.resumed);
        expect(platform.resumeCount, 1);

        platform.emit(const TrackingUploadedEvent(sequence: 1));
        expect(controller.recoveryAwaitingUpload, isFalse);

        await controller.close();
      },
    );

    test('a new interruption starts a new foreground recovery epoch', () async {
      final platform = _FakePlatform()
        ..restoreResult = const RestoreResult(hasActiveSession: true);
      final controller = _controller(
        platform,
        hostPlatform: DiagnosticHostPlatform.ios,
      );
      await controller.initializeOrRestore('runtime-secret');
      platform.emit(
        TrackingFailedEvent(
          error: AsleepError(
            code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
            message: 'Foreground required',
            category: AsleepErrorCategory.recoveryRequired,
          ),
        ),
      );

      await controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(platform.resumeCount, 1);
      expect(controller.recoveryAwaitingUpload, isTrue);

      platform.emit(const TrackingInterruptedEvent());
      expect(controller.snapshot.trackingStatus, TrackingStatus.paused);
      expect(controller.recoveryAwaitingUpload, isFalse);

      await controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(platform.resumeCount, 2);
      expect(controller.recoveryAwaitingUpload, isTrue);

      platform.emit(const TrackingUploadedEvent(sequence: 2));
      expect(controller.recoveryAwaitingUpload, isFalse);

      await controller.close();
    });

    test(
      'a new recovery-required failure starts a new recovery epoch',
      () async {
        final platform = _FakePlatform()
          ..restoreResult = const RestoreResult(hasActiveSession: true);
        final controller = _controller(
          platform,
          hostPlatform: DiagnosticHostPlatform.ios,
        );
        await controller.initializeOrRestore('runtime-secret');
        final recoveryError = AsleepError(
          code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
          message: 'Foreground required',
          category: AsleepErrorCategory.recoveryRequired,
        );
        platform.emit(TrackingFailedEvent(error: recoveryError));

        await controller.handleLifecycleState(AppLifecycleState.resumed);
        expect(platform.resumeCount, 1);
        expect(controller.recoveryAwaitingUpload, isTrue);

        platform.emit(TrackingFailedEvent(error: recoveryError));
        expect(controller.recoveryAwaitingUpload, isFalse);

        await controller.handleLifecycleState(AppLifecycleState.resumed);
        expect(platform.resumeCount, 2);
        expect(controller.recoveryAwaitingUpload, isTrue);

        platform.emit(const TrackingUploadedEvent(sequence: 2));
        expect(controller.recoveryAwaitingUpload, isFalse);

        await controller.close();
      },
    );

    test(
      'unrelated command failure does not clear a successful resume latch',
      () async {
        final platform = _FakePlatform()
          ..restoreResult = const RestoreResult(hasActiveSession: true)
          ..resumeCompleter = Completer<void>();
        final controller = _controller(
          platform,
          hostPlatform: DiagnosticHostPlatform.ios,
        );
        await controller.initializeOrRestore('runtime-secret');
        platform.emit(
          TrackingFailedEvent(
            error: AsleepError(
              code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
              message: 'Foreground required',
              category: AsleepErrorCategory.recoveryRequired,
            ),
          ),
        );

        final recovery = controller.handleLifecycleState(
          AppLifecycleState.resumed,
        );
        await Future<void>.delayed(Duration.zero);
        platform.reportError = StateError('report failed');
        await controller.loadReport('session-1');
        platform.resumeCompleter!.complete();
        await recovery;

        expect(controller.recoveryAwaitingUpload, isTrue);
        await controller.handleLifecycleState(AppLifecycleState.resumed);
        expect(platform.resumeCount, 1);

        platform.emit(const TrackingUploadedEvent(sequence: 1));
        expect(controller.recoveryAwaitingUpload, isFalse);

        await controller.close();
      },
    );

    test(
      'terminal and recording-dead failures release the recovery latch',
      () async {
        for (final category in <AsleepErrorCategory>[
          AsleepErrorCategory.terminal,
          AsleepErrorCategory.recordingDead,
        ]) {
          final platform = _FakePlatform()
            ..restoreResult = const RestoreResult(hasActiveSession: true);
          final controller = _controller(
            platform,
            hostPlatform: DiagnosticHostPlatform.ios,
          );
          await controller.initializeOrRestore('runtime-secret');
          platform.emit(
            TrackingFailedEvent(
              error: AsleepError(
                code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
                message: 'Foreground required',
                category: AsleepErrorCategory.recoveryRequired,
              ),
            ),
          );
          await controller.handleLifecycleState(AppLifecycleState.resumed);

          platform.emit(
            TrackingFailedEvent(
              error: AsleepError(
                code: 'RECOVERY_ENDED',
                message: 'Session ended',
                category: category,
              ),
            ),
          );

          expect(
            controller.recoveryAwaitingUpload,
            isFalse,
            reason: category.name,
          );
          await controller.close();
        }
      },
    );

    test('does not run foreground recovery on Android', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);

      await controller.handleLifecycleState(AppLifecycleState.resumed);

      expect(platform.resumeCount, 0);
      await controller.close();
    });

    test('a closed session releases the foreground recovery latch', () async {
      final platform = _FakePlatform()
        ..restoreResult = const RestoreResult(hasActiveSession: true);
      final controller = _controller(
        platform,
        hostPlatform: DiagnosticHostPlatform.ios,
      );
      await controller.initializeOrRestore('runtime-secret');
      final recoveryError = AsleepError(
        code: 'CANNOT_ACTIVATE_IN_BACKGROUND',
        message: 'Foreground required',
        category: AsleepErrorCategory.recoveryRequired,
      );

      platform.emit(TrackingFailedEvent(error: recoveryError));
      await controller.handleLifecycleState(AppLifecycleState.resumed);
      platform.emit(const TrackingClosedEvent(sessionId: 'first'));
      expect(controller.recoveryAwaitingUpload, isFalse);

      platform.emit(TrackingFailedEvent(error: recoveryError));
      await controller.handleLifecycleState(AppLifecycleState.resumed);
      expect(platform.resumeCount, 2);

      await controller.close();
    });

    test('requires explicit deletion confirmation', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      expect(
        await controller.deleteSession('session-1', confirmed: false),
        isFalse,
      );
      expect(platform.deleteCount, 0);
      expect(controller.operationMessage, isNot(contains('deleted')));

      expect(
        await controller.deleteSession('session-1', confirmed: true),
        isTrue,
      );
      expect(platform.deleteCount, 1);

      await controller.close();
    });

    test('deduplicates concurrent confirmed deletion requests', () async {
      final platform = _FakePlatform()..deleteCompleter = Completer<void>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final first = controller.deleteSession('session-1', confirmed: true);
      await Future<void>.delayed(Duration.zero);
      final duplicate = controller.deleteSession('session-1', confirmed: true);

      expect(controller.deletionInFlight, isTrue);
      expect(platform.deleteCount, 1);
      expect(await duplicate, isFalse);

      platform.deleteCompleter!.complete();
      expect(await first, isTrue);
      expect(controller.deletionInFlight, isFalse);
      expect(platform.deleteCount, 1);

      await controller.close();
    });

    test('successful deletion clears matching cached report state', () async {
      final platform = _FakePlatform();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');
      await controller.loadReport('session-1');
      await controller.loadReportList('2026-07-01', '2026-07-31');
      await controller.loadAverageReport('2026-07-01', '2026-07-31');

      expect(controller.report?.session.id, 'session-1');
      expect(controller.reportList.map((session) => session.id), <String>[
        'session-1',
      ]);
      expect(controller.averageReport, isNotNull);

      expect(
        await controller.deleteSession('session-1', confirmed: true),
        isTrue,
      );
      expect(controller.report, isNull);
      expect(controller.reportList, isEmpty);
      expect(controller.averageReport, isNull);

      await controller.close();
    });

    test('pending report loads cannot restore a deleted session', () async {
      final platform = _FakePlatform()
        ..reportCompleter = Completer<AsleepReport>()
        ..reportListCompleter = Completer<List<AsleepSession>>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final reportLoad = controller.loadReport('session-1');
      final listLoad = controller.loadReportList('2026-07-01', '2026-07-31');
      await Future<void>.delayed(Duration.zero);
      expect(
        await controller.deleteSession('session-1', confirmed: true),
        isTrue,
      );

      platform.reportCompleter!.complete(_reportFor('session-1'));
      await reportLoad;
      expect(controller.operationMessage, 'Deleted session report ignored');
      platform.reportListCompleter!.complete(<AsleepSession>[
        _sessionFor('session-1'),
      ]);
      await listLoad;

      expect(controller.report, isNull);
      expect(controller.reportList, isEmpty);

      await controller.close();
    });

    test('pending average report is ignored after deletion', () async {
      final platform = _FakePlatform()
        ..averageReportCompleter = Completer<AsleepAverageReport>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final averageLoad = controller.loadAverageReport(
        '2026-07-01',
        '2026-07-31',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        await controller.deleteSession('session-1', confirmed: true),
        isTrue,
      );
      platform.averageReportCompleter!.complete(
        _averageReportFor('2026-07-01', '2026-07-31'),
      );
      await averageLoad;

      expect(controller.averageReport, isNull);
      expect(controller.operationMessage, 'Stale average report ignored');

      await controller.close();
    });

    test('deleting another session preserves pending report results', () async {
      final platform = _FakePlatform()
        ..reportCompleter = Completer<AsleepReport>()
        ..reportListCompleter = Completer<List<AsleepSession>>();
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final reportLoad = controller.loadReport('session-a');
      final listLoad = controller.loadReportList('2026-07-01', '2026-07-31');
      await Future<void>.delayed(Duration.zero);
      expect(
        await controller.deleteSession('session-b', confirmed: true),
        isTrue,
      );

      platform.reportCompleter!.complete(_reportFor('session-a'));
      platform.reportListCompleter!.complete(<AsleepSession>[
        _sessionFor('session-a'),
        _sessionFor('session-b'),
      ]);
      await Future.wait(<Future<void>>[reportLoad, listLoad]);

      expect(controller.report?.session.id, 'session-a');
      expect(controller.reportList.map((session) => session.id), <String>[
        'session-a',
      ]);

      await controller.close();
    });

    test('only the newest detailed report request updates state', () async {
      final older = Completer<AsleepReport>();
      final newer = Completer<AsleepReport>();
      final platform = _FakePlatform()
        ..reportCompleters['session-older'] = older
        ..reportCompleters['session-newer'] = newer;
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final olderLoad = controller.loadReport('session-older');
      final newerLoad = controller.loadReport('session-newer');
      await Future<void>.delayed(Duration.zero);

      newer.complete(_reportFor('session-newer'));
      await newerLoad;
      expect(controller.report?.session.id, 'session-newer');
      expect(controller.operationMessage, 'Detailed report loaded');

      older.complete(_reportFor('session-older'));
      await olderLoad;
      expect(controller.report?.session.id, 'session-newer');
      expect(controller.operationMessage, 'Detailed report loaded');

      await controller.close();
    });

    test('only the newest report-list request updates state', () async {
      final older = Completer<List<AsleepSession>>();
      final newer = Completer<List<AsleepSession>>();
      final platform = _FakePlatform()
        ..reportListCompleters['2026-06-01:2026-06-30'] = older
        ..reportListCompleters['2026-07-01:2026-07-31'] = newer;
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final olderLoad = controller.loadReportList('2026-06-01', '2026-06-30');
      final newerLoad = controller.loadReportList('2026-07-01', '2026-07-31');
      await Future<void>.delayed(Duration.zero);

      newer.complete(<AsleepSession>[_sessionFor('session-newer')]);
      await newerLoad;
      expect(controller.reportList.single.id, 'session-newer');
      expect(controller.operationMessage, 'Report list loaded');

      older.complete(<AsleepSession>[_sessionFor('session-older')]);
      await olderLoad;
      expect(controller.reportList.single.id, 'session-newer');
      expect(controller.operationMessage, 'Report list loaded');

      await controller.close();
    });

    test('only the newest average report request updates state', () async {
      final older = Completer<AsleepAverageReport>();
      final newer = Completer<AsleepAverageReport>();
      final platform = _FakePlatform()
        ..averageReportCompleters['2026-06-01:2026-06-30'] = older
        ..averageReportCompleters['2026-07-01:2026-07-31'] = newer;
      final controller = _controller(platform);
      await controller.initializeOrRestore('runtime-secret');

      final olderLoad = controller.loadAverageReport(
        '2026-06-01',
        '2026-06-30',
      );
      final newerLoad = controller.loadAverageReport(
        '2026-07-01',
        '2026-07-31',
      );
      await Future<void>.delayed(Duration.zero);

      newer.complete(_averageReportFor('2026-07-01', '2026-07-31'));
      await newerLoad;
      expect(controller.averageReport?.period.startDate, '2026-07-01');
      expect(controller.operationMessage, 'Average report loaded');

      older.complete(_averageReportFor('2026-06-01', '2026-06-30'));
      await olderLoad;
      expect(controller.averageReport?.period.startDate, '2026-07-01');
      expect(controller.operationMessage, 'Average report loaded');

      await controller.close();
    });

    test(
      'close drains a pending deletion before disposing the client',
      () async {
        final platform = _FakePlatform()..deleteCompleter = Completer<void>();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');

        final deletion = controller.deleteSession('session-1', confirmed: true);
        await Future<void>.delayed(Duration.zero);
        final closing = controller.close();
        await Future<void>.delayed(Duration.zero);

        expect(platform.deleteCount, 1);
        expect(platform.disposeCount, 0);

        platform.deleteCompleter!.complete();
        expect(await deletion, isTrue);
        await closing;
        expect(platform.disposeCount, 1);
        expect(
          platform.calls.indexOf('delete:session-1'),
          lessThan(platform.calls.indexOf('dispose')),
        );
      },
    );

    test(
      'preserves the client structured error instance and redacts details',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');
        final details = <String, Object?>{
          'apiKey': 'runtime-secret',
          'nativePayload': 'private',
        };
        platform.reportError = AsleepException(
          AsleepErrorCode.nativeFailure,
          'Native message echoed runtime-secret',
          nativeCode: 'REPORT_FAILED',
          nativeDetails: details,
        );

        await controller.loadReport('session-1');

        expect(controller.operationError, same(controller.snapshot.error));
        expect(controller.operationErrorText, contains('REPORT_FAILED'));
        expect(
          controller.operationErrorText,
          isNot(contains('runtime-secret')),
        );
        expect(
          controller.operationErrorText,
          isNot(contains('Native message echoed')),
        );
        expect(controller.operationErrorText, isNot(contains('private')));

        platform.emit(const DebugLogEvent(message: 'apiKey=runtime-secret'));
        expect(controller.lastEvent, isNot(contains('runtime-secret')));
        expect(
          controller.operationErrorText,
          isNot(contains('runtime-secret')),
        );

        await controller.close();
      },
    );

    test('never renders a runtime credential echoed by native setup', () async {
      final platform = _FakePlatform()..echoSetupKeyInError = true;
      final controller = _controller(platform);

      await controller.initializeOrRestore('runtime-secret');

      expect(controller.operationErrorText, contains('SETUP_FAILED'));
      expect(controller.operationErrorText, isNot(contains('runtime-secret')));
      expect(
        controller.operationErrorText,
        isNot(contains('Native setup failed for')),
      );

      await controller.close();
    });

    test(
      'renders async snapshot failures without native message details',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.initializeOrRestore('runtime-secret');

        platform.emit(
          TrackingFailedEvent(
            error: AsleepError(
              code: 'NETWORK_OFFLINE',
              message: 'secret-native-message',
              category: AsleepErrorCategory.transient,
            ),
          ),
        );

        expect(controller.snapshotErrorText, 'NETWORK_OFFLINE (transient)');
        expect(
          controller.snapshotErrorText,
          isNot(contains('secret-native-message')),
        );

        await controller.close();
      },
    );

    test(
      'disables logging, cancels subscriptions, and disposes once',
      () async {
        final platform = _FakePlatform();
        final controller = _controller(platform);
        await controller.setLoggingEnabled(true);
        var notifications = 0;
        controller.addListener(() => notifications++);

        final first = controller.close();
        final second = controller.close();
        await Future.wait(<Future<void>>[first, second]);
        final afterClose = notifications;
        platform.emit(const TrackingInterruptedEvent());

        expect(
          platform.calls,
          containsAllInOrder(<String>[
            'logging:true',
            'logging:false',
            'dispose',
          ]),
        );
        expect(platform.disposeCount, 1);
        expect(notifications, afterClose);
      },
    );

    test(
      'waits for an active logging transition before forcing logging off',
      () async {
        final platform = _FakePlatform()
          ..loggingEnableCompleter = Completer<void>();
        final controller = _controller(platform);

        final enabling = controller.setLoggingEnabled(true);
        await Future<void>.delayed(Duration.zero);
        final closing = controller.close();
        await Future<void>.delayed(Duration.zero);

        expect(platform.calls, <String>['logging:true']);
        platform.loggingEnableCompleter!.complete();
        await Future.wait(<Future<void>>[enabling, closing]);

        expect(platform.calls, <String>[
          'logging:true',
          'logging:false',
          'dispose',
        ]);
      },
    );
  });
}

DiagnosticController _controller(
  _FakePlatform platform, {
  DiagnosticHostPlatform hostPlatform = DiagnosticHostPlatform.android,
}) {
  return DiagnosticController(
    client: AsleepClient(platform: platform),
    hostPlatform: hostPlatform,
  );
}

class _FakePlatform implements AsleepPlatform {
  final StreamController<AsleepEvent> _events =
      StreamController<AsleepEvent>.broadcast(sync: true);
  final List<String> calls = <String>[];

  RestoreResult restoreResult = const RestoreResult(hasActiveSession: false);
  BatteryOptimizationStatus batteryStatus = const BatteryOptimizationStatus(
    exempted: true,
    platform: 'android',
  );
  bool permissionsGranted = true;
  bool permissionRequestResult = true;
  Object? reportError;
  AsleepAnalysisResult? analysisResult;
  VoidCallback? onAnalysisRequest;
  Completer<void>? loggingEnableCompleter;
  Completer<void>? resumeCompleter;
  Completer<void>? startCompleter;
  Completer<RestoreResult>? restoreCompleter;
  Completer<BatteryOptimizationStatus>? batteryCheckCompleter;
  Completer<AnalysisRequest>? analysisCompleter;
  Completer<void>? deleteCompleter;
  Completer<AsleepReport>? reportCompleter;
  Completer<List<AsleepSession>>? reportListCompleter;
  Completer<AsleepAverageReport>? averageReportCompleter;
  final Map<String, Completer<AsleepReport>> reportCompleters =
      <String, Completer<AsleepReport>>{};
  final Map<String, Completer<List<AsleepSession>>> reportListCompleters =
      <String, Completer<List<AsleepSession>>>{};
  final Map<String, Completer<AsleepAverageReport>> averageReportCompleters =
      <String, Completer<AsleepAverageReport>>{};
  Object? disposeError;
  Object? setupError;
  Object? startError;
  Object? stopError;
  bool echoSetupKeyInError = false;
  String? setupApiKey;
  String? configuredApiKey;
  int resumeCount = 0;
  int deleteCount = 0;
  int disposeCount = 0;

  @override
  Stream<AsleepEvent> get events => _events.stream;

  void emit(AsleepEvent event) => _events.add(event);

  void emitError(Object error) => _events.addError(error);

  @override
  Future<void> setup(AsleepSetupOptions options) async {
    calls.add('setup');
    setupApiKey = options.apiKey;
    if (setupError case final error?) {
      throw error;
    }
    if (echoSetupKeyInError) {
      throw AsleepException(
        AsleepErrorCode.nativeFailure,
        'Native setup failed for ${options.apiKey}',
        nativeCode: 'SETUP_FAILED',
      );
    }
  }

  @override
  Future<void> configure(AsleepConfiguration configuration) async {
    calls.add('configure');
    configuredApiKey = configuration.apiKey;
  }

  @override
  Future<RestoreResult> checkAndRestoreTracking() async {
    calls.add('restore');
    return await restoreCompleter?.future ?? restoreResult;
  }

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    calls.add('battery-check');
    return await batteryCheckCompleter?.future ?? batteryStatus;
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async {
    calls.add('battery-request');
    return true;
  }

  @override
  Future<bool> hasRequiredPermissions() async {
    calls.add('permissions-check');
    return permissionsGranted;
  }

  @override
  Future<bool> requestRequiredPermissions() async {
    calls.add('permissions-request');
    return permissionRequestResult;
  }

  @override
  Future<void> startTracking(AsleepTrackingOptions options) async {
    calls.add('start');
    if (startError case final error?) {
      throw error;
    }
    await startCompleter?.future;
  }

  @override
  Future<void> resumeTracking() async {
    calls.add('resume');
    resumeCount++;
    await resumeCompleter?.future;
  }

  @override
  Future<void> stopTracking() async {
    calls.add('stop');
    if (stopError case final error?) {
      throw error;
    }
  }

  @override
  Future<AnalysisRequest> requestAnalysis() async {
    calls.add('analysis');
    onAnalysisRequest?.call();
    if (analysisCompleter case final completer?) {
      return completer.future;
    }
    return AnalysisRequest(
      status: AnalysisRequestStatus.requested,
      immediateResult: analysisResult,
    );
  }

  @override
  Future<AsleepReport> getReport(String sessionId) async {
    calls.add('report:$sessionId');
    if (reportError case final error?) {
      throw error;
    }
    if (reportCompleters[sessionId] case final completer?) {
      return completer.future;
    }
    return await reportCompleter?.future ?? _reportFor(sessionId);
  }

  @override
  Future<List<AsleepSession>> getReportList(
    String fromDate,
    String toDate,
  ) async {
    calls.add('report-list:$fromDate:$toDate');
    if (reportListCompleters['$fromDate:$toDate'] case final completer?) {
      return completer.future;
    }
    if (reportListCompleter case final completer?) {
      return completer.future;
    }
    return <AsleepSession>[_sessionFor('session-1')];
  }

  @override
  Future<AsleepAverageReport> getAverageReport(
    String fromDate,
    String toDate,
  ) async {
    calls.add('average-report:$fromDate:$toDate');
    if (averageReportCompleters['$fromDate:$toDate'] case final completer?) {
      return completer.future;
    }
    return await averageReportCompleter?.future ??
        _averageReportFor(fromDate, toDate);
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    calls.add('delete:$sessionId');
    deleteCount++;
    await deleteCompleter?.future;
  }

  @override
  Future<void> setLoggingEnabled(bool enabled) async {
    calls.add('logging:$enabled');
    if (enabled) {
      await loggingEnableCompleter?.future;
    }
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    disposeCount++;
    if (disposeError case final error?) {
      throw error;
    }
  }
}

AsleepReport _reportFor(String sessionId) => AsleepReport(
  timezone: 'UTC',
  session: AsleepReportSession(
    id: sessionId,
    createdTimezone: 'UTC',
    startTime: DateTime.utc(2026, 7, 1),
    state: 'COMPLETE',
  ),
  missingDataRatio: 0,
  peculiarities: const <String>[],
);

AsleepSession _sessionFor(String sessionId) => AsleepSession(
  id: sessionId,
  state: 'COMPLETE',
  startTime: DateTime.utc(2026, 7, 1),
  createdTimezone: 'UTC',
);

AsleepAverageReport _averageReportFor(String fromDate, String toDate) =>
    AsleepAverageReport.fromJson(<String, Object?>{
      'period': <String, Object?>{
        'timezone': 'UTC',
        'startDate': fromDate,
        'endDate': toDate,
      },
      'peculiarities': <Object?>[],
      'sleptSessions': <Object?>[],
      'neverSleptSessions': <Object?>[],
    });
