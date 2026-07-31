# Security policy

## Supported versions

`asleep_sdk_flutter` is an experimental `0.x` package. Security fixes are
released for the latest published minor line only.

| Version | Security fixes |
|---|---|
| 0.1.x | Supported |
| Earlier versions | Not supported |

Upgrade to the latest published version before reporting a problem when
possible. The support status in this table is updated when a new minor line is
released.

## Report a vulnerability

Do not report a suspected vulnerability through a public issue, discussion, or
social channel. Email [nocturne@asleep.ai](mailto:nocturne@asleep.ai) with the
subject `[asleep_sdk_flutter security] <short description>`.

Include:

- the affected package and native SDK versions;
- the affected Android or iOS versions and device type;
- the impact and the conditions required to reproduce it;
- minimal reproduction steps or a reduced test case;
- any suggested mitigation; and
- a safe way to contact you for follow-up.

Do not include API keys, access tokens, raw audio, sleep reports, user IDs, or
other personal data in the initial report. The maintainers will arrange a
safer transfer method if sensitive evidence is required.

The mailbox owner will acknowledge the report by email, assess severity and
scope, and coordinate remediation and disclosure with the reporter. Response
and remediation times depend on impact and complexity; this experimental
package does not currently offer a fixed response-time SLA. Do not disclose
the issue publicly until a fix is available or a disclosure date has been
agreed with Asleep.

## Scope

This policy covers vulnerabilities introduced by the Flutter package and its
Android and iOS bridges. Reports about the Asleep service, native SDKs, or
developer dashboard may use the same private address and will be routed to the
appropriate Asleep owner.

Questions, integration failures, and feature requests are not security
reports. Use the routes in [SUPPORT.md](SUPPORT.md) for those requests.
