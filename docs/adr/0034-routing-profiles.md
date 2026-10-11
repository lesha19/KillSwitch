# ADR 0034: named routing profiles, chosen by the person, approved like the subscription's DIRECT

- Status: accepted (Unreleased, issue #30)
- Date: 2026-10-12
- Decided by the agent («разрабатывай без спроса», roadmap #43); the owner may change any of it.

## Context

Issue #30 (INCY research, idea 4): user-selectable routing profiles, imported by link or QR,
updated by link, shown as their own source in the #8 transparency view; the app itself adds no
rules. Happ and INCY share a routing format: `Name`, `DirectSites`/`DirectIp`,
`ProxySites`/`ProxyIp`, `BlockSites`/`BlockIp`, `RouteOrder`, plus their own DNS, geodata URLs,
`GlobalProxy`, `DnsHosts`, `DomainStrategy`, `FakeDNS`. Providers and communities publish such
profiles (for example «Russian sites direct» when a subscription does not route them).

ADR 0013: routing is the subscription's, the person's own choices are rules in front of it and
labelled; anything that sends traffic past the VPN is in the DIRECT signature and needs the
admin. KS-10/KS-12: no passwordless path may widen what goes direct, and such a change is told
as a DIRECT change.

## Decision

- **What a profile is:** block / through-the-VPN / direct lists of sites (`domain:`, bare,
  `full:`, `keyword:`, `geosite:`) and addresses (CIDR, `geoip:cc`, `geoip:private`) in the
  Happ/INCY format, plus the order (`RouteOrder`, default block, proxy, direct). Nothing else of
  the format is taken: its DNS servers, geodata URLs (KillSwitch never downloads geodata),
  `DnsHosts`, `DomainStrategy`, `FakeDNS`, and `GlobalProxy: false` («everything else direct» —
  what no rule takes stays the subscription's). The app names what it ignored under the profile.
- **The app** (Settings › «Маршрутизация»): add by an https link (a plain GET without the device
  headers a subscription gets — the link is not the provider's; the redirect and size limits of a
  subscription fetch) or by pasting JSON, base64 or a `happ://routing/add|onadd/…` /
  `incy://routing/add/…` link; at most 10 000 entries, no control characters. One profile in use or
  «Как в подписке» (default). A profile with a link is fetched again once a day; a failure is shown
  next to it and the last good one stays. Deleting the one in use goes back to «Как в подписке».
- **To the helper** as `x-ks-routing` `{name, order, block|proxy|direct: {sites, ips}}`: with
  mihomo a top-level key of the profile (like `x-ks-overrides`), with Xray a key of the panel's
  first config, applied to every host (each host's approved DIRECT signature includes it, KS-10).
- **The helper** (`routing_hint`) checks every entry again; a malformed hint refuses the import,
  an entry it cannot take is left out with the reason (`regexp:`, `ext:`, negations, a bad value,
  `GEOSITE`/`GEOIP` without the shipped geodata). The rules go right after KillSwitch's own and
  before the subscription's: mihomo `DOMAIN-SUFFIX`/`DOMAIN`/`DOMAIN-KEYWORD`/`GEOSITE`/
  `IP-CIDR(6)`/`GEOIP` to `REJECT`, the proxy target or `DIRECT`; Xray `domain`/`ip` rule objects
  to the blackhole, the running server or the freedom outbound (ours if the subscription has
  none). «Through the VPN» is where the subscription sends what no rule takes (mihomo: its MATCH
  group, else its first select group, else KS-DNS; Xray: the running server) — never DIRECT.
- **Approval.** The direct rules are in the DIRECT signature like the subscription's (mihomo:
  `direct_sig` on the rules with them; Xray: `rule` lines), and so is a «proxy» rule whose group
  can itself go direct. Choosing or updating a profile hands the config over by the passwordless
  `ks core refresh`, which `refresh_check` refuses (exit 3) when the DIRECT signature differs from
  the approved one: the app then shows the existing «what goes past the VPN changed» notice and
  only a click imports it with the admin's password. A profile that only blocks or sends through
  the VPN changes nothing pf lets out and needs no password. pf is never touched by a profile.
- **Visible.** The routing report marks the rules `from: "profile"` with the profile's name;
  «Трафик» › «Правила» shows them with a «профиль» badge; «Проверить адрес» walks them like the
  others (they are ordinary rules).
- **Not automatic.** No switching by Wi‑Fi rule, deep link or schedule, and no profile pushed by a
  subscription header (`routing`/`autorouting`). Automatic switching would need a set of
  approved DIRECT signatures (as Xray's per-host approval, KS-10) so that only exactly approved
  profiles switch without a password; worth it only if people ask. A provider's profile can still
  be added by its link by hand.
- **Not in the settings file** (ADR 0024): a profile link may carry a token, like a subscription
  link; profiles are added again on a new Mac.

## Consequences

- With «Как в подписке» nothing changes in any config.
- A profile in use but waiting for the password: the core keeps the previous config until the
  click; the notice says why.
- A profile's direct list makes pf let the core out (egress `rules`), as a subscription's DIRECT
  does; with the subscription already sending something direct nothing changes in pf.
- Not verifiable here (the owner's Mac must not lose its internet): a real Happ/INCY profile link,
  the daily update, the approval notice end to end.
- Tests: `Helper/tests/core-routing-profile.sh` (both cores, `mihomo -t`, `xray run -test`,
  refresh_check), `Tests/RoutingProfileTests.swift`.
