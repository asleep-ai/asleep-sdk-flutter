import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:asleep_sdk_flutter_example/diagnostic/diagnostic_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DiagnosticController', () {
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

    test('keeps permission and Android battery actions separate', () async {
      final platform = _FakePlatform()
        ..permissionsGranted = false
        ..permissionRequestResult = true
        ..batteryStatus = const BatteryOptimizationStatus(
          exempted: false,
          platform: 'android',
        );
      final controller = _controller(platform);

      expect(await controller.checkPermissions(), isFalse);
      expect(controller.permissionsGranted, isFalse);
      expect(await controller.requestPermissions(), isTrue);
      expect(controller.permissionsGranted, isTrue);
      await controller.initializeOrRestore('runtime-secret');
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
      expect(controller.canStopTracking, isTrue);
      expect(controller.canStartTracking, isFalse);

      platform.emit(const TrackingClosedEvent(sessionId: 'session-1'));
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
      platform.reportListCompleter!.complete(<AsleepSession>[
        _sessionFor('session-1'),
      ]);
      await Future.wait(<Future<void>>[reportLoad, listLoad]);

      expect(controller.report, isNull);
      expect(controller.reportList, isEmpty);

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
  Completer<void>? loggingEnableCompleter;
  Completer<void>? resumeCompleter;
  Completer<void>? deleteCompleter;
  Completer<AsleepReport>? reportCompleter;
  Completer<List<AsleepSession>>? reportListCompleter;
  Object? disposeError;
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
    return restoreResult;
  }

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    calls.add('battery-check');
    return batteryStatus;
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
  }

  @override
  Future<AnalysisRequest> requestAnalysis() async {
    calls.add('analysis');
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
    return await reportCompleter?.future ?? _reportFor(sessionId);
  }

  @override
  Future<List<AsleepSession>> getReportList(
    String fromDate,
    String toDate,
  ) async {
    calls.add('report-list:$fromDate:$toDate');
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
    return AsleepAverageReport.fromJson(<String, Object?>{
      'period': <String, Object?>{
        'timezone': 'UTC',
        'startDate': fromDate,
        'endDate': toDate,
      },
      'peculiarities': <Object?>[],
      'sleptSessions': <Object?>[],
      'neverSleptSessions': <Object?>[],
    });
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
