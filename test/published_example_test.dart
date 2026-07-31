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
    final guide = File('example/example.md').readAsStringSync();
    expect(guide, contains('awaitingRecoveryUpload ||'));
  });

  test('published recovery guide releases the latch after resume failure', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(
      guide,
      contains(
        'catch (_) {\n'
        '    // No upload proof can arrive for a resume command that did not succeed.\n'
        '    // Release the latch so a later foreground callback can retry.\n'
        '    awaitingRecoveryUpload = false;\n'
        '    rethrow;',
      ),
    );
  });

  test('published battery guide waits for Settings to return', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(
      guide,
      contains('Future<void> recheckBatteryAfterSettingsReturn() async'),
    );
    expect(
      guide,
      isNot(
        contains(
          'await client.requestBatteryOptimizationExemption();\n'
          '  // Do not assume that opening Settings granted an exemption.',
        ),
      ),
    );
  });

  test('published recovery guide handles a new interruption epoch', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(guide, contains('event is TrackingInterruptedEvent ||'));
    expect(
      guide,
      contains('the next foreground callback will re-arm the latch'),
    );
    expect(
      guide,
      contains('event.error.category == AsleepErrorCategory.recoveryRequired'),
    );
  });

  test('published state guide keeps recording-dead cleanup durable', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(
      guide,
      contains(
        'final canStop = snapshot.isTracking || '
        'recordingDeadCleanupRequired;',
      ),
    );
    expect(
      guide,
      contains(
        'A successful stop request alone is\n'
        'not close proof.',
      ),
    );
  });

  test('published event switch separates upload and analysis cases', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(
      guide,
      contains(
        'case TrackingUploadedEvent():\n'
        '      // Upload progress, and iOS foreground-recovery proof when applicable.\n'
        '      handleUploadProgress();\n'
        '    case AnalysisResultEvent(:final result):',
      ),
    );
  });

  test('published ownership guide handles stream and shutdown failures', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(guide, contains('onError: (Object error, StackTrace stackTrace)'));
    expect(guide, contains('await Future.wait(activeOperations.toList());'));
    expect(
      guide,
      contains(
        'Widget shutdown cannot await `close()`; attach an\n'
        'error handler',
      ),
    );
  });

  test('published recovery guide releases ended-session state', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(guide, contains('event is TrackingClosedEvent ||'));
    expect(
      guide,
      contains('event.error.category == AsleepErrorCategory.terminal'),
    );
    expect(
      guide,
      contains('event.error.category == AsleepErrorCategory.recordingDead'),
    );
    expect(
      guide,
      contains(
        '// Release stale state without presenting the ended session as recovered.',
      ),
    );
  });

  test(
    'published cleanup guide attempts every step and rethrows first error',
    () {
      final guide = File('example/example.md').readAsStringSync();

      expect(guide, contains('firstError ??= error;'));
      expect(
        guide,
        contains('await cleanUp(() => client.setLoggingEnabled(false));'),
      );
      expect(guide, contains('await cleanUp(stateSubscription.cancel);'));
      expect(guide, contains('await cleanUp(eventSubscription.cancel);'));
      expect(guide, contains('await cleanUp(client.dispose);'));
      expect(
        guide,
        contains('Error.throwWithStackTrace(firstError!, firstStackTrace!);'),
      );
    },
  );
}
