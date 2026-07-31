import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:asleep_sdk_flutter_example/diagnostic/diagnostic_controller.dart';
import 'package:asleep_sdk_flutter_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('gates tracking actions until SDK preparation completes', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform()
      ..batteryCheckCompleter = Completer<BatteryOptimizationStatus>();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Initialize / restore'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Request analysis'),
          )
          .onPressed,
      isNull,
    );

    final preparation = controller.initializeOrRestore('runtime-secret');
    await tester.pump();
    expect(controller.sdkPreparationInFlight, isTrue);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Initialize / restore'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNull,
    );

    platform.batteryCheckCompleter!.complete(
      const BatteryOptimizationStatus(exempted: true, platform: 'android'),
    );
    await preparation;
    await tester.pump();

    expect(controller.sdkPrepared, isTrue);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Initialize / restore'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNotNull,
    );

    platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Request analysis'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android battery recheck enables Start after exemption', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform()
      ..batteryStatus = const BatteryOptimizationStatus(
        exempted: false,
        platform: 'android',
      );
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNull,
    );

    platform.batteryStatus = const BatteryOptimizationStatus(
      exempted: true,
      platform: 'android',
    );
    await controller.recheckBatteryOptimization();
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('renders the complete diagnostic journey', (tester) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );

    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    for (final label in <String>[
      'Initialize / restore',
      'Check permissions',
      'Request permissions',
      'Open battery settings',
      'Recheck battery',
      'Start tracking',
      'Resume tracking',
      'Stop tracking',
      'Recheck tracking state',
      'Request analysis',
      'Detailed report',
      'Report list',
      'Average report',
      'Delete session',
      'Native diagnostic logging',
    ]) {
      expect(find.text(label), findsAtLeastNWidgets(1));
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('uses a tracked session for report and deletion actions', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform()
      ..reportListResult = <AsleepSession>[
        _widgetSessionFor('tracked-session'),
      ];
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Use tracked session'),
          )
          .onPressed,
      isNull,
    );

    platform.emit(const TrackingCreatedEvent(sessionId: 'tracked-session'));
    platform.emit(const TrackingClosedEvent(sessionId: 'tracked-session'));
    await tester.pump();
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('tracked-session-id')))
          .data,
      'tracked-session',
    );

    await tester.tap(find.text('Use tracked session'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('session-id-field')))
          .controller!
          .text,
      'tracked-session',
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Detailed report'));
    await tester.pumpAndSettle();
    expect(platform.reportSessionIds, <String>['tracked-session']);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Report list'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('report-session-ids')))
          .data,
      'tracked-session',
    );

    await tester.tap(find.text('Delete session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    expect(platform.deletedSessionIds, <String>['tracked-session']);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('owned app contains asynchronous cleanup failures', (
    tester,
  ) async {
    final platform = _WidgetFakePlatform();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    var closeCount = 0;
    await tester.pumpWidget(
      AsleepExampleApp.owned(
        controller: controller,
        closeController: (_) {
          closeCount++;
          return Future<void>.error(StateError('secret cleanup detail'));
        },
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(closeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('requires explicit confirmation before deletion', (tester) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    await tester.tap(find.text('Delete session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Permanently delete this session?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(platform.deleteCount, 0);

    await tester.tap(find.text('Delete session'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete permanently'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(platform.deleteCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disables deletion through confirmation and request completion', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform()..deleteCompleter = Completer<void>();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    final deleteButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Delete session'),
    );
    deleteButton.onPressed!();
    deleteButton.onPressed!();
    await tester.pump();
    expect(find.text('Permanently delete this session?'), findsOneWidget);
    expect(platform.deleteCount, 0);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Delete session'),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Delete permanently'));
    await tester.pump();
    expect(platform.deleteCount, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Delete session'),
          )
          .onPressed,
      isNull,
    );

    platform.deleteCompleter!.complete();
    await tester.pump();
    expect(platform.deleteCount, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Delete session'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recording-dead state enables Stop and disables Start', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    platform.emit(
      TrackingFailedEvent(
        error: AsleepError(
          code: 'AUDIO_INITIALIZATION_FAILED',
          message: 'Recording stopped',
          category: AsleepErrorCategory.recordingDead,
        ),
      ),
    );
    await tester.pump();

    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start tracking'),
    );
    final stop = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Stop tracking'),
    );
    expect(start.onPressed, isNull);
    expect(stop.onPressed, isNotNull);

    await tester.tap(find.text('Check permissions'));
    await tester.pump();

    final startAfterCommand = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start tracking'),
    );
    final stopAfterCommand = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Stop tracking'),
    );
    expect(controller.snapshot.error, isNull);
    expect(startAfterCommand.onPressed, isNull);
    expect(stopAfterCommand.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('renders permission check and request outcomes distinctly', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform()
      ..permissionsGranted = false
      ..permissionRequestResult = true;
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    expect(find.text('unchecked'), findsAtLeastNWidgets(1));
    await tester.tap(find.text('Check permissions'));
    await tester.pumpAndSettle();
    expect(find.text('denied'), findsOneWidget);

    await tester.tap(find.text('Request permissions'));
    await tester.pumpAndSettle();
    expect(find.text('granted'), findsOneWidget);

    await tester.tap(find.text('Start tracking'));
    await tester.pumpAndSettle();
    expect(find.text('denied'), findsOneWidget);

    platform.permissionsGranted = true;
    await tester.tap(find.text('Start tracking'));
    await tester.pumpAndSettle();
    expect(find.text('granted'), findsOneWidget);

    platform.emit(const MicrophonePermissionDeniedEvent());
    await tester.pump();
    expect(find.text('denied'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Stop cancels a pending start', (tester) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform()..startCompleter = Completer<void>();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    platform.restoreCompleter = Completer<RestoreResult>();
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    await tester.tap(find.text('Start tracking'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Stop tracking'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Stop tracking'));
    await tester.pump();
    expect(platform.stopCount, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Stop tracking'),
          )
          .onPressed,
      isNull,
    );
    platform.startCompleter!.completeError(StateError('start cancelled'));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Recheck tracking state'),
          )
          .onPressed,
      isNull,
    );

    platform.restoreCompleter!.complete(
      const RestoreResult(hasActiveSession: false),
    );
    await tester.pumpAndSettle();

    expect(controller.operationMessage, 'Tracking stopped');
    expect(controller.operationError, isNull);
    expect(find.text('Tracking stopped'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start tracking'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Stop tracking'),
          )
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('renders snapshot errors without message or native details', (
    tester,
  ) async {
    _useTallSurface(tester);
    final platform = _WidgetFakePlatform();
    final controller = DiagnosticController(
      client: AsleepClient(platform: platform),
      hostPlatform: DiagnosticHostPlatform.android,
    );
    await controller.initializeOrRestore('runtime-secret');
    await tester.pumpWidget(AsleepExampleApp(controller: controller));

    platform.emit(
      TrackingFailedEvent(
        error: AsleepError(
          code: 'NETWORK_OFFLINE',
          message: 'secret-native-message',
          category: AsleepErrorCategory.transient,
          platformDetails: const <String, Object?>{
            'credential': 'runtime-secret',
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('NETWORK_OFFLINE (transient)'), findsOneWidget);
    expect(find.textContaining('secret-native-message'), findsNothing);
    expect(find.textContaining('runtime-secret'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 2400);
  addTearDown(tester.view.reset);
}

class _WidgetFakePlatform implements AsleepPlatform {
  final StreamController<AsleepEvent> _events =
      StreamController<AsleepEvent>.broadcast(sync: true);
  int deleteCount = 0;
  int stopCount = 0;
  final List<String> reportSessionIds = <String>[];
  final List<String> deletedSessionIds = <String>[];
  List<AsleepSession> reportListResult = const <AsleepSession>[];
  Completer<void>? deleteCompleter;
  Completer<void>? startCompleter;
  Completer<RestoreResult>? restoreCompleter;
  Completer<BatteryOptimizationStatus>? batteryCheckCompleter;
  BatteryOptimizationStatus batteryStatus = const BatteryOptimizationStatus(
    exempted: true,
    platform: 'android',
  );
  bool permissionsGranted = true;
  bool permissionRequestResult = true;

  @override
  Stream<AsleepEvent> get events => _events.stream;

  void emit(AsleepEvent event) => _events.add(event);

  @override
  Future<void> setup(AsleepSetupOptions options) async {}

  @override
  Future<void> configure(AsleepConfiguration configuration) async {}

  @override
  Future<RestoreResult> checkAndRestoreTracking() async =>
      await restoreCompleter?.future ??
      const RestoreResult(hasActiveSession: false);

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async =>
      await batteryCheckCompleter?.future ?? batteryStatus;

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;

  @override
  Future<bool> hasRequiredPermissions() async => permissionsGranted;

  @override
  Future<bool> requestRequiredPermissions() async => permissionRequestResult;

  @override
  Future<void> startTracking(AsleepTrackingOptions options) async {
    await startCompleter?.future;
  }

  @override
  Future<void> resumeTracking() async {}

  @override
  Future<void> stopTracking() async {
    stopCount++;
  }

  @override
  Future<AnalysisRequest> requestAnalysis() async =>
      const AnalysisRequest(status: AnalysisRequestStatus.requested);

  @override
  Future<AsleepReport> getReport(String sessionId) async {
    reportSessionIds.add(sessionId);
    return _widgetReportFor(sessionId);
  }

  @override
  Future<List<AsleepSession>> getReportList(
    String fromDate,
    String toDate,
  ) async => reportListResult;

  @override
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deleteCount++;
    deletedSessionIds.add(sessionId);
    await deleteCompleter?.future;
  }

  @override
  Future<void> setLoggingEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {}
}

AsleepReport _widgetReportFor(String sessionId) => AsleepReport(
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

AsleepSession _widgetSessionFor(String sessionId) => AsleepSession(
  id: sessionId,
  state: 'COMPLETE',
  startTime: DateTime.utc(2026, 7, 1),
  createdTimezone: 'UTC',
);
