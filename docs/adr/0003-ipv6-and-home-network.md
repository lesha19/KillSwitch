# ADR 0003: IPv6 is blocked, not tunnelled; the home network stays a pf switch

- Status: accepted (0.10)
- Date: 2026-10-10

## Context

Russian mobile and home networks increasingly hand out IPv6. A kill switch that only thinks in
IPv4 leaks the moment an app picks an IPv6 route. We checked what 0.9.1 does:

- The core's config has `ipv6: false` and `dns.ipv6: false`. In mihomo 1.19.32 `ipv6: false`
  clears `tun.inet6-address` (config.go `parseIPV6`), so the TUN gets no IPv6 address and no IPv6
  traffic enters the tunnel.
- pf (`ks rules`) is default-deny for both families. IPv6 passes only to link-local and
  multicast (`fe80::/10`, `ff00::/8`: neighbour discovery, router solicitation, Bonjour, AirDrop)
  and, for Tailscale, to the tailnet `fd7a:115c:a1e0::/48` on the Tailscale utun. A global IPv6
  destination therefore hits `block drop out quick all`; apps fall back to IPv4 through the VPN.
- One gap: a router announcing its DNS server on a link-local address (RDNSS, e.g. `fe80::1`)
  passed through the link-local rule, so with the VPN off the router's DNS saw every name even
  with «Адреса сайтов через роутер» off. The IPv4 equivalent was already blocked.

The «home network» switch (`lan`, default on since the first version) already existed as
«Домашняя сеть» in Settings → Защита.

## Decision

- Keep IPv6 off in the core and blocked in pf rather than tunnelling it: most VPN servers of our
  users have no IPv6 exit, and a half-working IPv6 tunnel is worse than none.
- Close the RDNSS gap: `block drop out quick inet6 proto { tcp udp } to { fe80::/10, ff00::/8 }
  port 53` before the link-local pass, unless both `lan` and `dns` are on (the same condition
  under which the router's IPv4 DNS is allowed).
- Keep `lan` default **on** (unchanged behaviour), renamed in the UI to «Доступ к домашней сети».
  It stays a pf-only switch: the core always excludes the private ranges and 100.64.0.0/10 from
  the TUN routes (`route-exclude-address`), so with the switch off LAN traffic is blocked by pf,
  never sent to a VPN server. Unique-local IPv6 (`fc00::/7`) is not added to the LAN set: home
  NAS boxes answer on IPv4 and link-local, and ULA would also match some carrier networks.
- Tests: `Helper/tests/rules.sh` (no IPv6 pass beyond link-local/multicast/tailnet, the RDNSS
  block, `lan` on/off, the final block), `Helper/tests/core-config.sh` (`ipv6: false`, no
  `tun.inet6-address`, private ranges excluded from the TUN).

## Consequences

- With the VPN off and protection on, a Mac on an IPv6-only DNS router has no names unless
  «Адреса сайтов через роутер» is on — the same as on IPv4.
- The content filter (second layer) still allows link-local without a port check; it is a
  backstop for pf, not the DNS policy.
