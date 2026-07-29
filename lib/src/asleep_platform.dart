import 'asleep_events.dart';
import 'asleep_models.dart';

/// Native platform contract and supported fake seam used by `AsleepClient`.
///
/// Implement this interface in tests to exercise client behavior without
/// invoking Flutter platform channels.
abstract class AsleepPlatform {
  /// Events emitted by the native Asleep SDK.
  Stream<AsleepEvent> get events;

  /// Sets up the native SDK.
  Future<void> setup(AsleepSetupOptions options);

  /// Applies SDK credentials and endpoints.
  Future<void> configure(AsleepConfiguration configuration);

  /// Checks for a native session that can be restored.
  Future<RestoreResult> checkAndRestoreTracking();

  /// Returns the Android battery-optimization status.
  Future<BatteryOptimizationStatus> checkBatteryOptimization();

  /// Requests an Android battery-optimization exemption when supported.
  Future<bool> requestBatteryOptimizationExemption();

  /// Whether the platform permissions required for tracking are granted.
  Future<bool> hasRequiredPermissions();

  /// Requests the platform permissions required for tracking.
  Future<bool> requestRequiredPermissions();

  /// Starts native tracking with [options].
  Future<void> startTracking(AsleepTrackingOptions options);

  /// Resumes native tracking after interruption or foreground recovery.
  Future<void> resumeTracking();

  /// Stops native tracking.
  Future<void> stopTracking();

  /// Requests analysis for the active session.
  Future<AnalysisRequest> requestAnalysis();

  /// Fetches the detailed report for [sessionId].
  Future<AsleepReport> getReport(String sessionId);

  /// Fetches session summaries within a date range.
  Future<List<AsleepSession>> getReportList(String fromDate, String toDate);

  /// Fetches an aggregate report within a date range.
  Future<AsleepAverageReport> getAverageReport(String fromDate, String toDate);

  /// Deletes the session identified by [sessionId].
  Future<void> deleteSession(String sessionId);

  /// Enables or disables native diagnostic logging.
  Future<void> setLoggingEnabled(bool enabled);

  /// Releases platform resources.
  Future<void> dispose() async {}
}
