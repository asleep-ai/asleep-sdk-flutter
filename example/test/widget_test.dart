import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:asleep_sdk_flutter_example/diagnostic/diagnostic_controller.dart';
import 'package:asleep_sdk_flutter_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  @override
  Stream<AsleepEvent> get events => _events.stream;

  @override
  Future<void> setup(AsleepSetupOptions options) async {}

  @override
  Future<void> configure(AsleepConfiguration configuration) async {}

  @override
  Future<RestoreResult> checkAndRestoreTracking() async =>
      const RestoreResult(hasActiveSession: false);

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async =>
      const BatteryOptimizationStatus(exempted: true, platform: 'android');

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;

  @override
  Future<bool> hasRequiredPermissions() async => true;

  @override
  Future<bool> requestRequiredPermissions() async => true;

  @override
  Future<void> startTracking(AsleepTrackingOptions options) async {}

  @override
  Future<void> resumeTracking() async {}

  @override
  Future<void> stopTracking() async {}

  @override
  Future<AnalysisRequest> requestAnalysis() async =>
      const AnalysisRequest(status: AnalysisRequestStatus.requested);

  @override
  Future<AsleepReport> getReport(String sessionId) {
    throw UnimplementedError();
  }

  @override
  Future<List<AsleepSession>> getReportList(String fromDate, String toDate) {
    throw UnimplementedError();
  }

  @override
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    deleteCount++;
  }

  @override
  Future<void> setLoggingEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {}
}
