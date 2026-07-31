import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('publish contract includes the guide and diagnostic source', () {
    for (final path in <String>[
      'example/example.md',
      'example/lib/main.dart',
      'example/lib/diagnostic/diagnostic_app.dart',
      'example/lib/diagnostic/diagnostic_controller.dart',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: 'Missing $path');
    }

    final ignored = File('.pubignore').readAsLinesSync().where(
      (line) => line.trim().isNotEmpty && !line.startsWith('#'),
    );
    expect(ignored, isNot(contains('example/')));
    expect(ignored, isNot(contains('example/example.md')));
    expect(ignored, isNot(contains('example/lib/')));

    const publicGuide = 'https://pub.dev/packages/asleep_sdk_flutter/example';
    expect(File('README.md').readAsStringSync(), contains(publicGuide));
    expect(File('pubspec.yaml').readAsStringSync(), contains(publicGuide));
  });
}
