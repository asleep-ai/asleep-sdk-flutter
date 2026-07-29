import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('constructs and disposes the client', (tester) async {
    final client = AsleepClient();

    expect(client.state.trackingStatus, TrackingStatus.idle);

    await client.dispose();
  });
}
