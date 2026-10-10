# ADR 0007: per-server transport overrides, whitelisted in the helper

- Status: accepted (0.10)
- Date: 2026-10-10

## Context

Against DPI a different TLS fingerprint or multiplexing sometimes gets a server through when the
subscription's settings do not. The person should be able to try that per server, without the
overrides becoming a way to change where traffic goes.

Checked against mihomo 1.19.32 (meta-docs; the pinned binary):

- `client-fingerprint`: chrome, firefox, safari, iOS, android, edge, 360, qq, random; on VMess,
  VLESS, Trojan and AnyTLS. `global-client-fingerprint` is gone. **`mihomo -t` accepts any value**
  (tried with a bogus one), so the helper must whitelist.
- `smux` (sing-mux): `enabled`, `protocol` smux | yamux | h2mux (default h2mux), plus padding,
  brutal and connection limits; "only for protocols using TCP transport"; the server must support
  it. Not with an XTLS `flow` (vision).
- No TLS or TCP fragment option exists in mihomo (unlike Xray's `fragment`): not offered.

## Decision

- The app stores overrides per server name (`Transport`, UserDefaults) and puts the ones that
  still apply into the profile as `x-ks-overrides` (`VPNClient.forCore`, after the failover hint):
  `{"<proxy>": {"client-fingerprint": "...", "smux": {"enabled": true, "protocol": "..."}}}`.
  Default everywhere: «Как в подписке» (no key).
- The helper (`core_generate`, right after the proxies are checked) accepts only those two keys,
  only the listed values, only on the protocols above, only for proxies of the profile; `smux`
  takes nothing but `enabled` and `protocol`. Anything else refuses the whole import, as any
  malformed profile does.
- Neither key touches `server`, `port`, `dialer-proxy`, `interface-name` or groups, so the server
  set and the DIRECT signature are unchanged: the app applies a change by the passwordless
  `ks core refresh`, and nothing can route outside the VPN. The subscription itself could already
  set both keys; the overrides add no capability.

## Consequences

- Mux on a server without sing-mux breaks that server; the caption says so and «Как в подписке»
  undoes it.
- A server renamed in the subscription loses its override silently (names are the key).
- `Helper/tests/core-overrides.sh`, `Tests/TransportTests.swift`.
