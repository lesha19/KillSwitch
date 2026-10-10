# ADR 0009: another program's VPN is named and replaced on request

- Status: accepted (0.12)
- Date: 2026-10-10

## Context

Field report on 0.11: Happ (a Network Extension packet tunnel, `utun23`, default route via
198.18.0.1) was connected when the owner launched KillSwitch. Protection came on, our VPN did not
connect (auto-connect skips with `.otherVPN`), and lava.ru, ggsel, digiseller and other sites
stopped opening. `daemon-state` showed `tunnels=vpn:utun23`: the kill switch lets Happ's tunnel
through as a VPN, but Happ's profile sends Russian sites DIRECT through en0, and that is exactly
the traffic outside tunnels the kill switch blocks. The app said «Работает другой VPN. Отключи
другой VPN: два VPN мешают друг другу.» with a disabled «Подключить», which explained neither the
dead sites nor what to press.

## Decision

- The summary state `otherVPN` carries `blocksDirect` (protection on). Its line says KillSwitch is
  not connected and, with protection on, that sites the other VPN sends directly (often Russian
  ones) are blocked. It is a warning (orange), never «Защищено». The main screen and the popover
  (same `HomeView`) name the VPN: «Работает другой VPN (Happ)». The separate banner is gone; the
  summary carries it, lower banners still wait behind it.
- Who it is (`App/Core/OtherVPN.swift`, tested): `scutil --nc list` as the user, read-only. A
  connected service whose provider is not Tailscale (`io.tailscale.*`, let through on purpose) and
  not Apple's (`com.apple.*`, built-in IKEv2/L2TP — work VPNs that do not take the 198.18 tunnel
  address) is the other VPN; its configuration name is the name. Without one (dropweb and other
  Clash apps run their own TUN), a running app from a list of known VPN apps gives the name;
  otherwise «другой VPN».
- The main button «Отключить Happ и подключить KillSwitch» runs `scutil --nc stop <uuid>` for those
  services as the user (no password, no root; see Consequences for what is not verified yet), waits up to 10 s for the 198.18 tunnel to go, then connects ours (`ks core on` refuses
  while another tunnel is up anyway). Its tunnel going down is not reported as a VPN drop.
- If the tunnel stays (on-demand rules reconnect it, the app refuses, or nothing could be
  stopped), the line says to turn it off in that app and the button becomes «Открыть Happ»
  (the app found by the provider's bundle id or among running apps). With no app found the button
  is a disabled «Подключить», as before.
- Auto-connect stays explicit: it never stops another VPN. It skips as before, writes the reason
  in Settings and posts one notification «Работает другой VPN (Happ). KillSwitch не подключился
  сам, чтобы не выключать его без спроса.»
- While another VPN is up, «Ничего не отвечает — почему» (ADR 0006) is not probed: our servers are
  silent because the other tunnel took the routes, not because of the provider. The leak test
  says the tunnel it checked was another program's («Проверен другой VPN») instead of a plain
  «Утечек нет». The widget's VPN mark follows our tunnel only.

## Consequences

- One click from the broken state to ours, without a password.
- Not verified on the owner's Mac: whether `scutil --nc stop` stops Happ's packet tunnel from user
  level (the agent was not allowed to disconnect the real Happ). If it does not, the fallback
  («Открыть Happ») is what the person sees; the first manual test of 0.12 settles it.
- `scutil --nc list` runs after every state refresh while another VPN is up (a few ms).
- Not changed: the kill switch still lets another VPN's tunnel through, and still blocks what that
  VPN sends around itself. Allowing that would be a leak by definition.
