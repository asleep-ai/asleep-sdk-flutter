# Support

`asleep_sdk_flutter` is an experimental package. It does not include a
response-time SLA or a guarantee that every requested integration will be
supported.

## Public intake

Use the [public issue tracker](https://github.com/asleep-ai/asleep-sdk-flutter/issues)
for non-security package requests:

| Request | Issue content |
|---|---|
| Defect | Reproduction, expected behavior, and actual behavior |
| Integration question | Intended integration and the point that is blocked |
| Feature request | Use case, proposed behavior, and alternatives considered |

The [source repository](https://github.com/asleep-ai/asleep-sdk-flutter) and
its issue tracker are public. Search existing issues before opening a new one.

For defects and integration questions, include:

- the Flutter, Dart, package, and native SDK versions;
- the Android or iOS version and device type;
- a minimal reproduction or the smallest relevant code sample;
- expected and actual behavior; and
- redacted logs and error codes.

Never send API keys, access tokens, raw audio, sleep reports, user IDs, or
other personal data. If protected evidence is necessary, ask for an approved
transfer method first.

For account, credential, or service requests that should not be public, email
[nocturne@asleep.ai](mailto:nocturne@asleep.ai) with the subject
`[asleep_sdk_flutter support]`. Suspected vulnerabilities follow the separate
private process in [SECURITY.md](SECURITY.md).

## Documentation

- [Flutter API reference](https://pub.dev/documentation/asleep_sdk_flutter/latest/)
- [Asleep developer guide](https://docs-en.asleep.ai/docs/quickstart)
- [Package page](https://pub.dev/packages/asleep_sdk_flutter)
- [Source repository](https://github.com/asleep-ai/asleep-sdk-flutter)
- [Issue tracker](https://github.com/asleep-ai/asleep-sdk-flutter/issues)

## Triage and ownership

The repository owner reviews public issues and pull requests, routes private
support and security reports, maintains native dependencies, and approves
package releases. The verified publisher mailbox owns private non-security
intake. `CODEOWNERS` records the current repository review owner; changing
that ownership requires a reviewed repository change.

Defects that can be reproduced in this Flutter package are prioritized ahead
of feature requests. Native SDK, service, credential, and account requests are
routed to their Asleep owners after initial triage.

## Experimental compatibility and deprecation policy

Before version 1.0.0, minor releases may include breaking API, behavior,
platform, toolchain, or native SDK changes. Patch releases should remain
backward-compatible within the same minor line.

When practical, an API scheduled for removal is deprecated for at least one
subsequent minor release and documented in the changelog. Immediate removal
may be necessary for a security, privacy, legal, or unusable-API issue.
Consumers should pin an appropriate version constraint, read the changelog,
and validate upgrades before production rollout.
