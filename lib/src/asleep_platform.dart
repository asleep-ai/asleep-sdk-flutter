import 'asleep_events.dart';
import 'asleep_models.dart';

abstract class AsleepPlatform {
  Stream<AsleepEvent> get events;

  Future<void> setup(AsleepSetupOptions options);
  Future<void> configure(AsleepConfiguration configuration);
  Future<RestoreResult> checkAndRestoreTracking();
  Future<BatteryOptimizationStatus> checkBatteryOptimization();
  Future<bool> requestBatteryOptimizationExemption();
  Future<bool> hasRequiredPermissions();
  Future<bool> requestRequiredPermissions();
  Future<void> startTracking(AsleepTrackingOptions options);
  Future<void> resumeTracking();
  Future<void> stopTracking();
  Future<AnalysisRequest> requestAnalysis();
  Future<AsleepReport> getReport(String sessionId);
  Future<List<AsleepSession>> getReportList(String fromDate, String toDate);
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate);
  Future<void> deleteSession(String sessionId);
  Future<void> setLoggingEnabled(bool enabled);

  Future<void> dispose() async {}
}
