import 'dart:async';

import 'package:asleep_sdk_flutter/asleep_sdk_flutter.dart';
import 'package:flutter/widgets.dart';

void main() {
  final client = AsleepClient();
  unawaited(client.dispose());
  runApp(const SizedBox.shrink());
}
