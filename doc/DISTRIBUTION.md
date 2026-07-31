# Distribution and release contract

Verified on 2026-07-31 against the Dart, Flutter, pub.dev, and GitHub
documentation linked below.

## Current safety boundary

The GitHub repository and pub.dev package archive are public. Any user can
browse the repository or download the archive and its included source files.
Experimental version 0.1.0 is published under the verified `asleep.ai`
publisher. The release owner confirmed on 2026-07-30 that the existing Asleep
proprietary notice applies to the Flutter archive. `.pubignore` excludes
internal `doc/` and Pigeon schema files; Dart, Kotlin, Swift, generated
transport, and example sources remain public archive contents.

The pinned AsleepSDK 3.2.0 CocoaPods artifact is the existing commercial
runtime baseline. It does not contain a privacy manifest. That is an App Store
compliance follow-up for the native SDK, not a technical blocker for publishing
this source-only Flutter package. The missing upstream license file is a
CocoaPods lint warning; the native binary is not included in the pub archive.

External dependency access was rechecked on 2026-07-30. Android
`ai.asleep:asleepsdk:3.2.1` is downloadable from Maven Central, and the
`AsleepSDK` 3.2.0 CocoaPods spec resolves to a publicly downloadable GitHub
release asset. Consumers still need Asleep credentials and application review
to use the service.

On 2026-07-31, the pub.dev API reports `asleep_sdk_flutter` 0.1.0 under the
verified `asleep.ai` publisher. Hosted-consumer verification must request an
exact published version rather than relying on the latest compatible release.

No workflow in this repository creates a tag. With the repository's default
settings, the release workflow validates a candidate while its publish and
GitHub Release jobs remain skipped. A release tag must be signed, annotated, and
point to a commit contained in `origin/main`; publishing also requires Dart,
Android, and iOS release validation. Publish and GitHub Release jobs require
explicit repository variables before they can run.

## Distribution choices

| Choice | Source visibility | Consumer setup | Release model |
|---|---|---|---|
| pub.dev | Public package archive | Standard `dependencies` entry | First release is manual; later releases can use OIDC |
| Private Git dependency | Private GitHub access required | Git URL plus a pinned tag or commit | Signed protected tags |
| Private hosted registry | Controlled by registry policy | Authenticated hosted source | Registry-specific CI and retention |

For an internal Git release on Dart 3.9 or later, consumers can combine
`tag_pattern` with a version constraint:

```yaml
dependencies:
  asleep_sdk_flutter:
    git:
      url: git@github.com:asleep-ai/asleep-sdk-flutter.git
      tag_pattern: v{{version}}
    version: ^1.0.0
```

If reproducibility is more important than version solving, pin a full commit
SHA instead.

An organization-hosted registry is appropriate when access control, package
retention, audit logs, or dependency resolution without Git credentials are
required. Dart supports authenticated custom package repositories; the
registry vendor and operational owner remain undecided.

## Public release prerequisites

The release owner must resolve every item before the next upload:

1. Approve public redistribution of every Dart, Kotlin, Swift, generated
   transport, and example source file in the package archive.
2. Confirm the candidate is attached to the verified `asleep.ai` publisher.
3. Confirm the public source and issue URLs remain reachable and match the
   package metadata.
4. Recheck that the pinned Android Maven and iOS CocoaPods artifacts remain
   publicly downloadable for external consumers.
5. Confirm the supported Flutter, Dart, Android, iOS, Asleep Android SDK, and
   Asleep iOS SDK versions still match `COMPATIBILITY.md`.
6. Review the exact `dart pub publish --dry-run` archive and run the secret
   scan from a clean release commit.
7. Confirm the pub.dev OIDC link for the repository is active. If automated
   publishing is unavailable, have an authorized uploader run
   `dart pub publish`.

The initial 0.1.0 upload and verified publisher transfer are complete.
Subsequent releases should use pub.dev automated publishing when the OIDC link
and repository controls are active.

## Automated pub.dev publishing

For subsequent releases:

1. In pub.dev Admin, connect `asleep-ai/asleep-sdk-flutter`.
2. Configure the tag pattern as `v{{version}}`.
3. Require the GitHub Environment named `pub.dev`.
4. In GitHub, create the `pub.dev` Environment with required reviewers and
   prevent self-review.
5. Protect `v*` tags with a repository ruleset that restricts creation,
   updates, deletion, and bypass actors.
6. Confirm the release commit contains the approved stable package version and
   public archive.
7. Set `PUBDEV_PUBLISH_ENABLED=true` only after all preceding controls are
   complete.
8. Set `RELEASE_CREATION_ENABLED=true` only after tag-triggered GitHub Releases
   are approved.

The gated publishing job uses the Dart team's reusable workflow and grants
only the OIDC permission needed by pub.dev:

```yaml
jobs:
  publish:
    permissions:
      id-token: write
    uses: dart-lang/setup-dart/.github/workflows/publish.yml@v1
    with:
      environment: pub.dev
```

The public repository supports GitHub Environment required reviewers. Keep
them enabled alongside the tag ruleset and restricted bypass list.

## Rollback and incident response

A pub.dev upload cannot be deleted as a rollback. A maintainer can retract a
version and publish a corrected version, but the uploaded source must be
treated as permanently disclosed. Deleting a GitHub Release or tag does not
undo a pub.dev upload. Never solve a release incident by reusing a version or
moving an existing version tag; issue a new SemVer version, document the
incident in the changelog, and retract the affected pub.dev version when
appropriate.

Private Git consumers pinned to a commit remain on that commit even if a tag is
removed. Prefer an additive corrective tag and an explicit consumer migration
notice over rewriting release history.

## Release checklist

1. Pull a clean `main` and confirm CI is green.
2. Classify the release as major, minor, or patch from the public API diff.
3. Update `version` in `pubspec.yaml` and add the matching `CHANGELOG.md`
   section.
4. Run format, analyze, package tests, example tests, native builds,
   `flutter pub outdated`, API documentation, pana, and
   `dart pub publish --dry-run`.
5. Inspect the archive file list, license, generated code, and secret-scan
   result.
6. Create a GPG-signed release commit.
7. Create a GPG-signed annotated `v<version>` tag.
8. Push only after explicit release approval.
9. Confirm release validation.
10. For the first public release, have the authorized uploader run
    `dart pub publish`; do not enable OIDC first.
11. For later public releases, confirm the gated OIDC job succeeded and the
    exact hosted version passed both clean-consumer builds.
12. For a manual publication, run the `Hosted consumer` workflow with the exact
    published version and require both platform jobs to pass.
13. Create the GitHub Release with generated notes, either through the gated
    job or an explicitly approved equivalent command.

`pubspec.yaml`, the tag, and the CHANGELOG heading must contain the same stable
SemVer version. Pre-release builds stay outside the automated stable-tag
workflow.

The release workflow pins `dart_apitool` 0.23.2 and compares the candidate
against the previous reachable stable tag. A breaking public API change must
use the version increment reported by the gate. The gate passes
`--no-ignore-prerelease`; omitting it would weaken checks for development
versions. Before 1.0.0, a breaking change increments the minor version. After
1.0.0, it increments the major version. If there is no previous stable tag, the
workflow extracts the API and rejects missing root exports, establishing the
initial baseline.

The root library is the package's public API boundary. `lib/src` and generated
Pigeon transport files are implementation details unless the root library
exports them. `AsleepPlatform` is intentionally exported as a consumer test
seam, so changing its required methods is a public breaking change.

## Validation commands

Run from the repository root:

```sh
dart format --output=none --set-exit-if-changed \
  lib test example/lib example/test example/integration_test pigeons
flutter analyze
flutter test
(cd example && flutter test)
dart doc
flutter pub outdated
archive_dir="$(mktemp -d)"
archive="$archive_dir/asleep_sdk_flutter.tar.gz"
copy="$(mktemp -d)"
dart pub publish --to-archive "$archive"
tar -xzf "$archive" -C "$copy"
(cd "$copy" && dart pub publish --dry-run)
```

Candidate CI also creates fresh Android and iOS applications with
`flutter create`, resolves `asleep_sdk_flutter` from that exact extracted
publication archive, analyzes the import and `AsleepClient` construction
fixture, and builds each native application. After publication, the `Hosted
consumer` workflow repeats the same checks with an exact pub.dev version:

```sh
gh workflow run hosted-consumer.yml -f version=0.1.0
```

The hosted workflow must not use a path override, Git dependency, API key, or
tracking call. It retries exact-version resolution for up to 50 seconds after
automated publication so a short pub.dev index propagation delay does not
produce a false release failure.

Run the verified latest pana version against a disposable copy because pana
may modify the package. The release workflow pins pana 0.23.15 and rejects a
score deficit greater than 20 points. A proprietary license may carry a score
cost even after the release owner approves it. The CocoaPods-only iOS
integration also carries a score cost because
native `AsleepSDK` 3.2.0 has no verified consumer-accessible Swift Package
Manager artifact, but the package does not claim SPM support.

```sh
copy="$(mktemp -d)"
git archive HEAD | tar -x -C "$copy"
dart pub global activate pana
dart pub global run pana "$copy"
```

The release owner must inspect the disposable copy and dry-run archive for
credentials, private endpoints, local paths, signing material, and
unredistributable binaries. A passing automated scan does not replace that
review.

## References

- [Publishing packages](https://dart.dev/tools/pub/publishing)
- [Automated pub.dev publishing](https://dart.dev/tools/pub/automated-publishing)
- [Pub package scoring](https://pub.dev/help/scoring)
- [Pubspec metadata](https://dart.dev/tools/pub/pubspec)
- [Git dependencies](https://dart.dev/tools/pub/dependencies#git-packages)
- [Custom package repositories](https://dart.dev/tools/pub/custom-package-repositories)
- [Developing Flutter packages](https://docs.flutter.dev/packages-and-plugins/developing-packages)
- [GitHub deployment environments](https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments)
- [GitHub repository rulesets](https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
