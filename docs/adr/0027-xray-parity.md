# ADR 0027: double VPN, own servers and «Проверить адрес» with Xray

- Status: accepted (Unreleased, issue #33)
- Date: 2026-10-11
- Decided by the agent («разрабатывай без спроса», roadmap #43); the owner may change any of it.

## Context

With Xray (ADR 0020) three things of the fallback way were missing: «Двойной VPN» was greyed out,
own servers added by link were not passed to the core, and «Трафик» had no «Проверить адрес».
Xray runs one host of the panel's array (one full config) at a time; every host's servers are
approved at import, and a passwordless host switch is measured against every host's DIRECT
signature (KS-10). Nothing new may go past the VPN without the admin (ADR 0013), and every new
path must fail closed.

## Decision

### Double VPN

- `multihop=<host>` (the same setting and `ks set multihop`, admin) names a **host** of the
  subscription with Xray. `core_generate_xray` copies that host's first server (its first
  vless/vmess/trojan/shadowsocks outbound with a tag) as the outbound `ks-entry`, tamed like the
  others (address pinned to the approved IPv4, `sendThrough`, interface and mark removed), and sets
  `streamSettings.sockopt.dialerProxy: "ks-entry"` on every server of the running host that is not
  already reached through another of its outbounds (that one is chained through the entry in turn).
  `dialerProxy`, not `proxySettings`: the exit keeps its own TLS/Reality and transport.
- Nothing new goes past the VPN: the servers for pf (every host's, approved at import), the DIRECT
  signature and egress are the same as without it (tested). No rule leads to `ks-entry`.
- The probes (`ks-ping-*`, ADR 0023) of every host but the entry go through `ks-entry` too
  (review round 2): otherwise each exit saw the Mac's real address every minute, against «вход
  видит твой адрес, выход — сайты»; the ping shown is then that of the chain. pf is **not**
  narrowed to the entry's address: `refresh_check` measures servers against the import's, and a
  narrower list would flag the subscription's IP-literal servers on the next refresh; the core may
  reach every approved server as before, and no outbound but the entry's and its probe dials one.
- `ks set multihop <host>` (admin) refuses a host not in the subscription, the running exit, or one
  the observatory finds dead. With Xray running, the chain must answer (the diagnostics probe through
  the fetch inbound) after the restart; otherwise double VPN goes off again, logged — fail closed
  (pf blocks throughout) but recoverable, never a VPN left on a dead entry.
- An entry the build cannot use later (gone from a refreshed subscription, chained itself, a
  subscription tag `ks-entry`) turns double VPN **off** with a line in `events.log`, and the config
  is built one hop: refusing the build (round 1) would have refused every refresh and rebuild until
  the person found the setting. The app reads the setting, so the switch shows off. The entry being
  the running host itself is one hop, as with mihomo; `ks core select` refuses the entry as the exit
  and the app does not offer it, so the screen never says «A → A».
- Failover (ADR 0023) never picks the entry host as the new exit, does nothing while the entry's own
  probe is dead (every exit is unreachable through it; moving the exit would only churn), and never
  picks an own server («(свой)», whose routing differs).
- `ks set core` turns double VPN off: the entry names a server in the other core's format. A
  `multihop=` kept from the mihomo era (before this ADR `set_core` did not clear it) is turned off
  by the upgrade's `ks _regen` while the Xray report has no `targets` (written before this ADR),
  logged; otherwise a mihomo name matching a host would quietly turn double VPN on.

### Own servers added by link

- The app (`XrayManual`) turns each own server the main way can use into a **host of its own**
  appended to the panel's array: `remarks` «<name> (свой)» (unique against the hosts), its server
  as the only outbound (tag `proxy`), `dns.servers` 1.1.1.1 and 8.8.8.8 with `UseIPv4`, no routing.
  What no rule takes goes to the first outbound, so everything goes through it, DNS too; with no
  freedom outbound nothing in it can go direct (empty egress and DIRECT signature, tested). The
  subscription's routing does not apply to an own server (with mihomo it did: there the own
  servers join the subscription's profile); that is the safer side.
- Taken: vless, vmess, trojan, shadowsocks without a plugin; tcp, ws, httpupgrade, grpc, xhttp
  (path, host, mode, padding); TLS or Reality. Left to the other way, with the reason under the
  server in Settings: other protocols (the helper takes only these from Xray configs), a plugin,
  h2, xHTTP's XMUX or separate download server, a skipped certificate check, an IPv6 address
  (the helper lets the core reach IPv4 servers only), a server name the helper's `host()` refuses
  (`g_x.example.com`): one such server is skipped, it never blocks the import of the others. A
  first setup with only such servers sets up the other way.
- Names come from the link's `#fragment`: control characters are removed and the name is cut to
  200 bytes, so «<имя> (свой) (n)» passes `valid_name` (settings, `ks core select`). The helper's
  `check()` refuses a subscription with a host name with control characters or over 256 bytes.
- The helper treats the array as the panel's: every element checked, server names pinned, a new
  address needs the admin (refresh exit 3, then the import with the password), as with mihomo.
  Nothing in the helper changed for this.

### «Проверить адрес»

- `routing.json` of Xray carries each rule also as the core's object (`xray`), the kind of every
  outbound tag (`targets`: vpn, direct, block, dns) and `fallback` (the first outbound, which
  takes what no rule does; an untagged first outbound has its kind under the tag ""). Tags and
  matchers only, no server object (no secrets; tested). A rule object over 16 KB is left out of
  the report; the app lists that rule under «Ответ приблизительный».
- A report of a helper before this ADR (Xray, no `targets`) gets no answer but «обнови службу»,
  never «через VPN» for every site.
- The app walks those rules for an ordinary visit: TCP to 443 into our TUN (`ks-tun`), sniffed as
  TLS. All conditions of a rule must hold, a list holds when one entry does. Domains:
  `domain:`, `full:`, `keyword:`/bare, `regexp:`, `dotless:`, `geosite:` (shipped geosite.dat);
  addresses: IP/CIDR, `geoip:<cc>`, `geoip:!<cc>`, `geoip:private`; port, network, inboundTag,
  protocol (`tls`), user (none on our TUN). What cannot be told — a program, `ext:` lists, the
  address a name gets (Xray matches IP rules against the real address from the TUN), source and
  local addresses or ports — is listed under «Ответ приблизительный». A balancer with a direct
  member is a caveat. No match: the fallback, not «напрямую». `geoip:private` (and mihomo's
  `GEOIP,LAN`) also counts 0.0.0.0/8, 192.0.0.0/24, 198.18.0.0/15 and the documentation networks.

## Consequences

- With double VPN on and the entry host dead, the exit cannot be reached and failover waits; the
  person turns double VPN off or picks another entry (the app offers only entries not known dead).
- An own server is pinned to the IPv4 its name had at import, like the panel's hosts; a server
  that cannot be resolved refuses the import, as with mihomo.
- Not verifiable here (the owner's Mac must not lose its internet): the chain through a real entry
  (XTLS Vision over `dialerProxy`), an own server's traffic and DNS, the time to connect. `xray run
  -test` takes every generated shape (tests).
- Tests: `Helper/tests/core-xray-multihop.sh`, `core-xray.sh` (own servers, report),
  `core-xray-ping.sh` (failover and the entry), `Tests/XrayManualTests.swift`,
  `Tests/RoutingTests.swift` (`XrayAddressCheckTests`).
