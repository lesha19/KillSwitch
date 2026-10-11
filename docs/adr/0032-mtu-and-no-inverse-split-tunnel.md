# ADR 0032: the TUN's MTU as a setting; no inverse split tunnel

- Status: accepted (Unreleased, issue #18)
- Date: 2026-10-12
- Decided by the agent («разрабатывай без спроса», roadmap #43); the owner may change any of it.

## Context

Issue #18 (from the Mullvad/IVPN gap research): an MTU setting and an inverse split tunnel —
only the chosen programs through the VPN, everything else past it. The rules that bind both: the
VPN must never leak, protection fails closed (ADR 0015), nothing goes past the VPN without the
admin (ADR 0013), and the DIRECT signature, egress and pf say honestly what goes direct.

Today the MTU is fixed: Xray's tun inbound has `mtu: 1500` (ADR 0020), mihomo's tun section names
none (its own default). A path that drops large packets (some mobile networks, PPPoE, a tunnel
inside a tunnel) shows as pages that load half-way or calls that freeze; a smaller MTU helps.

«Программы без VPN» (`splitapps`, ADR 0013/0020) sends the listed programs direct by a process
rule in the core; everything the core cannot attribute stays in the VPN.

## Decision

### MTU

- `mtu=<n>` in ks's settings, `n` four digits from 1280 (IPv6's minimum, the core runs IPv4 but
  the floor stays honest) to 1500; no line = «Авто», each core exactly as before (Xray 1500,
  mihomo its own). Any other line is a damaged settings file: everything blocked until repaired
  (ADR 0015), as with every other line.
- The generators put it into the TUN only: Xray's `ks-tun` inbound `settings.mtu`, mihomo's
  `tun.mtu`. Servers, pins, DIRECT signature, egress and the rest of the config are byte-for-byte
  the same (tested), so pf is unchanged and no approval is involved. `xray run -test` and
  `mihomo -t` take the configs.
- `ks set mtu auto|<n>`: admin (like every `ks set`), under the core lock, the config rebuilt,
  then the core restarted so the TUN is made anew (about a second; pf blocks meanwhile, the
  protection never goes off). A config that cannot be built keeps the old value. The daemon takes
  it as its own call (`setMTU`, 0 = auto) with the same check (HelperCommand.setMTU).
- The app: Settings › Дополнительно «Размер пакетов VPN» — «MTU»: «Авто», 1500, 1460, 1420, 1400,
  1380, 1340, 1280 (a value set elsewhere stays selectable), with a footnote. The settings file
  (ADR 0024) carries `"mtu": <n>|"auto"`; a reset is «Авто». Журнал защиты: «Размер пакетов VPN
  (MTU): 1380, VPN перезапущен».
- No automatic MTU detection (Mullvad tests on connect): a probe sequence through the tunnel is
  possible later; a wrong automatic value would look like the VPN breaking by itself.

### Inverse split tunnel: not built

It cannot be made fail-closed for the listed programs with this design:

1. **The default flips.** With «only these programs through the VPN», a connection the core
   cannot attribute to a listed program must go direct. Today an unattributed connection stays in
   the VPN (the safe side); inverse, every miss is a leak of exactly the traffic the person asked
   to protect.
2. **Misses are normal on macOS, not rare.** The core finds the program by the connection's local
   address in the system's socket tables. Much of a program's traffic is not its own process:
   Safari's and every WKWebView app's loads come from `com.apple.WebKit.Networking`, background
   downloads from `nsurlsessiond`, names from `mDNSResponder`, App Store apps often through system
   daemons; short UDP/QUIC flows can be gone before the lookup. Listing «Safari» would send
   Safari's pages direct while the app says it is protected.
3. **No second line.** pf can tell processes apart only by user and group (it does so for the
   core's `_ksvpn`), and programs of the same user share both. Nothing outside the core can stop a
   listed program's connection that the core sent direct.
4. What does hold: with the VPN down every program is blocked (pf passes only the core's group),
   and a listed program's connection the core does attribute never falls back to direct. But a
   protection that is fail-closed only when the attribution works is not fail-closed.

Doing it properly needs per-app flow attribution by the system (a Network Extension app proxy
that sees the source app's signing identity, including WebKit's attribution to the app), a
different architecture. «Программы без VPN» stays: its misses go through the VPN.

## Consequences

- Upgrade: no `mtu` line, nothing in any config changes; `ks _regen` does not restart a core for
  this.
- With a small MTU every packet carries less: a bit slower on a good network. The footnote says to
  change it only when pages load half-way or calls break.
- Not verifiable here (the owner's Mac must not lose its internet): a real path with a small MTU,
  mihomo and Xray creating their TUN with the value on this macOS version (`ifconfig utunN` shows
  the MTU after the restart).
- Tests: `Helper/tests/core-mtu.sh`, `Tests/TunnelMTUTests.swift`, `Tests/HelperCommandTests.swift`,
  `Tests/SettingsBackupTests.swift`, `Tests/ProtectionLogTests.swift`.
