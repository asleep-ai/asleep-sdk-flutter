import 'asleep_models.dart';

/// Base type for events emitted by the native Asleep SDK.
sealed class AsleepEvent {
  const AsleepEvent();
}

/// Indicates that native tracking was created.
class TrackingCreatedEvent extends AsleepEvent {
  const TrackingCreatedEvent({this.sessionId});
  final String? sessionId;
}

/// Indicates that a tracking audio segment was uploaded.
class TrackingUploadedEvent extends AsleepEvent {
  const TrackingUploadedEvent({required this.sequence});
  final int sequence;
}

/// Indicates that tracking closed for a session.
class TrackingClosedEvent extends AsleepEvent {
  const TrackingClosedEvent({this.sessionId});
  final String? sessionId;
}

/// Indicates that tracking failed.
class TrackingFailedEvent extends AsleepEvent {
  const TrackingFailedEvent({required this.error});
  final AsleepError error;
}

/// Indicates that tracking was interrupted by the platform.
class TrackingInterruptedEvent extends AsleepEvent {
  const TrackingInterruptedEvent();
}

/// Indicates that an interrupted tracking session resumed.
class TrackingResumedEvent extends AsleepEvent {
  const TrackingResumedEvent();
}

/// Indicates that the microphone permission was denied.
class MicrophonePermissionDeniedEvent extends AsleepEvent {
  const MicrophonePermissionDeniedEvent();
}

/// Indicates that a user was associated with the SDK.
class UserJoinedEvent extends AsleepEvent {
  const UserJoinedEvent({required this.userId});
  final String userId;
}

/// Indicates that associating a user with the SDK failed.
class UserJoinFailedEvent extends AsleepEvent {
  const UserJoinFailedEvent({required this.error});
  final AsleepError error;
}

/// Indicates that a user association was deleted.
class UserDeletedEvent extends AsleepEvent {
  const UserDeletedEvent({required this.userId});
  final String userId;
}

/// Indicates that native SDK setup completed.
class SetupCompletedEvent extends AsleepEvent {
  const SetupCompletedEvent();
}

/// Indicates that native SDK setup failed.
class SetupFailedEvent extends AsleepEvent {
  const SetupFailedEvent({required this.error});
  final AsleepError error;
}

/// Reports progress while native SDK setup is running.
class SetupProgressEvent extends AsleepEvent {
  const SetupProgressEvent({required this.progress});
  final double progress;
}

/// Carries a completed or updated sleep analysis result.
class AnalysisResultEvent extends AsleepEvent {
  const AnalysisResultEvent({required this.result});
  final AsleepAnalysisResult result;
}

/// Carries a diagnostic message emitted by the native SDK.
class DebugLogEvent extends AsleepEvent {
  const DebugLogEvent({required this.message});
  final String message;
}

/// Preserves an unrecognized native event for forward compatibility.
class UnknownNativeEvent extends AsleepEvent {
  UnknownNativeEvent({
    required this.type,
    required Map<String, Object?> payload,
  }) : payload = Map<String, Object?>.unmodifiable(payload);

  final String type;
  final Map<String, Object?> payload;
}
