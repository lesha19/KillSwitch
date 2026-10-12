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
- **A proxy rule in the `profile` line says «proxy», not the server's tag** (Xray, final 0.20.0
  review; decided by the agent). Its target is the running host's leading server, and the
  transport step of escalation (ADR 0030) makes another outbound of that host lead; with the tag in
  the line, that step's passwordless rebuild failed the server switch check (KS-10, exit 3) for
  every profile with proxy and direct rules, and the ladder skipped it. The marker cannot hide a
  change of what goes direct: the target is always one of the host's own VPN servers (the first
  vless/vmess/trojan/shadowsocks outbound with a tag; the generator refuses the build otherwise),
  never freedom and never a balancer, which may have a freedom member, so every rule so marked
  sends its traffic through the VPN whichever server leads, exactly as before. What goes direct
  is still in the line by its own tag, rule by rule and in order, and in the `profile-rule` lines.
- **Fewer profile lines need no password** (review S5, narrowed in the re-review, F1).
  `refresh_check` also accepts a signature whose lines other than the profile's own
  (`profile-rule`, `profile`) and the freedom outbounds (`outbound`) are exactly the approved
  ones in the same order, and whose `profile-rule`, `profile` and `outbound` lines are each among
  the approved ones (`direct_subset`). A first version accepted any subset of lines; that was
  wrong: a subscription rule to a group that can also go direct (mihomo) or to a balancer with a
  freedom member or fallback (Xray) is itself a signature line, and dropping or moving it lets what
  it took fall onto an approved DIRECT rule behind it — VPN traffic turned direct. So nothing of
  the subscription's part (its rules, groups, providers, DNS, balancers, the default, split apps'
  rules) may be fewer or move. Why the profile's part may: the profile's rules all come before the
  subscription's; it is approved only as the identical `profile` line (all its rules in order),
  and without that line no rule of it can go direct, so it can only take traffic away from the
  subscription's rules (block or VPN in front of them), which are then exactly as approved, in
  order. The profile's direct rules are `profile-rule`, never `rule`, so a subscription that copies
  one is a change of its own part. `outbound` lines are all the approved ones in their order, or
  the whole signature is empty (nothing goes direct at all; a direct line left without its
  outbounds is not taken, Codex P1): they pin the freedom outbounds' settings and are printed for every one of them once
  anything goes direct, so with the subscription's part unchanged they vanish only when nothing
  goes direct any more (the profile turned off over a subscription with nothing direct). Fewer or
  moved is not taken: an untagged first freedom outbound is Xray's default, whose `default` line
  names no tag, so dropping or swapping one would make another — a `redirect`, say — the default
  (re-review 2 N-A, Codex P1). What remains leans on ADR 0013's rule
  that a subscription's DIRECT rule, once approved, stands whatever non-direct rules in front of it
  do (they are not in the signature). Turning a direct profile off, deleting it or picking one
  without direct rules thus needs no password while the subscription's part is unchanged; a
  profile's link update that narrows its direct list still changes the `profile` line and needs
  the password. Compared only with the import's approval, not with what is running: turning a
  direct profile off is passwordless only when nothing else changed since the import — a split
  app the admin added later, for instance, makes it a change of the subscription's part (tagged
  so) until the next import (re-review 2 N-C; comparing with the running signature too was left
  out, since not every way the running one changes was checked to be the admin's).
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
- **The pending change is said.** The refusal names the part that is not approved
  (`direct_parts`: ` [profile]`, ` [subscription]`, ` [profile,subscription]` after «(DIRECT)»),
  and the app names the notice after it. `[profile]` means only the profile's lines differ, which a
  provider can still cause (mihomo: the group its «через VPN» goes to; Xray: the freedom outbound
  its direct rules use), so that text says the change can come from the profile or from the
  subscription (re-review 2 N-B; telling them apart would need the approved profile itself kept): «Профиль «…» меняет, что идёт мимо VPN», or «Подписка и
  профиль «…» меняют…» with the provider's part told as the provider's; an older helper says
  nothing, read as the subscription's. A block/proxy-only profile can be a profile part too (its
  «через VPN» group holds DIRECT). The old rules work until the password, and the notices say so
  (re-review F4; an earlier version guessed from the profile it applied last and blamed the
  profile for a provider's change).
- **Egress.** mihomo's egress counts `profile-rule` lines, so a subscription with nothing direct
  of its own and a direct profile gets egress `rules` (re-review F2).
- **Xray freedom outbound.** The subscription's freedom outbounds join the signature once anything
  goes direct, also when only split apps or the profile do (review S1); they keep their place in
  the signature, so signatures that had them are byte-identical.

## Consequences

- With «Как в подписке» nothing changes in any config.
- A profile in use but waiting for the password: the core keeps the previous config until the
  click; the notice names the profile and says the old rules work until then.
- Profile fetches run one at a time under `updating` and put each result back by id, so a profile
  deleted during a fetch is not overwritten or trapped on (review S4); the daily check fetches the
  profiles and then updates the subscription, one after the other. A fetch ends within 60 s
  (30 s without a byte), so it cannot hold `updating` for long (re-review F5).
- A keychain read that fails is not «no links»: nothing is written over then, and a later save
  keeps the links it did not load.
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
