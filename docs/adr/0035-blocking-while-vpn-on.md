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
- Not covered: the boot window before the watchdog loads the rules (Mullvad documents the same gap).
