# ADR 0026: NetBird's daemon passes pf for its own flows only

- Status: accepted (Unreleased, issue #44)
- Date: 2026-10-11

## Context

0.18.0 lets NetBird's root daemon out past the VPN by its group: `pass out quick group
_ksnetbird` (Helper/ks `rules()`, `netbird_sync`). The 0.18.0 security review noted that this
passes everything the daemon sends, not only what NetBird itself needs.

What the daemon sends, from NetBird v0.78.2 source and this Mac (NetBird Cloud, 0.78.2):

- Sockets made with NetBird's own dialer/listener (`client/net`, `nbnet`) are bound to the
  physical interface with `IP_BOUND_IF` (`client/net/net_darwin.go`, `dialer_init_darwin.go`), so
  they leave past any VPN: management and signal gRPC (`client/grpc/dialer_generic.go`), relay
  over WebSocket or QUIC (`shared/relay/client/dialer/ws|quic`), ICE/STUN/TURN (`client/internal/
  stdnet`) and WireGuard with its ICE mux (`client/iface/bind`, `udpmux`).
- Observed: TCP from the daemon only to port 443 (api.netbird.io, signal.netbird.io, relays
  `rels://…:443`, `turns:turn.netbird.io:443?transport=tcp`); UDP from `*:51820` only (WireGuard
  and the ICE mux); STUN at `stun.netbird.io:443` and `:5555` (UDP). Peers' WireGuard ports are
  whatever each peer uses (default 51820, random behind NAT), so UDP cannot be limited by port.
- Self-hosted defaults (`infrastructure_files/base.setup.env`, `turnserver.conf.tmpl`):
  management 33073, signal 10000, relay 33080 (`rel://`), coturn 3478 and TLS 5349; the newer
  combined setup puts all of it behind 443.
- Everything else uses plain `net.Dialer` and follows the routing table: the DNS upstream
  resolver (`client/internal/dns/upstream_general.go`, `ExchangeWithFallback`: UDP then TCP to the
  nameserver group's servers, port 53, or the Mac's original nameservers; on this Mac
  `127.0.0.1:53`) and a routing peer's userspace forwarder (`client/firewall/uspfilter/
  forwarder`). While our VPN is the default route they go into the VPN; they leave directly only
  when the routing table sends them to Wi‑Fi/Ethernet, e.g. with the VPN down, which is exactly
  when the broad group rule let them out.
- The netstack SOCKS5 proxy (`client/iface/netstack`) dials inside NetBird's netstack, so what
  leaves is WireGuard UDP to a peer, NetBird's own tunnel like Tailscale's.
- NetBird resolves its own hostnames through the system resolver (our DNS), not from its group.

## Decision

The group gets three rules instead of one, after loopback, the VPN and the LAN passes and before
the final block:

    block drop out quick proto { tcp udp } to any port { 53, 853 } group _ksnetbird
    pass out quick proto udp group _ksnetbird keep state
    pass out quick proto tcp to any port { 80, 443, 3478, 5349, 10000, 33073, 33080 } group _ksnetbird flags any keep state

- DNS (53), DoT and DoQ (853) from the daemon never leave directly: its upstream resolver goes
  through the VPN or not at all. DNS to the LAN follows the LAN/DNS settings as before.
- UDP passes to any port: WireGuard to peers, STUN, QUIC relays.
- TCP passes only to NetBird's ports (fixed list in `NB_TCP_PORTS`).

Destinations are not pinned: relays and TURN servers come from the management server and change,
and reading them from `netbird status -d` would need the CLI in the rule path and a new root file.

## Consequences

- A self-hosted NetBird on other TCP ports cannot reach its servers with protection on (peers stay
  «Connecting», `netbird status` shows management disconnected). Add the port to `NB_TCP_PORTS`.
- Still passed while the VPN is down: a routing peer's or exit node's forwarded UDP, and its
  forwarded TCP to the listed ports. Closing that needs telling NetBird's bound sockets from its
  unbound ones, which pf cannot do by group.
