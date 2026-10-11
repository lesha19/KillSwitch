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
- **Approval.** The direct rules are in the DIRECT signature like the subscription's, as
  `profile-rule` lines (mihomo: `direct_sig` with `KS_PROFILE_RULES`; Xray: the generator), and so
  is a «proxy» rule whose group can itself go direct. When any of them is there, one more line,
  `profile`, holds **all** the profile's rules in order: its block and proxy rules sit in front of
  its direct ones and shadow them, so the direct rules alone do not say what goes direct (review
  B1). Choosing or updating a profile hands the config over by the passwordless
  `ks core refresh`, which `refresh_check` refuses (exit 3) when the DIRECT signature is neither
  the approved one nor a part of it (below): the app then names the profile in the notice and
  only a click imports it with the admin's password. A profile that only blocks or sends through
  the VPN changes nothing pf lets out and needs no password. pf is never touched by a profile.
- **Fewer lines need no password** (review S5). `refresh_check` also accepts a signature every
  line of which is in the import's approved one (`direct_subset`). Why that never sends more past
  the VPN: every line is a whole part that goes direct — a rule with its target, a group with its
  members, a rule provider with its list, a provider's download proxy, a freedom outbound with its
  settings, the DNS settings as one object, a balancer with its members, the first outbound when
  it is freedom, and the profile with all its rules in order. Dropping a line removes a way out
  and adds none: traffic a dropped direct rule took falls to later rules, which go through the VPN
  or are direct rules still in the approved signature; a group, provider or outbound no longer
  listed no longer goes direct. The profile's part is approved only as the identical `profile`
  line; without it the profile has no rule that can go direct and can only take traffic away from
  the subscription's direct rules (block or VPN in front of them). The profile's direct rules are
  `profile-rule`, never `rule`, so a subscription that copies one is not covered by the profile's
  approval. What this leans on is the rule ADR 0013 already has: a subscription's DIRECT rule,
  once approved, is approved whatever its non-direct rules in front of it do (they are not in the
  signature; a provider dropping one is a passwordless refresh already). Turning a direct profile
  off, deleting it or picking one without direct rules thus needs no password while the
  subscription's own DIRECT is unchanged; a profile's link update that narrows its direct list
  still changes the `profile` line and needs the password (and says so). Compared only with the
  import's approval, not with what a passwordless refresh left running.
- **Visible.** The routing report marks the rules `from: "profile"` with the profile's name;
  «Трафик» › «Правила» shows them with a «профиль» badge; «Проверить адрес» walks them like the
  others (they are ordinary rules).
- **Not automatic.** No switching by Wi‑Fi rule, deep link or schedule, and no profile pushed by a
  subscription header (`routing`/`autorouting`). Automatic switching would need a set of
  approved DIRECT signatures (as Xray's per-host approval, KS-10) so that only exactly approved
  profiles switch without a password; worth it only if people ask. A provider's profile can still
  be added by its link by hand.
- **Not in the settings file** (ADR 0024): a profile link may carry a token, like a subscription
  link; profiles are added again on a new Mac. The links are kept in the keychain ({id: url}, as
  the subscription link), the list in UserDefaults without them; links stored there before move
  on the first load (review N1).
- **Only the person's.** The app takes `x-ks-routing` out of every config of an Xray panel and out
  of a mihomo profile before adding the chosen one, so a subscription cannot bring its own profile
  and have it shown as the person's (review S6).
- **Never bricks updates.** A `geosite:`/`geoip:` code the shipped `geosite.dat` (both cores) or
  `geoip.dat` (Xray) lacks is left out with `geodata-code:…`, shown in «Трафик», since the core
  would refuse the whole config and with it every subscription update (review S3; mihomo's GEOIP
  reads `geoip.metadb`, where an unknown country only never matches). The name may have 64
  characters (code points) in any script; the helper counted bytes before (review S2).
- **The pending change is said.** The app keeps which profile the core has
  (`routingProfileApplied`) and names a waiting change after it: the profile in use that sends
  sites direct, or a direct profile turned off while the subscription also changed. The old rules
  work until the password, and the notices say so.
- **Xray freedom outbound.** The subscription's freedom outbounds join the signature once anything
  goes direct, also when only split apps or the profile do (review S1); they keep their place in
  the signature, so signatures that had them are byte-identical.

## Consequences

- With «Как в подписке» nothing changes in any config.
- A profile in use but waiting for the password: the core keeps the previous config until the
  click; the notice names the profile and says the old rules work until then.
- Profile fetches run one at a time under `updating` and put each result back by id, so a profile
  deleted during a fetch is not overwritten or trapped on (review S4); the daily check fetches the
  profiles and then updates the subscription, one after the other.
- Xray with only split apps going direct through the subscription's freedom outbound asks for the
  password once after this change (the outbound joined the signature).
- Left for later: QR import, replacing a profile of the same name, a profile update interval
  other than a day, showing errors of profiles not in use.
- A profile's direct list makes pf let the core out (egress `rules`), as a subscription's DIRECT
  does; with the subscription already sending something direct nothing changes in pf.
- Not verifiable here (the owner's Mac must not lose its internet): a real Happ/INCY profile link,
  the daily update, the approval notice end to end.
- Tests: `Helper/tests/core-routing-profile.sh` (both cores, `mihomo -t`, `xray run -test`,
  refresh_check), `Tests/RoutingProfileTests.swift`.
