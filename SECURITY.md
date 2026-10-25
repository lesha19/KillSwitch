# Security policy

KillSwitch runs a root helper, loads pf rules and installs a content filter, so a bug here can
leak traffic or give a local user root. Reports are welcome and handled first.

## Maintainer

Aliaksei Zhuravel ([@lesha19](https://github.com/lesha19)) maintains KillSwitch and is
responsible for its security: triage, fixes, releases and advisories.

## Supported versions

Only the latest release gets security fixes. The app updates itself (Sparkle, signed with
an EdDSA key; the public key is in `project.yml`).

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private report form:
**Security → Report a vulnerability** on this repository
(<https://github.com/lesha19/KillSwitch/security/advisories/new>).
If you cannot use GitHub, write to zhuravel.lesha2005@gmail.com.

Please include the version (`ks status` or «О программе»), macOS version, and steps or a proof
of concept. Russian or English.

What to expect:

- acknowledgement within 3 days;
- a fix or a plan within 14 days for High and Critical, 30 days for the rest;
- a GitHub Security Advisory (and a CVE through GitHub when it applies) once the fix is
  released, crediting you unless you ask not to be named.

## In scope

- `Helper/` — the root helper `ks`, its LaunchDaemons and install / uninstall scripts;
- `Filter/` — the network content filter;
- `App/`, `CLI/`, `Widget/`, `Shared/` — privilege boundaries, the helper protocol, keychain use,
  subscription parsing, update checks;
- leaks: any way traffic or DNS leaves the Mac outside the tunnel while protection is on.

Out of scope: bugs in mihomo or Xray themselves (report upstream), attacks that need root
already, and VPN servers or subscriptions run by third parties.

## Past audits

Internal audits and hardening notes are public in [`docs/security/`](docs/security/), with the
findings and how each was fixed.
