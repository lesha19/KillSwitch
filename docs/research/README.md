# Research and roadmap

Research notes written by agents for the owner, one file per topic. Decisions live in
`docs/adr/`, work items in GitHub issues (lesha19/KillSwitch).

| File | Topic | Leads to |
|---|---|---|
| [mullvad-ivpn-gap-2026-10.md](mullvad-ivpn-gap-2026-10.md) | Mullvad and IVPN desktop features vs KillSwitch | #11–#18, #20 |
| [multi-core-2026-10.md](multi-core-2026-10.md) | Protocols per core, Xray / sing-box next to mihomo | #9 (done), #10, #19, #31 |
| [incy-2026-10.md](incy-2026-10.md) | INCY client features | #22–#30 |
| [wireguard-full-2026-10.md](wireguard-full-2026-10.md) | WireGuard at Mullvad/IVPN level: PQ, DAITA, obfuscation | #21 |
| [doodle-subscription-2026-10.md](doodle-subscription-2026-10.md) | DoodleVPN subscription vs StorkVPN | panel template, #20, #22 |

## Owner decisions (2026-10-10)

- KillSwitch is a Swiss-army knife: every protocol and core that is reasonably possible.
- Xray becomes the main core, chosen in settings: Xray (Happ-equivalent routing, mihomo only as
  TUN/kill-switch shell), pure Xray-TUN, or Mihomo (#31).
- WireGuard with everything Mullvad/IVPN have that can work against our own server (#21);
  server-side changes on the LT node need the owner's yes per change.
- Routing comes only from the subscription; the app shows all of it (#8, ADR 0013).
- The owner is a single user in Belarus: Belarusian and Russian sites go direct.
- Open: project licence (decides whether Mullvad's GPL code can be used, even as a separate process).

## Released

- 0.15 (2026-10-10): routing only from the subscription + «Трафик» (#8), all mihomo protocols and
  links (#9), daemon self-location fix for the passwordless helper upgrade.
