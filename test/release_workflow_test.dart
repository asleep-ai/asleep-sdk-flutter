import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final workflow = File('.github/workflows/release.yml').readAsStringSync();

  test('release notes run after every reversible release gate', () {
    final releaseNotes = _job(workflow, 'release-notes');

    for (final dependency in <String>[
      'minimum-toolchain',
      'validate',
      'android',
      'ios',
      'device-qualification',
    ]) {
      expect(releaseNotes, contains('- $dependency'));
    }
    expect(releaseNotes, contains(r"if: ${{ github.event_name == 'push' }}"));
    expect(releaseNotes, contains('contents: read'));
    expect(releaseNotes, contains('pull-requests: read'));
    expect(releaseNotes, contains('uses: actions/checkout@v6'));
    expect(releaseNotes, contains('fetch-depth: 0'));
    expect(
      releaseNotes,
      contains('uses: asleep-ai/actions/release-notes@release-notes/v1'),
    );
    expect(
      releaseNotes,
      contains(r'openai-api-key: ${{ secrets.OPENAI_API_KEY }}'),
    );
    expect(releaseNotes, contains(r'$GITHUB_STEP_SUMMARY'));
    expect(releaseNotes, contains('uses: actions/upload-artifact@v7'));
    expect(
      releaseNotes,
      contains(r'name: release-notes-${{ github.ref_name }}'),
    );
    expect(releaseNotes, contains('timeout-minutes: 10'));
    expect(releaseNotes, contains('retention-days: 7'));
  });

  test('publishing and GitHub release consume the shared notes artifact', () {
    final publish = _job(workflow, 'publish');
    final hostedConsumer = _job(workflow, 'hosted-consumer');
    final githubRelease = _job(workflow, 'github-release');

    for (final dependency in <String>[
      'minimum-toolchain',
      'validate',
      'android',
      'ios',
      'device-qualification',
      'release-notes',
    ]) {
      expect(publish, contains('- $dependency'));
      expect(githubRelease, contains('- $dependency'));
    }
    expect(publish, contains("vars.PUBDEV_PUBLISH_ENABLED == 'true'"));
    expect(publish, contains('id-token: write'));
    expect(hostedConsumer, contains('- publish'));
    expect(hostedConsumer, contains("needs.publish.result == 'success'"));
    expect(githubRelease, contains('- publish'));
    expect(githubRelease, contains('- hosted-consumer'));
    for (final result in <String>[
      'minimum-toolchain',
      'validate',
      'android',
      'ios',
      'device-qualification',
      'release-notes',
    ]) {
      expect(githubRelease, contains("needs.$result.result == 'success'"));
    }
    expect(
      githubRelease,
      contains("needs.hosted-consumer.result == 'success'"),
    );
    expect(githubRelease, contains("needs.publish.result == 'skipped'"));
    expect(githubRelease, contains("vars.RELEASE_CREATION_ENABLED == 'true'"));
    expect(githubRelease, contains('uses: actions/download-artifact@v8'));
    expect(
      githubRelease,
      contains(r'name: release-notes-${{ github.ref_name }}'),
    );
    expect(githubRelease, contains('--verify-tag'));
    expect(githubRelease, contains(r'--notes "$(cat "$NOTES_PATH")"'));
    expect(githubRelease, contains('--generate-notes'));
  });

  test('manual dispatch remains validation-only', () {
    expect(workflow, contains('workflow_dispatch:'));
    expect(
      _job(workflow, 'release-notes'),
      contains(r"if: ${{ github.event_name == 'push' }}"),
    );
    expect(_job(workflow, 'publish'), contains("github.event_name == 'push'"));
    expect(
      _job(workflow, 'github-release'),
      contains("github.event_name == 'push'"),
    );
  });
}

String _job(String workflow, String name) {
  final startPattern = RegExp(
    '^  ${RegExp.escape(name)}:\\s*\$',
    multiLine: true,
  );
  final start = startPattern.firstMatch(workflow);
  if (start == null) {
    throw StateError('Missing workflow job: $name');
  }
  final nextJobs = RegExp(
    r'^  [a-zA-Z0-9_-]+:\s*$',
    multiLine: true,
  ).allMatches(workflow, start.end);
  final nextJob = nextJobs.isEmpty ? null : nextJobs.first;
  return workflow.substring(start.start, nextJob?.start ?? workflow.length);
}
