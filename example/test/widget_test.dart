import 'package:asleep_sdk_flutter_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the explicit SDK journey', (tester) async {
    await tester.pumpWidget(const AsleepExampleApp());

    expect(find.text('Initialize'), findsOneWidget);
    expect(find.text('Check permission'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
  });
}
