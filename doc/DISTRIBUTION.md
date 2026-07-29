# Distribution and release contract

Verified on 2026-07-29 against the Dart, Flutter, pub.dev, and GitHub
documentation linked below.

## Current safety boundary

The GitHub repository is private. A pub.dev release is public even when its
source repository is private: any pub user can download the package archive
and its included source files. The package therefore keeps `publish_to: none`
until Asleep explicitly approves public source distribution.

On 2026-07-29, both the pub.dev package page and API endpoint for
`asleep_sdk_flutter` returned HTTP 404. This is evidence that no public package
currently uses the name, not a reservation. Recheck immediately before the
first publish.

No workflow in this repository creates a tag. With the repository's default
settings, the release workflow validates a candidate while its publish and
GitHub Release jobs remain skipped. Those jobs require explicit repository
variables before they can run.

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

The release owner must resolve every item before removing `publish_to: none`:

1. Approve public redistribution of all Dart, Kotlin, Swift, generated Pigeon,
   documentation, and example source in the package archive.
2. Replace the placeholder `LICENSE` with the approved license grant.
3. Recheck that `asleep_sdk_flutter` is still unused on pub.dev.
4. Decide whether the private GitHub repository URL should be exposed as
   package metadata or whether a public documentation and issue URL will be
   provided.
5. Resolve the native Android Maven and iOS CocoaPods artifact access policy
   for external consumers.
6. Confirm the supported Flutter, Dart, Android, iOS, Asleep Android SDK, and
   Asleep iOS SDK version ranges.
7. Review the exact `dart pub publish --dry-run` archive and run the secret
   scan from a clean release commit.
8. Have an authorized human run the first `dart pub publish`.

The first version of a new package cannot use pub.dev automated publishing.
The first human uploader becomes the package uploader. After that release, the
uploader can transfer the package to a verified publisher in pub.dev Admin.
That transfer cannot be reversed back to an individual account.

## Automated pub.dev publishing

After the first manual release:

1. In pub.dev Admin, connect `asleep-ai/asleep-sdk-flutter`.
2. Configure the tag pattern as `v{{version}}`.
3. Require the GitHub Environment named `pub.dev`.
4. In GitHub, create the `pub.dev` Environment with required reviewers and
   prevent self-review when the organization plan supports those controls for
   private repositories.
5. Protect `v*` tags with a repository ruleset that restricts creation,
   updates, deletion, and bypass actors.
6. Remove `publish_to: none` in the explicitly approved public release commit.
7. Set `PUBDEV_PUBLISH_ENABLED=true` only after the first manual publish and
   all preceding controls are complete.
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

GitHub Environment required reviewers for private repositories depend on the
organization plan. If unavailable, the tag ruleset and restricted bypass list
become mandatory controls rather than optional defense in depth.

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
11. For later public releases, confirm the gated OIDC job succeeded.
12. Create the GitHub Release with generated notes, either through the gated
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
copy="$(mktemp -d)"
git archive HEAD | tar -x -C "$copy"
sed -i.bak '/^publish_to: none$/d' "$copy/pubspec.yaml"
rm "$copy/pubspec.yaml.bak"
(cd "$copy" && dart pub publish --dry-run)
```

Run the verified latest pana version against a disposable copy because pana
may modify the package. The release workflow pins pana 0.23.15 and rejects a
score deficit greater than 20 points; the current license and iOS Swift Package
Manager blockers account for that allowed deficit.

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
