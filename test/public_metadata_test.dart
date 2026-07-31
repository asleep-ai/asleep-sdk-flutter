import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const repository = 'https://github.com/asleep-ai/asleep-sdk-flutter';
  const issueTracker = '$repository/issues';

  test('pubspec exposes the public source and issue routes', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(pubspec, contains('repository: $repository'));
    expect(pubspec, contains('issue_tracker: $issueTracker'));
    expect(
      pubspec,
      contains(
        'documentation: '
        'https://pub.dev/packages/asleep_sdk_flutter/example',
      ),
    );
  });

  test('public intake documents expose consistent routes', () {
    final readme = File('README.md').readAsStringSync();
    final support = File('SUPPORT.md').readAsStringSync();
    final contributing = File('CONTRIBUTING.md').readAsStringSync();
    final compatibility = File('doc/COMPATIBILITY.md').readAsStringSync();

    for (final document in <String>[
      readme,
      support,
      contributing,
      compatibility,
    ]) {
      expect(document, matches(RegExp('${RegExp.escape(repository)}(?!/)')));
      expect(document, contains(issueTracker));
    }
  });

  test('public intake keeps private security and ownership boundaries', () {
    final support = File('SUPPORT.md').readAsStringSync();
    final security = File('SECURITY.md').readAsStringSync();
    final codeowners = File('.github/CODEOWNERS').readAsStringSync();

    expect(support, contains('private process in [SECURITY.md]'));
    expect(support, contains('`CODEOWNERS` records the current'));
    expect(
      security,
      contains('Do not report a suspected vulnerability through a public'),
    );
    expect(codeowners, contains('/SECURITY.md @keenranger'));
    expect(codeowners, contains('/SUPPORT.md @keenranger'));
  });

  test('public documents do not retain the private repository premise', () {
    for (final path in <String>[
      'README.md',
      'SUPPORT.md',
      'CONTRIBUTING.md',
      'doc/COMPATIBILITY.md',
      'doc/DISTRIBUTION.md',
      'doc/IMPLEMENTATION_PLAN.md',
    ]) {
      final document = File(path).readAsStringSync().toLowerCase();
      expect(
        document,
        isNot(contains('source repository and its issue tracker are private')),
        reason: path,
      );
      expect(
        document,
        isNot(contains('private github urls are intentionally omitted')),
        reason: path,
      );
      expect(
        document,
        isNot(contains('the github repository is private')),
        reason: path,
      );
      expect(
        document,
        isNot(contains('before the first upload')),
        reason: path,
      );
      expect(
        document,
        isNot(contains('still unused on pub.dev')),
        reason: path,
      );
    }
  });

  test('experimental compatibility and deprecation policy remain explicit', () {
    final support = File('SUPPORT.md').readAsStringSync();

    expect(
      support,
      contains('minor releases may include breaking API, behavior'),
    );
    expect(
      support,
      contains('deprecated for at least one\nsubsequent minor release'),
    );
    expect(support, contains('does not include a\nresponse-time SLA'));
  });
}
