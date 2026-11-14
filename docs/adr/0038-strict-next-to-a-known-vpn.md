# ADR 0038: next to another VPN whose server was added by hand, protection blocks instead of standing by

- Status: accepted (Unreleased); amends ADR 0018 and ADR 0009. Решено агентом, можно поменять.
- Date: 2026-11-14

## Context

The owner (2026-11-14) uses Happ as the main VPN, always to one server (Lithuania, 88.216.62.46),
and wants the Mac to behave «as if it were plugged into the Lithuanian internet by a cable»: while
Happ is connected everything goes through it; while Happ is off, crashed, reconnecting or updating
there is no internet at all, and no site ever sees the real address. Our own core stays off.

Measured on the owner's Mac (0.21.0, 2026-11-14): `daemon-state` said `protection=on standby=1 vpn=0
blocking=1`, tunnels `vpn:utun6` (Happ, 198.18.0.1). Standby (ADR 0018) loads `pass out quick all`,
so `curl --interface en0 https://www.google.com/generate_204` answered 204 around the VPN, and when
Happ drops, programs go out directly for up to a second (and for as long as their pf states live).
`servers-manual` was empty; `servers` held only 88.216.62.46, which comes from our own subscription
and is therefore open only to the core's group. Happ's packet tunnel (`Tunnel`, run as the user)
connects to 88.216.62.46 on TCP 443 and 2083 from en0. The subscription gives that server as an IP
(KillSwitch's copy of the same subscription has `address 88.216.62.46`), so Happ needs no DNS lookup
to reconnect. Happ's own log (`access.log`) shows its profile sends Apple (17.0.0.0/8: iCloud mail
993, push 5223, iCloud 443), Yandex (77.88.21.125) and a few other addresses DIRECT.

ADR 0018 stands by because blocking cut Happ's own server, which was reachable only by our core.
`ks server-add` (Settings → «Адреса серверов для других VPN-программ») already opens a server to any
process, so a server added there no longer has that problem.

## Decision

- **Standby only while no server was added by hand.** `vpn_standby` is false when `servers-manual`
  (before the first `servers_migrate`, `servers`, as `rules()` reads it) is not empty. Then next to
  another VPN the ordinary blocking rules load: that VPN's tunnel (198.18) passes, the hand-added
  servers are reachable by any process, LAN, DHCP, Tailscale, NetBird and the exceptions as always,
  everything else on the physical interfaces is dropped.
- A hand-added server is the person saying «this is my other VPN's server»: no new switch. Adding
  the first address is the switch to the strict mode, removing the last one goes back to standby.
- `ks server-add` checks the new list (the rules for it are built with that list), so it checks the
  blocking rules, not the standby pass-all.
- Nothing changes while our VPN is on (ADR 0035 already never stands by) or with damaged settings
  (lockdown first).
- The app needs no change: `daemon-state` says `standby=0`, so the summary is the existing
  `otherVPN(blocksDirect: true)` line «KillSwitch не подключён. Сайты, которые тот VPN пускает
  напрямую (часто российские), защита блокирует.» — which is exactly what happens.

## Consequences

- With Happ up, nothing leaves around it except its own server, LAN, Tailscale/NetBird and the
  exceptions. With Happ down, the Mac has no internet; Happ can still reach its server and come back.
- What Happ's profile sends DIRECT stops working (blocked, not tunnelled): measured Apple addresses
  (iCloud mail, push, iCloud), Yandex and a few others; Russian sites that Happ routes DIRECT may
  fail. That is fixed in the subscription template (route them through the server), not here.
- If Happ switches to a server that is not in the list, it is cut, and the Mac has no internet until
  that server is added or the list is emptied (standby again). The owner uses one server.
- Old installs whose `servers-manual` was filled by `servers_migrate` (before the split, every server
  was «manual») lose standby next to another VPN; they get the 0.11-era behaviour of ADR 0009 for the
  other VPN's direct sites, and that VPN's server works only if it is in the list.
- Tailscale and NetBird keep going out directly as before (rules unchanged): tailscaled's WireGuard
  (UDP 41641) and STUN (UDP 3478), DERP relays and the control plane (tsrelays, TCP 80/443, UDP 3478),
  NetBird's daemon (UDP anywhere, TCP to its management/signal/relay ports). Those services and peers
  see the real address; no website does. Closing them is a separate decision.
- pf states made under standby (a direct connection opened before the first server was added) live
  until they close, as noted in ADR 0035.
- Not verifiable here (no pf, no Happ): the owner's first run with Happ settles it — `curl --interface
  en0` must fail, Happ must stay up, and with Happ off there must be no internet.
