# Contributing

Thank you for helping improve `asleep_sdk_flutter`.

## Before proposing a change

The package, [source repository](https://github.com/asleep-ai/asleep-sdk-flutter),
and issue tracker are public. Search
[existing issues](https://github.com/asleep-ai/asleep-sdk-flutter/issues)
before opening a focused defect report or feature request. For a source
change, open or reference an issue, fork the repository, and submit a pull
request against `main`.

Report suspected vulnerabilities privately by following
[SECURITY.md](SECURITY.md). Do not include security details in a regular
issue or pull request.

## Change scope

- Keep each change focused on one approved problem.
- Preserve the existing Dart, Kotlin, and Swift style.
- Update tests and public documentation with behavior changes.
- Regenerate Pigeon output when `pigeons/asleep_messages.dart` changes.
- Never commit API keys, credentials, signing material, raw audio, sleep
  reports, user identifiers, or private endpoints.

## Validation

Run the relevant checks before requesting review:

```sh
dart format --output=none --set-exit-if-changed \
  lib test example/lib example/test example/integration_test pigeons
flutter analyze
flutter test
(cd example && flutter test)
dart pub publish --dry-run
```

Native changes also require the matching Android or iOS bridge tests and
example build. Runtime behavior must be checked on a supported ARM Android
device or iPhone when the change affects permissions, background execution,
audio, restoration, or tracking lifecycle.

## Review and release

Repository maintainers review source, dependency, workflow, security, and
release changes according to `CODEOWNERS`. A merged change is not a promise of
an immediate pub.dev release. Releases follow the signed-tag and package
validation process documented in the repository.
