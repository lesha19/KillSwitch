# ADR 0035: the VPN blocks everything outside it from Connect to Disconnect, whatever «защита» says

- Status: accepted (0.20.0); amends ADR 0012 and ADR 0020 (their «pf blocks meanwhile» held only with
  protection on)
- Date: 2026-10-12

## Context

Measured on the owner's Mac, 2026-10-12: Sparkle installed 0.19.1 at 17:02:07, the helper upgraded
itself ~22 s later as designed, rebuilt the Xray config and restarted the core: `events.log` has
«core config rebuilt by the new helper» at 17:02:32 and «core not running: DNS restored» at 17:02:39,
the tunnel was back at 17:02:43. Protection had been off since 2026-10-11 14:42. With protection off
the anchor is empty (`ks off` flushes it), so for those ~10 s everything went out directly with the
real IP. 2026-10-11 15:45 the same at the previous update. The same gap opens on every core restart
KillSwitch makes itself: a server switch (Xray has no reload API), a settings change, MTU, a
subscription refresh.

The owner (2026-10-12): «самая важная функция — чтобы при обновлении никак невозможно было увидеть
реальный IP; VPN может отключаться, но киллсвитч должен быть активен всегда». Asked where the
blocking should hold, he chose «always while the VPN is on, like Mullvad», and after a study of
Mullvad and IVPN (docs/research/mullvad-ivpn-blocking-2026-10.md) confirmed copying Mullvad.

Mullvad, from its source: the kill switch cannot be turned off; every state between Connect and an
explicit Disconnect (Connecting, Connected, Disconnecting, Error) blocks; «Lockdown mode» only adds
blocking in Disconnected. An update keeps the rules: the preinstall moves the old daemon into a
blocking state and keeps its target state, SIGTERM on macOS never counts as user-initiated, the pf
rules stay in the kernel, the new daemon reads the target state, keeps the rules and connects.
Error blocks with no timeout; the way out is Disconnect. IVPN ties its firewall to the GUI and does
not reconnect after an upgrade, so it is not the model.

## Decision

- **The VPN is on** from «Подключить» (`ks core on`) until an explicit «Отключить» (`ks core off`),
  whatever happens in between: connecting, connected, a restart by KillSwitch, a server switch, a
  dropped or dead server, a core that does not start, a helper upgrade, a helper or core crash, a
  reboot with the core enabled. This target is kept by root (a file under `/Library/KillSwitch`),
  written by `core on`, removed only by `core off`; nothing else clears it.
- **While the VPN is on, pf blocks** exactly as with protection on (the same `rules()`: the tunnel,
  the servers for the core's group, LAN and the other exceptions the user set), whatever the
  protection switch, a pause or «выключено» say.
- **«Защита»** (protection) keeps its switch and now means Mullvad's lockdown: blocking also while
  the VPN is off. Off or paused, and the VPN off → no blocking, as before.
- **No timeout.** If the VPN cannot come back, the Mac stays without internet until it does or the
  user presses «Отключить VPN».
- **Updates.** The upgrade path never leaves a moment without the rules while the VPN is on, even
  when the helper being replaced is 0.19.x (its watchdog flushes rules while protection is off, so
  the new watchdog must take over before any core restart). The core is never disabled by an
  upgrade while the VPN is on; it comes back by itself.
- **The screen.** While the VPN is on but not connected: «Интернет закрыт: VPN переподключается»
  with «Отключить VPN». Connected with protection off is «Защищено» (nothing can leak while the VPN is
  on). If the VPN is on and the rules are not loaded, a red notice that traffic may be leaking. The
  «Журнал защиты» gets a line per gap: how long the internet was closed and why.

## Consequences

- A user with protection off loses internet while the VPN reconnects or fails, until it is back or
  they press «Отключить VPN». That is the point.
- Failover and transport escalation, limited to protection on because a restart leaked, are safe
  whenever the VPN is on.
- A failed install can leave the Mac blocked with the VPN on; «Отключить VPN» (app, menu bar,
  `killswitch` CLI) or `ks core off` gets out; uninstall flushes as before.
- Tests that asserted «the upgrade never touches pf» and «rules found loaded while off are flushed»
  change meaning: rules are flushed while off only when the VPN is off.
- The boot window: covered as with protection on (see the addendum: the shutdown guard turns the
  physical network off at shutdown while the VPN is on, and the watchdog turns it back on only once
  the rules block). Not covered, as with protection on: the boot window with the guard off
  (`wifiguard=0`) or after an unclean shutdown (Mullvad documents the same gap).

## Addendum (0.20.0): the implementation, #54 — решено агентом, можно поменять

- **The target file** is `/Library/KillSwitch/vpn-on` (root, 644, the epoch of «Подключить»). `ks core
  on` writes it after its own checks (core installed, a config, no other VPN up) and loads the rules
  before the core starts; `ks core off` boots the core out, waits until launchd has it gone, removes
  the file, then flushes the anchor only if the off/pause flag is there. A refused `core on` writes
  nothing; a core that does not start keeps it (blocked until «Отключить VPN», Mullvad's Error state;
  the screen shows «Подключение затянулось» with «Отключить VPN», see below). A core that does not stop at `core off`
  keeps the file and the rules and fails (the button can be pressed again). Written through a
  unique temporary file. `$VPN_ON` and `$GAPF` in ks; a sourced ks (the tests) points them nowhere
  unless the test sets its own.
- **Serialised** (review of #56): `core on`, `core off` and `core restart` take the core lock like
  import, select and refresh, so «Отключить» pressed during «Подключить» (whose config rebuild takes
  seconds) runs after it, never in the middle; `core on` rebuilds in its own process (a second ks
  would wait for the lock it holds). The app shows connected with neither `vpn=1` nor protection on
  as `unblocked` «Трафик может идти мимо VPN», never «Защищено».
- **«Перезапустить VPN»** is `ks core restart` (passwordless, like `core on`): with the VPN on, the
  rules asserted and the core restarted in place (`kickstart -k`, or `core on` when the job is not
  loaded); `vpn-on` and the rules stay. The app no longer runs `core off` then `core on`, which
  opened pf and left no core for seconds.
- **Standby** (ADR 0018) never while our VPN is on: during our own restart another program's 198.18
  tunnel and our core momentarily gone made the rules pass everything. With the VPN on the rules
  block, that VPN included (its server is open only to our core); «Отключить VPN» brings standby
  back. This replaces item 7 of #54 («standby keeps its behaviour when our VPN is on but not
  connected»), decided on review.
- **The watchdog** (`guard`) treats the flag as before only while the file is absent; with it, the
  rules are checked and reloaded as with protection on, and `protection=` in `daemon-state` still
  says off/paused (the switch). Two new lines there: `vpn=0|1` and `blocking=0|1` (our rules in
  place). `ks off`/`ks pause` flush only with the VPN off. `ks state` is unchanged: `on` means the
  rules are loaded. The shutdown guard (network off at shutdown) and `ks netrestore` count the VPN on
  as protection on, so the boot window stays closed with protection off too. The VPN turning on or
  off makes the next pass a full one, so `blocking=` follows at once (no false red notice right
  after «Подключить»). Uninstall removes `vpn-on` before it stops the watchdog, whose shutdown guard
  would otherwise turn the network off.
- **The upgrade ordering** (install.sh): (1) put the new files in place; (2) a core job loaded and
  not disabled by 0.19 writes `vpn-on` (migration; a disabled one would not start after a reboot); (3) HUP the watchdog (also when the ks in place is already new
  but `daemon-state` has no `vpn=` line: an install that stopped after the rename); (4) with the VPN
  on, wait up to ~30 s until `daemon-state` says `vpn=1` and `blocking=1` — only the new watchdog
  writes those, and only after its first pass loaded the rules, so the 0.19 watchdog (which flushes
  while protection is off) is gone by then; no takeover fails the install before anything of the
  core is touched (no marker, the app runs it again); (5) only then `core_update` (`_regen`, binary,
  geodata, plist restarts). `launchctl disable` of the core is skipped while `vpn-on` exists. Proved
  in Helper/tests/upgrade.sh with a fake 0.19 watchdog that keeps flushing for several polls after
  the HUP: every core restart and the rebuild see the rules loaded.
- **pf states: no kill.** Our transitions into blocking start from an empty anchor (protection off):
  pf's default pass creates no state, and our own `keep state` rules are not loaded then, so no old
  direct connection has a state that would let it keep flowing — its next packet meets the new
  rules. Within blocking (a restart, a server switch) every state was created by our rules and is
  still allowed by them. A blanket `pfctl -F states`/`-k` would cut the core's own server
  connection, LAN, Tailscale and NetBird for nothing, and pfctl cannot kill states by our anchor or
  group. Not covered: states made under the standby rule (ADR 0018) when standby ends — unchanged
  from before. To verify live: a long direct TCP connection opened with protection and VPN off
  stops at «Подключить».
- **Failover and escalation** run whenever `blocking=1` and our core runs (not in standby).
- **«Журнал защиты»**: a gap is the VPN on and our core not running or its tunnel not up. Its start
  is in `/Library/KillSwitch/vpn-gap` (`<epoch> <boot id>`), so the watchdog restarting in place
  keeps it; a gap from before a reboot is dropped. At its end one event: `internet closed for <n>
  s: update|server switch|VPN off|reconnect`, the cause from the last matching event from 30 s
  before the gap began («new helper», «failover (», «escalate (», «core: … -> …»). The app shows
  «Интернет был закрыт 8 с: обновление» (· «смена сервера» · «до отключения VPN» ·
  «переподключение»; over a minute «2 мин 5 с»).
- **The screen** (round 2 of the review, like Mullvad's Connecting / Reconnecting): `reconnecting`
  = the VPN on, its tunnel up at some point since «Подключить» and not up now (a drop, a restart, an
  update, a server switch), whatever the switch. The first connect (no tunnel yet since
  «Подключить», a core that does not start included) stays `connecting` → `stuck` after 15 s, with
  `closed`: the line «Интернет закрыт, пока VPN подключается» / «Сервер не отвечает, интернет
  закрыт. Попробуй другой.», «Отключить VPN» the main button of `connecting`, the second of `stuck`;
  Shortcuts' «Подключить» on `stuck` says to open KillSwitch instead of «уже подключается». «The
  tunnel was up» is the app's: the content of `vpn-on` (the epoch of «Подключить») stored when our
  tunnel is seen up, so it survives a relaunch and a reboot. Another VPN next to ours turned on is
  `otherVPN(vpnOn:)`: «KillSwitch включён, поэтому интернет мимо него закрыт. Отключи один из двух
  VPN.», «Отключить VPN» the second button and in the menu bar. `unblocked` has «Включить защиту»
  as its main button and no «Перезапустить VPN» (`core restart` needs the VPN on). Wording решено
  агентом, можно поменять.
- **One read per watchdog pass**: `watch_pass` reads `vpn-on` once (`VPN_PASS`) for what it reports
  (the state file, the gap, the full-pass trigger), so a «Подключить» landing mid-pass never shows
  `vpn=1 blocking=0` (the red notice) for a second; the flush of rules found loaded while off and
  `load`'s early return look at the file itself, so they never flush the rules «Подключить» just
  loaded (review 3).
- **An old watchdog at «Подключить»** (review 4): between install.sh putting the new ks in place and
  its HUP, the watchdog running is 0.19's, which flushes the rules every pass while protection is
  off, and the relaunched app connects at once. `core on` and `core restart` see it as install.sh
  does (`daemon-state` without `vpn=`), HUP it and wait up to ~30 s for `vpn=1 blocking=1` before
  the core starts; otherwise they fail first (`core on` removes the target it wrote).
- **Rules missing outrank the VPN's states** (review 4): the VPN on and `blocking=0` is
  `unblocked(vpnOn:)` «Трафик может идти мимо VPN» / «VPN включён, но правила защиты не
  загружены.» with «Восстановить службу…» and «Отключить VPN», never connecting, reconnecting or
  «Защищено» (pf refused the rules at «Подключить», say); `vpn-on` stays.
- **A core that does not stop** at `core off`: the job is disabled only after it is gone, so with
  `vpn-on` kept the job stays enabled (after a reboot the core runs, as the target says); DNS stays
  on the core, which still runs. The app clears its «Отключить pressed» mark when the command fails,
  so the next drop is told. Connected is `protected` with the VPN on or protection on, else
  `unblocked`. Red notice (first of the main screen's notices): «Трафик может идти мимо
  VPN.» / «VPN включён, но правила защиты не загружены. Восстанови службу.» with «Восстановить
  службу…», shown when `daemon-state` says `vpn=1` and `blocking=0` (without the watchdog's file:
  `vpn-on` exists and `ks state` is not `on`). Deep-link and Shortcuts rules are unchanged.
