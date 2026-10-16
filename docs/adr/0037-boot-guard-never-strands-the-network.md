# ADR 0037: the boot window guard never strands the network

- Status: accepted (0.20.0); amends the boot window guard (setting `wifiguard`, `ks watch`) and ADR 0012
- Date: 2026-10-15

## Context

The boot window guard (`shutdown_guard` in Helper/ks) turns off every network service on a physical
port when launchd stops the watchdog at shutdown, writes them to `/Library/KillSwitch/wifi-off-by-ks`,
and the watchdog turns them back on once the pf rules are loaded, so nothing gets an address before
the rules exist.

The incident of 15.10.2026, from the owner's sysdiagnose (docs/security/audit-2026-10-15.md, section 0):
17:02:05 restart, the guard turned off Wi‑Fi, the AX88179A adapter and Thunderbolt Bridge. 17:05:28
login, the watchdog started; 17:05:29.6 rules loaded and `networksetup -setnetworkserviceenabled Wi-Fi on`
ran once. configd only saw en0 at 17:05:30.1: the call did nothing, without an error. The mark was
deleted anyway and nothing tried again. 17:07 KillSwitch was uninstalled: no mark, so Wi‑Fi stayed
off (`__INACTIVE__ = 1` in the 17:14 snapshot). The owner got the network back by deleting
SystemConfiguration files by hand.

Defects (audit B1–B8): one `on`, never checked, the mark deleted regardless; a second shutdown
truncated the mark (disabled services are listed as `(*) Name`, which the parser skipped); `on` only
with the rules loaded, so a failed pf or a crashed watchdog meant no network without end; the
Login Items branch did not restore an existing mark; services by name only; `networksetup` without
a timeout in the one-second loop; uninstall and `ks netrestore` deleted the mark without a check;
the app's banner only showed with the watchdog gone.

The owner (15.10.2026): keep the guard, but fix it.

## Decision

Invariants:

1. **A mark line goes only when the service is verified on**: `networksetup -getnetworkserviceenabled`
   says `Enabled`, its device (when the mark knows it) is known to configd (`scutil`,
   `State:/Network/Interface`), and both still hold when checked again at least 3 s later (a first `on`
   that did nothing is caught by the second look). The mark goes only when no line is left. One
   function, `net_back`, for the watchdog, `ks netrestore`, install.sh (through `ks netrestore`, before
   the watchdog changes) and uninstall.sh. A device missing from the kernel (`ifconfig -l`) is not
   waited for: after 90 s `Enabled` alone is enough. A device the kernel has but configd never learns
   gets 300 s from first seen, then `Enabled` alone is accepted, logged, and the line dropped.
2. **The mark is never truncated**: lines are `name<TAB>device` (old name-only lines still read).
   At shutdown the new list is merged into an existing mark by device. Every change of the mark
   (merge, line removal, deletion) runs under `locked_rewrite`, so the watchdog, shutdown and
   `ks netrestore` do not overwrite each other. Names pass through `ENVIRON`, not the awk command line;
   a service whose name has a tab is left on at shutdown (it could not be written back).
3. **Tried on every watchdog pass** while the mark exists; every `networksetup` is killed after 3 s;
   failures logged at most every 30 s. `net_guard` runs in `watch_pass` right after `guard`, so a
   slow or failed pf step cannot delay it.
4. **The network always comes back**: 90 s after the boot's first-seen time (below) it is turned on
   whatever the rules do (and the watchdog itself has been up 90 s, or the first-seen time predates its
   start by 90 s: a wall clock jumping forward, bad RTC then NTP, must not open the network before the
   rules. `SECONDS` ignores jumps; the age at start, `age - (now - start)`, is jump-neutral after start),
   and logged; while that still fails, `NETWORK STILL OFF` once a minute. A Mac
   without network is worse than an open boot window. There is no «old mark, so on at once» shortcut:
   after a night with the Mac off the mark is old too, and turning the network on at once would open
   the boot window the guard exists for.
5. A service renamed since is found by its device; one that is gone (no name, no device) is dropped.
6. The watchdog switched off in Login Items restores an existing mark (nothing else would).
7. **First seen.** `/Library/KillSwitch/net-guard-seen` (644) holds `<kern.bootsessionuuid> <epoch>` (`kern.boottime` moves when the clock is stepped early in boot; an old numeric id reads as another boot; epochs are read base 10, an unusable one is rewritten now). It is
   written once per boot, when the watchdog first sees the mark, and survives watchdog restarts and
   HUP. The 90 s fallback and the 20 s rules count from that epoch, not from the process start
   (`SECONDS`; see 4). The watchdog does not touch the mark at start. The app shows «Сеть выключена» when
   the mark exists and the watchdog is gone **or** 20 s have passed since first seen (rechecked once
   those 20 s are up). Without a usable first-seen file of this boot the banner counts from the later of the mark's mtime and the boot time, so a daemon stuck before `net_guard` still shows it; `ks netrestore` refuses only while all hold: first seen under 20 s ago, the watchdog job is loaded, the guard is wanted (no kill-switch flag, or the VPN is on) and the rules are not loaded; otherwise it turns the network on.
8. uninstall.sh: keeps its root re-exec; `ks netrestore`, then, as the last chance, every disabled
   service on en*/bridge* (a mark lost by 0.19 cannot be trusted), with its own timeout on
   `networksetup`, and only then removes /Library/KillSwitch.

Tests: Helper/tests/netguard.sh (a stateful fake networksetup: `on` that does nothing twice or
never, a late interface, `(*)` lines, rename and deletion, old marks, Login Items, the 20 s and 90 s rules from the first-seen file, a
hanging networksetup, uninstall without a mark); Tests/NetworkMarkTests.swift for the banner.

## Consequences

- Known limit: uninstall's last chance also turns on a physical service the user had disabled
  himself. Accepted: a Mac left without network is the worse failure.
- Any SIGTERM to the watchdog (Activity Monitor, `kickstart -k`) still turns the network off; it now
  comes back within 90 s at the latest.
- Still to check on a live Mac before release: two restarts in a row, Wi‑Fi works after each.
