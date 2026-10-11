# ADR 0020: Xray is the main core, mihomo the fallback

- Status: accepted (Unreleased); research `docs/research/xray-core-2026-10.md`
- Date: 2026-10-10
- Owner decision 2026-10-10: pure Xray-TUN as the main core (like Happ), mihomo kept as a choice in
  Settings; no connections list in «Трафик» with Xray is accepted. Xray-core v26.9.30 pinned.
  Routing comes only from the subscription (ADR 0013).

## Context

On the owner's Mac 10–15% of TCP connections through our mihomo tunnel got nothing back; Happ
(libXray in a packet tunnel) to the same server lost 0.6% (system logs, 2026-10-10). Xray-core has
its own macOS TUN since v26.1.18, sets its routes since v26.6.27 (`autoSystemRoutingTable`) and
binds its own sockets to the physical interface (`autoOutboundsInterface`). Remnawave serves Xray
clients the full Xray config (an array of configs, one per host).

## Decision

- **Files.** `Helper/fetch-xray.sh` pins Xray-core v26.9.30 (`Xray-macos-arm64-v8a.zip`, sha256
  `4b363bd9…3c7dce`, the same in the release's `.dgst`), keeps only the binary and signs it with
  the core's identifier `com.lesha19.KillSwitch.core`: the content filter (`TrustedCode`) trusts
  by identifier, so it needs no change; one core runs at a time. `fetch-geodata.sh` adds
  MetaCubeX `geoip.dat` of the already pinned commit (sha256 `116cc0f0…df6093`; `geoip:by` is in
  it, checked with `xray run -test`). `release.sh` checks, signs, ships and publishes both.
- **The choice.** `core=xray|mihomo` in `/Library/KillSwitch/settings` (`ks set core`, admin).
  Without the line: mihomo, so every install before this keeps running what it runs.
  `install.sh` writes `core=xray` on an install that has no mihomo config or subscription yet
  (new installs). Existing installs are not switched by the upgrade: the switch needs the
  subscription in Xray's format, fetched by the app and imported with the admin password, and a
  subscription that is not a Remnawave one may not have it. The app offers the switch in
  Settings (one password).
- **Switching** (`ks set core`) stores the choice and removes the chosen core's config of an older
  import; the app then imports the subscription for it, and `ks core on` swaps the launchd job (both
  plists are kept in `core/`, the job label stays `local.killswitch.core`, so ks, the watchdog,
  sudoers and uninstall are unchanged). A running core keeps running until that swap: with
  protection on, the subscription in the new format can only be fetched, and its server names
  resolved, through it (addendum 2026-10-11: stopping it first left the Mac without any VPN).
  `install.sh` meanwhile keeps the running job.
- **The config** (`core_generate_xray`): the panel's array; every element is checked and all
  their servers approved at import (servers, pins, direct signature), so switching between the
  subscription's hosts (`ks core select Сервер <remarks>`, stored as `xrayserver=`) needs no
  password. Outbound protocols: vless, vmess, trojan, shadowsocks, freedom, blackhole, dns,
  loopback; anything else refuses the import. Server names are pinned to IPv4 as with mihomo,
  the name kept as `serverName`. Dropped with a reason in the report: `api`, `stats`, `reverse`
  and other unknown sections, rules with unknown keys (webhook) or a missing target, DNS servers
  `localhost` (that is our own 127.0.0.1:53) and `fakedns`; `sendThrough` and a bound
  interface/mark are removed. Ours: the inbounds — TUN with `gateway 198.18.128.0/30` (the utun
  gets `198.18.128.1 = CORE_TUN_ADDR`, so pf, `vpn_ifaces` and `foreign_tuns` know it as before),
  `autoSystemRoutingTable ["0.0.0.0/0"]`, `autoOutboundsInterface "auto"`, sniffing from the
  template's inbound; `dokodemo-door` on 127.0.0.1:53 for the system DNS, routed first to the
  template's `dns` outbound (one is added if it has none); the fetch inbound on 127.0.0.1:47890
  routed to the first server, never direct (ADR 0016); log `warning` without an access log.
  The person's choices go before the subscription's rules: ad block (`geosite:category-ads-all`
  to blackhole, only with the shipped geosite.dat) and «Программы без VPN» (`process` rule to
  freedom). «Двойной VPN» is refused with Xray for now (since ADR 0027: an entry host, `dialerProxy`).
- **pf unchanged.** The core runs with gid `_ksvpn`; `egress` is `rules` when a rule, a balancer
  member or the first outbound (what no rule takes) is freedom, `dns` when only DNS servers'
  queries go to freedom, `splitapps` for the programs; the direct signature holds those rules,
  balancers, freedom outbounds and the DNS section.
- **Checked** with `xray run -test -format json` before a config is put in place (the file
  names do not end in .json).
- **Without an API** (0.18.0: a stats API for counters only, ADR 0021). `ks core proxies` answers from the report in mihomo's shape: one Selector
  `Сервер` of the subscription's hosts. Delay, traffic and connections answer «С ядром Xray это
  недоступно»; the app hides the connections list. A server switch or a setting restarts the core
  (about a second; pf blocks meanwhile).

## Consequences

- No connections list, no ping, no speed in the menu bar with Xray yet (the stats API on a unix
  socket is the next step). Ping, speed and failover came with ADR 0021 and ADR 0023.
- Own servers added by link (manual servers) are mihomo proxies and are not passed to Xray (since
  ADR 0027: each one the main way can use is a host of its own in the array).
- Not verifiable here (the owner's Mac must not lose its internet): the utun address and routes
  of a running Xray, DNS through 127.0.0.1:53, routes after `kill -9`, LuLu with a new binary, the
  Remnawave answer through the fetch inbound.
