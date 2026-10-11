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
none, so mihomo takes 9000 (v1.19.32, `listener/sing_tun/server.go`: `if tunMTU == 0 { tunMTU =
9000 }`; its docs show the same value in the example). So «Авто» is not one number: 1500 with Xray,
9000 with mihomo.

What the TUN's MTU reaches is narrower than with a kernel VPN. Both cores end the programs' TCP
in a userspace stack (gVisor) and open their own TCP to the server through the physical interface,
whose MSS and path MTU discovery are the system's: the TUN's MTU does not size the packets that
actually cross the path for TCP. It sizes what programs hand the TUN: the MSS offered to local TCP
(only between the program and the core) and, mainly, UDP datagrams (calls, games, QUIC), which a
core relays as they come and which a smaller MTU keeps small. So it may help calls or games that
freeze on a path dropping large packets (some mobile networks, PPPoE, a tunnel inside a tunnel); it
is unlikely to fix pages that load half-way. It is a troubleshooting setting, and whether it helps
needs a live check on such a path.

«Программы без VPN» (`splitapps`, ADR 0013/0020) sends the listed programs direct by a process
rule in the core; everything the core cannot attribute stays in the VPN.

## Decision

### MTU

- `mtu=<n>` in ks's settings, `n` four digits from 1280 (IPv6's minimum, the core runs IPv4 but
  the floor stays honest) to 1500; no line = «Авто», each core exactly as before (Xray 1500,
  mihomo 9000). Any other line is a damaged settings file: everything blocked until repaired
  (ADR 0015), as with every other line.
- The generators put it into the TUN only: Xray's `ks-tun` inbound `settings.mtu`, mihomo's
  `tun.mtu`. Servers, pins, DIRECT signature, egress and the rest of the config are byte-for-byte
  the same (tested), so pf is unchanged and no approval is involved. `xray run -test` and
  `mihomo -t` take the configs.
- `ks set mtu auto|<n>`: admin (like every `ks set`), under the core lock. The config is built
  with the value on a copy of the settings first and the value stored only after that (as `ks set
  multihop`); then the core is restarted exactly once so the TUN is made anew (about a second; pf
  blocks meanwhile, the protection never goes off). Xray has no reload, and mihomo's API reload
  keeps the old TUN, so for both it is one `launchctl kickstart -k`, not a reload and a restart. A
  core that was running must come up again (`core_up`, ~5 s); if it does not, or the restart itself
  fails, the previous value, config and its files go back and the core is restarted with them
  (logged, the app shows the message). A config that cannot be built keeps the old value and
  restarts nothing. The copy of the settings the build ran on becomes the settings, so whatever
  the build changed in it reaches the app too (a double VPN entry it cannot use goes off and
  «Двойной VPN выключен» is told, as on every other rebuild); a rollback puts the settings back with
  the config. A config byte for byte the old one (Xray's «Авто» and 1500) is stored without a
  restart. The same value again changes nothing, except after a change cut short (killed between
  the commit and the restart: its `.prev` copies are still there): that one is undone, logged, and
  the change made again. With the VPN off (no job) or no subscription yet the value is only stored
  and used at the next start or import. The journal says «VPN перезапущен» only when a running
  core was restarted and came up (a job loaded but not running is started, not «restarted»). The daemon takes
  it as its own call (`setMTU`, 0 = auto) with the same check (HelperCommand.setMTU).
- The app: Settings › Дополнительно «Размер пакетов VPN» — «MTU»: «Авто», 1500, 1460, 1420, 1400,
  1380, 1340, 1280 (a value set elsewhere stays selectable), with a footnote. The settings file
  (ADR 0024) carries `"mtu": <n>|"auto"`; a reset is «Авто». Журнал защиты: «Размер пакетов VPN
  (MTU): 1380, VPN перезапущен» only when the core was restarted (`tunnel MTU: <v>, VPN restarted`),
  else «Размер пакетов VPN (MTU): 1380»; a rollback: «VPN не запустился с размером пакетов 1280 —
  вернули прежний: Авто». «Скопировать диагностику» names the MTU.
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
   downloads and uploads of many apps from `nsurlsessiond`, App Store apps often through system
   daemons; short UDP/QUIC flows can be gone before the lookup. (DNS is not the example: the
   system's lookups go to the core's own `ks-dns` inbound and through the VPN whatever process asked.) Listing «Safari» would send
   Safari's pages direct while the app says it is protected.
3. **No second line.** pf can tell processes apart only by user and group (it does so for the
   core's `_ksvpn`), and programs of the same user share both. Nothing outside the core can stop a
   listed program's connection that the core sent direct.
4. What does hold: with the VPN down every program is blocked (pf passes only the core's group),
   and a listed program's connection the core does attribute never falls back to direct. But a
   protection that is fail-closed only when the attribution works is not fail-closed.

Nor is it a parity gap: Mullvad's macOS split tunnel is the exclude form only (as «Программы без
VPN»), and IVPN's inverse mode is Windows/Linux only and IVPN has no split tunnel on macOS at all
(docs/research/mullvad-ivpn-gap-2026-10.md, the split tunneling row).

Doing it properly needs per-app flow attribution by the system (a Network Extension app proxy
that sees the source app's signing identity, including WebKit's attribution to the app), a
different architecture. «Программы без VPN» stays: its misses go through the VPN.

## Consequences

- Upgrade: no `mtu` line, nothing in any config changes; `ks _regen` does not restart a core for
  this.
- With a small MTU every packet carries less: a bit slower on a good network. The footnote calls it
  a troubleshooting setting that may help calls or games, and «Подробнее» says pages are usually not
  affected and to go back to «Авто» if it does not help.
- Not verifiable here (the owner's Mac must not lose its internet): a real path with a small MTU,
  mihomo and Xray creating their TUN with the value on this macOS version (`ifconfig utunN` shows
  the MTU after the restart), and whether a smaller value helps anything in practice (needs a live
  check).
- Tests: `Helper/tests/core-mtu.sh` (the restart chain runs for real with only launchd, lsof, pf
  and the core binaries replaced: one restart per core, rollback, no-op, VPN off), `Tests/TunnelMTUTests.swift`, `Tests/HelperCommandTests.swift`,
  `Tests/SettingsBackupTests.swift`, `Tests/ProtectionLogTests.swift`.
