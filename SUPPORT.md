# Support

`asleep_sdk_flutter` is an experimental package. It does not include a
response-time SLA or a guarantee that every requested integration will be
supported.

## Contact

Email [nocturne@asleep.ai](mailto:nocturne@asleep.ai) for all non-security
requests. Use one of these subject prefixes so the request can be routed:

| Request | Subject prefix |
|---|---|
| Defect | `[asleep_sdk_flutter bug]` |
| Integration question | `[asleep_sdk_flutter support]` |
| Feature request | `[asleep_sdk_flutter feature]` |

The package source repository and its issue tracker are private. Do not use a
private GitHub URL from pub.dev unless Asleep has explicitly granted your
account access.

For defects and integration questions, include:

- the Flutter, Dart, package, and native SDK versions;
- the Android or iOS version and device type;
- a minimal reproduction or the smallest relevant code sample;
- expected and actual behavior; and
- redacted logs and error codes.

Never send API keys, access tokens, raw audio, sleep reports, user IDs, or
other personal data. If protected evidence is necessary, ask for an approved
transfer method first.

## Documentation

- [Flutter API reference](https://pub.dev/documentation/asleep_sdk_flutter/latest/)
- [Asleep developer guide](https://docs-en.asleep.ai/docs/quickstart)
- [Package page](https://pub.dev/packages/asleep_sdk_flutter)

## Triage and ownership

The verified publisher mailbox is the public intake owner. The repository
owner reviews new requests, routes security reports, maintains native
dependencies, and approves package releases. `CODEOWNERS` records the current
repository review owner; changing that ownership requires a reviewed
repository change.

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
