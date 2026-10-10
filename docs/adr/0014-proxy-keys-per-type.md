# ADR 0014: every single-server protocol of the core, with the keys of its type only

- Status: accepted (Unreleased)
- Date: 2026-10-10
- Issues: #9 (cores phase 0), client side of #21

## Context

The helper took a proxy of the profile when its `type` was in `PROXY_TYPES` and copied it as it
came, minus `interface-name` and `routing-mark`. The owner wants every protocol the bundled core
already has (`docs/research/multi-core-2026-10.md`, phase 0). Checked against the pinned mihomo
1.19.32 (`mihomo -v`: build tag `with_gvisor` only; `adapter/parser.go`, `adapter/outbound/*.go`
of the tag; every type tried with `mihomo -t`):

- Outbound types: ss, ssr, socks5, http, vmess, vless, snell, trojan, hysteria, hysteria2,
  wireguard (AmneziaWG 1.0/1.5/2.0/3 in `amnezia-wg-option`), tuic, shadowquic, gost-relay, ssh,
  mieru, anytls, sudoku, masque, trusttunnel, openvpn, tailscale, zerotier, easytier, plus the
  built-ins direct, dns, reject, rematch. JLS, Restls, ShadowTLS and kcptun are shadowsocks plugins
  (and `*-opts` of vless/vmess/trojan/anytls), not types. VLESS `encryption` (ML-KEM-768 +
  X25519) and xHTTP `download-settings` are there.
- Not in this build: naive, juicity, tor, standalone jls/restls types.
- Some keys make the root core read a file: `certificate` and `private-key` of every TLS client
  (`component/ca`: text that is not PEM is a path, limited to the core's directory by mihomo's
  safe-path check) and ssh's `private-key` (a path unless it contains "PRIVATE KEY").
- Some keys dial somewhere else than `server`: tuic `ip`, xHTTP `download-settings.server`,
  hysteria2 `realm-opts` (a rendezvous URL and STUN servers), `dialer-proxy` (any proxy or group
  name, including DIRECT), vmess `tlsmirror-opts.connection-enrolment` (names outbounds).

## Decision

- `PROXY_TYPES` gains masque, trusttunnel, sudoku, shadowquic and openvpn. tailscale, zerotier
  and easytier stay out: they talk to their own control planes, relays and peers, so pf would have
  to let the core reach addresses outside the pinned list. gost-relay stays out until someone
  needs it (one server, would only need fixtures).
- After pinning, each proxy keeps only the keys mihomo 1.19.32 reads for its type (`proxy_keys`
  in `Helper/ks`), plus `name type server port tfo mptcp ip-version dialer-proxy smux`. Other keys
  are dropped, not refused: mihomo ignores them anyway, and subscriptions carry client-specific
  extras that should not break an import. `interface-name` and `routing-mark` are among the
  dropped ones.
- Refused, failing the whole import as any malformed profile does:
  - `certificate`/`private-key` at any depth that is not PEM text (WireGuard's and MASQUE's
    top-level `private-key` is a key, not a file; ssh's must hold a key);
  - `dialer-proxy` that is not another proxy or group of the profile;
  - hysteria2 `realm-opts`, vmess `tlsmirror-opts.connection-enrolment`;
  - a shadowsocks plugin other than obfs, v2ray-plugin, gost-plugin, shadow-tls, restls, jls,
    kcptun, and `plugin-opts` that is not an object.
- tuic `ip` must be a usable IPv4 address and goes into `servers`; the xHTTP download server is
  pinned like `server` (a host name is resolved by our DoH, replaced by its address, kept as the
  download `servername`) and goes into `servers`.
- pf is unchanged: the core's tcp and udp reach `servers` only, any port, so QUIC/UDP protocols
  (hysteria, hysteria2 with port hopping, tuic, wireguard, masque, shadowquic, openvpn over udp,
  mieru's port range) work and nothing else is opened.
- The app parses vmess://, anytls://, socks(5)://, http(s):// links and Xray's xHTTP `extra`
  (padding, XMUX, downloadSettings); its output uses only keys the helper keeps.

## Consequences

- A subscription that pointed a TLS certificate at a file of the core's directory, used
  `dialer-proxy: DIRECT`, or a hysteria2 realm now fails to import with a message naming the
  proxy (not checked against the live StorkVPN subscription).
- A key added in a later mihomo is dropped until `proxy_keys` lists it: updating the core means
  re-reading `adapter/outbound/*.go` of the new tag (`Helper/fetch-mihomo.sh`).
- Tests: `Helper/tests/core-protocols.sh` (per type: accepted, pinned, servers, pf rule; refusals),
  one `ok-<type>.json` fixture per protocol in `Helper/tests/fixtures` (also run by
  `core-config.sh` with `mihomo -t`), `Tests/ProxyLinkTests.swift`, `Tests/WireGuardTests.swift`.
