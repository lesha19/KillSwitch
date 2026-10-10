# ADR 0018: protection stands by while only another VPN is up

- Status: accepted (Unreleased); amends ADR 0009
- Date: 2026-10-10

## Context

Measured on the owner's Mac (system logs, 2026-10-10, 18:17 and 22:22–22:26): Happ was connected
when the install (or «Включить защиту») loaded the rules. Happ's server is one of the
subscription's servers, and pf lets only the core's group `_ksvpn` reach those (servers-core).
Happ's own connection to it was cut, its tunnel stayed up with nothing behind it, and
`ks core on` refused to start ours while that tunnel was up. The Mac had no internet for 2–5
minutes, until Happ was turned off by hand. ADR 0009 accepted that protection blocks what the
other VPN sends around itself; it did not foresee that it also blocks the other VPN's own server.

## Decision

- **Standby** (`vpn_standby` in Helper/ks): a 198.18 tunnel is up (Happ, dropweb), none of the
  tunnels carries our address (`CORE_TUN_ADDR`) and our core is not running. Then `rules()`
  loads `pass out quick all flags any keep state` instead of the blocking rules. Damaged settings
  (ADR 0015) still win: lockdown first.
- It is not a mode anyone switches: the watchdog compares the tunnel list every second, so the
  blocking rules come back within a second of that VPN going down, and as soon as our TUN comes
  up. The install and «Включить защиту» go through the same `rules()`, so neither can cut a
  working VPN any more.
- The watchdog's state file says `standby=1`; the app shows the other VPN without the warning that
  protection blocks its direct sites: «KillSwitch не подключён. Пока работает другой VPN, защита
  ему не мешает и включится, когда он отключится.» The main button stays «Отключить Happ и
  подключить KillSwitch» (ADR 0009): it stops that VPN, waits for its tunnel to go, then starts
  ours. `ks core on` still refuses next to another tunnel (two TUNs fight over routes and DNS).
- Next to our running core another VPN changes nothing: the blocking rules stay (ADR 0009).

## Consequences

- While only another VPN runs, KillSwitch protects nothing: if that VPN drops, programs may go out
  directly for up to a second before the watchdog loads the blocking rules. That VPN is the
  person's choice; cutting it was worse (no internet at all, and no way back without the
  terminal or a manual switch-off).
- Tunnels outside 198.18 (WireGuard 10.x, IKEv2) are not a reason to stand by: they are not let
  through by pf anyway and our core can start next to them.
- Not verifiable here: the real Happ on the owner's Mac (it must not be disturbed); the first
  manual run of this build with Happ up settles it.
