import 'asleep_models.dart';

sealed class AsleepEvent {
  const AsleepEvent();
}

class TrackingCreatedEvent extends AsleepEvent {
  const TrackingCreatedEvent({this.sessionId});
  final String? sessionId;
}

class TrackingUploadedEvent extends AsleepEvent {
  const TrackingUploadedEvent({required this.sequence});
  final int sequence;
}

class TrackingClosedEvent extends AsleepEvent {
  const TrackingClosedEvent({required this.sessionId});
  final String sessionId;
}

class TrackingFailedEvent extends AsleepEvent {
  const TrackingFailedEvent({required this.error});
  final AsleepError error;
}

class TrackingInterruptedEvent extends AsleepEvent {
  const TrackingInterruptedEvent();
}

class TrackingResumedEvent extends AsleepEvent {
  const TrackingResumedEvent();
}

class MicrophonePermissionDeniedEvent extends AsleepEvent {
  const MicrophonePermissionDeniedEvent();
}

class UserJoinedEvent extends AsleepEvent {
  const UserJoinedEvent({required this.userId});
  final String userId;
}

class UserJoinFailedEvent extends AsleepEvent {
  const UserJoinFailedEvent({required this.error});
  final AsleepError error;
}

class UserDeletedEvent extends AsleepEvent {
  const UserDeletedEvent({required this.userId});
  final String userId;
}

class SetupCompletedEvent extends AsleepEvent {
  const SetupCompletedEvent();
}

class SetupFailedEvent extends AsleepEvent {
  const SetupFailedEvent({required this.error});
  final AsleepError error;
}

class SetupProgressEvent extends AsleepEvent {
  const SetupProgressEvent({required this.progress});
  final double progress;
}

class AnalysisResultEvent extends AsleepEvent {
  const AnalysisResultEvent({required this.result});
  final AsleepAnalysisResult result;
}

class DebugLogEvent extends AsleepEvent {
  const DebugLogEvent({required this.message});
  final String message;
}

class UnknownNativeEvent extends AsleepEvent {
  const UnknownNativeEvent({required this.type, required this.payload});

  final String type;
  final Map<String, Object?> payload;
}
