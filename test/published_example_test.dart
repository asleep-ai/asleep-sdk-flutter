import 'dart:async';
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

  test('published analysis guide consumes only the canonical event result', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(
      guide,
      contains(
        'final acknowledgement = await client.requestAnalysis();\n'
        '// Use only acknowledgement status for request-progress UI.\n'
        'showAnalysisRequestStatus(acknowledgement.status);',
      ),
    );
    expect(guide, isNot(contains('acknowledgement.immediateResult')));
    expect(
      guide,
      contains(
        'case AnalysisResultEvent(:final result):\n'
        '      // Canonical cross-platform analysis result.\n'
        '      consumeAnalysis(result);',
      ),
    );
  });

  test('published deletion guide latches confirmation and delete by ID', () {
    final guide = File('example/example.md').readAsStringSync();

    expect(
      guide,
      contains(
        'final deletionsInFlight = <String, Future<void>>{};\n'
        '\n'
        'Future<void> deleteAfterConfirmation(',
      ),
    );
    expect(
      guide,
      contains(
        'final activeDeletion = deletionsInFlight[sessionId];\n'
        '  if (activeDeletion != null) {\n'
        '    return activeDeletion;\n'
        '  }\n'
        '  late final Future<void> operation;\n'
        '  operation = _deleteAfterConfirmation(\n'
        '    client,\n'
        '    sessionId,\n'
        '    confirmIrreversibleAction,\n'
        '  ).whenComplete(() {\n'
        '    if (identical(deletionsInFlight[sessionId], operation)) {\n'
        '      deletionsInFlight.remove(sessionId);\n'
        '    }\n'
        '  });\n'
        '  deletionsInFlight[sessionId] = operation;\n'
        '  return operation;',
      ),
    );
    expect(
      guide,
      contains(
        'if (!await confirmIrreversibleAction()) {\n'
        '    return;\n'
        '  }\n'
        '  await client.deleteSession(sessionId);',
      ),
    );
  });

  test(
    'deletion latch coalesces matching IDs and isolates different IDs',
    () async {
      final coordinator = _DeletionCoordinator();
      final confirmations = <String, Completer<bool>>{
        'session-a': Completer<bool>(),
        'session-b': Completer<bool>(),
      };
      final deletions = <String, Completer<void>>{
        'session-a': Completer<void>(),
        'session-b': Completer<void>(),
      };
      final confirmationCalls = <String, int>{};
      final deletionCalls = <String, int>{};

      Future<bool> confirm(String sessionId) {
        confirmationCalls.update(
          sessionId,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        return confirmations[sessionId]!.future;
      }

      Future<void> delete(String sessionId) {
        deletionCalls.update(
          sessionId,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        return deletions[sessionId]!.future;
      }

      final firstA = coordinator.run('session-a', confirm, delete);
      final duplicateA = coordinator.run('session-a', confirm, delete);
      final firstB = coordinator.run('session-b', confirm, delete);

      expect(duplicateA, same(firstA));
      expect(firstB, isNot(same(firstA)));
      expect(confirmationCalls, <String, int>{'session-a': 1, 'session-b': 1});

      confirmations['session-a']!.complete(true);
      confirmations['session-b']!.complete(true);
      await Future<void>.delayed(Duration.zero);

      expect(deletionCalls, <String, int>{'session-a': 1, 'session-b': 1});

      deletions['session-a']!.complete();
      deletions['session-b']!.complete();
      await Future.wait(<Future<void>>[firstA, duplicateA, firstB]);

      final cancelledRetry = coordinator.run(
        'session-a',
        (_) async => false,
        delete,
      );
      expect(cancelledRetry, isNot(same(firstA)));
      await cancelledRetry;
      expect(deletionCalls['session-a'], 1);
    },
  );

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

class _DeletionCoordinator {
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  Future<void> run(
    String sessionId,
    Future<bool> Function(String sessionId) confirm,
    Future<void> Function(String sessionId) delete,
  ) {
    final activeDeletion = _inFlight[sessionId];
    if (activeDeletion != null) {
      return activeDeletion;
    }
    late final Future<void> operation;
    operation = _run(sessionId, confirm, delete).whenComplete(() {
      if (identical(_inFlight[sessionId], operation)) {
        _inFlight.remove(sessionId);
      }
    });
    _inFlight[sessionId] = operation;
    return operation;
  }

  Future<void> _run(
    String sessionId,
    Future<bool> Function(String sessionId) confirm,
    Future<void> Function(String sessionId) delete,
  ) async {
    if (!await confirm(sessionId)) {
      return;
    }
    await delete(sessionId);
  }
}
