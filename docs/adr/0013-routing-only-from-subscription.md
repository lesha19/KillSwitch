# ADR 0013: routing comes only from the subscription, and the app shows it

- Status: accepted (Unreleased, issue #8)
- Date: 2026-10-10

## Context

Since 0.7 the app had its own routing switch, «Российские сайты напрямую» (`coredirect=1`). It
added `GEOSITE,category-ru,DIRECT`, `GEOIP,RU,DIRECT` and private networks in front of the
subscription's rules, and that same switch was what let pf pass the core (gid `_ksvpn`) to any
address. Two problems followed:

- the provider already decides what goes around the VPN (the subscription has its own
  `GEOIP,RU,DIRECT`, rule sets, sometimes a `DIRECT` member in its group). With the switch on,
  the app's rules came first and overrode the provider; with it off, pf cut every `DIRECT` rule
  of the subscription, so its Russian sites broke without a word;
- nobody could see what actually happened to a connection: which rules were in the config,
  what the generator dropped, what the app added and why.

## Decision

1. **Routing is the subscription's.** `core_generate` takes the subscription's `rules` and
   `rule-providers` in their order and adds no site routing of its own. Removed: `coredirect`
   (setting, `ks set` key, app toggle, Home quick switch, Settings row, daemon command); the
   install drops the `coredirect=` line from `settings`. «Программы без VPN» (splitapps) no
   longer depends on it.
2. **What the app adds is mechanics, named as such:** the hidden `KS-DNS` fallback group
   (DNS and rule-set downloads only ever leave through subscription servers), DoH resolvers
   through it, failover groups (ADR 0005), server pinning, transport overrides (ADR 0007),
   rule-set downloads through `KS-DNS` when the subscription says nothing, the default rule
   when a subscription has no rules (`MATCH,<first group>`, never DIRECT). The user's own
   choices are rules in front of the subscription's and are labelled as such: ad blocking
   (`adblock=1`, opt-in, `GEOSITE,category-ads-all,REJECT`), «Программы без VPN»
   (`PROCESS-PATH-REGEX`/`PROCESS-NAME` rules to DIRECT), «Двойной VPN» (a `dialer-proxy`, no rules).
3. **pf follows the subscription.** The core's group may reach any address only when the
   generated config can send something DIRECT: `core_publish` writes the reasons into
   `/Library/KillSwitch/core/egress` (644, one word per line) and `rules()` passes
   `group _ksvpn` broadly only while that file is not empty:
   - `rules`: a subscription rule or a group member targets DIRECT (`direct_sig` has rule lines);
   - `dns`: the subscription sets `direct-nameserver` or `nameserver-policy` (servers reached
     outside the tunnel);
   - `splitapps`: the user chose programs without VPN.
   Otherwise pf passes the core only to the server addresses, the DoH resolvers and the probe,
   as before. DIRECT targets stay part of the approval signature (`direct_sig`, ADR 0001): a
   refresh that adds or changes them needs the admin (exit 3). The DNS policy that reaches
   servers outside the tunnel is part of the signature too (`dns\t<canonical json>` line).
4. **Rules mihomo cannot take are dropped with a reason, not the whole import:** unknown rule
   type, `SUB-RULE`, a target that does not exist, a rule set that does not exist, `IP-ASN`
   (no ASN database is shipped), `GEOSITE`/`GEOIP` without the shipped geodata (mihomo would
   download it outside the tunnel). Providers stay fail-closed as before. Private-network
   `IP-CIDR` rules of the app are gone: `route-exclude-address` already keeps the LAN out of
   the tunnel.
5. **Sniffer and DNS policy come from the subscription, validated.**
   - `sniffer`: `enable`, `parse-pure-ip`, `override-destination`, `force-dns-mapping`,
     `sniff.{TLS,HTTP,QUIC}.{ports,override-destination}`, `force-domain`, `skip-domain`
     (patterns, `geosite:`/`rule-set:` only when present). Names checked against mihomo
     1.19.32 (`-t` on generated configs). Without one, KillSwitch enables a routing-only
     default: TLS 443/8443, HTTP 80/8080-8880, QUIC 443, `parse-pure-ip`,
     `override-destination: false` (the name is used to pick the rule, the connection still
     goes to the address the program asked for). It is listed under «Добавлено KillSwitch».
   - `dns`: `fake-ip-filter`, `nameserver-policy`, `direct-nameserver`,
     `direct-nameserver-follow-policy`, `respect-rules` are taken; servers must be an address or
     a `udp/tcp/tls/https/quic/h3` URL (no `system`, no `dhcp://` — the LAN's resolver), a `#via`
     must name an existing proxy or group. `enable`, `listen`, `enhanced-mode`, `nameserver`,
     `default-nameserver` and the rest stay ours (reported as «KillSwitch задаёт сам»).
     With `respect-rules` the app also sets `proxy-server-nameserver` to its DoH through
     `KS-DNS`, as mihomo requires.
   - The app passes `sniffer` and `dns` on (ProfileConverter keeps them) and remembers the
     names of the other top-level keys it leaves out, for the window.
6. **A routing report.** `core_generate` writes `core/routing.json` (644, version 1): the
   rules in config order with `from` (subscription with its index, or killswitch), what was
   dropped with a reason code, providers (type, behavior, format, URL host only, interval,
   size, inline payload up to 1000 entries), groups and proxies (name and type only), what was
   added and why, the sniffer and DNS taken (DNS server URLs cut to host), the egress reasons.
   No proxy objects, passwords, UUIDs, URL paths or query strings: the file is world-readable
   on purpose (the app reads it without the helper).
7. **Live connections.** `ks core connections` (passwordless: sudoers, `passwordless_args_ok`,
   the daemon's `HelperCommand.coreConnections`) returns the core's open connections with only
   what the window shows: id, host, address, port, network, process name and path, rule and
   payload, chains, bytes, start; plus totals and each rule provider's size and update time.
   No source address or port, uid, inbound or DNS mode; control characters replaced, strings
   capped. `find-process-mode: always`, so the core knows the program of every connection.
8. **«Трафик» in the window** (spec §5.6): «Правила» (the report), «Соединения» (polled once a
   second only while that tab is on screen and not paused), «Проверить адрес». mihomo has no
   API to ask which rule a host would meet, so the check walks the rules in Swift for an
   ordinary visit (TCP to 443): domains, keywords, regex and wildcards, CIDR, `GEOSITE` and
   `GEOIP` with the shipped geodata, inline rule sets, AND/OR/NOT. What it cannot tell
   (programs, rule sets the core downloads, the address a name will resolve to) is listed as
   «Ответ приблизительный» with the reason, never guessed.

## Consequences

- Upgrading from 0.14 with `coredirect=1`: the setting is dropped; if the subscription has
  DIRECT rules, they were already in `approved-direct`, so pf lets the core out for them
  without a new password. With `coredirect=0` and DIRECT rules in the subscription, those
  rules start working after the upgrade (they were silently cut by pf before) — that is the
  point of this decision; the approval signature had already been granted for them.
- A subscription without DIRECT rules keeps the tightest pf: the core reaches only servers.
- People who relied on the app's own RU list need a subscription that routes RU directly;
  the window says which rules there are and where traffic goes.
- `geosite.dat`/`geoip.metadb` are still shipped: for the subscription's `GEOSITE`/`GEOIP`
  rules and ad blocking.
- The report and the connections list never carry secrets; reading them needs no password.
