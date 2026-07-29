import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/transport.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/ai/asleep/asleep_sdk_flutter/Transport.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'ai.asleep.asleep_sdk_flutter',
      includeErrorClass: true,
    ),
    swiftOut:
        'ios/asleep_sdk_flutter/Sources/asleep_sdk_flutter/Transport.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: true),
    dartPackageName: 'asleep_sdk_flutter',
  ),
)
class SetupMessage {
  SetupMessage({
    required this.apiKey,
    this.baseUrl,
    this.callbackUrl,
    this.service,
    required this.enableOnDeviceAnalysis,
  });

  String apiKey;
  String? baseUrl;
  String? callbackUrl;
  String? service;
  bool enableOnDeviceAnalysis;
}

class ConfigurationMessage {
  ConfigurationMessage({
    required this.apiKey,
    this.userId,
    this.baseUrl,
    this.callbackUrl,
  });

  String apiKey;
  String? userId;
  String? baseUrl;
  String? callbackUrl;
}

enum AudioSessionOptionMessage {
  duckOthers,
  allowAirPlay,
  allowBluetooth,
  allowBluetoothA2DP,
}

class NotificationMessage {
  NotificationMessage({this.title, this.text, this.icon});

  String? title;
  String? text;
  String? icon;
}

class TrackingMessage {
  TrackingMessage({
    this.androidNotification,
    required this.iosAudioSessionOptions,
  });

  NotificationMessage? androidNotification;
  List<AudioSessionOptionMessage> iosAudioSessionOptions;
}

class RestoreMessage {
  RestoreMessage({required this.hasActiveSession});
  bool hasActiveSession;
}

class BatteryOptimizationMessage {
  BatteryOptimizationMessage({
    required this.exempted,
    required this.platform,
    this.message,
  });

  bool exempted;
  String platform;
  String? message;
}

class AnalysisRequestMessage {
  AnalysisRequestMessage({
    required this.status,
    this.timestampMilliseconds,
    this.resultJson,
  });

  String status;
  int? timestampMilliseconds;
  String? resultJson;
}

class NativeEventMessage {
  NativeEventMessage({required this.type, required this.payloadJson});

  String type;
  String payloadJson;
}

@HostApi()
abstract class AsleepHostApi {
  @async
  void setup(SetupMessage message);

  @async
  void configure(ConfigurationMessage message);

  @async
  RestoreMessage checkAndRestoreTracking();

  @async
  BatteryOptimizationMessage checkBatteryOptimization();

  @async
  bool requestBatteryOptimizationExemption();

  @async
  bool hasRequiredPermissions();

  @async
  bool requestRequiredPermissions();

  @async
  void startTracking(TrackingMessage message);

  @async
  void resumeTracking();

  @async
  void stopTracking();

  @async
  AnalysisRequestMessage requestAnalysis();

  @async
  String getReport(String sessionId);

  @async
  List<String> getReportList(String fromDate, String toDate);

  @async
  String getAverageReport(String fromDate, String toDate);

  @async
  void deleteSession(String sessionId);

  @async
  void setLoggingEnabled(bool enabled);
}

@EventChannelApi()
abstract class AsleepEventChannelApi {
  NativeEventMessage events();
}
