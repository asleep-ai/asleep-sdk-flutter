import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsleepClient', () {
    late FakeAsleepPlatform platform;
    late AsleepClient client;

    setUp(() {
      platform = FakeAsleepPlatform();
      client = AsleepClient(platform: platform);
    });

    tearDown(() async {
      await client.dispose();
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

    test('does not request permission when startTracking is called', () async {
      platform.hasPermissions = false;
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));

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

    test('keeps recovery-required sessions active', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        const TrackingFailedEvent(
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

    test('projects a restored native session into tracking state', () async {
      platform.hasActiveSession = true;
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));

      final result = await client.checkAndRestoreTracking();

      expect(result.hasActiveSession, isTrue);
      expect(client.state.trackingStatus, TrackingStatus.tracking);
      expect(client.state.didClose, isFalse);
    });

    test('requests analysis on every ODA upload', () async {
      await client.initialize(
        const AsleepSetupOptions(
          apiKey: 'test-api-key',
          enableOnDeviceAnalysis: true,
        ),
      );

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();

      expect(platform.analysisRequestCount, 1);
      expect(client.state.isAnalyzing, isTrue);
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

      platform.emit(const TrackingUploadedEvent(sequence: 1));
      await pumpEventQueue();

      expect(platform.analysisRequestCount, 1);
    });

    test('recording-dead failure does not report a clean close', () async {
      await client.initialize(const AsleepSetupOptions(apiKey: 'test-api-key'));
      platform.emit(const TrackingCreatedEvent(sessionId: 'session-1'));
      platform.emit(
        const TrackingFailedEvent(
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
  });
}

class FakeAsleepPlatform extends AsleepPlatform {
  final StreamController<AsleepEvent> _events =
      StreamController<AsleepEvent>.broadcast();

  bool hasPermissions = true;
  bool hasActiveSession = false;
  int permissionRequestCount = 0;
  int startCount = 0;
  int analysisRequestCount = 0;

  @override
  Stream<AsleepEvent> get events => _events.stream;

  void emit(AsleepEvent event) => _events.add(event);

  Future<void> close() => _events.close();

  @override
  Future<void> setup(AsleepSetupOptions options) async {}

  @override
  Future<void> configure(AsleepConfiguration configuration) async {}

  @override
  Future<RestoreResult> checkAndRestoreTracking() async {
    return RestoreResult(hasActiveSession: hasActiveSession);
  }

  @override
  Future<BatteryOptimizationStatus> checkBatteryOptimization() async {
    return const BatteryOptimizationStatus(exempted: true, platform: 'test');
  }

  @override
  Future<bool> requestBatteryOptimizationExemption() async => true;

  @override
  Future<bool> hasRequiredPermissions() async => hasPermissions;

  @override
  Future<bool> requestRequiredPermissions() async {
    permissionRequestCount++;
    return hasPermissions;
  }

  @override
  Future<void> startTracking(AsleepTrackingOptions options) async {
    startCount++;
  }

  @override
  Future<void> resumeTracking() async {}

  @override
  Future<void> stopTracking() async {}

  @override
  Future<AnalysisRequest> requestAnalysis() async {
    analysisRequestCount++;
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
}
